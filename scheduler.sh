#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# Env vars specifying parameters (see REFERENCE.md):
# SCHED_MAX_JOBS
# SCHED_TIMEOUT_S
# SCHED_IDLE_TIMEOUT_S
# SCHED_JOB_TIMEOUT_S
# SCHED_FIFO
# SCHED_AUTO_PARAMS
# SCHED_ID
# SCHED_INNER_SUBSHELL
# SCHED_CGROUP_BASE
# SCHED_AWK_CMD

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

# IPC record framing: <STX><payload><ETX><LF>, written with a single printf.
# Neither byte can occur in a payload
SCH_STX=$'\002'
SCH_ETX=$'\003'

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
		sch_tr_trailing sre_l "${sre_l}" " "
		sch_tr_leading sre_l "${sre_l}" " "
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

# 1 - var name for centiseconds output
sch_get_uptime_cs() {
	local gup_time gup_cs gup_s
	export -n "${1}="

	read -r gup_time _ < /proc/uptime &&
	case "${gup_time}" in
		''|*.*.*) false ;;
		*.*) ;;
		*) false ;;
	esac &&
	gup_cs="${gup_time##*.}" &&
	case "${gup_cs}" in
		'') gup_cs=00 ;;
		?) gup_cs="${gup_cs}0" ;;
		??) ;;
		??*) gup_cs="${gup_cs%"${gup_cs#??}"}"
	esac &&
	gup_s="${gup_time%.*}" &&
	sch_is_uint "${gup_s}" "${gup_cs}" ||
	{
		sch_fail_msg "Failed to get uptime from /proc/uptime."
		export -n "${1}"=0
		return 1
	}
	gup_cs="${gup_s:-0}${gup_cs:-00}"
	sch_tr_leading gup_cs "${gup_cs}" "0"
	export -n "${1}=${gup_cs:-0}"
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
	export -n "${1:?}=${2#"${2%%[!"${3}"]*}"}"
}

sch_tr_trailing() {
	export -n "${1:?}=${2%"${2##*[!"${3}"]}"}"
}

sch_has_f() {
	case "${-}" in
		*f*) return 0 ;;
		*) return 1
	esac
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
# any extra args attached to err msg
sch_in_main_process() {
	local uid args caller="${1}"
	sch_get_uid uid &&
	[ "${uid}" = "${SCHED_UID}" ] &&
	eval "[ -n \"\${SCH_STARTED_${uid}}\" ]" &&
		return 0
	[ "${#}" -ge 1 ] && shift
	for arg in "${@}"; do
		args="${args}${args:+, }'${arg}'"
	done
	sch_fail_msg "${caller}: Scheduler is not running in this process or SCHED_UID '${SCHED_UID}' doesn't match this process UID '${uid}'.${args:+" args: ${args}"}"
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

	sch_in_main_process "${sch_me}" "${@}" ||
		return "${sch_rv:-1}"

	unset "SCH_STARTED_${SCHED_UID}"

	trap ':' USR1 INT TERM EXIT

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	[ -n "${sch_fifo_owned}" ] && rm -f "${sch_ipc_fifo}"
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
		printf "%s%s %s%s\n" "${SCH_STX}" "${sch_job_rv}" "${sch_job_id}" "${SCH_ETX}" >&3 2>/dev/null
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

	if [ -n "${SCHED_INNER_SUBSHELL}" ]; then
		( "${DO_JOB_CB:?}" "${sch_job_id}" "${@}" 3>&- )
	else
		"${DO_JOB_CB:?}" "${sch_job_id}" "${@}"
	fi

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

# Read one framed record from the IPC FIFO into an out var, framing stripped.
# Out var empty means nothing usable arrived. Returns non-zero when the read came
#   back empty-handed, so a caller can count consumed records; a mid-line timeout in
#   busybox ash also reports non-zero, as ash gives no way to tell it consumed bytes.
# 1: out var
# 2: FIFO path
# 3: read timeout, whole seconds; 0 reads nothing
sch_read_rec() {
	local srr_out="${1:?}" srr_fifo="${2:?}" srr_t="${3:?}" \
		srr_rec srr_tail srr_cut srr_frag

	export -n "${srr_out}="
	[ "${srr_t}" -gt 0 ] || return 1

	IFS= read -t "${srr_t}" -r srr_rec < "${srr_fifo}" || {
		# Timed out, possibly mid-record: busybox ash discards the bytes it consumed,
		#   bash leaves them in ${srr_rec}. Either way the rest of the record is still
		#   queued - take it now, or a later read sees it as an unframed record.
		# 'read -t 0' consumes nothing: a plain timeout must not cost another second
		IFS= read -t 0 -r _ < "${srr_fifo}" &&
			IFS= read -t 1 -r srr_tail < "${srr_fifo}"

		# Bash can complete the record from the head it kept; ash has already lost it
		srr_rec="${srr_rec}${srr_tail}"
		srr_cut=1

		# Nothing was queued: a plain read timeout
		[ -n "${srr_rec}" ] || return 1
	}

	# A bare empty line deframes to nothing, but it did consume a read
	[ -n "${srr_rec}" ] || return 0

	case "${srr_rec}" in
		*"${SCH_STX}"*) ;;
		*)
			# Straight after a timeout an unframed line is the tail of the record that
			#   timeout cut in half; at any other time it is garbage
			[ -n "${srr_cut}" ] ||
				sch_finalize 1 "Unframed record on the IPC FIFO: '${srr_rec}'."
			sch_fail_msg "Discarded truncated record tail '${srr_rec}'."
			return 0
		;;
	esac

	# Resync on the last STX: a truncated write carries no LF, so it can only
	#   arrive glued to the front of the next record - dropping the prefix recovers it
	srr_frag="${srr_rec%"${SCH_STX}"*}"
	srr_rec="${srr_rec##*"${SCH_STX}"}"
	[ -n "${srr_frag}" ] &&
		sch_fail_msg "Discarded truncated record '${srr_frag}'."

	# No ETX: a truncated writer, or a cut record whose tail never arrived
	case "${srr_rec}" in
		*"${SCH_ETX}") srr_rec="${srr_rec%"${SCH_ETX}"}" ;;
		*)
			sch_fail_msg "Discarded incomplete record '${srr_rec}'."
			srr_rec=
		;;
	esac

	export -n "${srr_out}=${srr_rec}"
}

