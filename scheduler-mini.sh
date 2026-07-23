#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

### Helpers

sch_is_included() {
	case " ${2} " in
		*" ${1} "*) return 0 ;;
		*) return 1
	esac
}

sch_append() {
	sch_check_name "var" "${1}" || return 1
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
		sch_rm_trailing sre_l " "
		sch_rm_leading sre_l " "
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
	sch_rm_leading cs "0"
	export -n "${1}=${cs:-0}"
}

sch_fail_msg() {
	if [ -n "${SCHED_FAIL_MSG_CB}" ] && sch_is_cmd "${SCHED_FAIL_MSG_CB}"; then
		"${SCHED_FAIL_MSG_CB}" "${@}"
	else
		printf '%s\n' "${@}" >&2
	fi
}

sch_is_cmd() {
	command -v "${1}" 1>/dev/null 2>&1
}

sch_had_f() {
	case "${-}" in
		*f*) return 0 ;;
		*) return 1
	esac
}

sch_rm_leading() {
	sch_check_name "var" "${1}" || return 1
	eval "${1}=\"\${${1}#\"\${${1}%%[!\"\${2}\"]*}\"}\""
}

sch_rm_trailing() {
	sch_check_name "var" "${1}" || return 1
	eval "${1}=\"\${${1}%\"\${${1}##*[!\"\${2}\"]}\"}\""
}

# Get PID of current shell process
# 1 - var name for output
sch_get_cur_pid() {
	local __pid line
	export -n "${1:?}="

	while IFS= read -r line; do
		case "${line}" in
			Pid:*)
				__pid="${line##*[!0-9]}"
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
		IFS=" "$'\t'$'\n' \
		sch_rv="${1}"

	trap ':' USR1 INT TERM

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	[ -n "${sch_run_dir}" ] && rm -rf "${sch_run_dir}"

	if [ -n "${SCH_HAD_F}" ]; then set -f; else set +f; fi

	# shellcheck disable=SC2086
	[ -n "${JOB_TERM_CB}" ] &&
	[ -n "${SCH_RUNNING_PIDS}" ] &&
		sch_term_run ${SCH_RUNNING_PIDS}

	# Add pids of timed-out jobs to <running_pids>
	for sch_exp_e in ${SCH_EXPIRED}; do
		sch_append SCH_RUNNING_PIDS "${sch_exp_e%%:*}"
	done

	# Compute sch_unfinished_ids
	for sch_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_id}" "${SCH_OK_IDS} ${SCH_UNDISPATCHED_IDS} ${SCH_FAIL_IDS} ${SCH_EXPIRED_IDS}" ||
			sch_append sch_unfinished_ids "${sch_id}"
	done

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

	job_get_params -export "${sch_job_id}" sch_all || exit 1

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
		sch_rec \
		sch_rec_tail \
		sch_rec_garbage \
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

	# Cap the wait by the nearest job deadline if any
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

	# Wait for the next completion record. Read the whole line into one raw field.
	[ "${sch_read_t_s}" -gt 0 ] && {
		IFS= read -t "${sch_read_t_s}" -r sch_rec < "${sch_ipc_fifo}" ||
		[ -z "${sch_rec}" ] ||
		{
			# Non-zero code means read -t timeout mid-line,
			#   so partial line consumed and remainder is buffered in the FIFO
			# Finish reading
			IFS= read -t 1 -r sch_rec_tail < "${sch_ipc_fifo}"
			sch_rec="${sch_rec}${sch_rec_tail}"
		}
	}

	# Re-split the completion record
	# Empty record unambiguously means read -t timeout
	[ -n "${sch_rec}" ] && {
		set -f
		set -- ${sch_rec}
		sch_done_pid=${1}
		sch_done_rv=${2}
		sch_done_id=${3}
		shift 3
		sch_rec_garbage="${*}"
		[ -n "${sch_had_f}" ] || set +f
	}

	# Process the completion record if any
	# Arrival wins over expiry: the record is handled before deadlines are swept
	[ -n "${sch_done_pid}${sch_done_rv}${sch_done_id}" ] && {
		[ -z "${sch_rec_garbage}" ] &&
		sch_is_uint "${sch_done_pid}" "${sch_done_rv}" &&
		[ -n "${sch_done_id}" ] &&
		sch_is_included "${sch_done_id}" "${SCH_JOB_IDS}" ||
			sch_finalize 1 "Malformed completion record: either bad PID '${sch_done_pid}' or bad RV '${sch_done_rv}' or bad job ID '${sch_done_id}' or trailing garbage '${sch_rec_garbage}'."

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
			# Unknown PID: either
			# - late record from a timed out job
			# - or fatal protocol error
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

		# ${sch_expired} is glob-safe
		for sch_e in ${sch_expired}; do
			[ -n "${sch_had_f}" ] || set +f
			sch_pid="${sch_e%%:*}"
			sch_id="${sch_e#*:*:}"

			sch_rm_elem SCH_RUNNING_PIDS "${sch_pid}" "${SCH_RUNNING_PIDS}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))

			sch_append SCH_EXPIRED_IDS "${sch_id}" &&
			sch_append SCH_EXPIRED "${sch_e}" ||
				sch_finalize 1

			# Kill the timed-out job's whole process tree (wrapper included)
			[ -n "${JOB_TERM_CB}" ] && sch_term_run "${sch_pid}"

			[ -z "${sch_job_done_cb}" ] ||
			"${sch_job_done_cb}" "${sch_id}" 124 "${sch_pid}" ||
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
	:
}

