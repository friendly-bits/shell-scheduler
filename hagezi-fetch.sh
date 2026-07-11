#!/bin/sh
# shellcheck disable=SC3045,SC2329,SC3043
# shellcheck source=/dev/null

# Example script for integration of the shell-scheduler library.

# Downloads several HaGeZi DNS blocklists concurrently.

SCHEDULER_LIB="${SCHEDULER_LIB:-./scheduler.sh}"
. "${SCHEDULER_LIB}"

# --- Job list: one numeric ID per list, per-job data via JOB_*_<id> ---
job_set_params pro      "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt"
job_set_params proplus  "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.txt"
job_set_params multi    "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi.txt"
job_set_params tif      "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"
job_set_params invalid  "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/invalid.txt"
job_set_params gambling "url=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/gambling.txt"


JOBS_CNT=6
SUCCESS_CNT=0

IDS="pro proplus multi tif invalid gambling"

OUT_DIR="/tmp/lists"
mkdir -p "${OUT_DIR}" || exit 1

# --- Callbacks ---

# Job execution callback - DO_JOB_CB
# Downloads one list; returns wget's exit code.
download_list()
{
	local name="${1:?}" rv

	printf 'Downloading: '%s' from %s\n' "${name}" "${url:?}"

	# shellcheck disable=SC2154
	wget -q -O "${OUT_DIR}/${name}.txt" "${url}"
	rv=$?

	# Don't leave a partial/empty file behind on failure.
	[ "${rv}" = 0 ] || rm -f "${OUT_DIR}/${name}.txt"

	return "${rv}"
}

# Job completion callback - JOB_DONE_CB
#   per-job completion bookkeeping.
job_done()
{
	local name="${1}" rv="${2}"

	if [ "${rv}" = 0 ]
	then
		SUCCESS_CNT=$((SUCCESS_CNT + 1))
		printf 'OK: %s\n' "${name}"
	else
		printf 'Failed: %s (wget rv=%s)\n' "${name}" "${rv}"
	fi
}

# Scheduler error reporting callback - SCHED_FAIL_MSG_CB
sched_error()
{
	printf 'scheduler error: %s\n' "${@}" >&2
}


# Scheduler termination callback - SCHED_FINALIZE_CB
#
# wget PIDs are discovered via `pgrep -P` and signalled directly,
#   since sending the kill signal to the shell process which invoked wget
#   would only orphane the wget process rather than killing it.
#
# NOTE: The scheduler (including this callback) runs in a background child process.
#   Updates to SUCCESS_CNT made in job_done() are visible here but not in the scope of the main process.
finalize_dl()
{
	local \
		rv="${1}" running_pids="${2}" \
		running_pid child_pids

	if [ -n "${running_pids}" ]
	then
		for running_pid in ${running_pids}
		do
			child_pids="${child_pids}${child_pids:+ }$(pgrep -P "${running_pid}" 2>/dev/null)"
		done

		printf '\n%s\n' "Killing job execution PIDs: ${running_pids}"
		[ -n "${child_pids}" ] && printf '%s\n' "Killing child PIDs (probably wget): ${child_pids}"
		# shellcheck disable=SC2086
		kill -TERM ${child_pids} ${running_pids} 2>/dev/null
	fi

	printf 'Downloaded: %s\n' "${SUCCESS_CNT}"
	printf 'Failed: %s\n' "$((JOBS_CNT - SUCCESS_CNT))"

	return 0
}

# --- Run ---

DO_JOB_CB=download_list \
JOB_DONE_CB=job_done \
SCHED_FAIL_MSG_CB=sched_error \
SCHED_FINALIZE_CB=finalize_dl \
SCHED_MAX_JOBS=4 \
SCHED_TIMEOUT_S=120 \
SCHED_AUTO_PARAMS=1 \
	schedule_jobs "${IDS}" &
sched_pid=$!

# Forward Ctrl-C/TERM as the scheduler's own cancellation signal (USR1), so
# in-flight downloads get the same cleanup path as a timeout.
trap '
	trap - INT TERM
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	exit "$?"
' INT TERM

wait "${sched_pid}"
exit "$?"
