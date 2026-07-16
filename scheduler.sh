#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003


# Environment variables specifying parameters:
# SCHED_MAX_JOBS        Maximum number of concurrent jobs (integer >= 1)
# SCHED_TIMEOUT_S       Global scheduler timeout (seconds)
# SCHED_IDLE_TIMEOUT_S  Maximum allowed time without job starts or completions (seconds)
# SCHED_JOB_TIMEOUT_S   Optional default per-job timeout (seconds); per-job override via job_set_timeout(). See TIMEKEEPING.md.
# SCHED_DIR             Directory used to store scheduler FIFO. Defaults to /tmp if unset.
# SCHED_AUTO_PARAMS     Automatically assign and export job-specific param variables before starting each job (1 = on, unset or another value = off)

# Environment variables specifying callbacks:
#  (command name only - no arguments)

# DO_JOB_CB             Command implementing a job:
#                         <cmd> <job_id> [extra_args_passed_to_scheduler...]

# SCHED_FAIL_MSG_CB     Optional command reporting scheduler errors (default: STDERR):
#                         <cmd> <message...>

# SCHED_FINALIZE_CB     Optional command invoked when the scheduler exits:
#                         <cmd> <scheduler_return_code> <running_pids> <ok_job_ids> <fail_job_ids> <unfinished_job_ids> <undispatched_job_ids> <expired_job_ids>
#                       <running_pids> is normally empty; non-empty when the scheduler exits before all jobs complete
#                       <expired_job_ids> are jobs abandoned via per-job timeout (see TIMEKEEPING.md)

# JOB_DONE_CB           Optional command invoked after each completed job:
#                         <cmd> <job_id> <job_return_code>
#                       For a job abandoned via per-job timeout (see TIMEKEEPING.md):
#                         <cmd> <job_id> 124 <job_pid>

# SCHED_DISPATCH_TICK_CB  Optional, for testing only: called with <job_id> right after each job is dispatched in the initial scheduling loop.



### Helpers

sch_is_included() {
	case " ${2} " in
		*" ${1} "*)
			return 0 ;;
		*)
			return 1
	esac
}

sch_append()
{
	sch_check_name "var" "${1}" || return 1
	eval "${1}=\"\${${1}}\${${1}:+\" \"}\${2}\""
}

sch_had_f() {
	case "${-}" in
		*f*) return 0 ;;
		*) return 1
	esac
}

# Remove first matching element
# 1: out var
# 2: element
# 3: cur list
sch_rm_elem() {
	local sre_out_var="${1}" sre_e="${2}" sre_l="${3}"

	sch_is_included "${sre_e}" "${sre_l}" && {
		sre_l=" ${sre_l} "
		local sre_s=" ${sre_e} "
		sre_l="${sre_l%%"${sre_s}"*} ${sre_l#*"${sre_s}"}"
		sre_l="${sre_l%"${sre_l##*[!" "]}"}"
		sre_l="${sre_l#"${sre_l%%[!" "]*}"}"
	}

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

sch_fail_msg() {
	if [ -n "${SCHED_FAIL_MSG_CB}" ] && sch_is_cmd "${SCHED_FAIL_MSG_CB}"; then
		"${SCHED_FAIL_MSG_CB}" "${@}"
	else
		printf '%s\n' "${@}" >&2
	fi
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

sch_check_name() {
	case "${2}" in
		''|*[!a-zA-Z0-9_]*) false ;;
		*) : ;;
	esac &&
	{
		[ "${1}" != var ] ||
		case "${2}" in
			[a-zA-Z_]*) : ;;
			*) false
		esac
	} &&
	return 0

	sch_fail_msg "${3}${3:+": "}${1}${1:+ }'${2}' is empty string or contains incompatible characters."
	return 1
}

