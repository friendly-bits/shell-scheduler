#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003


# Environment variables specifying parameters:
# SCHED_MAX_JOBS        Maximum number of concurrent jobs (integer >= 1)
# SCHED_TIMEOUT_S       Global scheduler timeout (seconds)
# SCHED_IDLE_TIMEOUT_S  Maximum allowed time without job completions (seconds)
# SCHED_DIR             Directory used to store scheduler FIFO. Defaults to /tmp if unset.

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
#                         <cmd> <scheduler_return_code> <running_pids>
#                       <running_pids> will normally be empty string, except when a timeout is reached or when scheduler is terminated before jobs complete

# JOB_DONE_CB           Optional command invoked after each completed job:
#                       Will be called like so:
#                         <cmd> <job_id> <job_return_code>

# SCHED_DISPATCH_TICK_CB  Optional, for testing only: called with <job_id> right after each job is dispatched in the initial scheduling loop.



### Helpers

is_valid_param() {
	check_var_chars "param" "${1}" "${2}" || return 1
	case "${1}" in
		sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|IFS)
			sch_fail_msg "${2}${2:+": "}param '${1}' is reserved for internal use."
			return 1
	esac
	:
}

check_var_chars() {
	local quiet
	[ "${1}" = -q ] && { quiet=1; shift; }
	case "${2}" in
		''|*[!a-zA-Z0-9_]*) false ;;
		*) : ;;
	esac &&
	{
		[ "${1}" != param ] ||
		case "${2}" in
			[a-zA-Z_]*) : ;;
			*) false
		esac
	} &&
	return 0

	[ -n "${quiet}" ] || sch_fail_msg "${3}${3:+": "}${1}${1:+ }'${2}' is empty string or contains incompatible characters."
	return 1
}

# 1: job ID
# 2: any number of <param=value> pairs
job_set_params() {
	local sch_me=job_set_params \
		sch_param sch_val sch_cur_params \
		sch_pair \
		sch_job_id="${1}"

	[ -n "${sch_job_id+x}" ] && shift

	check_var_chars "job ID" "${sch_job_id}" "${sch_me}" || return 1

	eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""

	for sch_pair; do
		case "${sch_pair}" in
			*=*) ;;
			*)
				sch_fail_msg "${sch_me}: Invalid key-value pair '${sch_pair}'."
				return 1
		esac

		sch_param="${sch_pair%%=*}"
		sch_val="${sch_pair#"${sch_param}="}"
		is_valid_param "${sch_param}" "${sch_me}" || return 1

		export -n "SCH_JOB_${sch_job_id}_${sch_param}=${sch_val}"
		case " ${sch_cur_params} " in
			*" ${sch_param} "*) : ;;
			*) sch_cur_params="${sch_cur_params}${sch_cur_params:+ }${sch_param}"
		esac
	done
	export -n "SCH_JOB_PARAMS_${sch_job_id}=${sch_cur_params}"
}