# Drain the records queued on the IPC FIFO. Abort records act at once - ahead of
#   dispatch and of every completion record, including ones queued by an earlier call.
#   Completion records are only appended to the batch, for sch_process_done_batch().
# Waits only when a record could still arrive and there is nothing else to do
# 1: name of the completion record batch var to append to
# 2: current value of that batch var
# 3: FIFO path
# 4: current time (centiseconds)
sch_drain_fifo_records() {
	local \
		sch_cs \
		\
		sch_rec \
		sch_aborts \
		sch_read_t_cs \
		sch_read_t_s=0 \
		sch_n \
		\
		sch_had_f \
		sch_e \
		\
		sch_batch_var="${1:?}" \
		sch_queued="${2}" \
		sch_ipc_fifo="${3:?}" \
		sch_cur_time_cs="${4:?}"

	sch_has_f && sch_had_f=1

	if [ -z "${sch_queued}" ] && [ "${SCH_RUNNING_JOBS_CNT}" -gt 0 ] &&
		{ [ -z "${SCH_PENDING_IDS}" ] || [ "${SCH_RUNNING_JOBS_CNT}" -ge "${SCH_MAX_JOBS}" ]; }
	then
		# Cap the wait by the nearest job deadline
		sch_read_t_cs="${SCH_REMAIN_TIME_CS}"
		set -f
		for sch_e in ${SCH_DEADLINES}; do
			sch_cs=$(( ${sch_e%%:*} - sch_cur_time_cs ))
			[ "${sch_cs}" -lt "${sch_read_t_cs}" ] && sch_read_t_cs="${sch_cs}"
		done
		[ -n "${sch_had_f}" ] || set +f

		sch_read_t_s=$(( (sch_read_t_cs + 99) / 100 ))
	fi

	# Classify each record as abort or completion.
	# Capped at 100 records per call, so that a sustained writer cannot defer dispatch and the timeout check indefinitely
	# The first read is a no-op when polling: count it only if it consumed a record
	sch_n=0
	sch_read_rec sch_rec "${sch_ipc_fifo}" "${sch_read_t_s}" && sch_n=1
	while :; do
		# Empty means read -t timeout, or a record that deframed to nothing
		if [ -n "${sch_rec}" ]; then
			set -f
			set -- ${sch_rec}
			[ -n "${sch_had_f}" ] || set +f

			if [ "${1}" = abort ]; then
				shift
				if [ "${#}" -gt 0 ]; then
					sch_append sch_aborts "${*}"
				else
					sch_fail_msg "No job IDs found in the abort record."
				fi
			else
				[ "${#}" = 2 ] && sch_is_uint "${1}" && sch_is_included "${2}" "${SCH_JOB_IDS}" ||
					sch_finalize 1 "Malformed completion record: '${sch_rec}'."
				# Collect completion records as '<rv>:<job ID>'
				sch_append "${sch_batch_var}" "${1}:${2}"
			fi
		fi

		[ "${sch_n}" -lt 100 ] || break

		# 'read -t 0' reports whether more data is waiting, consumes nothing
		IFS= read -t 0 -r _ < "${sch_ipc_fifo}" || break
		sch_n=$((sch_n+1))
		sch_read_rec sch_rec "${sch_ipc_fifo}" 1
	done

	# Abort wins over a completion record drained in the same batch
	# ${sch_aborts} comes off the FIFO unvalidated - never glob it
	[ -n "${sch_aborts}" ] && {
		set -f
		set -- ${sch_aborts}
		[ -n "${sch_had_f}" ] || set +f
		jobs_abort "${@}"
	}

	return 0
}

