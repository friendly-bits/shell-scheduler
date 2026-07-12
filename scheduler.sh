#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003


# Environment variables specifying parameters:
# SCHED_MAX_JOBS        Maximum number of concurrent jobs (integer >= 1)
# SCHED_TIMEOUT_S       Global scheduler timeout (seconds)
# SCHED_IDLE_TIMEOUT_S  Maximum allowed time without job completions (seconds)
# SCHED_DIR             Directory used to store scheduler FIFO. Defaults to /tmp if unset.
# SCHED_AUTO_PARAMS     Automatically assign and export job-specific param variables before starting each job (1 = on, unset or another value = off)

# Environment variables specifying callbacks:
#  (command name only - no arguments)

# DO_JOB_CB             Command implementing a job.
#                       Will be called like so:
#                         <cmd> <job_id> [extra_args_passed_to_scheduler...]

# SCHED_FAIL_MSG_CB     Optional command invoked to report scheduler errors:
#                       If not set, errors will be printed to STDERR.
#                       Will be called like so:
#                         <cmd> <message...>

# SCHED_FINALIZE_CB     Optional command invoked when the scheduler exits.
#                       Will be called like so:
#                         <cmd> <scheduler_return_code> <running_pids> <ok_job_ids> <fail_job_ids> <unfinished_job_ids> <undispatched_job_ids>
#                       <running_pids> will normally be empty string, except when a timeout is reached or when scheduler is terminated before jobs complete

# JOB_DONE_CB           Optional command invoked after each completed job:
#                       Will be called like so:
#                         <cmd> <job_id> <job_return_code>

# SCHED_DISPATCH_TICK_CB  Optional, for testing only: called with <job_id> right after each job is dispatched in the initial scheduling loop.



### Helpers

sch_is_included() {
	local delim="${3:-" "}"
	case "${delim}${2}${delim}" in
		*"${delim}${1}${delim}"*)
			return 0 ;;
		*)
			return 1
	esac
}

sch_append()
{
	sch_check_var_chars "var" "${1}" || return 1
	eval "${1}=\"\${${1}}\${${1}:+\"\${3:-" "}\"}\${2}\""
}

# 1: out var
# 2: element
# 3: cur list
# 4 (optional): delim
sch_rm_elem() {
	local sre_out_var="${1}" sre_e="${2}" sre_d="${4:- }"
	local sre_l="${sre_d}${3}${sre_d}"
	sre_l="${sre_l%%"${sre_d}${sre_e}${sre_d}"*}${sre_d}${sre_l##*"${sre_d}${sre_e}${sre_d}"}"
	sre_l="${sre_l%"${sre_l##*[!"${sre_d}"]}"}"
	sre_l="${sre_l#"${sre_l%%[!"${sre_d}"]*}"}"
	export -n "${sre_out_var}=${sre_l}"
}

sch_is_uint() {
	local _v
	for _v; do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

sch_is_cmd() {
	command -v "${1}" 1>/dev/null 2>&1
}

# 1 - var name for centiseconds output
sch_get_uptime_cs() {
	local __uptime i_cs cs s
	export -n "${1}="

	read -r __uptime _ < /proc/uptime &&
	case "${__uptime}" in
		''|*.*.*) false ;;
		*.*) ;;
		*) false ;;
	esac &&
	i_cs="${__uptime##*.}" &&
	case "${i_cs}" in
		'') cs=00 ;;
		?) cs="${i_cs}0" ;;
		??) cs="${i_cs}" ;;
		??*) cs="${i_cs%"${i_cs#??}"}"
	esac &&
	s="${__uptime%.*}" &&
	sch_is_uint "${s}" "${cs}" ||
	{
		sch_fail_msg "Failed to get uptime from /proc/uptime."
		export -n "${1}"=0
		return 1
	}
	cs="${s:-0}${cs:-00}"
	cs="${cs#"${cs%%[!0]*}"}"
	export -n "${1}=${cs:-0}"
}

# Get PID of current shell process
# 1 - var name for output
sch_get_cur_pid() {
	local __pid line
	export -n "${1:?}="

	while IFS= read -r line; do
		case "${line}" in
			Pid:*)
				__pid="${line##*[^0-9]}"
				break
			;;
		esac
	done < /proc/self/status

	sch_is_uint "${__pid}" || { sch_fail_msg "Failed to get current PID."; return 1; }
	export -n "${1}=${__pid}"
}