sch_finalize() {
	local sch_cb_rv sch_unfinished_ids sch_exp_e \
		sch_rv="${1}"

	trap ':' USR1 INT TERM

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	rm -f "${sch_ipc_fifo}"

	set -f

	# Pids of timed-out jobs that never reported belong in <running_pids>
	# (see TIMEKEEPING.md)
	for sch_exp_e in ${SCH_EXPIRED}; do
		sch_append SCH_RUNNING_PIDS "${sch_exp_e%%:*}"
	done

	# Compute sch_unfinished_ids
	for sch_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_id}" "${SCH_OK_IDS} ${SCH_UNDISPATCHED_IDS} ${SCH_FAIL_IDS} ${SCH_EXPIRED_IDS}" ||
			sch_append sch_unfinished_ids "${sch_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	[ -z "${SCHED_FINALIZE_CB}" ] ||
		"${SCHED_FINALIZE_CB}" "${sch_rv}" "${SCH_RUNNING_PIDS}" "${SCH_OK_IDS}" "${SCH_FAIL_IDS}" "${sch_unfinished_ids}" "${SCH_UNDISPATCHED_IDS}" "${SCH_EXPIRED_IDS}" ||
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
		sch_cs \
		sch_dl_min \
		sch_now_cs \
		sch_dl_prev \
		sch_expired \
		sch_pid \
		sch_id \
		\
		sch_done_pid \
		sch_done_rv \
		sch_done_id \
		sch_rec_verdict \
		sch_read_t_cs \
		sch_read_t_s \
		\
		sch_had_f \
		sch_e \
		\
		sch_ipc_fifo="${1:?}" \
		sch_job_done_cb="${2}"

	[ -e "${sch_ipc_fifo}" ] ||
		sch_finalize 1 "FIFO file '${sch_ipc_fifo}' does not exist."

	sch_had_f && sch_had_f=1

	sch_read_t_cs="${SCH_REMAIN_TIME_CS}"

	# Cap the wait by the nearest job deadline, if any (see TIMEKEEPING.md)
	[ -n "${SCH_DEADLINES}" ] && {
		sch_get_uptime_cs sch_now_cs || sch_finalize 1

		set -f
		for sch_e in ${SCH_DEADLINES}; do
			sch_cs="${sch_e#*:}"
			sch_cs="${sch_cs%%:*}"
			[ -n "${sch_dl_min}" ] && [ "${sch_cs}" -ge "${sch_dl_min}" ] ||
				sch_dl_min="${sch_cs}"
		done
		[ -n "${sch_had_f}" ] || set +f

		sch_dl_min=$((sch_dl_min - sch_now_cs))
		[ "${sch_dl_min}" -lt "${sch_read_t_cs}" ] &&
			sch_read_t_cs="${sch_dl_min}"
	}

	sch_read_t_s=$(( (sch_read_t_cs + 99) / 100 ))

	# Wait for the next completion record; an empty record means read -t
	# timed out (or was skipped): a job deadline and/or a scheduler timeout
	# is due, both handled by the common tail below
	[ "${sch_read_t_s}" -gt 0 ] &&
	read -t "${sch_read_t_s}" -r sch_done_pid sch_done_rv sch_done_id < "${sch_ipc_fifo}"

	# Process the completion record, if any (arrival wins over expiry: the
	# record is handled before deadlines are swept - see TIMEKEEPING.md)
	[ -n "${sch_done_pid}${sch_done_rv}${sch_done_id}" ] && {
		sch_is_uint "${sch_done_pid}" "${sch_done_rv}" &&
		[ -n "${sch_done_id}" ] &&
		sch_is_included "${sch_done_id}" "${SCH_JOB_IDS}" ||
			sch_finalize 1 "Malformed completion record: either bad PID '${sch_done_pid}' or bad RV '${sch_done_rv}' or bad job ID '${sch_done_id}'."

		if sch_is_included "${sch_done_pid}" "${SCH_RUNNING_PIDS}"; then
			# Normal completion
			sch_rm_elem SCH_RUNNING_PIDS "${sch_done_pid}" "${SCH_RUNNING_PIDS}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))

			# Remove the job's deadline entry, if it had one
			[ -n "${SCH_DEADLINES}" ] &&
				sch_deadline_rm_pid SCH_DEADLINES "${sch_done_pid}" "${SCH_DEADLINES}"

			if [ "${sch_done_rv}" = 0 ]; then
				sch_append SCH_OK_IDS "${sch_done_id}"
			else
				sch_append SCH_FAIL_IDS "${sch_done_id}"
			fi || sch_finalize 1

			sch_get_uptime_cs SCH_LAST_PROGRESS_TIME_CS || sch_finalize 1

			[ -z "${sch_job_done_cb}" ] ||
			"${sch_job_done_cb}" "${sch_done_id}" "${sch_done_rv}" ||
				sch_finalize ${?}
		else
			# Unknown pid: either a late record from a job already classified
			# as timed out - the timeout classification stands (see
			# TIMEKEEPING.md) - or a fatal protocol error
			sch_rec_verdict=malformed
			set -f
			for sch_e in ${SCH_EXPIRED}; do
				[ "${sch_e%%:*}" = "${sch_done_pid}" ] || continue
				[ "${sch_e#*:*:}" = "${sch_done_id}" ] && sch_rec_verdict=discard
				break
			done
			[ -n "${sch_had_f}" ] || set +f

			[ "${sch_rec_verdict}" = discard ] ||
				sch_finalize 1 "Unknown PID '${sch_done_pid}'."

			sch_deadline_rm_pid SCH_EXPIRED "${sch_done_pid}" "${SCH_EXPIRED}"
		fi
	}

	# Sweep expired deadlines:
	#   classifies jobs whose deadline has expired as timed out (rv 124) and reclaims their concurrency slots.
	# Abandoned jobs are recorded in ${SCH_EXPIRED}, so that
	#   their completion records can be recognized and discarded if they arrive later.
	[ -n "${SCH_DEADLINES}" ] && {
		sch_get_uptime_cs sch_now_cs || sch_finalize 1

		# Split the deadline list into expired (deadline <= now) and pending
		sch_dl_prev="${SCH_DEADLINES}"
		SCH_DEADLINES=
		set -f
		for sch_e in ${sch_dl_prev}; do
			sch_cs="${sch_e#*:}"
			sch_cs="${sch_cs%%:*}"
			if [ "${sch_cs}" -le "${sch_now_cs}" ]; then
				sch_append sch_expired "${sch_e}"
			else
				sch_append SCH_DEADLINES "${sch_e}"
			fi
		done
		[ -n "${sch_had_f}" ] || set +f

		# Chomp expired entries one by one (no word-splitting: job IDs may contain glob characters,
		#   and the callback below must run with unmodified glob state)
		while [ -n "${sch_expired}" ]; do
			sch_e="${sch_expired%% *}"
			sch_expired="${sch_expired#"${sch_e}"}"
			sch_expired="${sch_expired# }"

			sch_pid="${sch_e%%:*}"
			sch_id="${sch_e#*:*:}"

			sch_rm_elem SCH_RUNNING_PIDS "${sch_pid}" "${SCH_RUNNING_PIDS}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))

			sch_append SCH_EXPIRED_IDS "${sch_id}" &&
			sch_append SCH_EXPIRED "${sch_e}" ||
				sch_finalize 1

			[ -z "${sch_job_done_cb}" ] ||
			"${sch_job_done_cb}" "${sch_id}" 124 "${sch_pid}" ||
				sch_finalize ${?}
		done
	}

	# Recompute remaining time from a fresh clock reading.
	# If scheduler timeout is due, refresh_remain_time() calls sch_finalize().
	refresh_remain_time

	return 0
}