# Act on a batch of drained completion records, then sweep expired job deadlines.
# 1: completion record batch, '<rv>:<job ID>' entries
sch_process_done_batch() {
	local \
		sch_now_cs \
		sch_dl_prev \
		sch_job_pid \
		sch_job_id \
		sch_done_rv \
		sch_done_id \
		\
		sch_had_f \
		sch_e \
		\
		sch_batch="${1}"

	sch_has_f && sch_had_f=1

	# One reading serves both the progress stamp and the expiry sweep. Taken before any
	#   callback runs, so time a callback spends counts against the idle timeout
	sch_get_uptime_cs sch_now_cs || sch_finalize 1

	# Arrival wins over expiry: records are handled before deadlines are swept.
	# ${sch_batch} is local to this call and holds only validated fields,
	#   so unlike the run-state list swept below it needs no noglob guard
	for sch_e in ${sch_batch}; do
		sch_done_rv="${sch_e%%:*}"
		sch_done_id="${sch_e#*:}"

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

			# Only a genuine completion is progress; a discarded late record is not
			SCH_LAST_PROGRESS_TIME_CS="${sch_now_cs}"

			[ -z "${JOB_DONE_CB}" ] ||
			sch_run_done_cb "${JOB_DONE_CB}" "${sch_done_id}" "${sch_done_rv}" ||
				sch_finalize ${?}
		else
			sch_finalize 1 "Unexpected completion record for job ID '${sch_done_id}'."
		fi
	done

	# Sweep expired deadlines:
	#   classifies jobs whose deadline has expired as timed out (rv 124) and reclaims their concurrency slots.
	# Abandoned jobs are recorded in ${SCH_UNREAPED}, so that
	#   their completion records can be recognized and discarded if they arrive later.
	[ -n "${SCH_DEADLINES}" ] && {
		# Rebuild the list, acting on entries that expired (deadline <= now).
		# Carries run state a callback can reach, so the split runs with globbing off
		sch_dl_prev="${SCH_DEADLINES}"
		SCH_DEADLINES=
		set -f
		for sch_e in ${sch_dl_prev}; do
			# Restored per iteration: the expiry path calls into user code
			[ -n "${sch_had_f}" ] || set +f

			if [ "${sch_e%%:*}" -le "${sch_now_cs}" ]; then
				sch_job_id="${sch_e#*:}"

				# Gone from SCH_RUNNING: a callback above aborted it - drop the entry,
				#   the job is already classified
				sch_pid_of_id sch_job_pid "${sch_job_id}" "${SCH_RUNNING}" || continue
				sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_job_id}" "${SCH_RUNNING}"
				SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))
				sch_append SCH_EXPIRED_IDS "${sch_job_id}"
				sch_append SCH_UNREAPED "${sch_job_pid}:${sch_job_id}"

				# Kill the timed-out job's whole process tree (wrapper included)
				[ -n "${SCH_TERM_ACTIVE}" ] && sch_term_run term "${sch_job_pid}"

				[ -z "${JOB_DONE_CB}" ] ||
				sch_run_done_cb "${JOB_DONE_CB}" "${sch_job_id}" 124 "${sch_job_pid}" ||
					sch_finalize ${?}
			else
				sch_append SCH_DEADLINES "${sch_e}"
			fi
		done
		[ -n "${sch_had_f}" ] || set +f
	}

	return 0
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


# Modular job termination (JOB_TERM_CB) - see REFERENCE.md