sch_is_valid_param() {
	sch_check_var_chars "param" "${1}" "${2}" || return 1
	case "${1}" in
		sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|IFS)
			sch_fail_msg "${2}${2:+": "}param '${1}' is reserved for internal use."
			return 1
	esac
	:
}

sch_check_var_chars() {
	case "${2}" in
		''|*[!a-zA-Z0-9_]*) false ;;
		*) : ;;
	esac &&
	{
		case "${1}" in
			param|var) false ;;
			*) : ;;
		esac ||
		case "${2}" in
			[a-zA-Z_]*) : ;;
			*) false
		esac
	} &&
	return 0

	sch_fail_msg "${3}${3:+": "}${1}${1:+ }'${2}' is empty string or contains incompatible characters."
	return 1
}

# 1 = var name
refresh_remain_time()  {
	get_remain_time "${1}" || sch_finalize "${?}"
}

# Sets var named $1 to remaining time to ${SCH_PROC_TIMEOUT_S} or to ${SCH_IDLE_TIMEOUT_S}, whichever is lower
# If timeout is hit, returns code ${SCH_RV_GLOBAL_TIMEOUT} or ${SCH_RV_IDLE_TIMEOUT}
# 1: var name to output remaining time
# 2 (optional): freshly retrieved uptime_cs
get_remain_time() {
	local gt_cur_time_cs gt_total_time_cs gt_remain_time_cs gt_idle_remain_time_cs rv
	export -n "${1}"=0

	if [ -n "${2}" ]; then
		gt_cur_time_cs="${2}"
	else
		sch_get_uptime_cs gt_cur_time_cs || return 1
	fi
	gt_total_time_cs=$((gt_cur_time_cs - SCH_INIT_UPTIME_CS))

	gt_remain_time_cs=$((SCH_PROC_TIMEOUT_S*100 - gt_total_time_cs))
	gt_idle_remain_time_cs=$(( SCH_IDLE_TIMEOUT_S*100 - (gt_cur_time_cs-SCH_LAST_PROGRESS_TIME_CS) ))

	if [ ! "${gt_remain_time_cs}" -gt 0 ]
	then
		sch_fail_msg "Processing timeout (${SCH_PROC_TIMEOUT_S} s) for scheduler (PID: ${SCH_PID})."
		rv="${SCH_RV_GLOBAL_TIMEOUT}"
	elif [ ! "${gt_idle_remain_time_cs}" -gt 0 ]
	then
		sch_fail_msg "Idle timeout (${SCH_IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCH_PID})."
		rv="${SCH_RV_IDLE_TIMEOUT}"
	fi

	if [ "${gt_idle_remain_time_cs}" -lt "${gt_remain_time_cs}" ]; then
		gt_remain_time_cs="${gt_idle_remain_time_cs}"
	fi

	export -n "${1}=${gt_remain_time_cs}"

	return "${rv:-0}"
}

# 1: job ID
# 2: any number of <param=value> pairs
job_set_params() {
	local sch_me=job_set_params \
		sch_param \
		sch_val \
		sch_cur_params \
		sch_pair \
		sch_pair_seen \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift

	sch_check_var_chars "job ID" "${sch_job_id}" "${sch_me}" || return 1

	for sch_pair; do
		sch_pair_seen=1
		case "${sch_pair}" in
			*=*) ;;
			*)
				sch_fail_msg "${sch_me}: Invalid key-value pair '${sch_pair}'."
				return 1
		esac

		sch_param="${sch_pair%%=*}"
		sch_val="${sch_pair#"${sch_param}="}"
		sch_is_valid_param "${sch_param}" "${sch_me}" || return 1

		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""
		sch_is_included "${sch_param}" "${sch_cur_params}" ||
		sch_append "SCH_JOB_PARAMS_${sch_job_id}" "${sch_param}" ||
			return 1
		export -n "SCH_JOB_PARAM_${sch_job_id}_${sch_param}=${sch_val}"
	done

	[ -n "${sch_pair_seen}" ] &&
		return 0

	sch_fail_msg "${sch_me}: no params specified."
	return 1
}