#
# Time keeping
#

# Sets ${SCH_REMAIN_TIME_CS} to the remaining time until ${SCH_TIMEOUT_S},
#   or to ${SCH_IDLE_TIMEOUT_S}, whichever is lower;
# Finalizes the scheduler when either timeout has been hit
refresh_remain_time() {
	local gt_cur_time_cs gt_idle_remain_time_cs

	sch_get_uptime_cs gt_cur_time_cs || sch_finalize 1

	SCH_REMAIN_TIME_CS=$(( SCH_TIMEOUT_S*100 - (gt_cur_time_cs-SCH_INIT_UPTIME_CS) ))
	gt_idle_remain_time_cs=$(( SCH_IDLE_TIMEOUT_S*100 - (gt_cur_time_cs-SCH_LAST_PROGRESS_TIME_CS) ))

	if [ ! "${SCH_REMAIN_TIME_CS}" -gt 0 ]; then
		sch_finalize "${SCH_RV_GLOBAL_TIMEOUT}" "Processing timeout (${SCH_TIMEOUT_S} s) for scheduler (PID: ${SCH_PID})."
	elif [ ! "${gt_idle_remain_time_cs}" -gt 0 ]; then
		sch_finalize "${SCH_RV_IDLE_TIMEOUT}" "Idle timeout (${SCH_IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCH_PID})."
	fi

	if [ "${gt_idle_remain_time_cs}" -lt "${SCH_REMAIN_TIME_CS}" ]; then
		SCH_REMAIN_TIME_CS="${gt_idle_remain_time_cs}"
	fi
}