# Invoke '<cb> <subcommand> sch_tr_out [pids...]' and process the verified-PID report assigned by the callback:
#   scrub reported PIDs from ${SCH_RUNNING}, record them in ${SCH_TERM_KILLED}
# 1: subcommand: <term|cleanup>
# Extra args: passed to the command after the out var name
sch_term_run() {
	local sch_tr_sub="${1:?}" sch_tr_out='' sch_tr_p sch_tr_had_f sch_e

	shift
	"${JOB_TERM_CB}" "${sch_tr_sub}" sch_tr_out "${@}" ||
		sch_fail_msg "Job termination callback '${JOB_TERM_CB} ${sch_tr_sub}' returned code ${?}."

	[ -n "${sch_tr_out}" ] || return 0

	sch_has_f && sch_tr_had_f=1
	set -f
	for sch_tr_p in ${sch_tr_out}; do
		[ -n "${sch_tr_had_f}" ] || set +f
		sch_is_uint "${sch_tr_p}" || {
			sch_fail_msg "'${JOB_TERM_CB} ${sch_tr_sub}': ignoring invalid verified PID '${sch_tr_p}'."
			continue
		}

		# Extract the full entry starting with "<pid>:"
		# Job IDs contain no whitespace, so " <pid>:" can only occur at an entry boundary
		sch_e=" ${SCH_RUNNING} "
		sch_e="${sch_e#* "${sch_tr_p}":}"
		sch_e="${sch_tr_p}:${sch_e%% *}"
		sch_rm_elem SCH_RUNNING "${sch_e}" "${SCH_RUNNING}"

		sch_is_included "${sch_tr_p}" "${SCH_TERM_KILLED}" ||
		sch_append SCH_TERM_KILLED "${sch_tr_p}"
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
		sch_tr_leading val "${val}" "0"
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
		sch_done_batch \
		sch_seen_ids \
		sch_job_to \
		sch_dl_now_cs \
		SCH_RUNNING_JOBS_CNT=0 \
		sch_ipc_fifo \
		sch_fifo_owned \
		sch_run_dir \
		sch_run_n \
		sch_dir="/tmp" \
		\
		sch_cur_time_cs \
		sch_idle_remain_time_cs \
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

	if [ -n "${SCHED_FIFO}" ]; then
		# Created by the caller, removed by this run.
		# Checked right before the open: '<>' would silently create a regular
		#   file, and reads on one never block - a spin until the global timeout
		sch_ipc_fifo="${SCHED_FIFO}"
		[ -p "${sch_ipc_fifo}" ] ||
			sch_finalize 1 "SCHED_FIFO '${sch_ipc_fifo}' does not exist or is not a FIFO."
	else
		mkdir -p "${sch_dir}" ||
			sch_finalize 1 "Failed to create directory '${sch_dir}'."

		# Claim a unique run dir. mkdir is atomic: it fails if the name exists,
		#   so concurrent instances never collide.
		sch_run_n=0
		while :; do
			sch_run_dir="${sch_dir}/sched_${SCHED_UID}.${sch_run_n}"
			sch_ipc_fifo="${sch_run_dir}/ipc"
			# Owner-only FIFO and run dir
			(
				umask 077
				mkdir "${sch_run_dir}" 2>/dev/null &&
				{
					mkfifo "${sch_ipc_fifo}" || {
						rm -rf "${sch_run_dir}"
						false
					}
				}
			) && break
			sch_run_n=$((sch_run_n + 1))
			[ "${sch_run_n}" -lt 16 ] ||
				sch_finalize 1 "Failed to create run directory or FIFO file under '${sch_dir}'."
		done
	fi

	exec 3<>"${sch_ipc_fifo}" ||
		sch_finalize 1 "Failed to open FIFO '${sch_ipc_fifo}'."

	# Gates cleanup. Set only past the open: a caller-supplied path that failed validation is not ours to delete
	sch_fifo_owned=1

	trap 'sch_finalize "${SCH_RV_USR1}"' USR1
	trap 'sch_finalize "${SCH_RV_INT_TERM}"' INT TERM
	trap 'sch_finalize "${?}" "Scheduler process exited unexpectedly."' EXIT

	# Start jobs

	# Priority ladder, highest first:
	#   abort records, then filling a free concurrency slot, then completion records and expiries.
	# Aborts are applied by the drain itself; a completion record only queues up, so it can never preempt a dispatch.
	# ${SCH_PENDING_IDS} shrinks as jobs are dispatched; jobs_abort() may also remove from it
	while [ -n "${SCH_PENDING_IDS}" ] || [ "${SCH_RUNNING_JOBS_CNT}" -gt 0 ]; do
		[ -e "${sch_ipc_fifo}" ] || sch_finalize 1 "Scheduler FIFO disappeared."

		# Check if global or idle timeout is due, update SCH_REMAIN_TIME_CS
		sch_get_uptime_cs sch_cur_time_cs || sch_finalize 1
		SCH_REMAIN_TIME_CS=$(( SCH_TIMEOUT_S*100 - (sch_cur_time_cs-SCH_INIT_UPTIME_CS) ))
		sch_idle_remain_time_cs=$(( SCH_IDLE_TIMEOUT_S*100 - (sch_cur_time_cs-SCH_LAST_PROGRESS_TIME_CS) ))

		if [ ! "${SCH_REMAIN_TIME_CS}" -gt 0 ]; then
			sch_finalize "${SCH_RV_GLOBAL_TIMEOUT}" "Processing timeout (${SCH_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
		elif [ ! "${sch_idle_remain_time_cs}" -gt 0 ]; then
			sch_finalize "${SCH_RV_IDLE_TIMEOUT}" "Idle timeout (${SCH_IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
		fi

		if [ "${sch_idle_remain_time_cs}" -lt "${SCH_REMAIN_TIME_CS}" ]; then
			SCH_REMAIN_TIME_CS="${sch_idle_remain_time_cs}"
		fi

		# Waits for a wake-up only when nothing else could progress.
		# Otherwise takes what is queued and returns.
		# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING}
		sch_drain_fifo_records sch_done_batch "${sch_done_batch}" "${sch_ipc_fifo}" "${sch_cur_time_cs}"

		# Picked after the drain: an abort may have dropped the previous head
		sch_job_id="${SCH_PENDING_IDS%% *}"

		if [ "${SCH_RUNNING_JOBS_CNT}" -lt "${SCH_MAX_JOBS}" ] && [ -n "${sch_job_id}" ]; then
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

			# Keep filling free slots before any completion record is acted on
			continue
		fi

		# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING}; ${SCH_LAST_PROGRESS_TIME_CS}
		sch_process_done_batch "${sch_done_batch}"
		sch_done_batch=
	done

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
		IFS=" "$'\t'$'\n' \
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
		IFS=" "$'\t'$'\n' \
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
		IFS=" "$'\t'$'\n' \
		sch_val="${2}" \
		sch_ns \
		sch_job_id="${1}"

	sch_get_ns sch_ns "${sch_me}" &&
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	sch_is_uint "${sch_val}" && [ "${sch_val}" -ge 1 ] || {
		sch_fail_msg "${sch_me}: invalid timeout value '${sch_val}' for job '${sch_job_id}'."
		return 1
	}
	sch_tr_leading sch_val "${sch_val}" "0"
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


#
# Job termination mechanisms
#

# Kills each job's whole process tree (background children, orphaned grandchildren)
#   via one of three mechanisms:
#   - cgroup: the kernel's cgroup.kill, with kernel-verified kill reporting;
#       needs cgroup v2 and a writable cgroup subtree (root or a delegated subtree)
#   - children: walks /proc/<pid>/task/<tid>/children;
#       needs a kernel built with CONFIG_PROC_CHILDREN, plus awk
#   - ppid: walks PPID links from /proc/*/stat;
#       needs only /proc/<pid>/stat and awk - available on essentially any Linux
#   The /proc mechanisms cannot verify kills and report no verified PIDs.
# See REFERENCE.md ("Job termination").

# Usage: select the mechanism with
#   sched_use_job_term <cgroup|children|ppid|auto>
# which sets JOB_TERM_CB=sched_job_term_<mechanism> on success, or JOB_TERM_CB= and
#   returns 1 when the requested mechanism is unusable here.

# Alternatively, select the callback manually: JOB_TERM_CB=sched_job_term_ppid

# Reads env vars:
# SCHED_CGROUP_BASE (optional): writable cgroup2 directory under which the per-run cgroup is created,
#  skipping base autodetection
# SCHED_AWK_CMD (optional): awk command to use for the /proc mechanisms

# These functions own variables prefixed SCH_JT_.

### Shared helper

# Collect the valid PIDs from <pid>..., warning about and skipping the invalid ones.
# 1: out var for the space-separated valid PIDs
# 2: caller name
# 3..: candidate PIDs
sch_collect_valid_pids() {
	local cvp_out_var="${1:?}" cvp_caller="${2:?}" cvp_p
	shift 2

	export -n "${cvp_out_var}="
	for cvp_p in "${@}"; do
		sch_is_uint "${cvp_p}" ||
			{ sch_fail_msg "${cvp_caller}: term: ignoring invalid PID '${cvp_p}'."; continue; }
		sch_append "${cvp_out_var}" "${cvp_p}"
	done
	:
}


### /proc mechanisms

# Collect all live descendant PIDs (space-separated, seeds excluded)
#   by walking /proc/*/stat PPID links
# Returns 1 if /proc yielded no parseable records
# 1: out var
# 2: space-separated seed PIDs
sch_get_descendants_ppid() {
	local gd_rv gd_out \
		gd_out_var="${1:?}" gd_seeds="${2?}"

	# The awk pipeline runs in a subshell either way, so capture it here rather than
	#   printing to stdout
	gd_out="$(
		set +f
		cat /proc/[0-9]*/stat 2>/dev/null | {
			set -f
			# shellcheck disable=SC2016
			${SCHED_AWK_CMD:-awk} -v seeds="${gd_seeds}" '
			/^[0-9]+ \(/ {
				pid = $1
				s = $0
				# Strip "pid (comm) X " (X = single state char).
				# comm may contain spaces and parens - the greedy match handles those;
				#   a line that does not match is a fragment of a newline-containing comm - skip
				if (!sub(/^[0-9]+ \(.*\) . /, "", s)) next
				split(s, f, " ")
				if (f[1] !~ /^[0-9]+$/) next
				ppid[pid] = f[1]
				valid++
			}
			END {
				if (!valid) exit 1
				n = split(seeds, a, " ")
				for (i = 1; i <= n; i++)
					if (a[i] ~ /^[0-9]+$/) {
						seed[a[i]] = 1
						want[a[i]] = 1
					}
				do {
					changed = 0
					for (p in ppid)
						if (!(p in want) && (ppid[p] in want)) { want[p] = 1; changed = 1 }
				} while (changed)
				for (p in want) if (!(p in seed)) printf "%s ", p
			}'
		}
	)"
	gd_rv=${?}

	export -n "${gd_out_var}=${gd_out}"
	return ${gd_rv}
}

# Walk /proc/<pid>/task/<tid>/children breadth-first from the seeds and collect all live descendant PIDs
#   (space-separated, seeds excluded).
# Globs task/* so children forked by non-leader threads are found.
# 1: out var
# 2: space-separated seed PIDs
sch_get_descendants_children() {
	local \
		gd_had_f gd_rv=0 \
		gd_frontier gd_next gd_seen gd_files \
		gd_p gd_f gd_kid \
		gd_out_var="${1}" gd_seeds="${2}"

	sch_has_f && gd_had_f=1

	gd_seen="${gd_seeds}"
	gd_frontier="${gd_seeds}"
	export -n "${gd_out_var}="

	while [ -n "${gd_frontier}" ]; do
		gd_files=
		set -f
		# shellcheck disable=SC2086
		for gd_p in ${gd_frontier}; do
			set +f
			for gd_f in /proc/"${gd_p}"/task/*/children; do
				sch_append gd_files "${gd_f}"
			done
		done
		set -f

		# getline < file: -1 on missing file (skipped), 0 at EOF
		gd_next="$(${SCHED_AWK_CMD:-awk} -v paths="${gd_files}" '
		BEGIN {
			num_paths = split(paths, path_list, " ")
			for (i = 1; i <= num_paths; i++) {
				children_file = path_list[i]
				while ((getline line < children_file) > 0) {
					num_kids = split(line, child_pids, " ")
					for (j = 1; j <= num_kids; j++) printf "%s ", child_pids[j]
				}
				close(children_file)
			}
		}')" || gd_rv=${?}

		gd_frontier=
		# shellcheck disable=SC2086
		for gd_kid in ${gd_next}; do
			sch_is_included "${gd_kid}" "${gd_seen}" && continue
			sch_append gd_seen "${gd_kid}"
			sch_append gd_frontier "${gd_kid}"
			sch_append "${gd_out_var}" "${gd_kid}"
		done
	done

	[ -n "${gd_had_f}" ] || set +f

	return ${gd_rv}
}

# Shared implementation of the /proc job termination callbacks.
#   init, setup and cleanup are no-ops: no per-run or per-job state is held.
#   term freezes, re-scans to a fixpoint and kills.
# Reports no verified killed PIDs (assigns empty list to <out var>):
#   kill verification is not possible here.
# 1: mechanism (ppid|children)
# 2: subcommand
# 3..: subcommand args
sch_term_proc() {
	local \
		mech="${1:?}" \
		caller="sched_job_term_${1}" \
		had_f \
		seeds all prev found try \
		subcmd="${2}"

	shift
	[ -n "${1}" ] && shift

	case "${subcmd}" in
		init|setup|cleanup) return 0 ;;
		term) : ;;
		*) sch_fail_msg "${caller}: unknown subcommand '${subcmd}'."; return 1
	esac

	sch_check_name "var" "${1}" "${caller}: term" || return 1
	export -n "${1}="
	shift

	sch_collect_valid_pids seeds "${caller}" "${@}"
	[ -n "${seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill:
	#   each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	all="${seeds}"
	prev=

	sch_has_f && had_f=1
	set -f

	for try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${all} 2>/dev/null
		case "${mech}" in
			ppid) sch_get_descendants_ppid found "${all}" ;;
			children) sch_get_descendants_children found "${all}" ;;
			*) false
		esac ||
		{
			sch_fail_msg "${caller}: /proc scan failed."
			break
		}
		sch_append all "${found}"
		sch_tr_trailing all "${all}" " "
		[ "${all}" = "${prev}" ] && break
		prev="${all}"
	done

	# SIGKILL is delivered to stopped processes; no CONT needed
	# shellcheck disable=SC2086
	[ -n "${all}" ] && kill -KILL ${all} 2>/dev/null

	[ -n "${had_f}" ] || set +f
	:
}

# Job termination callbacks (see the protocol contract in REFERENCE.md):
#   sched_job_term_<mech> init|setup             (no-ops)
#   sched_job_term_<mech> term <out var> <pid>...
#   sched_job_term_<mech> cleanup <out var>
sched_job_term_ppid() { sch_term_proc ppid "${@}"; }

sched_job_term_children() { sch_term_proc children "${@}"; }


### cgroup mechanism

# Create the per-run base cgroup as a child of <parent dir>
#
# mkdir is atomic (fails if the name exists), so concurrent scheduler instances -
#   even ones sharing <pid> across PID namespaces under a shared SCHED_CGROUP_BASE - claim distinct bases.
# 1: out var for the created base cgroup path
# 2: parent dir
# 3: PID to name the base after
sch_mk_base_cgroup() {
	local mbc_n=0 mbc_d

	export -n "${1}="
	while :; do
		mbc_d="${2}/sched_${3:?}.${mbc_n}"
		mkdir "${mbc_d}" 2>/dev/null && { export -n "${1}=${mbc_d}"; return 0; }
		mbc_n=$((mbc_n + 1))
		[ "${mbc_n}" -lt 16 ] || return 1
	done
}

# Set up the per-run base cgroup which will hold per-job child cgroups. Base autodetection tries,
#   in order:
#   - this process's own cgroup: writable when running as root,
#       or unprivileged inside a delegated subtree (e.g. a systemd user session
#       or user service, or any command launched via 'systemd-run --user --scope')
#   - cgroup2 mount root: writable when running as root
# Validates the whole mechanism by moving a probe subshell into a child cgroup
sch_cgroup_init() {
	local \
		me=sch_cgroup_init \
		mnt own line fstype cand uid pid \
		hint="need root or a delegated cgroup subtree, e.g. run via 'systemd-run --user --scope <cmd>'"

	SCH_JT_BASE=
	SCH_JT_PENDING=

	# Cgroup base names stay PID-keyed; collisions are handled by the '.<n>' retry
	sch_get_uid uid || return 1
	pid="${uid%%_*}"

	# Locate the cgroup2 mountpoint
	mnt=
	while read -r _ line fstype _; do
		[ "${fstype}" = cgroup2 ] && { mnt="${line}"; break; }
	done 2>/dev/null < /proc/mounts

	[ -n "${mnt}" ] ||
		{ sch_fail_msg "${me}: no cgroup2 mount found."; return 1; }

	if [ -n "${SCHED_CGROUP_BASE}" ]; then
		# Specified by the user
		cand="${SCHED_CGROUP_BASE}"
		sch_tr_trailing cand "${cand}" "/"
		sch_mk_base_cgroup SCH_JT_BASE "${cand}" "${pid}" || {
			sch_fail_msg "${me}: cannot create a cgroup under '${SCHED_CGROUP_BASE}'."
			return 1
		}
	else
		# Own cgroup path: the '0::<path>' (cgroup v2) entry
		own=
		while IFS= read -r line; do
			case "${line}" in
				0::*) own="${line#0::}"; break
			esac
		done 2>/dev/null < /proc/self/cgroup

		cand="${mnt}${own}"
		sch_tr_trailing cand "${cand}" "/"

		sch_mk_base_cgroup SCH_JT_BASE "${cand}" "${pid}" ||
		sch_mk_base_cgroup SCH_JT_BASE "${mnt}" "${pid}" || {
			sch_fail_msg "${me}: cannot create a cgroup under '${cand}' or '${mnt}' (${hint})."
			return 1
		}
	fi

	[ -f "${SCH_JT_BASE}/cgroup.kill" ] || {
		sch_fail_msg "${me}: no cgroup.kill in '${SCH_JT_BASE}' (kernel >= 5.14 required)."
		rmdir "${SCH_JT_BASE}" 2>/dev/null
		SCH_JT_BASE=
		return 1
	}

	mkdir "${SCH_JT_BASE}/probe" 2>/dev/null &&
	{
		{ printf '0\n' 2>/dev/null > "${SCH_JT_BASE}/probe/cgroup.procs"; } &
		wait "${!}"
	} &&
	rmdir "${SCH_JT_BASE}/probe" 2>/dev/null || {
		sch_fail_msg "${me}: job processes cannot join cgroups under '${SCH_JT_BASE}' (${hint})."
		rmdir "${SCH_JT_BASE}/probe" "${SCH_JT_BASE}" 2>/dev/null
		SCH_JT_BASE=
		return 1
	}
}

# Try to remove the per-job cgroup of the job with wrapper PID <pid>.
# rmdir succeeds only once the kernel confirmed cgroup empty and fully reaped,
#   i.e. kill of the job's process tree is verified: append the PID to <out var>
# Otherwise park the PID in ${SCH_JT_PENDING} for later retries.
# 1: out var for reaped PID
# 2: job wrapper PID
sch_rm_job_cgroup() {
	export -n "${1:?}="
	rmdir "${SCH_JT_BASE:?}/job_${2:?}" 2>/dev/null &&
		{ export -n "${1:?}=${2}"; return 0; }
	sch_is_included "${2}" "${SCH_JT_PENDING}" ||
		sch_append SCH_JT_PENDING "${2}"
	return 1
}

# Kill all processes remaining in the per-job cgroup of the job with wrapper PID <pid>
#   and try to remove the cgroup (verifying the kill)
# 1: out var for reaped PID
# 2: job wrapper PID
sch_kill_job_cgroup() {
	local kj_d="${SCH_JT_BASE:?}/job_${2:?}"

	export -n "${1:?}="
	[ -d "${kj_d}" ] || return 0
	printf '1\n' 2>/dev/null > "${kj_d}/cgroup.kill"
	sch_rm_job_cgroup "${1:?}" "${2}"
	:
}

# 'term' body: retry previously unverified removals, then kill the listed jobs.
#   Always runs the retry pass and always assigns <out var> - no empty-seeds shortcut.
# 1: out var for kernel-verified killed PIDs (already validated and cleared by the caller)
# 2..: job wrapper PIDs
sch_kill_jobs_cgroup() {
	local \
		kjs_me=sch_kill_jobs_cgroup \
		kjs_reaped kjs_seeds kjs_p kjs_prev \
		kjs_out_var="${1}"

	shift 2>/dev/null

	# Retry previously unverified removals first, then kill
	kjs_prev="${SCH_JT_PENDING}"
	SCH_JT_PENDING=
	export -n "${kjs_out_var}="

	# shellcheck disable=SC2086
	for kjs_p in ${kjs_prev}; do
		sch_rm_job_cgroup kjs_reaped "${kjs_p}"
		sch_append "${kjs_out_var}" "${kjs_reaped}"
	done

	sch_collect_valid_pids kjs_seeds "${kjs_me}" "${@}"
	# shellcheck disable=SC2086
	for kjs_p in ${kjs_seeds}; do
		sch_kill_job_cgroup kjs_reaped "${kjs_p}"
		sch_append "${kjs_out_var}" "${kjs_reaped}"
	done

	:
}

# 'cleanup' body: sweep all remaining job cgroups, retry unverified removals and remove the base cgroup.
# 1: out var for kernel-verified killed PIDs (already validated and cleared by the caller)
sch_cleanup_cgroup() {
	local \
		clc_me=sch_cleanup_cgroup \
		clc_reaped clc_p clc_prev clc_try clc_had_f \
		clc_out_var="${1}"

	export -n "${clc_out_var}="

	# Sweep all remaining job cgroups - including those of completed jobs that left processes behind:
	#   nothing a job spawned survives the run.
	# The glob must expand regardless of the caller's noglob state (the application may run under set -f)
	[ -n "${SCH_JT_BASE}" ] && {
		sch_has_f && clc_had_f=1
		set +f
		set -- "${SCH_JT_BASE}"/job_*
		[ -z "${clc_had_f}" ] || set -f
		for clc_p in "${@}"; do
			[ -d "${clc_p}" ] || continue
			clc_p="${clc_p##*/job_}"
			sch_is_uint "${clc_p}" && {
				sch_kill_job_cgroup clc_reaped "${clc_p}"
				sch_append "${clc_out_var}" "${clc_reaped}"
			}
		done
	}

	# Bounded retry for unverified removals:
	#   rmdir succeeds only once the kernel has fully reaped a cgroup's processes
	for clc_try in 1 2 3; do
		[ -n "${SCH_JT_PENDING}" ] || break
		clc_prev="${SCH_JT_PENDING}"
		SCH_JT_PENDING=
		# shellcheck disable=SC2086
		for clc_p in ${clc_prev}; do
			sch_rm_job_cgroup clc_reaped "${clc_p}"
			sch_append "${clc_out_var}" "${clc_reaped}"
		done
		[ -n "${SCH_JT_PENDING}" ] || break
		[ "${clc_try}" = 3 ] || sleep 1
	done
	[ -z "${SCH_JT_BASE}" ] || {
		rmdir "${SCH_JT_BASE}" 2>/dev/null ||
			sch_fail_msg "${clc_me}: failed to remove cgroup(s) under '${SCH_JT_BASE}'."
	}
	SCH_JT_BASE=

	:
}

