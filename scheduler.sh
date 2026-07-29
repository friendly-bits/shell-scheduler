#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# Env vars specifying parameters (see REFERENCE.md):
# SCHED_MAX_JOBS
# SCHED_TIMEOUT_S
# SCHED_IDLE_TIMEOUT_S
# SCHED_JOB_TIMEOUT_S
# SCHED_DIR
# SCHED_AUTO_PARAMS
# SCHED_ID

# Env vars specifying callbacks (see REFERENCE.md):
# DO_JOB_CB
# SCHED_FAIL_MSG_CB
# SCHED_FINALIZE_CB
# JOB_DONE_CB
# JOB_TERM_CB
# SCHED_DISPATCH_TICK_CB

# ${SCHED_PID} can be used inside callbacks to terminate scheduler early
# ${SCHED_UID} is '<pid>_<starttime>' of the scheduler process.
# Unlike a bare pid, it cannot be confused with a recycled pid, so nested instances never collide


### Helpers

sch_is_included() {
	case " ${2} " in
		*" ${1} "*) return 0 ;;
		*) return 1
	esac
}

sch_append() {
	sch_check_name "var" "${1}" || return 1
	[ -n "${2}" ] || return 0
	eval "${1}=\"\${${1}}\${${1}:+\" \"}\${2}\""
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
		sch_tr_trailing sre_l " "
		sch_tr_leading sre_l " "
	}

	export -n "${sre_out_var}=${sre_l}"
}

# Look up PID of a job in list of '<pid>:<job ID>' entries
# Job IDs contain no whitespace, so ":<job ID> " can only match at an entry boundary
# 1: out var
# 2: job ID
# 3: cur list
sch_pid_of_id() {
	local spi_l=" ${3} " spi_p
	export -n "${1:?}="

	case "${spi_l}" in
		*":${2} "*) ;;
		*) return 1
	esac

	spi_p="${spi_l%%":${2} "*}"
	export -n "${1}=${spi_p##* }"
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
	sch_tr_leading cs "0"
	export -n "${1}=${cs:-0}"
}

# The callback runs in a subshell and behind a re-entry flag: a callback that itself
#   fails into sch_fail_msg would otherwise recurse until the shell dies
sch_fail_msg() {
	if [ -z "${SCH_IN_FAIL_MSG_CB}" ] && [ -n "${SCHED_FAIL_MSG_CB}" ] && sch_is_cmd "${SCHED_FAIL_MSG_CB}"; then
		local SCH_IN_FAIL_MSG_CB=1
		( "${SCHED_FAIL_MSG_CB}" "${@}" )
	elif [ -n "${SCH_IN_FAIL_MSG_CB}" ]; then
		printf '%s\n' "${@}" "Warning: stopping infinite SCHED_FAIL_MSG_CB recursion." >&2
	else
		printf '%s\n' "${@}" >&2
	fi
}

sch_is_cmd() {
	command -v "${1}" 1>/dev/null 2>&1
}

sch_tr_leading() {
	sch_check_name "var" "${1}" &&
	eval "${1}=\"\${${1}#\"\${${1}%%[!\"\${2}\"]*}\"}\""
}

sch_tr_trailing() {
	sch_check_name "var" "${1}" &&
	eval "${1}=\"\${${1}%\"\${${1}##*[!\"\${2}\"]}\"}\""
}

sch_has_f() {
	case "${-}" in
		*f*) return 0 ;;
		*) return 1
	esac
}

# Get reuse-proof identity '<pid>_<starttime>' of current shell process
# Only ever reads /proc/self: reading another process's stat races with its exit
# 1: out-var
sch_get_uid() {
	local sgu_had_f sgu_pid sgu_start sgu_line \
		IFS=" "$'\t'$'\n' \
		sgu_out="${1:?}"
	export -n "${sgu_out}="

	IFS= read -r sgu_line 2>/dev/null < /proc/self/stat || sgu_line=

	sgu_pid="${sgu_line%% *}"
	# Strip 'pid (comm) ' greedily - comm may contain ') ' and spaces
	sgu_line="${sgu_line##*") "}"

	sch_has_f && sgu_had_f=1
	set -f
	set -- ${sgu_line}
	[ -n "${sgu_had_f}" ] || set +f

	# Start time is stat field 22; the strip leaves state (field 3) first
	[ "${#}" -ge 20 ] && shift 19 && sgu_start="${1}"

	sch_is_uint "${sgu_pid}" "${sgu_start}" ||
		{ sch_fail_msg "Failed to get PID and start time from /proc/self/stat."; return 1; }
	export -n "${sgu_out}=${sgu_pid}_${sgu_start}"
}