# Remove the entry matching <pid> from a deadline list
#
# A deadline list is a space-separated list of <pid>:<deadline_cs>:<job_id> entries.
# <pid> and <deadline_cs> are uints,
#   so the job ID parses as the trailing remainder and may contain any non-whitespace character.
#
# 1: out var name
# 2: pid
# 3: deadline list
sch_deadline_rm_pid() {
	# Extract the full entry starting with "<pid>:" - job IDs contain no
	# whitespace, so " <pid>:" can only occur at an entry boundary
	local sdr_e=" ${3} "
	sdr_e="${sdr_e#* "${2}":}"
	sdr_e="${2}:${sdr_e%% *}"

	sch_is_included "${sdr_e}" "${3}" ||
		{ export -n "${1:?}=${3}"; return 1; }
	sch_rm_elem "${1}" "${sdr_e}" "${3}"
}


#
# User-facing functions
#

schedule_jobs() {
	# 1: var name
	# 2: required(1/empty)
	sch_check_cb() {
		local val
		eval "val=\"\${${1}}\""
		[ -z "${val}" ] && [ -z "${2}" ] && return 0
		[ -z "${val}" ] && { sch_fail_msg "Required callback is missing (set via \${${1}})."; return 1; }
		sch_is_cmd "${val}" || { sch_fail_msg "Invalid value of ${1} '${val}'."; return 1; }
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

	# Validates that <in_val> is a non-zero uint, strips leading zeros and assigns to <out_var>
	# <out_var> must be named SCH_<name>, pairing env var SCHED_<name> (error messages rely on this).
	# 1: out var
	# 2: in value
	# 3: required(1/empty)
	sch_normalize_uint() {
		local val="${2}"
		export -n "${1:?}="
		[ -z "${val}" ] && [ -z "${3}" ] && return 0
		sch_is_uint "${val}" && [ "${val}" -ge 1 ] ||
			{ sch_fail_msg "Invalid value '${val}' of env var SCHED_${1#SCH_}."; return 1; }
		val="${val#"${val%%[!0]*}"}"
		export -n "${1}=${val}"
	}

	local \
		SCH_RV_IDLE_TIMEOUT=81 \
		SCH_RV_GLOBAL_TIMEOUT=82 \
		SCH_RV_USR1=83 \
		SCH_RV_INT_TERM=84

	local \
		IFS=" "$'\t'$'\n' \
		SCH_PID \
		SCH_REMAIN_TIME_CS \
		SCH_INIT_UPTIME_CS \
		sch_id \
		sch_seen_ids \
		sch_pid \
		sch_job_to \
		sch_dl_now_cs \
		SCH_RUNNING_JOBS_CNT=0 \
		sch_ipc_fifo \
		sch_dir="${SCHED_DIR:-/tmp}" \
		\
		SCH_HAD_F \
		SCH_UNDISPATCHED_IDS \
		SCH_OK_IDS \
		SCH_FAIL_IDS \
		SCH_RUNNING_PIDS \
		SCH_LAST_PROGRESS_TIME_CS \
		SCH_MAX_JOBS \
		SCH_TIMEOUT_S \
		SCH_IDLE_TIMEOUT_S \
		SCH_JOB_TIMEOUT_S \
		SCH_DEADLINES \
		SCH_EXPIRED \
		SCH_EXPIRED_IDS \
		\
		SCH_JOB_IDS="${1?}"
	
	: "${SCH_REMAIN_TIME_CS}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via sch_start_job()

	# Register noglob state
	sch_had_f && SCH_HAD_F=1

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB &&
	sch_check_cb SCHED_FINALIZE_CB &&
	sch_check_cb DO_JOB_CB required &&
	sch_check_cb JOB_DONE_CB &&
	sch_check_cb SCHED_DISPATCH_TICK_CB || exit 1

	# Check env vars, normalize into internal copies
	sch_normalize_uint SCH_MAX_JOBS "${SCHED_MAX_JOBS}" required &&
	sch_normalize_uint SCH_TIMEOUT_S "${SCHED_TIMEOUT_S:-900}" &&
	sch_normalize_uint SCH_IDLE_TIMEOUT_S "${SCHED_IDLE_TIMEOUT_S:-300}" &&
	sch_normalize_uint SCH_JOB_TIMEOUT_S "${SCHED_JOB_TIMEOUT_S}" || exit 1

	# Removing trailing '/'
	sch_dir="${sch_dir%"${sch_dir##*[!/]}"}"

	[ -n "${sch_dir}" ] ||
		{ sch_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; exit 1; }

	# Convert ${SCH_JOB_IDS} to space-separated list
	sch_normalize_ids SCH_JOB_IDS "${SCH_JOB_IDS}" || exit 1

	set -f
	for sch_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_id}" "${sch_seen_ids}" &&
			{
				[ -n "${SCH_HAD_F}" ] || set +f
				sch_fail_msg "Duplicate Job ID '${sch_id}'."
				exit 1
			}
		sch_append sch_seen_ids "${sch_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	SCH_UNDISPATCHED_IDS="${SCH_JOB_IDS}"

	# Main logic

	sch_get_uptime_cs SCH_INIT_UPTIME_CS &&
	sch_get_cur_pid SCH_PID ||
		exit 1

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
		while [ "${SCH_RUNNING_JOBS_CNT}" -ge "${SCH_MAX_JOBS}" ] &&
			[ -e "${sch_ipc_fifo}" ]
		do
			# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING_PIDS}; ${SCH_REMAIN_TIME_CS}; ${SCH_LAST_PROGRESS_TIME_CS}
			process_done_record \
				"${sch_ipc_fifo}" \
				"${JOB_DONE_CB}"
		done
		refresh_remain_time

		SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT + 1))

		sch_start_job "${sch_id}" "${@}" &
		sch_pid="${!}"

		sch_append SCH_RUNNING_PIDS "${sch_pid}" || sch_finalize 1
		sch_rm_elem SCH_UNDISPATCHED_IDS "${sch_id}" "${SCH_UNDISPATCHED_IDS}"

		# A job start counts as scheduler progress: reset the idle timeout
		# (see TIMEKEEPING.md)
		sch_get_uptime_cs sch_dl_now_cs || sch_finalize 1
		SCH_LAST_PROGRESS_TIME_CS="${sch_dl_now_cs}"

		# Register the job's timeout deadline, if it has one (see TIMEKEEPING.md)
		# The eval is safe: the case statement restricts it to IDs consisting
		# of name-safe characters (only those can carry a per-job timeout)
		sch_job_to="${SCH_JOB_TIMEOUT_S}"
		case "${sch_id}" in
			''|*[!a-zA-Z0-9_]*) ;;
			*) eval "sch_job_to=\"\${SCH_TIMEOUT_JOB_${sch_id}:-\${SCH_JOB_TIMEOUT_S}}\"" ;;
		esac

		[ -n "${sch_job_to}" ] &&
			sch_append SCH_DEADLINES "${sch_pid}:$((sch_dl_now_cs + sch_job_to*100)):${sch_id}"

		[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
			"${SCHED_DISPATCH_TICK_CB}" "${sch_id}"
	done

	[ -n "${SCH_HAD_F}" ] || set +f

	# Wait for running jobs
	while [ "${SCH_RUNNING_JOBS_CNT}" -gt 0 ] &&
		[ -e "${sch_ipc_fifo}" ]
	do
		# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING_PIDS}; ${SCH_REMAIN_TIME_CS}; ${SCH_LAST_PROGRESS_TIME_CS}
		process_done_record \
			"${sch_ipc_fifo}" \
			"${JOB_DONE_CB}"
	done

	[ "${SCH_RUNNING_JOBS_CNT}" = 0 ] ||
	{
		refresh_remain_time
		sch_finalize 1 "Not all jobs are done: SCH_RUNNING_JOBS_CNT=${SCH_RUNNING_JOBS_CNT}"
	}

	sch_finalize 0
}