# Job termination callback (see the protocol contract in REFERENCE.md):
#   sched_job_term_cgroup init
#   sched_job_term_cgroup setup <job_id> <pid>   (runs in the job process)
#   sched_job_term_cgroup term <out var> <pid>...
#   sched_job_term_cgroup cleanup <out var>
# 'term' and 'cleanup' report kernel-verified killed PIDs by assigning
#   space-separated list to <out var>.
sched_job_term_cgroup() {
	local \
		me=sched_job_term_cgroup \
		sub="${1}"

	shift 2>/dev/null

	case "${sub}" in
		init)
			sch_cgroup_init
		;;

		setup)
			# Join a fresh per-job cgroup: writing '0' to cgroup.procs moves the writing process,
			#   which is the job process since the core invokes 'setup' there;
			#   all the job's descendants inherit the membership
			sch_is_uint "${2}" ||
				{ sch_fail_msg "${me}: setup: invalid PID '${2}'."; return 1; }
			mkdir "${SCH_JT_BASE:?}/job_${2}" 2>/dev/null &&
			printf '0\n' 2>/dev/null > "${SCH_JT_BASE}/job_${2}/cgroup.procs" ||
			{
				sch_fail_msg "${me}: job '${1}' (PID ${2}): failed to join cgroup '${SCH_JT_BASE}/job_${2}'."
				return 1
			}
		;;

		term)
			sch_check_name "var" "${1}" "${me}: term" || return 1
			export -n "${1}="
			sch_kill_jobs_cgroup "${@}"
		;;

		cleanup)
			sch_check_name "var" "${1}" "${me}: cleanup" || return 1
			export -n "${1}="
			sch_cleanup_cgroup "${1}"
		;;

		*)
			sch_fail_msg "${me}: unknown subcommand '${sub}'."
			return 1
	esac
}


