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



### Helpers

is_uint()
{
	local _v
	for _v in "${@}"
	do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

is_cmd()
{
	command -v "${1}" 1>/dev/null 2>&1
}

# 1 - var name for centiseconds output
get_uptime_cs() {
	local __uptime i_cs gu_cs gu_s
	export -n "${1}="

	read -r __uptime _ < /proc/uptime &&
	case "${__uptime}" in
		''|*.*.*) false ;;
		*.*) ;;
		*) false ;;
	esac &&
	i_cs="${__uptime##*.}" &&
	case "${i_cs}" in
		'') gu_cs=00 ;;
		?) gu_cs="${i_cs}0" ;;
		??) gu_cs="${i_cs}" ;;
		??*) gu_cs="${i_cs%"${i_cs#??}"}"
	esac &&
	gu_s="${__uptime%.*}" &&
	is_uint "${gu_s}" "${gu_cs}" ||
	{
		sched_fail_msg "Failed to get uptime from /proc/uptime."
		export -n "${1}"=0
		return 1
	}
	gu_cs="${gu_s:-0}${gu_cs:-00}"
	gu_cs="${gu_cs#"${gu_cs%%[!0]*}"}"
	export -n "${1}=${gu_cs:-0}"
}

# Get PID of current shell process
# 1 - var name for output
get_curr_pid()
{
	local __pid line
	export -n "${1:?}="

	while IFS= read -r line
	do
		case "${line}" in
			Pid:*)
				__pid="${line##*[^0-9]}"
				break
			;;
		esac
	done < /proc/self/status

	is_uint "${__pid}" || { sched_fail_msg "Failed to get current PID."; return 1; }
	export -n "${1}=${__pid}"
}

finalize()
{
	local cb_rv rv="${1}"

	trap ':' USR1

	[ -n "${2}" ] && [ "${rv}" != 0 ] && sched_fail_msg "${2}"
	[ -n "${USR_TRIG}" ] && printf '\n%s\n' "Job scheduler is stopping on receipt of USR1 signal." >&2

	exec 3>&-
	rm -f "${sched_ipc_fifo}"

	[ -z "${SCHED_FINALIZE_CB}" ] ||
		"${SCHED_FINALIZE_CB}" "${rv}" "${running_pids}" ||
		{
			cb_rv=${?}
			[ "${rv}" = 0 ] && rv="${cb_rv}"
		}

	exit "${rv}"
}

start_job()
{
	local job_pid rv \
		job_id="${1:?}"

	shift

	get_curr_pid job_pid || exit 1

	trap '
		rv=${?}
		printf "%s %s %s\n" "${job_pid}" "${rv}" "${job_id}" >&3 2>/dev/null
		exit "${rv}"
	' EXIT

	"${DO_JOB_CB:?}" "${job_id}" "${@}"
	exit "${?}"
}

# 1 = var name
refresh_remaining_time() 
{
	get_remaining_time "${1}" || finalize "${?}"
}

# Sets var named $1 to remaining time to ${PROC_TIMEOUT_S} or to ${IDLE_TIMEOUT_S}, whichever is lower
# If timeout is hit, returns code ${SCHED_RV_GLOBAL_TIMEOUT} or ${SCHED_RV_IDLE_TIMEOUT}
# 1 - var name to output remaining time
get_remaining_time()
{
	local gt_cur_time_cs gt_total_time_cs gt_remaining_time_cs rv
	export -n "${1}"=0

	get_uptime_cs gt_cur_time_cs || return 1
	gt_total_time_cs=$((gt_cur_time_cs - SCHED_INIT_UPTIME_CS))

	gt_remaining_time_cs=$((PROC_TIMEOUT_S*100 - gt_total_time_cs))


	if [ ! "${gt_remaining_time_cs}" -gt 0 ]
	then
		sched_fail_msg "Processing timeout (${PROC_TIMEOUT_S} s) for scheduler (PID: ${SCHEDULER_PID})."
		rv="${SCHED_RV_GLOBAL_TIMEOUT}"
	elif [ ! "$(( IDLE_TIMEOUT_S*100 - (gt_cur_time_cs-LAST_PROGRESS_TIME_CS) ))" -gt 0 ]
	then
		sched_fail_msg "Idle timeout (${IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCHEDULER_PID})."
		rv="${SCHED_RV_IDLE_TIMEOUT}"
	fi

	case $((IDLE_TIMEOUT_S*100 - gt_remaining_time_cs)) in
		-*) gt_remaining_time_cs="$((IDLE_TIMEOUT_S*100))"
	esac

	export -n "${1}=${gt_remaining_time_cs}"

	return "${rv:-0}"
}