# 1: job ID
# Extra args: any number of <param=value> pairs
job_set_params() {
	local sch_me=job_set_params \
		sch_param \
		sch_val \
		sch_cur_params \
		sch_pair \
		sch_pair_seen \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift

	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

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
		sch_check_name "param" "${sch_param}" "${sch_me}" || return 1

		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""
		sch_is_included "${sch_param}" "${sch_cur_params}" ||
		sch_append "SCH_JOB_PARAMS_${sch_job_id}" "${sch_param}" ||
			return 1
		export -n "SCH_JOB_PARAM_${#sch_job_id}_${sch_job_id}_${sch_param}=${sch_val}"
	done

	[ -n "${sch_pair_seen}" ] ||
		{ sch_fail_msg "${sch_me}: no params specified."; return 1; }
}

# For each param <P> assigns corresponding param value to variable named <P>
# For each pair <var>=<P> assigns param value to variable <var>
# 0 (optional): '-export'
# 1: job ID
# Extra args: "sch_all" or <list of params, one per argument>, or <list of var=param>
job_get_params() {
	local sch_export
	[ "${1}" = '-export' ] && { sch_export="export "; shift; }

	local sch_me=job_get_params \
		sch_param \
		sch_var \
		sch_had_f \
		sch_job_params \
		sch_param_seen \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	[ "${*}" = sch_all ] && {
		eval "sch_job_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""
		[ -n "${sch_job_params}" ] || return 0

		sch_had_f && sch_had_f=1
		set -f
		set -- ${sch_job_params}
		[ -n "${sch_had_f}" ] || set +f
	}

	for sch_param; do
		sch_param_seen=1
		sch_var="${sch_param}"
		case "${sch_param}" in
			*=*)
				sch_var="${sch_param%%=*}"
				sch_param="${sch_param#*=}"
		esac

		sch_check_name "param" "${sch_param}" "${sch_me}" &&
		sch_check_name "var" "${sch_var}" "${sch_me}" || return 1
		case "${sch_var}" in
			sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|IFS)
				sch_fail_msg "${sch_me}: var name '${sch_var}' is reserved for internal use."
				return 1
		esac

		eval "${sch_export}${sch_var}=\"\${SCH_JOB_PARAM_${#sch_job_id}_${sch_job_id}_${sch_param}}\""
	done

	[ -n "${sch_param_seen}" ] ||
		{ sch_fail_msg "${sch_me}: no params specified."; return 1; }
}

# Set a per-job timeout, overriding ${SCHED_JOB_TIMEOUT_S} for this job
# 1: job ID
# 2: timeout in seconds (uint >= 1)
job_set_timeout() {
	local sch_me=job_set_timeout \
		sch_val="${2}" \
		sch_job_id="${1}"

	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	sch_is_uint "${sch_val}" && [ "${sch_val}" -ge 1 ] || {
		sch_fail_msg "${sch_me}: invalid timeout value '${sch_val}' for job '${sch_job_id}'."
		return 1
	}
	sch_val="${sch_val#"${sch_val%%[!0]*}"}"
	# Not SCH_JOB_TIMEOUT_<id>: that would collide with the internal
	# ${SCH_JOB_TIMEOUT_S} copy of ${SCHED_JOB_TIMEOUT_S} for a job named 'S'
	export -n "SCH_TIMEOUT_JOB_${sch_job_id}=${sch_val}"
}