sch_check_name() {
	# A job ID reaches this check both bare and wrapped in the internal 'SCH_JOB_PARAMS_<namespace><job ID>' var name,
	#   so a var gets the base budget plus that prefix - otherwise the same ID would pass one and fail the other
	local scn_pfx="SCH_JOB_PARAMS_${#SCHED_ID}_${SCHED_ID}_" scn_max_len=2020

	[ "${1}" = var ] && scn_max_len=$((scn_max_len + ${#scn_pfx}))

	[ "${#2}" -le "${scn_max_len}" ] &&
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

	sch_fail_msg "${3}${3:+": "}${1}${1:+ }'${2}' is empty string or contains incompatible characters, or is too long."
	return 1
}

# Validate user-supplied var name
# 1: name
# 2: caller name
sch_check_var_name() {
	sch_check_name "var" "${1}" "${2}" || return 1
	case "${1}" in
		sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|JOB_TERM_CB|IFS)
			sch_fail_msg "${2}: var name '${1}' is reserved for internal use."
			return 1
	esac
}

# Reject calls from a job wrapper, from SCHED_FINALIZE_CB, or from outside a run.
#   Also guards sch_finalize() against re-entry: it unsets the started-flag first
# 1: caller
sch_in_main_process() {
	local sip_uid
	sch_get_uid sip_uid &&
	[ "${sip_uid}" = "${SCHED_UID}" ] &&
	eval "[ -n \"\${SCH_STARTED_${sip_uid}}\" ]" &&
		return 0
	sch_fail_msg "${1}: SCHED_UID is not set or scheduler is not running in this process."
	return 1
}

# Resolve the ${SCHED_ID} namespace infix '<len of SCHED_ID>_<SCHED_ID>_' for internal per-job var names
# Unset ${SCHED_ID} is valid and produces '0__'
#
# The length prefix is what keeps the namespace apart from the job ID: both are
#   [a-zA-Z0-9_], so plain concatenation would let SCHED_ID='a'+job '1_x'
#   collide with SCHED_ID='a_1'+job 'x'
#
# 1: out var name
# 2: caller name
sch_get_ns() {
	export -n "${1:?}="
	[ -z "${SCHED_ID}" ] ||
		sch_check_name "SCHED_ID" "${SCHED_ID}" "${2}" || return 1
	export -n "${1}=${#SCHED_ID}_${SCHED_ID}_"
}

sch_finalize() {
	local sch_me=sch_finalize sch_unfinished_ids sch_exp_e sch_job_id sch_running_pids sch_kill_pids \
		IFS=" "$'\t'$'\n' \
		sch_rv="${1}"

	sch_in_main_process "${sch_me}" ||
		return "${sch_rv:-1}"

	unset "SCH_STARTED_${SCHED_UID}"

	trap ':' USR1 INT TERM

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	[ -n "${sch_run_dir}" ] && rm -rf "${sch_run_dir}"

	# Restore the caller's noglob state: a trap may have entered sch_finalize()
	#   from inside an internal 'set -f' section. Job IDs and PIDs are
	#   glob-safe, and user-provided code must run with the caller's state
	if [ -n "${SCH_HAD_F}" ]; then set -f; else set +f; fi

	# Kill the process trees of all jobs still running
	# Verified kills are scrubbed from ${SCH_RUNNING} by sch_term_run(), so the
	#   surviving pids must be collected after the term pass, not before
	[ -n "${SCH_TERM_ACTIVE}" ] && {
		for sch_exp_e in ${SCH_RUNNING}; do
			sch_append sch_kill_pids "${sch_exp_e%%:*}"
		done
		# shellcheck disable=SC2086
		[ -n "${sch_kill_pids}" ] &&
			sch_term_run term ${sch_kill_pids}
		sch_term_run cleanup
	}

	# Collect pids of jobs still accounted as running
	for sch_exp_e in ${SCH_RUNNING}; do
		sch_append sch_running_pids "${sch_exp_e%%:*}"
	done

	# Pids of timed-out and aborted jobs that never reported belong in <running_pids> -
	#   except those whose kill has been verified
	for sch_exp_e in ${SCH_UNREAPED}; do
		sch_is_included "${sch_exp_e%%:*}" "${SCH_TERM_KILLED}" ||
			sch_append sch_running_pids "${sch_exp_e%%:*}"
	done

	# Compute sch_unfinished_ids
	for sch_job_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_job_id}" "${SCH_OK_IDS} ${SCH_UNDISPATCHED_IDS} ${SCH_FAIL_IDS} ${SCH_EXPIRED_IDS} ${SCH_ABORTED_IDS}" ||
			sch_append sch_unfinished_ids "${sch_job_id}"
	done

	[ -n "${SCHED_FINALIZE_CB}" ] && {
		"${SCHED_FINALIZE_CB}" "${sch_rv}" "${sch_running_pids}" "${SCH_OK_IDS}" "${SCH_FAIL_IDS}" "${sch_unfinished_ids}" "${SCH_UNDISPATCHED_IDS}" "${SCH_EXPIRED_IDS}" "${SCH_ABORTED_IDS}"
		sch_rv=${?}
	}

	exit "${sch_rv}"
}

sch_start_job() {
	local \
		sch_job_uid \
		sch_job_pid \
		sch_job_rv \
		sch_job_id="${1:?}"

	shift

	trap '
		sch_job_rv=${?}
		printf "%s %s\n" "${sch_job_rv}" "${sch_job_id}" >&3 2>/dev/null
		exit "${sch_job_rv}"
	' EXIT

	# Per-job termination setup - runs in job's process,
	#   so shell-function command can affect the process itself (e.g. join a cgroup).
	# The completion record is keyed by job ID, so the pid is needed only here
	[ -n "${SCH_TERM_ACTIVE}" ] && {
		sch_get_uid sch_job_uid || exit 1
		sch_job_pid="${sch_job_uid%%_*}"

		"${JOB_TERM_CB}" setup "${sch_job_id}" "${sch_job_pid}" ||
		{
			sch_fail_msg "Job '${sch_job_id}' (PID ${sch_job_pid}): termination setup failed."
			exit 1
		}
	}

	[ "${SCHED_AUTO_PARAMS}" = 1 ] &&
		{ job_get_params -export "${sch_job_id}" sch_all || exit 1; }

	"${DO_JOB_CB:?}" "${sch_job_id}" "${@}"
	exit "${?}"
}

# Invoke JOB_DONE_CB, export params when ${SCHED_AUTO_PARAMS} is on
# Params are local to this function, they do not persist
# 1: callback command
# 2: job ID
# Extra args: passed to the callback as-is
sch_run_done_cb() {
	local sch_me=sch_run_done_cb \
		sch_had_f \
		sch_p \
		sch_names \
		sch_ns \
		sch_cb="${1}" \
		sch_dc_id="${2}"

	shift

	[ "${SCHED_AUTO_PARAMS}" = 1 ] && {
		sch_get_ns sch_ns "${sch_me}" || return 1
		eval "sch_names=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_dc_id}}\""

		sch_has_f && sch_had_f=1
		set -f

		# 'local' with invalid name aborts busybox ash
		for sch_p in ${sch_names}; do
			sch_check_var_name "${sch_p}" "${sch_me}" || { sch_names=; break; }
		done

		[ -z "${sch_names}" ] || {
			#shellcheck disable=SC2086
			local ${sch_names}
			job_get_params -export "${sch_dc_id}" sch_all
		}

		[ -n "${sch_had_f}" ] || set +f
	}

	"${sch_cb}" "${@}"
}

process_done_record() {
	local \
		sch_cs \
		sch_dl_min \
		sch_now_cs \
		sch_dl_prev \
		sch_expired \
		sch_job_pid \
		sch_job_id \
		\
		sch_done_rv \
		sch_done_id \
		sch_rec \
		sch_rec_tail \
		sch_rec_garbage \
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

	sch_has_f && sch_had_f=1

	sch_read_t_cs="${SCH_REMAIN_TIME_CS}"

	# Cap the wait by the nearest job deadline if any
	[ -n "${SCH_DEADLINES}" ] && {
		sch_get_uptime_cs sch_now_cs || sch_finalize 1

		set -f
		for sch_e in ${SCH_DEADLINES}; do
			sch_cs="${sch_e%%:*}"
			[ -n "${sch_dl_min}" ] && [ "${sch_cs}" -ge "${sch_dl_min}" ] ||
				sch_dl_min="${sch_cs}"
		done
		[ -n "${sch_had_f}" ] || set +f

		sch_dl_min=$((sch_dl_min - sch_now_cs))
		[ "${sch_dl_min}" -lt "${sch_read_t_cs}" ] &&
			sch_read_t_cs="${sch_dl_min}"
	}

	sch_read_t_s=$(( (sch_read_t_cs + 99) / 100 ))

	# Wait for the next completion record. Read the whole line into one raw field.
	[ "${sch_read_t_s}" -gt 0 ] && {
		IFS= read -t "${sch_read_t_s}" -r sch_rec < "${sch_ipc_fifo}" ||
		[ -z "${sch_rec}" ] ||
		[ -z "${BASH}" ] ||
		{
			# Non-zero code means read -t timeout mid-line
			# Busybox ash throws partial read away and flushes the FIFO buffer
			# Bash assigns partial line and keeps FIFO buffer
			IFS= read -t 1 -r sch_rec_tail < "${sch_ipc_fifo}"
			sch_rec="${sch_rec}${sch_rec_tail}"
		}
	}

	# Re-split the completion record
	# Empty record unambiguously means read -t timeout
	[ -n "${sch_rec}" ] && {
		set -f
		set -- ${sch_rec}
		sch_done_rv=${1}
		sch_done_id=${2}
		shift 2
		sch_rec_garbage="${*}"
		[ -n "${sch_had_f}" ] || set +f
	}

	# Process the completion record if any
	# Arrival wins over expiry: the record is handled before deadlines are swept
	[ -n "${sch_done_rv}${sch_done_id}" ] && {
		[ -z "${sch_rec_garbage}" ] &&
		sch_is_uint "${sch_done_rv}" &&
		[ -n "${sch_done_id}" ] &&
		sch_is_included "${sch_done_id}" "${SCH_JOB_IDS}" ||
			sch_finalize 1 "Malformed completion record: either bad job ID '${sch_done_id}' or bad RV '${sch_done_rv}' or trailing garbage '${sch_rec_garbage}'."

		if sch_pid_of_id sch_job_pid "${sch_done_id}" "${SCH_UNREAPED}"; then
			# Late record from a job already timed out or aborted - discard
			sch_rm_elem SCH_UNREAPED "${sch_job_pid}:${sch_done_id}" "${SCH_UNREAPED}"
		elif sch_pid_of_id sch_job_pid "${sch_done_id}" "${SCH_RUNNING}"; then
			# Normal completion
			sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_done_id}" "${SCH_RUNNING}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))

			# Remove the job's deadline entry, if it had one
			[ -n "${SCH_DEADLINES}" ] &&
				sch_deadline_rm_id SCH_DEADLINES "${sch_done_id}" "${SCH_DEADLINES}"

			if [ "${sch_done_rv}" = 0 ]; then
				sch_append SCH_OK_IDS "${sch_done_id}"
			else
				sch_append SCH_FAIL_IDS "${sch_done_id}"
			fi

			sch_get_uptime_cs SCH_LAST_PROGRESS_TIME_CS || sch_finalize 1

			[ -z "${sch_job_done_cb}" ] ||
			sch_run_done_cb "${sch_job_done_cb}" "${sch_done_id}" "${sch_done_rv}" ||
				sch_finalize ${?}
		else
			sch_finalize 1 "Unexpected completion record for job ID '${sch_done_id}'."
		fi
	}

	# Sweep expired deadlines:
	#   classifies jobs whose deadline has expired as timed out (rv 124) and reclaims their concurrency slots.
	# Abandoned jobs are recorded in ${SCH_UNREAPED}, so that
	#   their completion records can be recognized and discarded if they arrive later.
	[ -n "${SCH_DEADLINES}" ] && {
		sch_get_uptime_cs sch_now_cs || sch_finalize 1

		# Split the deadline list into expired (deadline <= now) and pending
		sch_dl_prev="${SCH_DEADLINES}"
		SCH_DEADLINES=
		set -f
		for sch_e in ${sch_dl_prev}; do
			sch_cs="${sch_e%%:*}"
			if [ "${sch_cs}" -le "${sch_now_cs}" ]; then
				sch_append sch_expired "${sch_e}"
			else
				sch_append SCH_DEADLINES "${sch_e}"
			fi
		done

		# ${sch_expired} is glob-safe
		for sch_e in ${sch_expired}; do
			[ -n "${sch_had_f}" ] || set +f
			sch_job_id="${sch_e#*:}"

			sch_pid_of_id sch_job_pid "${sch_job_id}" "${SCH_RUNNING}" || continue
			sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_job_id}" "${SCH_RUNNING}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))
			sch_append SCH_EXPIRED_IDS "${sch_job_id}"
			sch_append SCH_UNREAPED "${sch_job_pid}:${sch_job_id}"

			# Kill the timed-out job's whole process tree (wrapper included)
			[ -n "${SCH_TERM_ACTIVE}" ] && sch_term_run term "${sch_job_pid}"

			[ -z "${sch_job_done_cb}" ] ||
			sch_run_done_cb "${sch_job_done_cb}" "${sch_job_id}" 124 "${sch_job_pid}" ||
				sch_finalize ${?}
		done
		[ -n "${sch_had_f}" ] || set +f
	}

	# Recompute remaining time from a fresh clock reading
	# If scheduler timeout is due, refresh_remain_time() calls sch_finalize()
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
		sch_finalize "${SCH_RV_GLOBAL_TIMEOUT}" "Processing timeout (${SCH_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
	elif [ ! "${gt_idle_remain_time_cs}" -gt 0 ]; then
		sch_finalize "${SCH_RV_IDLE_TIMEOUT}" "Idle timeout (${SCH_IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
	fi

	if [ "${gt_idle_remain_time_cs}" -lt "${SCH_REMAIN_TIME_CS}" ]; then
		SCH_REMAIN_TIME_CS="${gt_idle_remain_time_cs}"
	fi
	:
}