# For each param <P> assigns corresponding param value to variable named <P>
# 0 (optional): '-export'
# 1: job ID
# Any extra args: "sch_all" or a list of params, one per argument
job_get_params() {
	local sch_export
	[ "${1}" = '-export' ] && { sch_export="export "; shift; }

	local sch_me=job_get_params \
		sch_param \
		sch_had_f \
		sch_job_params \
		sch_param_seen \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift
	sch_check_var_chars "job ID" "${sch_job_id}" "${sch_me}" || return 1

	[ "${*}" = sch_all ] && {
		case "${-}" in
			*f*) sch_had_f=1 ;;
		esac
		eval "sch_job_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""
		[ -n "${sch_job_params}" ] || return 0

		set -f
		set -- ${sch_job_params}
		[ -n "${sch_had_f}" ] || set +f
	}

	for sch_param; do
		sch_param_seen=1
		sch_is_valid_param "${sch_param}" "${sch_me}" || return 1
		eval "${sch_export}${sch_param}=\"\${SCH_JOB_PARAM_${sch_job_id}_${sch_param}}\""
	done

	[ -n "${sch_param_seen}" ] &&
		return 0

	sch_fail_msg "${sch_me}: no params specified."
	return 1
}

sch_finalize() {
	local sch_cb_rv sch_unfinished_ids \
		sch_rv="${1}"

	trap ':' USR1 INT TERM

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	rm -f "${sch_ipc_fifo}"

	# Compute sch_unfinished_ids
	set -f
	for sch_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_id}" "${SCH_OK_IDS} ${SCH_UNDISPATCHED_IDS} ${SCH_FAIL_IDS}" ||
			sch_append sch_unfinished_ids "${sch_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	[ -z "${SCHED_FINALIZE_CB}" ] ||
		"${SCHED_FINALIZE_CB}" "${sch_rv}" "${SCH_RUNNING_PIDS}" "${SCH_OK_IDS}" "${SCH_FAIL_IDS}" "${sch_unfinished_ids}" "${SCH_UNDISPATCHED_IDS}" ||
		{
			sch_cb_rv=${?}
			[ "${sch_rv}" = 0 ] && sch_rv="${sch_cb_rv}"
		}

	exit "${sch_rv}"
}

sch_start_job() {
	local \
		sch_job_pid \
		sch_job_rv \
		sch_job_id="${1:?}"

	shift

	trap '
		sch_job_rv=${?}
		printf "%s %s %s\n" "${sch_job_pid}" "${sch_job_rv}" "${sch_job_id}" >&3 2>/dev/null
		exit "${sch_job_rv}"
	' EXIT

	sch_get_cur_pid sch_job_pid || exit 1

	[ "${SCHED_AUTO_PARAMS}" = 1 ] &&
		{ job_get_params -export "${sch_job_id}" sch_all || exit 1; }

	"${DO_JOB_CB:?}" "${sch_job_id}" "${@}"
	exit "${?}"
}

