## Real-world example: concurrent downloader for DNS blocklists.

```sh
#!/bin/sh
# shellcheck disable=SC3045,SC2329,SC3043
# shellcheck source=/dev/null

# Download several HaGeZi DNS blocklists concurrently.

SCHEDULER_LIB="${SCHEDULER_LIB:-./scheduler.sh}"
. "${SCHEDULER_LIB}"

# Params assignment
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

	printf '%s\n' "Downloading: ${name} (${url:?})"

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


# Scheduler completion callback - SCHED_FINALIZE_CB
#
# wget PIDs are discovered via `pgrep -P` and signalled directly,
#   since sending the kill signal to the shell process which invoked wget
#   would only orphan the wget process rather than killing it.
#
# NOTE: The scheduler (including this callback) runs in a background child process.
#   Collected statuses are visible here but not in the scope of the main process.
finalize_dl()
{
	local running_pid child_pids
	local \
		rv="${1}" \
		running_pids="${2}" \
		ok_ids="${3}" \
		fail_ids="${4}" \
		unfinished_ids="${5}" \
		undispatched_ids="${6}" \
		expired_ids="${7}"

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

	printf '\n'
	printf '%s\n' "OK count: ${SUCCESS_CNT}"
	printf '%s\n' "Failed count (including timed-out, unfinished and undispatched): $((JOBS_CNT - SUCCESS_CNT))"

	printf '\n'
	printf '%s\n' "Successful jobs:  ${ok_ids:-<none>}"
	printf '\n'
	printf '%s\n' "Failed jobs by completion status:"
	printf '%s\n' "Returned non-zero code:  ${fail_ids:-<none>}"
	printf '%s\n' "Unfinished jobs:         ${unfinished_ids:-<none>}"
	printf '%s\n' "Undispatched jobs:       ${undispatched_ids:-<none>}"
	printf '%s\n' "Timed out jobs:          ${expired_ids:-<none>}"

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
```

_**Note**: this example script intentionally includes an invalid download URL to showcase scheduler error tracking and propagation._

## Implementation highlights

### Passing parameters to jobs

As explained in the [Job parameters](REFERENCE.md#job-parameters) section of REFERENCE.md, this example sets job-specific parameters via `job_set_params`. Setting `SCHED_AUTO_PARAMS=1` makes it so these parameters are immediately available to each job as variables inside the **job execution callback** (`DO_JOB_CB`).

```sh
# Job-specific parameters are assigned in the main script
job_set_params pro "url=https://..."

# Job execution callback (showing only param-related details)
download_list() {
	local name="${1:?}"

    # *With* SCHED_AUTO_PARAMS=1, the ${url} variable is set by the scheduler before callback invocation,
    #   so ${url} *must not be declared local or reset* inside the callback

    # *Without* SCHED_AUTO_PARAMS=1, declare the variable local and get its value from job_get_params:
    # local url
    # job_get_params "${name}" url || exit 1

    wget -q -O "${OUT_DIR}/${name}.txt" "${url:?}"
}

# Setting SCHED_AUTO_PARAMS=1 tells the scheduler to fetch and export job-specific params when initializing each job
# <...>
SCHED_AUTO_PARAMS=1 \
    schedule_jobs "${IDS}" &
```

### Signal forwarding

Because the scheduler is designed to run asynchronously (in the background), terminating the application script with a signal does not automatically terminate the scheduler or its jobs, so if such termination happens, job subshells - as well as any commands started by those subshells - may continue execution.

To handle this reliably, the example script traps signals `INT` and `TERM` and translates these signals into `USR1` sent to the scheduler's PID. This ensures the scheduler's native cleanup path is triggered and the **scheduler completion callback** (`SCHED_FINALIZE_CB`) is invoked and gets the chance to perform application-specific cleanup and/or to kill orphaned child processes, regardless of whether the interruption came from `Ctrl-C` or a direct `kill` command. The scheduler behaves identically when receiving signals `USR1`, `INT`, or `TERM`, except it exits with code `83` for `USR1` and with code `84` for `INT` or `TERM`.

```sh
schedule_jobs "${IDS}" &
sched_pid=$!

trap '
    trap - INT TERM
    kill -USR1 "${sched_pid}" 2>/dev/null
    wait "${sched_pid}"
    exit "$?"
' INT TERM
```

### Cleaning up orphaned child processes

The scheduler tracks the PIDs of the jobs (i.e. instances of the shell function `download_list()`, each running in a separate subshell). If your **job execution callback** invokes an external binary (like `wget` or `curl`), that binary runs in a child process of the job's subshell. If the scheduler terminates before all jobs have completed, the subshell in which the callback lives, as well as any external binaries it called, will keep running as orphaned processes. The example script uses `pgrep -P` inside the **scheduler completion callback** (`SCHED_FINALIZE_CB`) to find and terminate the actual child processes along with the job subshell processes:

```sh
# Inside SCHED_FINALIZE_CB
for running_pid in ${running_pids}; do
    child_pids="${child_pids}${child_pids:+ }$(pgrep -P "${running_pid}" 2>/dev/null)"
done
kill -TERM ${child_pids} ${running_pids} 2>/dev/null
```

### Tracking state across callbacks

This example implements a rudimentary application-specific bookkeeping (incrementing `SUCCESS_CNT` for each successful job) and combines that with scheduler-backed bookkeeping (fetching and reporting the list of jobs by status, i.e. `ok_ids`, `fail_ids`, `unfinished_ids`, `undispatched_ids`, `expired_ids`).

Because, from the application point of view, `schedule_jobs` runs in a background child process, any callbacks invoked by the scheduler are isolated from the application process. Hence variable updates (e.g. incrementing `SUCCESS_CNT`) inside callbacks will not be visible in the scope of the application script. If your application needs to do bookkeeping on the running jobs, the example script shows how to implement this. Rudimentary in-flight bookkeeping is implemented in the **job completion callback** (`JOB_DONE_CB`), while final processing of the collected information is in the **scheduler completion callback** (`SCHED_FINALIZE_CB`) and utilizes both information collected by the application (`SUCCESS_CNT`) and information collected by the scheduler (`ok_ids`, `fail_ids`, `unfinished_ids`, `undispatched_ids`, `expired_ids`).