# Remove a job's entry from a deadline list
#
# Deadline list is a space-separated list of <deadline_cs>:<job_id> entries.
# Job IDs contain no whitespace, so ":<job ID> " can only match at an entry boundary
#
# 1: out var name
# 2: job ID
# 3: deadline list
sch_deadline_rm_id() {
	local sdr_e=" ${3} "

	case "${sdr_e}" in
		*":${2} "*) ;;
		*) export -n "${1:?}=${3}"; return 1
	esac

	sdr_e="${sdr_e%%":${2} "*}"
	sdr_e="${sdr_e##* }:${2}"
	sch_rm_elem "${1}" "${sdr_e}" "${3}"
}

# Remove the entry keyed by <pid> from a list of <pid>:<job_id> entries.
# Keyed by pid because the caller (sch_term_run) is handed pids by JOB_TERM_CB, which has no way to know job IDs
#
# 1: out var name
# 2: pid
# 3: list
sch_rm_pid_entry() {
	# Extract the full entry starting with "<pid>:"
	# Job IDs contain no whitespace, so " <pid>:" can only occur at an entry boundary
	local srp_e=" ${3} "
	srp_e="${srp_e#* "${2}":}"
	srp_e="${2}:${srp_e%% *}"

	sch_is_included "${srp_e}" "${3}" ||
		{ export -n "${1:?}=${3}"; return 1; }
	sch_rm_elem "${1}" "${srp_e}" "${3}"
}


