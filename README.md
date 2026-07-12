## shell-scheduler
The goal of this project is to implement a reliable, reusable, flexible and reasonably comprehensive library for parallelization in shell scripts, which would allow to keep application code separate from scheduler infrastructure - and keep it small, lightweight and self-contained.

## Contents

- [Main Features](#main-features)
- [Dependencies](#dependencies)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Scheduler API](#scheduler-api)
- [Callbacks](#callbacks)
- [Job Parameters](#job-parameters)
- [Environment variables](#environment-variables)
- [Return Codes](#return-codes)
- [Timeouts](#timeouts)
- [Signal Handling](#signal-handling)
- [Termination of Running Jobs](#termination-of-running-jobs)
- [Real-World Example](#real-world-example)

## Main Features

- Parallel job scheduling: execute independent jobs concurrently with a configurable maximum number of running jobs.
- Callback-based API: job execution, job completion, scheduler termination and error reporting are implemented through user-defined callbacks, in order to stay out of the way of application-specific code.
- Validates configuration, callback definitions, job completion records and internal scheduler state, terminating with an error if inconsistency is detected.
- Supports Bash and BusyBox ash. Simpler shells (like dash) are not supported.
- Configurable global and idle timeouts: automatically terminate the scheduler and call termination callback when total allowed runtime is exceeded or no job completions have been observed for N seconds.


## Dependencies

- Linux: required because of reliance on `/proc`, used to get PIDs and system uptime (for precise'ish time measurement). Should be not too complicated to port to any other Unix-like system.
- Bash or BusyBox ash. Other shells are not supported. Could be conceivably ported to POSIX-compliant code.
- Utilities: `mkfifo`, `mkdir`, `rm`. No other binary utilies are used by the code.


## Quick start

Minimal implementation needs to:
- source the library
- implement a callback function that performs the work for a single job
- configure the scheduler through environment variables
- call `schedule_jobs()` with the list of job IDs

Example below demonstrates such minimal implementation.

```sh
#!/bin/sh

. ./scheduler.sh

do_job()
{
	local job_id="${1}"
	echo "Hello from job ${job_id}!"
}

DO_JOB_CB=do_job
SCHED_MAX_JOBS=3

schedule_jobs "1 2 3 4 5" &
wait ${!}

echo "Scheduler finished with exit code ${?}"
```

Output:
```text
Hello from job 1!
Hello from job 2!
Hello from job 3!
Hello from job 4!
Hello from job 5!
Scheduler finished with exit code 0
```

This example executes five jobs while allowing up to three to run concurrently. In this case, jobs 1, 2, 3 will start almost simultaneously, while jobs 4 and 5 initially wait for one of the prior jobs to complete.

Note:
- The order in which jobs start is deterministic but the order in which they complete may not be.
- The scheduler is started in the background (see `&` after the call to `schedule_jobs()`). This is how it is designed to work. Technically you can call `schedule_jobs()` in the foreground (without `&`) but this will mess up any `trap`'s you defined in your code, and cause your script to exit when the scheduler exits.


## How it works

schedule_jobs() accepts a whitespace-separated list of job IDs. The scheduler starts jobs in the background, each one in its own process, in the same order as they appear in the list. The value of `${SCHED_MAX_JOBS}` defines the concurrency limit. The scheduler treats this as a number of execution slots and makes sure that as soon as a slot becomes vacant, a new job is started to occupy it, as long as any jobs are pending.

To execute each job, the scheduler starts a background process in which the **job execution callback** (defined by the value of `DO_JOB_CB`) is invoked, passing the job ID as the first argument. If the scheduler itself was called with any additional arguments (besides the list of job IDs), these arguments are passed as-is to every invocation of the **job execution callback** after the job ID (as the second, third, and subsequent arguments).

The scheduler continues to run until every job has completed or it hit a timeout or other fatal error occurs.

The scheduler associates each job ID with a PID (process ID) and tracks job completion and return codes. For each completed job, the scheduler invokes the optional **job completion callback** (`JOB_DONE_CB` - if defined). The **job completion callback** is invoked by the scheduler process (not by the job itself) and runs synchronously. Arguments passed to this callback are: 1. job ID; 2. job return code.

Once all jobs completed, or a timeout is reached, or scheduler execution was interrupted by a signal (`USR1` or `INT` or `TERM`), the scheduler cleans up and invokes the optional **scheduler termination callback** (`SCHED_FINALIZE_CB` - if defined).


## Scheduler API

To start the scheduler:

```sh
schedule_jobs "<job_id_list>" [arg1 [arg2 ...]]
```

- `<job_id_list>` : a string containing one or more job IDs separated by any combination of spaces, tabs and newlines (prefer spaces for simplicity). Job IDs themselves must not contain any of the above delimiters. Any other character is allowed.
- `arg1 [arg2 ...]` : optional additional arguments. Passed as-is to every invocation of the **job execution callback** (`DO_JOB_CB`) after the job ID.

Before calling `schedule_jobs()`, the following variables must be set:

- `${DO_JOB_CB}`: **job execution callback** implementing a single job. Typically this is the name of a shell function implemented in your script.
- `${SCHED_MAX_JOBS}`: maximum number of jobs that may execute concurrently.

You can set these values inline with the call to `schedule_jobs()` if you want to avoid extra local variables declarations, e.g.:

```sh
DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3"
```

For each job ID, the scheduler invokes the **job execution callback** as:

```sh
${DO_JOB_CB} <job_id> [arg1 [arg2 ...]]
```

All other callbacks and scheduler parameters are optional and have default values where applicable.

#### Return value

On success, `schedule_jobs()` returns `0`.

If configuration validation fails, callback execution fails, a timeout is reached, or the scheduler is terminated by a signal, it returns a non-zero code. The complete list of scheduler return codes is documented in the [Return Codes](#return-codes) section.


## Callbacks

All callbacks are specified by assigning the callback name to the corresponding environment variable before calling `schedule_jobs()`. Callback values must be command names only - arguments are not allowed. In practice, this will normally be the name of a shell function implemented by your script. The section [Job Parameters](#job-parameters) explains how to pass parameters to each individual job.

### Job execution callback (required)

Defined by the value of **`${DO_JOB_CB}`**. Implements the work performed for a single job. Invoked by the scheduler this way:

```sh
${DO_JOB_CB} <job_id> [arg1 [arg2 ...]]
```

where: `arg1 [arg2 ...]` are the additional arguments passed to `schedule_jobs()`.

This callback runs in a separate background process. Its exit code is considered by the scheduler to be the job's return code and is passed to the job completion callback (if defined).

### Job completion callback (optional)

Defined by the value of **`${JOB_DONE_CB}`**. Invoked by the scheduler for each job after receiving its completion record:

```sh
${JOB_DONE_CB} <job_id> <job_return_code>
```

If this callback returns a non-zero code, the scheduler terminates immediately with the same return code (after invoking the **scheduler termination callback**).

It can be used to e.g. collect job results or handle failures.

### Scheduler termination callback (optional)

This callback may be used for user-defined cleanup, e.g. terminating unfinished jobs, or to implement a processing completion handler.

Under normal operation, all jobs have already finished when this callback is invoked. If you want to kill any unfinished jobs, this callback is where you should implement that.

Defined by the value of **`${SCHED_FINALIZE_CB}`**. Invoked this way immediately before the scheduler exits:

```sh
${SCHED_FINALIZE_CB} <scheduler_return_code> <running_pids> <ok_job_ids> <fail_job_ids> <unfinished_job_ids> <undispatched_job_ids>
```

- `<running_pids>`: PIDs corresponding to jobs that the scheduler started but did not receive completion records for. Under normal operation this is an empty string.
- `<ok_job_ids>`: job IDs whose **job execution callback** (`DO_JOB_CB`) returned code `0`.
- `<fail_job_ids>`: job IDs whose **job execution callback** returned a non-zero code.
- `<unfinished_job_ids>`: job IDs that were dispatched (i.e. a process was started for them) but for which no completion record was received before the scheduler exited. Under normal operation this is an empty string; it becomes non-empty when the scheduler exits before all dispatched jobs report back, e.g. due to a timeout, a signal, a fatal error, or a non-zero return code from `JOB_DONE_CB`.
- `<undispatched_job_ids>`: job IDs that were never started at all. Under normal operation this is an empty string; it becomes non-empty when the scheduler exits before it has dispatched every job ID from the original list.

(all above lists are space-separated)

**Note**: every job ID passed to `schedule_jobs()` is guaranteed to appear in **exactly one** of `<ok_job_ids>`, `<fail_job_ids>`, `<unfinished_job_ids>`, `<undispatched_job_ids>`. This makes them a convenient basis for final bookkeeping, logging, or cleanup in the **scheduler termination callback**, without having to separately track job status yourself.

If this callback returns a non-zero code while `<scheduler_return_code>` is `0`, the scheduler exits with the callback's return code instead. Otherwise, the scheduler's return code is unchanged.

#### Example: inspecting final job status

The example below defines a **scheduler termination callback** that unconditionally reports on every outcome category, regardless of whether a given category ended up empty. It does not manufacture any failure or timeout scenario; job `3` simply returns a non-zero code on its own, like any job might in practice.

```sh
#!/bin/sh

. ./scheduler.sh

do_job() {
	local job_id="${1}"
	# Simulates job C failure
	[ "${job_id}" = C ] && return 1
	return 0
}

finalize_report() {
	local rv="${1}" running_pids="${2}" ok_ids="${3}" fail_ids="${4}" \
		unfinished_ids="${5}" undispatched_ids="${6}"

	echo "Scheduler exited with code ${rv}"
	echo "Succeeded:    ${ok_ids:-<none>}"
	echo "Failed:       ${fail_ids:-<none>}"
	echo "Unfinished:   ${unfinished_ids:-<none>}"
	echo "Undispatched: ${undispatched_ids:-<none>}"
}

DO_JOB_CB=do_job
SCHED_FINALIZE_CB=finalize_report
SCHED_MAX_JOBS=3

schedule_jobs "A B C D E" &
wait ${!}
```

Output:
```text
Scheduler exited with code 0
Succeeded:    A B D E
Failed:       C
Unfinished:   <none>
Undispatched: <none>
```

Since all five jobs run to completion in this example, `<unfinished_job_ids>` and `<undispatched_job_ids>` are both empty - see the [Timeouts](#timeouts) and [Signal Handling](#signal-handling) sections below for cases where they are populated.

### Scheduler error reporting callback (optional)
Defined by the value of **`${SCHED_FAIL_MSG_CB}`**. Invoked whenever the scheduler needs to report an error.

```sh
${SCHED_FAIL_MSG_CB} <message>
```

If this callback is not defined, error messages are written to standard error.

**Note**: All callbacks, except the **job execution callback**, are invoked synchronously (in the foreground, from the scheduler's perspective). Synchronous callbacks block scheduler execution, bookkeeping and time-keeping. Previously started jobs do continue to run but the scheduler will not launch new jobs or register job completions until the callback returns control to the scheduler. For this reason, avoid including commands which may stall for prolonged time in such callbacks.


## Job Parameters

Any extra arguments passed to `schedule_jobs()` (after the list of job ID's in the first argument) are forwarded unchanged to every job and are therefore shared by all jobs, available as positional parameters inside the **job execution callback** (`DO_JOB_CB`).

Assigning **per-job parameters** can be done via a dedicated helper: `job_set_params()`. Syntax:

```sh
job_set_params <job_ID> <param_name_1>="<value_1>" <param_name_2>="<value_2>" ...
```

To retrieve values of previously set params, use the helper `job_get_params()`:

```sh
job_get_params <job_ID> <param_name_1> <param_name_2> ...
```

`job_get_params` will assign the value for each specified parameter to same-named variable, e.g.:

```
local filename
local url
job_get_params "job_1" filename url
echo "filename is '${filename}', url is '${url}'"
```

This works in every callback and in your application script.

If you want to **export** the variables set by `job_set_params` then prepend the `-export` flag to the command:
```
job_get_params -export "job1" filename url
```

If you want to make job-specific parameters immediately available to each job, you can set the environment variable `SCHED_AUTO_PARAMS` to `1`. Then every job-specific parameter you have set via `job_set_params` will be fetched and exported when initializing each job, and so will be immediately available to the job, including if the job is implemented as an external command (rather than as a shell function). Note that in that case, you should not declare the variable as local and not reset its value in the **job execution callback**, because the value is assigned outside of the function implementing the callback.

Example with `SCHED_AUTO_PARAMS=1`:
```sh
. ./scheduler.sh

# Job execution callback
process_file() {
    echo "For job ${1}, file is '${filename}${extension}'."
}

job_set_params A "filename=foo" "extension=.bz2"
job_set_params B "filename=bar" "extension=.gz"

DO_JOB_CB=process_file \
SCHED_MAX_JOBS=3 \
SCHED_AUTO_PARAMS=1 \
    schedule_jobs "A B C" &
wait ${!}
```

Example with `SCHED_AUTO_PARAMS` unset:
```sh
. ./scheduler.sh

# Job execution callback
process_file() {
    local filename
    local extension
    job_get_params "${1}" filename extension || exit 1
    echo "For job ${1}, file is '${filename}${extension}'."
}

job_set_params A "filename=foo" "extension=.bz2"
job_set_params B "filename=bar" "extension=.gz"

DO_JOB_CB=process_file \
SCHED_MAX_JOBS=3 \
    schedule_jobs "A B C" &
wait ${!}
```

Output in both cases:
```
For job A, file is 'foo.bz2'.
For job B, file is 'bar.gz'.
For job C, file is ''.
```

**Notes**:
- When `SCHED_AUTO_PARAMS` is set to `1`, parameters are **exported** before the **job execution callback** is invoked, so corresponding variables are effectively available to the callback itself and to any commands it calls as environment variables.
- Assigning and fetching parameters is internally implemented via indirection. In order to keep the implementation compatible with Busybox ash, this indirection requires the use of `eval`. The scheduler implementation strictly validates strings passed to these `eval` calls both at assignment time (in `job_set_params()`) and when fetching values for each job at execution time. This prevents any possibility of command injection vulnerabilities in this mechanism.
- Setting job-specific parameters via `job_set_params` requires corresponding **job ID** to contain only following characters: `a-z`, `A-Z`, `0-9`, `_`. It also requires corresponding **param name** to contain only the same set of characters, and not start with a digit (for compliance with POSIX specification of valid variable names). In addition, parameter names can not start with `SCHED_`, `SCH_`, `sch_`, `_sch_` and can not be the same as callback variables (`DO_JOB_CB`, `JOB_DONE_CB`) and the `IFS` variable. These are all reserved for internal use. When either of these requirements is not met, `job_set_params()` will print an error, return code 1, and the parameter will not be set.


## Environment variables

The scheduler is configured entirely through environment variables. Required variables must be set before calling `schedule_jobs()`. All others are optional.

| Variable                  | Required | Default | Description                                                                                                                      |
| ------------------------- | :------: | :-----: | -------------------------------------------------------------------------------------------------------------------------------- |
| DO_JOB_CB                 |     *    |    -    | Command implementing the job execution callback.                                                                                 |
| JOB_DONE_CB               |          |  unset  | Command implementing the job completion callback.                                                                                |
| SCHED_FINALIZE_CB         |          |  unset  | Command implementing the scheduler termination callback.                                                                         |
| SCHED_FAIL_MSG_CB         |          |  unset  | Command implementing the scheduler error reporting callback.                                                                     |
| SCHED_MAX_JOBS            |     *    |    -    | Concurrency limit ( integer >= 1 ).                                                                                              |
| SCHED_TIMEOUT_S           |          |  `900`  | Global scheduler timeout in seconds ( integer >= 1 ).                                                                            |
| SCHED_IDLE_TIMEOUT_S      |          |  `300`  | Maximum allowed time, in seconds, without any job completions ( integer >= 1 ).                                                  |
| SCHED_DIR                 |          |  `/tmp` | Directory in which the scheduler creates its FIFO used for communication with running jobs. Trailing `/` characters are ignored. |
| SCHED_AUTO_PARAMS         |          |  unset  | Whether to export job-specific params when initializing each job ( 1 to enable, any other value to disable ).                    |

Notes:

* Callback variables must contain command names only. Arguments are not allowed.
* Invalid value of any required or optional variable causes `schedule_jobs()` to fail before starting any jobs.

## Return Codes

`schedule_jobs()` returns one of the following exit codes:

| Return code | Meaning                                                            |
| :---------: | ------------------------------------------------------------------ |
|     `0`     | Scheduler completed successfully.                                  |
|     `1`     | Fatal error.                                                       |
|     `81`    | Idle timeout (`${SCHED_IDLE_TIMEOUT_S}`) was reached.              |
|     `82`    | Global timeout (`${SCHED_TIMEOUT_S}`) was reached.                 |
|     `83`    | Scheduler was terminated by the `USR1` signal.                     |
|     `84`    | Scheduler was terminated by either the `INT` or the `TERM` signal. |

**Note**: The job execution callback (`DO_JOB_CB`) returns a **job** return code, not a scheduler return code. This value is reported to the job completion callback (`JOB_DONE_CB`) if one is defined.

If the job completion callback (`JOB_DONE_CB`) returns a non-zero code, the scheduler terminates immediately and returns the same code (after invoking the scheduler termination callback, if defined).

The **scheduler termination callback** (`SCHED_FINALIZE_CB`) is always invoked before the scheduler exits. It receives the scheduler's return code as its first argument, along with the running PIDs and job ID breakdown described in the [Scheduler termination callback](#scheduler-termination-callback-optional) section above. Normally the scheduler exits with that same return code. The only exception is when the scheduler itself would otherwise return `0` but the **scheduler termination callback** returns a non-zero code. In that case, the scheduler exits with the callback's return code instead.

## Timeouts

The scheduler implements two independent timeout mechanisms. Their default values are documented in the [Environment variables](#environment-variables) section.

### Global timeout

The global timeout (`${SCHED_TIMEOUT_S}`) limits the total time the scheduler is allowed to run. It starts when the scheduler begins execution and continues to run regardless of how many jobs are currently executing or waiting to be started.

If the global timeout is reached, the scheduler reports an error, invokes the **scheduler termination callback** (if defined), and exits with return code `82`.

### Idle timeout

The idle timeout (`${SCHED_IDLE_TIMEOUT_S}`) limits the maximum time the scheduler may go without receiving a job completion. The timeout is reset whenever the scheduler successfully processes a job completion.

This timeout is useful for detecting situations where no progress is being made, for example because one or more jobs became stuck.

If the idle timeout is reached, the scheduler reports an error, invokes the **scheduler termination callback** (if defined), and exits with return code `81`.

## Signal Handling

The scheduler installs handlers for signals: `USR1`, `INT`, `TERM`. When any of these signals is received, the scheduler stops processing, performs its internal cleanup, invokes the **scheduler termination callback** (if defined), and exits with return code `83` (for `USR1`) or `84` (for `INT` or `TERM`).

## Termination of Running Jobs

The scheduler does not terminate running jobs by itself, including when a timeout is reached or when `USR1` is received. If your application needs to stop unfinished jobs, implement this in the **scheduler termination callback** using the list of unfinished job PIDs (`<running_pids>`) passed to it. The corresponding job IDs are also available, as `<unfinished_job_ids>`, if your cleanup or logging is keyed by job ID rather than by PID.



## Real-World Example

For a real-world integration example, check out [`hagezi-fetch.sh`](hagezi-fetch.sh). It implements a concurrent downloader for DNS blocklists.

*Note 1: `wget` and `pgrep` are dependencies of this specific example, not the `shell-scheduler` library.*

*Note 2: this example script intentionally includes an invalid download URL to showcase scheduler error tracking and propagation.*

Implementation highlights you will likely need in your own projects utilizing this library:

### 1. Passing Parameters to Jobs
As explained in the [Job Parameters](#job-parameters) section above, this example sets job-specific parameters via `job_set_params`. Setting `SCHED_AUTO_PARAMS=1` makes it so these parameters are immediately available to each job as variables inside the **job execution callback** (`DO_JOB_CB`).

```sh
# Job-specific parameters are assigned in the main script
job_set_params pro "url=https://..."

# Job execution callback (showing only param-related details)
download_list() {
	local name="${1:?}"

    # Note: with SCHED_AUTO_PARAMS=1, the ${url} variable is set by the scheduler before callback invocation,
    #   so this variable *must not be declared local or reset* inside the callback

    # Without SCHED_AUTO_PARAMS=1, declare the variable local and get its value from job_get_params:
    # local url
    # job_get_params "${name}" url || exit 1

    wget -q -O "${OUT_DIR}/${name}.txt" "${url:?}"
}

# Setting SCHED_AUTO_PARAMS=1 tells the scheduler to fetch and export job-specific params when initializing each job
# <...>
SCHED_AUTO_PARAMS=1 \  
    schedule_jobs "${IDS}" &

```

### 2. Signal Forwarding
Because the scheduler is designed to run asynchronously (in the background), terminating the application script with a signal does not automatically terminate the scheduler or its jobs, so if such termination happens, job subshells, as well as any commands started by those subshells, may continue execution.

To handle this reliably, the example script traps signals `INT` and `TERM` and translates these signals into `USR1` sent to the scheduler's PID. This ensures the scheduler's native cleanup path is triggered and the **scheduler termination callback** (`SCHED_FINALIZE_CB`) is invoked and gets the chance to perform application-specific cleanup and/or to kill orphaned child processes, regardless of whether the interruption came from `Ctrl-C` or a direct `kill` command. The scheduler behaves identically when receiving signals `USR1`, `INT`, or `TERM`, except it exits with code `83` for `USR1` and with code `84` for `INT` or `TERM`.

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

### 3. Cleaning Up Orphaned Child Processes
The scheduler tracks the PIDs of the jobs (i.e. instances of the shell function `download_list()`, each running in a separate subshell). If your **job execution callback** invokes an external binary (like `wget` or `curl`), that binary runs in a child process of the job's subshell. If the scheduler terminates before all jobs have completed, the subshell in which the callback lives, as well as any external binaries it called, will keep running as orphaned processes. The example script uses `pgrep -P` inside the **scheduler termination callback** (`SCHED_FINALIZE_CB`) to find and terminate the actual child processes along with the job subshell processes:

```sh
# Inside SCHED_FINALIZE_CB
# (only the running_pids argument is used here; the job-ID arguments described
#  in the Scheduler termination callback section are ignored by this snippet)
for running_pid in ${running_pids}; do
    child_pids="${child_pids}${child_pids:+ }$(pgrep -P "${running_pid}" 2>/dev/null)"
done
kill -TERM ${child_pids} ${running_pids} 2>/dev/null
```

### 4. Tracking State Across Callbacks
Because, from the application point of view, `schedule_jobs` runs in a background child process, any callbacks invoked by the scheduler are isolated from the application process. Hence variable updates (e.g. incrementing `SUCCESS_CNT`) inside callbacks will not be visible in the scope of the application script. If your application needs to do bookkeeping on the running jobs, the example script shows how to implement this. The in-flight bookkeeping is implemented in the **job completion callback** (`JOB_DONE_CB`) while final processing of the collected information is in the **scheduler termination callback** (`SCHED_FINALIZE_CB`) - both of these callbacks execute synchronously within the scheduler's process context and share visibility of the callback-updated variables.