process_done_record() {
	local \
		sch_done_pid \
		sch_done_rv \
		sch_done_id \
		_sch_remain_time_cs \
		_sch_cur_time_cs \
		_sch_running_pids \
		_sch_running_cnt \
		sch_read_t_s \
		sch_rem_time_var="${1:?}" \
		sch_pids_var="${2:?}" \
		sch_running_cnt_var="${3:?}" \
		sch_last_progr_time_var="${4:?}" \
		sch_ipc_fifo="${5:?}" \
		sch_job_done_cb="${6}"

	eval \
		"_sch_remain_time_cs=\"\${${sch_rem_time_var}}\"" \
		"_sch_running_pids=\"\${${sch_pids_var}}\"" \
		"_sch_running_cnt=\"\${${sch_running_cnt_var}}\""

	[ -e "${sch_ipc_fifo}" ] ||
		sch_finalize 1 "FIFO file '${sch_ipc_fifo}' does not exist."

	sch_read_t_s=$(( (_sch_remain_time_cs + 99) / 100 ))
	[ "${sch_read_t_s}" -gt 0 ] &&
	read -t "${sch_read_t_s}" -r sch_done_pid sch_done_rv sch_done_id < "${sch_ipc_fifo}"

	[ -n "${sch_done_pid}${sch_done_rv}${sch_done_id}" ] || {
		refresh_remain_time "${sch_rem_time_var}"
		# Empty completion record: read -t timed out with nothing to report
		# Next call to process_done_record() will trigger timeout
		return 0
	}

	sch_is_uint "${sch_done_pid}" &&
	sch_is_uint "${sch_done_rv}" &&
	[ -n "${sch_done_id}" ] &&
	sch_is_included "${sch_done_id}" "${SCH_JOB_IDS}" ||
		sch_finalize 1 "Malformed completion record: either bad PID '${sch_done_pid}' or bad RV '${sch_done_rv}' or bad job ID '${sch_done_id}'."

	sch_is_included "${sch_done_pid}" "${_sch_running_pids}" ||
		sch_finalize 1 "Unknown PID '${sch_done_pid}'."

	# Remove done pid from list
	sch_rm_elem _sch_running_pids "${sch_done_pid}" "${_sch_running_pids}"

	_sch_running_cnt=$((_sch_running_cnt - 1))
	export -n \
		"${sch_running_cnt_var}=${_sch_running_cnt}" \
		"${sch_pids_var}=${_sch_running_pids}"

	if [ "${sch_done_rv}" = 0 ]; then
		sch_append SCH_OK_IDS "${sch_done_id}"
	else
		sch_append SCH_FAIL_IDS "${sch_done_id}"
	fi || sch_finalize 1

	sch_get_uptime_cs _sch_cur_time_cs || sch_finalize 1
	export -n "${sch_last_progr_time_var}=${_sch_cur_time_cs}"

	[ -z "${sch_job_done_cb}" ] ||
	"${sch_job_done_cb}" "${sch_done_id}" "${sch_done_rv}" ||
		sch_finalize ${?}

	get_remain_time "${sch_rem_time_var}" "${_sch_cur_time_cs}" || sch_finalize "${?}"

	return 0
}

# Convert any mix of spaces/tabs/newlines to single-space separators
sch_normalize_ids() {
	local \
		IFS=" "$'\t'$'\n' \
		out_var="${1}"

	set -f
	set -- ${2}
	IFS=" "
	export -n "${out_var}=${*}"
	[ -n "${SCH_HAD_F}" ] || set +f
}

sch_fail_msg() {
	if [ -n "${SCHED_FAIL_MSG_CB}" ] && sch_is_cmd "${SCHED_FAIL_MSG_CB}"
	then
		"${SCHED_FAIL_MSG_CB}" "${@}"
	else
		printf '%s\n' "${@}" >&2
	fi
}

# 1: var name
# 2: required(1/empty)
sch_check_cb() {
	local val
	eval "val=\"\${${1}}\""
	[ -z "${val}" ] && [ -z "${2}" ] && return 0
	[ -z "${val}" ] && { sch_fail_msg "Required callback is missing (set via \${${1}})."; return 1; }
	sch_is_cmd "${val}" || { sch_fail_msg "Invalid value of ${1} '${val}'."; return 1; }
}

# 1: var name
# 2: required(1/empty)
sch_check_uint() {
	local val
	eval "val=\"\${${1}}\""
	[ -z "${val}" ] && [ -z "${2}" ] && return 0
	sch_is_uint "${val}" && [ "${val}" -ge 1 ] ||
		{ sch_fail_msg "Invalid value '${val}' of env var ${1}."; return 1; }
}