# Modular job termination (JOB_TERM_CB) - see REFERENCE.md

# Invoke '<cb> <subcommand> sch_tr_out [pids...]' and process the verified-PID report assigned by the callback:
#   scrub reported PIDs from ${SCH_RUNNING}, record them in ${SCH_TERM_KILLED}
# 1: subcommand: <term|cleanup>
# Extra args: passed to the command after the out var name
sch_term_run() {
	local sch_tr_sub="${1:?}" sch_tr_out='' sch_tr_p sch_tr_had_f

	shift
	"${JOB_TERM_CB}" "${sch_tr_sub}" sch_tr_out "${@}" ||
		sch_fail_msg "Job termination callback '${JOB_TERM_CB} ${sch_tr_sub}' returned code ${?}."

	[ -n "${sch_tr_out}" ] || return 0

	sch_has_f && sch_tr_had_f=1
	set -f
	for sch_tr_p in ${sch_tr_out}; do
		sch_is_uint "${sch_tr_p}" || {
			sch_fail_msg "'${JOB_TERM_CB} ${sch_tr_sub}': ignoring invalid verified PID '${sch_tr_p}'."
			continue
		}
		[ -n "${sch_tr_had_f}" ] || set +f
		sch_rm_pid_entry SCH_RUNNING "${sch_tr_p}" "${SCH_RUNNING}"
		sch_is_included "${sch_tr_p}" "${SCH_TERM_KILLED}" ||
		sch_append SCH_TERM_KILLED "${sch_tr_p}" ||
			sch_finalize 1
	done
	[ -n "${sch_tr_had_f}" ] || set +f
	:
}