### Probes and mechanism selection

# Return 0 if the PPID-walk mechanism can work here:
#   awk is available and /proc exposes per-process stat records.
sch_term_probe_ppid() {
	sch_is_cmd "${SCHED_AWK_CMD:-awk}" && [ -r /proc/self/stat ]
}

# Return 0 if awk is available and the kernel exposes /proc/<pid>/task/<tid>/children (needs CONFIG_PROC_CHILDREN).
sch_term_probe_children() {
	local had_f

	sch_is_cmd "${SCHED_AWK_CMD:-awk}" || return 1

	# Resolve the glob with globbing on; an absent children file leaves the pattern literal,
	#   so a live glob is the presence test
	sch_has_f && had_f=1
	set +f
	set -- /proc/self/task/*/children
	[ -n "${had_f}" ] && set -f

	[ -e "${1}" ]
}

# Return 0 if cgroup v2 job termination is supported in the current environment:
#   runs the same validation 'sched_job_term_cgroup init' performs, then cleans up after itself.
# Honors ${SCHED_CGROUP_BASE} if set.
sch_term_probe_cgroup() {
	local SCH_JT_BASE SCH_JT_PENDING rv=0

	SCHED_FAIL_MSG_CB=: sch_cgroup_init || rv=1

	[ -n "${SCH_JT_BASE}" ] && rmdir "${SCH_JT_BASE}" 2>/dev/null
	return "${rv}"
}

# Select a job termination mechanism: probe it and, on success, arm the matching callback
#   by assigning JOB_TERM_CB=sched_job_term_<mech>.
# 'auto' tries cgroup -> children -> ppid.
# On failure - the mechanism is unusable here, or the argument is outside the closed set -
#   JOB_TERM_CB is assigned an empty value, so a failed selection never leaves a stale callback armed.
# Prints errors unless run with '-q'.
# 0 (optional): '-q' for quiet mode (no errors)
# 1: cgroup|children|ppid|auto
# Return codes: 0 - selected; 1 - not selected
sched_use_job_term() {
	local q
	[ "${1}" = '-q' ] && { q=1; shift; }
	local mech="${1}" arg="${1}"

	export -n JOB_TERM_CB=

	case "${mech}" in
		auto)
			if sch_term_probe_cgroup; then mech=cgroup
			elif sch_term_probe_children; then mech=children
			elif sch_term_probe_ppid; then mech=ppid
			else false
			fi
		;;
		cgroup) sch_term_probe_cgroup ;;
		children) sch_term_probe_children ;;
		ppid) sch_term_probe_ppid ;;
		*) false
	esac 2>/dev/null ||
	{
		[ -n "${q}" ] && return 1
		if [ "${arg}" = auto ]; then
			sch_fail_msg "Failed to find a functional job termination mechanism for this system."
		else
			sch_fail_msg "Job termination mechanism '${arg}' is unavailable."
		fi
		return 1
	}

	JOB_TERM_CB="sched_job_term_${mech}"
}