sch_deadline_rm_pid() {
	local sdr_e=" ${3} "
	sdr_e="${sdr_e#* "${2}":}"
	sdr_e="${2}:${sdr_e%% *}"

	sch_is_included "${sdr_e}" "${3}" ||
		{ export -n "${1:?}=${3}"; return 1; }
	sch_rm_elem "${1}" "${sdr_e}" "${3}"
}


# Args: passed to the command
sch_term_run() {
	"${JOB_TERM_CB}" "${@}" ||
		sch_fail_msg "Job termination callback '${JOB_TERM_CB}' returned code ${?}."
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

	# 1: out var
	# 2: in value
	# 3: required(1/empty)
	sch_normalize_uint() {
		local val="${2}"
		export -n "${1:?}="
		[ -z "${val}" ] && [ -z "${3}" ] && return 0
		sch_is_uint "${val}" && [ "${val}" -ge 1 ] ||
			{ sch_fail_msg "Invalid value '${val}' of env var SCHED_${1#SCH_}."; return 1; }
		sch_rm_leading val "0"
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
		sch_run_dir \
		sch_run_n \
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
	
	: "${SCH_REMAIN_TIME_CS}" "${SCH_JOB_TIMEOUT_S}" # Silence shellcheck warning

	shift 1

	# !!! Any additional arguments are passed as-is to user-defined ${DO_JOB_CB} via sch_start_job()

	# Register noglob state
	sch_had_f && SCH_HAD_F=1

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

	sch_rm_trailing sch_dir "/"

	[ -n "${sch_dir}" ] ||
		{ sch_fail_msg "Invalid value '${SCHED_DIR}' of env var SCHED_DIR."; exit 1; }

	# Convert ${SCH_JOB_IDS} to space-separated list
	sch_normalize_ids SCH_JOB_IDS "${SCH_JOB_IDS}" || exit 1

	# Validate job IDs ([a-zA-Z0-9_] only), check for duplicates.
	set -f
	for sch_id in ${SCH_JOB_IDS}; do
		[ -n "${SCH_HAD_F}" ] || set +f
		sch_check_name "job ID" "${sch_id}" || exit 1
		sch_is_included "${sch_id}" "${sch_seen_ids}" &&
			{ sch_fail_msg "Duplicate Job ID '${sch_id}'."; exit 1; }
		sch_append sch_seen_ids "${sch_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	SCH_UNDISPATCHED_IDS="${SCH_JOB_IDS}"

	# Main logic

	sch_get_uptime_cs SCH_INIT_UPTIME_CS &&
	sch_get_cur_pid SCH_PID ||
		exit 1

	SCH_LAST_PROGRESS_TIME_CS="${SCH_INIT_UPTIME_CS}"

	mkdir -p "${sch_dir}" ||
		sch_finalize 1 "Failed to create directory '${sch_dir}'."

	sch_run_n=0
	while :; do
		sch_run_dir="${sch_dir}/sched_${SCH_PID}.${sch_run_n}"
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

	# ${SCH_JOB_IDS} are glob-safe here
	for sch_id in ${SCH_JOB_IDS}; do
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
		sch_get_uptime_cs sch_dl_now_cs || sch_finalize 1
		SCH_LAST_PROGRESS_TIME_CS="${sch_dl_now_cs}"

		# Register job's timeout deadline if it has one
		eval "sch_job_to=\"\${SCH_TIMEOUT_JOB_${sch_id}:-\${SCH_JOB_TIMEOUT_S}}\""

		[ -n "${sch_job_to}" ] &&
			sch_append SCH_DEADLINES "${sch_pid}:$((sch_dl_now_cs + sch_job_to*100)):${sch_id}"

		[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
			"${SCHED_DISPATCH_TICK_CB}" "${sch_id}"
	done

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

# args: one or more whitespace-separated job ID lists
jobs_init() {
	local \
		IFS=" "$'\t'$'\n' \
		sch_had_f \
		sch_cur_params \
		sch_param \
		sch_job_id \
		sch_rv=0

	sch_had_f && sch_had_f=1
	set -f

	#shellcheck disable=SC2048
	for sch_job_id in ${*}; do
		sch_check_name "job ID" "${sch_job_id}" "jobs_init" ||
			{ sch_rv=1; break; }
		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""

		for sch_param in ${sch_cur_params}; do
			case "${sch_param}" in
				''|*[!a-zA-Z0-9_]*) continue ;;
			esac
			unset "SCH_JOB_PARAM_${#sch_job_id}_${sch_job_id}_${sch_param}"
		done
		unset "SCH_JOB_PARAMS_${sch_job_id}" \
			"SCH_TIMEOUT_JOB_${sch_job_id}"
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
			sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|JOB_TERM_CB|IFS)
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
	sch_rm_leading sch_val "0"
	export -n "SCH_TIMEOUT_JOB_${sch_job_id}=${sch_val}"
}


# Prints to stdout all live descendant PIDs (space-separated, seeds excluded).
# 1: space-separated seed PIDs
sch_get_descendants_mini() {
	local sjt_had_f sjt_rv sjt_seeds="${1}"

	sch_had_f && sjt_had_f=1
	set +f

	cat /proc/[0-9]*/stat 2>/dev/null | {
		set -f
		# shellcheck disable=SC2016
		${SCHED_AWK_CMD:-awk} -v seeds="${sjt_seeds}" '
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
	sjt_rv=${?}
	[ -n "${sjt_had_f}" ] && set -f
	return ${sjt_rv}
}

# Job termination callback (ppid-walk mechanism)
# Args: job PIDs
sched_job_term_mini() {
	local \
		me=sched_job_term_mini \
		sjt_had_f \
		sjt_p sjt_seeds sjt_all sjt_prev sjt_found sjt_try

	sjt_seeds=
	for sjt_p in "${@}"; do
		sch_is_uint "${sjt_p}" ||
			{ sch_fail_msg "${me}: ignoring invalid PID '${sjt_p}'."; continue; }
		sch_append sjt_seeds "${sjt_p}"
	done
	[ -n "${sjt_seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill:
	#   each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	sjt_all="${sjt_seeds}"
	sjt_prev=

	sch_had_f && sjt_had_f=1
	set -f

	for sjt_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${sjt_all} 2>/dev/null
		sjt_found="$(sch_get_descendants_mini "${sjt_all}")" || {
			sch_fail_msg "${me}: /proc scan failed."
			break
		}
		sjt_all="${sjt_seeds} ${sjt_found}"
		sch_rm_trailing sjt_all " "
		[ "${sjt_all}" = "${sjt_prev}" ] && break
		sjt_prev="${sjt_all}"
	done

	# shellcheck disable=SC2086
	kill -KILL ${sjt_all} 2>/dev/null

	[ -n "${sjt_had_f}" ] || set +f
	:
}