process_done_record()
{
	local \
		done_pid \
		done_rv \
		done_id \
		_remaining_time_cs \
		_cur_time_cs \
		_running_pids \
		_running_padded \
		_running_cnt \
		rem_time_var="${1:?}" \
		pids_var="${2:?}" \
		running_cnt_var="${3:?}" \
		last_progress_time_var="${4:?}" \
		job_ids="${5:?}" \
		ipc_fifo="${6:?}" \
		job_done_cb="${7}"

	eval \
		"_remaining_time_cs=\"\${${rem_time_var}}\"" \
		"_running_pids=\"\${${pids_var}}\"" \
		"_running_cnt=\"\${${running_cnt_var}}\""

	[ -e "${ipc_fifo}" ] ||
		finalize 1 "FIFO file '${ipc_fifo}' does not exist."

	local _read_t_s=$(( (_remaining_time_cs + 99) / 100 ))
	[ "${_read_t_s}" -gt 0 ] &&
	read -t "${_read_t_s}" -r done_pid done_rv done_id < "${ipc_fifo}"

	refresh_remaining_time "${rem_time_var}"

	# Empty completion record: read -t timed out with nothing to report
	# Next call to process_done_record() will trigger timeout
	[ -n "${done_pid}${done_rv}${done_id}" ] || return 0

	is_uint "${done_pid}" &&
	is_uint "${done_rv}" &&
	case " ${job_ids} " in
		*" ${done_id} "*) : ;;
		*) false ;;
	esac ||
	finalize 1 "Malformed completion record: either bad PID '${done_pid}' or bad RV '${done_rv}' or bad job ID '${done_id}'."

	_running_padded=" ${_running_pids} "
	case "${_running_padded}" in
		*" ${done_pid} "*) ;;
		*) finalize 1 "Unknown PID '${done_pid}'." ;;
	esac

	# Remove done pid from list
	_running_pids="${_running_padded%%" ${done_pid} "*} ${_running_padded##*" ${done_pid} "}"

	# Remove leading/trailing whitespaces
	_running_pids="${_running_pids%"${_running_pids##*[! ]}"}"
	_running_pids="${_running_pids#"${_running_pids%%[! ]*}"}"

	_running_cnt=$((_running_cnt - 1))
	export -n \
		"${running_cnt_var}=${_running_cnt}" \
		"${pids_var}=${_running_pids}"

	get_uptime_cs _cur_time_cs || finalize 1
	export -n "${last_progress_time_var}=${_cur_time_cs}"

	[ -z "${job_done_cb}" ] ||
	"${job_done_cb}" "${done_id}" "${done_rv}" ||
		finalize ${?}

	return 0
}

# Convert any mix of spaces/tabs/newlines to single-space separators
normalize_ids()
{
	local \
		had_f \
		IFS=" 	"$'\n' \
		out_var="${1}"

	case "${-}" in
		*f*) had_f=1 ;;
	esac

	set -f
	set -- ${2}
	IFS=" "
	export -n "${out_var}=${*}"
	[ -n "${had_f}" ] || set +f
}

sched_fail_msg()
{
	if [ -n "${SCHED_FAIL_MSG_CB}" ] && is_cmd "${SCHED_FAIL_MSG_CB}"
	then
		"${SCHED_FAIL_MSG_CB}" "${@}"
	else
		printf '%s\n' "${@}" >&2
	fi
}

# 1: var name (for messages)
# 2: value
# 3: required(1/empty)
sch_check_cb()
{
	[ -z "${2}" ] && [ -z "${3}" ] && return 0
	[ -z "${2}" ] && { sched_fail_msg "Required callback is missing (set via \${${1}})."; return 1; }
	is_cmd "${2}" || { sched_fail_msg "Invalid value of ${1} '${2}'."; return 1; }
}

# 1: var name (for messages)
# 2: value
# 3: required(1/empty)
sch_check_uint()
{
	[ -z "${2}" ] && [ -z "${3}" ] && return 0
	is_uint "${2}" && [ "${2}" -ge 1 ] ||
		{ sched_fail_msg "Invalid value '${2}' of env var ${1}."; return 1; }
}