#
# User-facing functions
#

schedule_jobs() {
	# 1: var name
	# 2: required(1/empty)
	sch_check_cb() {
		local val
		sch_check_name "var" "${1}" "sch_check_cb" || return 1
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
		sch_tr_leading val "0"
		export -n "${1}=${val}"
	}

	local \
		SCH_RV_IDLE_TIMEOUT=81 \
		SCH_RV_GLOBAL_TIMEOUT=82 \
		SCH_RV_USR1=83 \
		SCH_RV_INT_TERM=84

	local \
		IFS=" "$'\t'$'\n' \
		SCHED_PID \
		SCHED_UID \
		SCH_REMAIN_TIME_CS \
		SCH_INIT_UPTIME_CS \
		sch_job_id \
		sch_job_pid \
		sch_ns \
		sch_seen_ids \
		sch_job_to \
		sch_dl_now_cs \
		SCH_RUNNING_JOBS_CNT=0 \
		sch_ipc_fifo \
		sch_run_dir \
		sch_run_n \
		sch_dir="${SCHED_DIR:-/tmp}" \
		\
		SCH_HAD_F \
		SCH_IN_FAIL_MSG_CB \
		SCH_RUNNING \
		SCH_LAST_PROGRESS_TIME_CS \
		SCH_MAX_JOBS \
		SCH_TIMEOUT_S \
		SCH_IDLE_TIMEOUT_S \
		SCH_JOB_TIMEOUT_S \
		SCH_DEADLINES \
		SCH_UNREAPED \
		SCH_TERM_ACTIVE \
		SCH_TERM_KILLED \
		\
		SCH_PENDING_IDS \
		SCH_ABORTED_IDS \
		SCH_UNDISPATCHED_IDS \
		SCH_OK_IDS \
		SCH_FAIL_IDS \
		SCH_EXPIRED_IDS \
		\
		SCH_JOB_IDS="${1?}"
	
	: "${SCH_REMAIN_TIME_CS}" "${SCH_JOB_TIMEOUT_S}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via sch_start_job()

	# Register noglob state
	sch_has_f && SCH_HAD_F=1

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB &&
	sch_check_cb SCHED_FINALIZE_CB &&
	sch_check_cb DO_JOB_CB required &&
	sch_check_cb JOB_DONE_CB &&
	sch_check_cb JOB_TERM_CB &&
	sch_check_cb SCHED_DISPATCH_TICK_CB || exit 1

	# Check env vars, normalize into internal copies
	sch_normalize_uint SCH_MAX_JOBS "${SCHED_MAX_JOBS}" required &&
	sch_normalize_uint SCH_TIMEOUT_S "${SCHED_TIMEOUT_S:-900}" &&
	sch_normalize_uint SCH_IDLE_TIMEOUT_S "${SCHED_IDLE_TIMEOUT_S:-300}" &&
	sch_normalize_uint SCH_JOB_TIMEOUT_S "${SCHED_JOB_TIMEOUT_S}" || exit 1

	sch_tr_trailing sch_dir "/"

	[ -n "${sch_dir}" ] ||
		{ sch_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; exit 1; }

	# Check namespace; register scheduler start
	sch_get_ns sch_ns "schedule_jobs" &&
	sch_get_uptime_cs SCH_INIT_UPTIME_CS &&
	sch_get_uid SCHED_UID ||
		exit 1
	SCHED_PID="${SCHED_UID%%_*}"
	export -n "SCH_STARTED_${SCHED_UID}=1"

	# Convert ${SCH_JOB_IDS} to space-separated list
	sch_normalize_ids SCH_JOB_IDS "${SCH_JOB_IDS}" || exit 1

	# Validate job IDs ([a-zA-Z0-9_] only), check for duplicates.
	set -f
	for sch_job_id in ${SCH_JOB_IDS}; do
		[ -n "${SCH_HAD_F}" ] || set +f
		sch_check_name "job ID" "${sch_job_id}" || exit 1
		sch_is_included "${sch_job_id}" "${sch_seen_ids}" &&
			{ sch_fail_msg "Duplicate Job ID '${sch_job_id}'."; exit 1; }
		sch_append sch_seen_ids "${sch_job_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	SCH_UNDISPATCHED_IDS="${SCH_JOB_IDS}"
	SCH_PENDING_IDS="${SCH_JOB_IDS}"

	# Main logic

	# Initialize the job termination callback if configured
	[ -n "${JOB_TERM_CB}" ] && {
		"${JOB_TERM_CB}" init || exit 1
		SCH_TERM_ACTIVE=1
	}

	SCH_LAST_PROGRESS_TIME_CS="${SCH_INIT_UPTIME_CS}"

	mkdir -p "${sch_dir}" ||
		sch_finalize 1 "Failed to create directory '${sch_dir}'."

	# Claim a unique run dir. mkdir is atomic: it fails if the name exists,
	#   so concurrent instances never collide.
	sch_run_n=0
	while :; do
		sch_run_dir="${sch_dir}/sched_${SCHED_UID}.${sch_run_n}"
		mkdir "${sch_run_dir}" 2>/dev/null && break
		sch_run_n=$((sch_run_n + 1))
		[ "${sch_run_n}" -lt 16 ] ||
			sch_finalize 1 "Failed to create run directory under '${sch_dir}'."
	done
	sch_ipc_fifo="${sch_run_dir}/ipc"

	mkfifo "${sch_ipc_fifo}" &&
	exec 3<>"${sch_ipc_fifo}" ||
		sch_finalize 1 "Failed to create FIFO '${sch_ipc_fifo}'."

	trap 'sch_finalize "${SCH_RV_USR1}"' USR1
	trap 'sch_finalize "${SCH_RV_INT_TERM}"' INT TERM

	# Start jobs

	# ${SCH_PENDING_IDS} shrinks as jobs are dispatched; jobs_abort() may also remove from it
	while [ -n "${SCH_PENDING_IDS}" ]; do
		while [ "${SCH_RUNNING_JOBS_CNT}" -ge "${SCH_MAX_JOBS}" ]; do
			[ -e "${sch_ipc_fifo}" ] || sch_finalize 1 "Scheduler FIFO disappeared."
			# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING}; ${SCH_REMAIN_TIME_CS}; ${SCH_LAST_PROGRESS_TIME_CS}
			process_done_record \
				"${sch_ipc_fifo}" \
				"${JOB_DONE_CB}"
		done
		[ -e "${sch_ipc_fifo}" ] || sch_finalize 1 "Scheduler FIFO disappeared."

		sch_job_id="${SCH_PENDING_IDS%% *}"
		[ -n "${sch_job_id}" ] || break

		refresh_remain_time

		# Callback may have broken the contract by changing sch_ns or SCHED_ID - recompute sch_ns before fork
		sch_get_ns sch_ns "schedule_jobs" || sch_finalize 1

		SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT + 1))

		sch_start_job "${sch_job_id}" "${@}" &
		sch_job_pid="${!}"
		# Track the child first - on a signal, finalize can only kill what's listed here
		sch_append SCH_RUNNING "${sch_job_pid}:${sch_job_id}"

		sch_rm_elem SCH_PENDING_IDS "${sch_job_id}" "${SCH_PENDING_IDS}"
		sch_rm_elem SCH_UNDISPATCHED_IDS "${sch_job_id}" "${SCH_UNDISPATCHED_IDS}"

		# A job start counts as scheduler progress: reset the idle timeout
		sch_get_uptime_cs sch_dl_now_cs || sch_finalize 1
		SCH_LAST_PROGRESS_TIME_CS="${sch_dl_now_cs}"

		# Register job's timeout deadline if it has one
		eval "sch_job_to=\"\${SCH_TIMEOUT_JOB_${sch_ns}${sch_job_id}:-\${SCH_JOB_TIMEOUT_S}}\""

		[ -n "${sch_job_to}" ] &&
			sch_append SCH_DEADLINES "$((sch_dl_now_cs + sch_job_to*100)):${sch_job_id}"

		[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
			"${SCHED_DISPATCH_TICK_CB}" "${sch_job_id}"
	done

	# Wait for running jobs
	while [ "${SCH_RUNNING_JOBS_CNT}" -gt 0 ]
	do
		[ -e "${sch_ipc_fifo}" ] || sch_finalize 1 "Scheduler FIFO disappeared."
		# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING}; ${SCH_REMAIN_TIME_CS}; ${SCH_LAST_PROGRESS_TIME_CS}
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

# args: one or more whitespace-separated job ID lists
jobs_init() {
	local \
		IFS=" "$'\t'$'\n' \
		sch_had_f \
		sch_cur_params \
		sch_param \
		sch_job_id \
		sch_ns \
		sch_rv=0

	# Resolved before any name is built: 'unset' with an invalid name aborts busybox ash
	sch_get_ns sch_ns "jobs_init" || return 1

	sch_has_f && sch_had_f=1
	set -f

	#shellcheck disable=SC2048
	for sch_job_id in ${*}; do
		sch_check_name "job ID" "${sch_job_id}" "jobs_init" ||
			{ sch_rv=1; break; }
		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_job_id}}\""

		for sch_param in ${sch_cur_params}; do
			case "${sch_param}" in
				''|*[!a-zA-Z0-9_]*) continue ;;
			esac
			unset "SCH_JOB_PARAM_${sch_ns}${#sch_job_id}_${sch_job_id}_${sch_param}"
		done
		unset "SCH_JOB_PARAMS_${sch_ns}${sch_job_id}" \
			"SCH_TIMEOUT_JOB_${sch_ns}${sch_job_id}"
	done

	[ -n "${sch_had_f}" ] || set +f
	return "${sch_rv}"
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
		sch_ns \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift

	sch_get_ns sch_ns "${sch_me}" || return 1
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

		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_job_id}}\""
		sch_is_included "${sch_param}" "${sch_cur_params}" ||
		sch_append "SCH_JOB_PARAMS_${sch_ns}${sch_job_id}" "${sch_param}" ||
			return 1
		export -n "SCH_JOB_PARAM_${sch_ns}${#sch_job_id}_${sch_job_id}_${sch_param}=${sch_val}"
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
		sch_ns \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift
	sch_get_ns sch_ns "${sch_me}" || return 1
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	[ "${*}" = sch_all ] && {
		eval "sch_job_params=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_job_id}}\""
		[ -n "${sch_job_params}" ] || return 0

		sch_has_f && sch_had_f=1
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
		sch_check_var_name "${sch_var}" "${sch_me}" || return 1

		eval "${sch_export}${sch_var}=\"\${SCH_JOB_PARAM_${sch_ns}${#sch_job_id}_${sch_job_id}_${sch_param}}\""
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
		sch_ns \
		sch_job_id="${1}"

	sch_get_ns sch_ns "${sch_me}" &&
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	sch_is_uint "${sch_val}" && [ "${sch_val}" -ge 1 ] || {
		sch_fail_msg "${sch_me}: invalid timeout value '${sch_val}' for job '${sch_job_id}'."
		return 1
	}
	sch_tr_leading sch_val "0"
	# Not SCH_JOB_TIMEOUT_<id>: that would collide with the internal
	# ${SCH_JOB_TIMEOUT_S} copy of ${SCHED_JOB_TIMEOUT_S} for a job named 'S'
	export -n "SCH_TIMEOUT_JOB_${sch_ns}${sch_job_id}=${sch_val}"
}