# For each param <P> assigns corresponding param value to variable named <P>
# 1: job ID
# 2: list of params
job_get_params() {
	local sch_me=job_get_params \
		sch_param \
	[ -n "${sch_job_id+x}" ] && shift
	check_var_chars -q "job ID" "${sch_job_id}" "${sch_me}" || return 1
	for sch_param; do
		is_valid_param "${sch_param}" "${sch_me}" || return 1
		eval "${sch_param}=\"\${SCH_JOB_${sch_job_id}_${sch_param}}\""
	done
	:
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

sch_finalize() {
	local sch_cb_rv sch_rv="${1}"

	trap ':' USR1 INT TERM

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	rm -f "${sch_ipc_fifo}"

	[ -z "${SCHED_FINALIZE_CB}" ] ||
		"${SCHED_FINALIZE_CB}" "${sch_rv}" "${SCH_RUNNING_PIDS}" ||
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

	"${DO_JOB_CB:?}" "${sch_job_id}" "${@}"
	exit "${?}"
}

# 1 = var name
refresh_remain_time()  {
	get_remain_time "${1}" || sch_finalize "${?}"
}

# Sets var named $1 to remaining time to ${SCH_PROC_TIMEOUT_S} or to ${SCH_IDLE_TIMEOUT_S}, whichever is lower
# If timeout is hit, returns code ${SCH_RV_GLOBAL_TIMEOUT} or ${SCH_RV_IDLE_TIMEOUT}
# 1 - var name to output remaining time
get_remain_time() {
	local gt_cur_time_cs gt_total_time_cs gt_remain_time_cs gt_idle_remain_time_cs rv
	export -n "${1}"=0

	sch_get_uptime_cs gt_cur_time_cs || return 1
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

process_done_record() {
	local \
		sch_done_pid \
		sch_done_rv \
		sch_done_id \
		_sch_remain_time_cs \
		_sch_cur_time_cs \
		_sch_running_pids \
		sch_running_padded \
		_sch_running_cnt \
		sch_read_t_s \
		sch_rem_time_var="${1:?}" \
		sch_pids_var="${2:?}" \
		sch_running_cnt_var="${3:?}" \
		sch_last_progr_time_var="${4:?}" \
		sch_job_ids="${5:?}" \
		sch_ipc_fifo="${6:?}" \
		sch_job_done_cb="${7}"

	eval \
		"_sch_remain_time_cs=\"\${${sch_rem_time_var}}\"" \
		"_sch_running_pids=\"\${${sch_pids_var}}\"" \
		"_sch_running_cnt=\"\${${sch_running_cnt_var}}\""

	[ -e "${sch_ipc_fifo}" ] ||
		sch_finalize 1 "FIFO file '${sch_ipc_fifo}' does not exist."

	sch_read_t_s=$(( (_sch_remain_time_cs + 99) / 100 ))
	[ "${sch_read_t_s}" -gt 0 ] &&
	read -t "${sch_read_t_s}" -r sch_done_pid sch_done_rv sch_done_id < "${sch_ipc_fifo}"

	refresh_remain_time "${sch_rem_time_var}"

	# Empty completion record: read -t timed out with nothing to report
	# Next call to process_done_record() will trigger timeout
	[ -n "${sch_done_pid}${sch_done_rv}${sch_done_id}" ] || return 0

	sch_is_uint "${sch_done_pid}" &&
	sch_is_uint "${sch_done_rv}" &&
	[ -n "${sch_done_id}" ] &&
	case " ${sch_job_ids} " in
		*" ${sch_done_id} "*) : ;;
		*) false ;;
	esac ||
	sch_finalize 1 "Malformed completion record: either bad PID '${sch_done_pid}' or bad RV '${sch_done_rv}' or bad job ID '${sch_done_id}'."

	sch_running_padded=" ${_sch_running_pids} "
	case "${sch_running_padded}" in
		*" ${sch_done_pid} "*) ;;
		*) sch_finalize 1 "Unknown PID '${sch_done_pid}'." ;;
	esac

	# Remove done pid from list
	_sch_running_pids="${sch_running_padded%%" ${sch_done_pid} "*} ${sch_running_padded##*" ${sch_done_pid} "}"

	# Remove leading/trailing whitespaces
	_sch_running_pids="${_sch_running_pids%"${_sch_running_pids##*[! ]}"}"
	_sch_running_pids="${_sch_running_pids#"${_sch_running_pids%%[! ]*}"}"

	_sch_running_cnt=$((_sch_running_cnt - 1))
	export -n \
		"${sch_running_cnt_var}=${_sch_running_cnt}" \
		"${sch_pids_var}=${_sch_running_pids}"

	sch_get_uptime_cs _sch_cur_time_cs || sch_finalize 1
	export -n "${sch_last_progr_time_var}=${_sch_cur_time_cs}"

	[ -z "${sch_job_done_cb}" ] ||
	"${sch_job_done_cb}" "${sch_done_id}" "${sch_done_rv}" ||
		sch_finalize ${?}

	return 0
}

# Convert any mix of spaces/tabs/newlines to single-space separators
sch_normalize_ids() {
	local \
		sch_had_f \
		IFS=" "$'\t'$'\n' \
		out_var="${1}"

	case "${-}" in
		*f*) sch_had_f=1 ;;
	esac

	set -f
	set -- ${2}
	IFS=" "
	export -n "${out_var}=${*}"
	[ -n "${sch_had_f}" ] || set +f
}