### Entry point
schedule_jobs()
{
	local \
		SCHED_RV_IDLE_TIMEOUT=81 \
		SCHED_RV_GLOBAL_TIMEOUT=82 \
		SCHED_RV_SIGNAL=83

	local \
		IFS=" 	"$'\n' \
		SCHEDULER_PID \
		remaining_time_cs \
		SCHED_INIT_UPTIME_CS \
		id \
		pid \
		running_pids \
		running_jobs_cnt=0 \
		LAST_PROGRESS_TIME_CS \
		USR_TRIG \
		sched_ipc_fifo \
		sched_dir="${SCHED_DIR:-/tmp}" \
		PROC_TIMEOUT_S="${SCHED_TIMEOUT_S:-900}" \
		IDLE_TIMEOUT_S="${SCHED_IDLE_TIMEOUT_S:-300}" \
		\
		job_ids="${1?}"
	
	: "${remaining_time_cs}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via start_job()

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB "${SCHED_FAIL_MSG_CB}" &&
	sch_check_cb SCHED_FINALIZE_CB "${SCHED_FINALIZE_CB}" &&
	sch_check_cb DO_JOB_CB "${DO_JOB_CB}" required &&
	sch_check_cb JOB_DONE_CB "${JOB_DONE_CB}" || return 1

	# Check env vars
	sch_check_uint SCHED_MAX_JOBS "${SCHED_MAX_JOBS}" 1 &&
	sch_check_uint SCHED_TIMEOUT_S "${SCHED_TIMEOUT_S}" &&
	sch_check_uint SCHED_IDLE_TIMEOUT_S "${SCHED_IDLE_TIMEOUT_S}" || return 1

	# Removing trailing '/'
	sched_dir="${sched_dir%"${sched_dir##*[!/]}"}"

	[ -n "${sched_dir}" ] ||
		{ sched_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; return 1; }

	# Convert ${job_ids} to space-separated list
	normalize_ids job_ids "${job_ids}" || return 1

	# Main logic

	get_uptime_cs SCHED_INIT_UPTIME_CS &&
	get_curr_pid SCHEDULER_PID ||
		return 1

	LAST_PROGRESS_TIME_CS="${SCHED_INIT_UPTIME_CS}"

	sched_ipc_fifo="${sched_dir}/sched_ipc_${SCHEDULER_PID}"

	mkdir -p "${sched_dir}" &&
	rm -f "${sched_ipc_fifo}" &&
	mkfifo "${sched_ipc_fifo}" &&
	exec 3<>"${sched_ipc_fifo}" ||
		finalize 1 "Failed to create FIFO '${sched_ipc_fifo}'."

	trap 'USR_TRIG=1 finalize "${SCHED_RV_SIGNAL}"' USR1

	local had_f=
	case "${-}" in
		*f*) had_f=1 ;;
	esac
	set -f

	for id in ${job_ids}
	do
		[ -n "${had_f}" ] || set +f
		while [ "${running_jobs_cnt}" -ge "${SCHED_MAX_JOBS}" ] &&
			[ -e "${sched_ipc_fifo}" ]
		do
			process_done_record \
				remaining_time_cs \
				running_pids \
				running_jobs_cnt \
				LAST_PROGRESS_TIME_CS \
				"${job_ids}" \
				"${sched_ipc_fifo}" \
				"${JOB_DONE_CB}"
		done

		refresh_remaining_time remaining_time_cs

		running_jobs_cnt=$((running_jobs_cnt + 1))

		start_job "${id}" "${@}" &
		pid="${!}"

		running_pids="${running_pids}${running_pids:+ }${pid}"
	done

	[ -n "${had_f}" ] || set +f

	while [ "${running_jobs_cnt}" -gt 0 ] &&
		[ -e "${sched_ipc_fifo}" ]
	do
		process_done_record \
			remaining_time_cs \
			running_pids \
			running_jobs_cnt \
			LAST_PROGRESS_TIME_CS \
			"${job_ids}" \
			"${sched_ipc_fifo}" \
			"${JOB_DONE_CB}"
	done

	[ "${running_jobs_cnt}" = 0 ] ||
	{
		refresh_remaining_time remaining_time_cs
		finalize 1 "Not all jobs are done: running_jobs_cnt=${running_jobs_cnt}"
	}

	finalize 0
}