# Abort jobs by ID: drop pending ones, kill and delist running ones.
# Callable only from the scheduler's own process, i.e. from JOB_DONE_CB or SCHED_DISPATCH_TICK_CB
# args: job IDs
jobs_abort() {
	local \
		sch_me=jobs_abort \
		IFS=" "$'\t'$'\n' \
		sch_job_id sch_job_pid sch_kill_pids

	# guard against calls from DO_JOB_CB, SCHED_FINALIZE_CB or outside the scheduler
	sch_in_main_process "${sch_me}" || return 1

	for sch_job_id in "${@}"; do
		sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || continue
		sch_is_included "${sch_job_id}" "${SCH_JOB_IDS}" || { sch_fail_msg "${sch_me}: unknown job ID '${sch_job_id}'."; continue; }
		# Not dispatched yet: stays undispatched rather than aborted - outcome matters more than cause
		if sch_is_included "${sch_job_id}" "${SCH_PENDING_IDS}"; then
			sch_rm_elem SCH_PENDING_IDS "${sch_job_id}" "${SCH_PENDING_IDS}"
		elif sch_pid_of_id sch_job_pid "${sch_job_id}" "${SCH_RUNNING}"; then
			sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_job_id}" "${SCH_RUNNING}"
			[ -n "${SCH_DEADLINES}" ] &&
				sch_deadline_rm_id SCH_DEADLINES "${sch_job_id}" "${SCH_DEADLINES}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))
			sch_append SCH_UNREAPED "${sch_job_pid}:${sch_job_id}"
			sch_append SCH_ABORTED_IDS "${sch_job_id}"
			[ -n "${SCH_TERM_ACTIVE}" ] && sch_append sch_kill_pids "${sch_job_pid}"
		fi
	done
	[ -n "${sch_kill_pids}" ] || return 0
	# shellcheck disable=SC2086
	sch_term_run term ${sch_kill_pids}
	:
}