sch_fail_msg() {
	if [ -n "${SCHED_FAIL_MSG_CB}" ] && sch_is_cmd "${SCHED_FAIL_MSG_CB}"
	then
		"${SCHED_FAIL_MSG_CB}" "${@}"
	else
		printf '%s\n' "${@}" >&2
	fi
}

# 1: var name (for messages)
# 2: value
# 3: required(1/empty)
sch_check_cb() {
	[ -z "${2}" ] && [ -z "${3}" ] && return 0
	[ -z "${2}" ] && { sch_fail_msg "Required callback is missing (set via \${${1}})."; return 1; }
	sch_is_cmd "${2}" || { sch_fail_msg "Invalid value of ${1} '${2}'."; return 1; }
}

# 1: var name (for messages)
# 2: value
# 3: required(1/empty)
sch_check_uint() {
	[ -z "${2}" ] && [ -z "${3}" ] && return 0
	sch_is_uint "${2}" && [ "${2}" -ge 1 ] ||
		{ sch_fail_msg "Invalid value '${2}' of env var ${1}."; return 1; }
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
		SCH_RUNNING_PIDS \
		SCH_LAST_PROGRESS_TIME_CS \
		SCH_PROC_TIMEOUT_S="${SCHED_TIMEOUT_S:-900}" \
		SCH_IDLE_TIMEOUT_S="${SCHED_IDLE_TIMEOUT_S:-300}" \
		\
		sch_job_ids="${1?}"
	
	: "${sch_remain_time_cs}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via sch_start_job()

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB "${SCHED_FAIL_MSG_CB}" &&
	sch_check_cb SCHED_FINALIZE_CB "${SCHED_FINALIZE_CB}" &&
	sch_check_cb DO_JOB_CB "${DO_JOB_CB}" required &&
	sch_check_cb JOB_DONE_CB "${JOB_DONE_CB}" &&
	sch_check_cb SCHED_DISPATCH_TICK_CB "${SCHED_DISPATCH_TICK_CB}" || return 1

	# Check env vars
	sch_check_uint SCHED_MAX_JOBS "${SCHED_MAX_JOBS}" 1 &&
	sch_check_uint SCHED_TIMEOUT_S "${SCHED_TIMEOUT_S}" &&
	sch_check_uint SCHED_IDLE_TIMEOUT_S "${SCHED_IDLE_TIMEOUT_S}" || return 1

	# Removing trailing '/'
	sch_dir="${sch_dir%"${sch_dir##*[!/]}"}"

	[ -n "${sch_dir}" ] ||
		{ sch_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; return 1; }

	# Convert ${sch_job_ids} to space-separated list
	sch_normalize_ids sch_job_ids "${sch_job_ids}" || return 1

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

	local sch_had_f=
	case "${-}" in
		*f*) sch_had_f=1 ;;
	esac
	set -f

	for sch_id in ${sch_job_ids}; do
		[ -n "${sch_had_f}" ] || set +f
		while [ "${sch_running_jobs_cnt}" -ge "${SCHED_MAX_JOBS}" ] &&
			[ -e "${sch_ipc_fifo}" ]
		do
			process_done_record \
				sch_remain_time_cs \
				SCH_RUNNING_PIDS \
				sch_running_jobs_cnt \
				SCH_LAST_PROGRESS_TIME_CS \
				"${sch_job_ids}" \
				"${sch_ipc_fifo}" \
				"${JOB_DONE_CB}"
		done

		refresh_remain_time sch_remain_time_cs

		sch_running_jobs_cnt=$((sch_running_jobs_cnt + 1))

		sch_start_job "${sch_id}" "${@}" &
		sch_pid="${!}"

		SCH_RUNNING_PIDS="${SCH_RUNNING_PIDS}${SCH_RUNNING_PIDS:+ }${sch_pid}"

		[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
			"${SCHED_DISPATCH_TICK_CB}" "${sch_id}"
	done

	[ -n "${sch_had_f}" ] || set +f

	while [ "${sch_running_jobs_cnt}" -gt 0 ] &&
		[ -e "${sch_ipc_fifo}" ]
	do
		process_done_record \
			sch_remain_time_cs \
			SCH_RUNNING_PIDS \
			sch_running_jobs_cnt \
			SCH_LAST_PROGRESS_TIME_CS \
			"${sch_job_ids}" \
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