### Entry point
schedule_jobs() {
	local \
		SCH_RV_IDLE_TIMEOUT=81 \
		SCH_RV_GLOBAL_TIMEOUT=82 \
		SCH_RV_USR1=83 \
		SCH_RV_INT_TERM=84

	local \
		IFS=" "$'\t'$'\n' \
		SCH_PID \
		sch_remain_time_cs \
		SCH_INIT_UPTIME_CS \
		sch_id \
		sch_pid \
		sch_running_jobs_cnt=0 \
		sch_ipc_fifo \
		sch_dir="${SCHED_DIR:-/tmp}" \
		\
		SCH_HAD_F \
		SCH_UNDISPATCHED_IDS \
		SCH_OK_IDS \
		SCH_FAIL_IDS \
		SCH_RUNNING_PIDS \
		SCH_LAST_PROGRESS_TIME_CS \
		SCH_PROC_TIMEOUT_S="${SCHED_TIMEOUT_S:-900}" \
		SCH_IDLE_TIMEOUT_S="${SCHED_IDLE_TIMEOUT_S:-300}" \
		\
		SCH_JOB_IDS="${1?}"
	
	: "${sch_remain_time_cs}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via sch_start_job()

	# Register noglob state
	case "${-}" in
		*f*) SCH_HAD_F=1 ;;
	esac

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB &&
	sch_check_cb SCHED_FINALIZE_CB &&
	sch_check_cb DO_JOB_CB required &&
	sch_check_cb JOB_DONE_CB &&
	sch_check_cb SCHED_DISPATCH_TICK_CB || return 1

	# Check env vars
	sch_check_uint SCHED_MAX_JOBS required &&
	sch_check_uint SCHED_TIMEOUT_S &&
	sch_check_uint SCHED_IDLE_TIMEOUT_S || return 1

	# Removing trailing '/'
	sch_dir="${sch_dir%"${sch_dir##*[!/]}"}"

	[ -n "${sch_dir}" ] ||
		{ sch_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; return 1; }

	# Convert ${SCH_JOB_IDS} to space-separated list
	sch_normalize_ids SCH_JOB_IDS "${SCH_JOB_IDS}" || return 1

	SCH_UNDISPATCHED_IDS="${SCH_JOB_IDS}"

	# Main logic

	sch_get_uptime_cs SCH_INIT_UPTIME_CS &&
	sch_get_cur_pid SCH_PID ||
		return 1

	SCH_LAST_PROGRESS_TIME_CS="${SCH_INIT_UPTIME_CS}"

	sch_ipc_fifo="${sch_dir}/sched_ipc_${SCH_PID}"

	mkdir -p "${sch_dir}" &&
	rm -f "${sch_ipc_fifo}" &&
	mkfifo "${sch_ipc_fifo}" &&
	exec 3<>"${sch_ipc_fifo}" ||
		sch_finalize 1 "Failed to create FIFO '${sch_ipc_fifo}'."

	trap 'sch_finalize "${SCH_RV_USR1}"' USR1
	trap 'sch_finalize "${SCH_RV_INT_TERM}"' INT TERM

	# Start jobs
	set -f
	for sch_id in ${SCH_JOB_IDS}; do
		[ -n "${SCH_HAD_F}" ] || set +f
		while [ "${sch_running_jobs_cnt}" -ge "${SCHED_MAX_JOBS}" ] &&
			[ -e "${sch_ipc_fifo}" ]
		do
			process_done_record \
				sch_remain_time_cs \
				SCH_RUNNING_PIDS \
				sch_running_jobs_cnt \
				SCH_LAST_PROGRESS_TIME_CS \
				"${sch_ipc_fifo}" \
				"${JOB_DONE_CB}"
		done

		refresh_remain_time sch_remain_time_cs

		sch_running_jobs_cnt=$((sch_running_jobs_cnt + 1))

		sch_start_job "${sch_id}" "${@}" &
		sch_pid="${!}"

		sch_append SCH_RUNNING_PIDS "${sch_pid}" || return 1
		sch_rm_elem SCH_UNDISPATCHED_IDS "${sch_id}" "${SCH_UNDISPATCHED_IDS}"

		[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
			"${SCHED_DISPATCH_TICK_CB}" "${sch_id}"
	done

	[ -n "${SCH_HAD_F}" ] || set +f

	# Wait for running jobs
	while [ "${sch_running_jobs_cnt}" -gt 0 ] &&
		[ -e "${sch_ipc_fifo}" ]
	do
		process_done_record \
			sch_remain_time_cs \
			SCH_RUNNING_PIDS \
			sch_running_jobs_cnt \
			SCH_LAST_PROGRESS_TIME_CS \
			"${sch_ipc_fifo}" \
			"${JOB_DONE_CB}"
	done

	[ "${sch_running_jobs_cnt}" = 0 ] ||
	{
		refresh_remain_time sch_remain_time_cs
		sch_finalize 1 "Not all jobs are done: sch_running_jobs_cnt=${sch_running_jobs_cnt}"
	}

	sch_finalize 0
}
