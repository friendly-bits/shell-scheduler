# shell-scheduler — Reference

Complete technical reference for the `shell-scheduler` library. If you're just getting started, read the [README](README.md) first — it covers the common case in a few minutes. This document covers everything else.

## Contents

- [Scheduler API](#scheduler-api)
- [Callbacks](#callbacks)
- [Job parameters](#job-parameters)
- [Environment variables](#environment-variables)
- [Return codes](#return-codes)
- [Timeouts](#timeouts)
- [Signal handling](#signal-handling)
- [Termination of running jobs](#termination-of-running-jobs)
- [Real-world example](#real-world-example)

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

You can set these values inline with the call to `schedule_jobs()` if you want to avoid extra local variable declarations, e.g.:

```sh
DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3"
```

For each job ID, the scheduler invokes the **job execution callback** as:

```sh
${DO_JOB_CB} <job_id> [arg1 [arg2 ...]]
```

All other callbacks and scheduler parameters are optional and have default values where applicable.

### Return value

On success, `schedule_jobs()` returns `0`.

If configuration validation fails, callback execution fails, a timeout is reached, or the scheduler is terminated by a signal, it returns a non-zero code. The complete list of scheduler return codes is documented in the [Return codes](#return-codes) section.

## Callbacks

All callbacks are specified by assigning the callback name to the corresponding environment variable before calling `schedule_jobs()`. Callback values must be command names only — arguments are not allowed. In practice, this will normally be the name of a shell function implemented by your script. The section [Job parameters](#job-parameters) explains how to pass parameters to each individual job.

> **Note**: All callbacks, except the **job execution callback**, are invoked synchronously (in the foreground, from the scheduler's perspective). Synchronous callbacks block scheduler execution, bookkeeping and time-keeping. Previously started jobs do continue to run, but the scheduler will not launch new jobs or register job completions until the callback returns control to the scheduler. For this reason, avoid including commands which may stall for a prolonged time in such callbacks.

### Job execution callback (required)

Defined by the value of **`${DO_JOB_CB}`**. Implements the work performed for a single job. Invoked by the scheduler this way:

```sh
${DO_JOB_CB} <job_id> [arg1 [arg2 ...]]
```

where `arg1 [arg2 ...]` are the additional arguments passed to `schedule_jobs()`.

This callback runs in a separate background process. Its exit code is considered by the scheduler to be the job's return code and is passed to the job completion callback (if defined).

### Job completion callback (optional)

Defined by the value of **`${JOB_DONE_CB}`**. Invoked by the scheduler for each job after receiving its completion record:

```sh
${JOB_DONE_CB} <job_id> <job_return_code>
```

If this callback returns a non-zero code, the scheduler terminates immediately with the same return code (after invoking the **scheduler termination callback**).

It can be used to e.g. collect job results or handle failures.

**Note**: this callback — like every scheduler callback except the **job execution callback** — runs inside the scheduler process, which continuously has child processes exiting as jobs complete. On BusyBox builds where `sleep` is a NOFORK shell builtin (e.g. with `CONFIG_FEATURE_SH_STANDALONE` enabled), an in-process `sleep` in such a callback can be silently cut short by the `SIGCHLD` of an exiting job. If a callback needs a reliable delay, force a forked sleep, which is immune to this: `sleep <seconds> & wait "$!"`.

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

<details>
<summary><strong>Example: inspecting final job status</strong></summary>

The example below defines a **scheduler termination callback** that unconditionally reports on every outcome category, regardless of whether a given category ended up empty. It does not manufacture any failure or timeout scenario; job `C` simply returns a non-zero code on its own, like any job might in practice.

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

Since all five jobs run to completion in this example, `<unfinished_job_ids>` and `<undispatched_job_ids>` are both empty — see the [Timeouts](#timeouts) and [Signal handling](#signal-handling) sections below for cases where they are populated.

</details>

### Scheduler error reporting callback (optional)

Defined by the value of **`${SCHED_FAIL_MSG_CB}`**. Invoked whenever the scheduler needs to report an error.

```sh
${SCHED_FAIL_MSG_CB} <message>
```

If this callback is not defined, error messages are written to standard error.

## Job parameters

Any extra arguments passed to `schedule_jobs()` (after the list of job IDs in the first argument) are forwarded unchanged to every job and are therefore shared by all jobs, available as positional parameters inside the **job execution callback** (`DO_JOB_CB`).

Assigning **per-job parameters** can be done via a dedicated helper: `job_set_params()`. Syntax:

```sh
job_set_params <job_ID> <param_name_1>="<value_1>" <param_name_2>="<value_2>" ...
```

To retrieve values of previously set params, use the helper `job_get_params()`:

```sh
job_get_params <job_ID> <param_name_1> <param_name_2> ...
```

`job_get_params` will assign the value for each specified parameter to a same-named variable, e.g.:

```sh
local filename
local url
job_get_params "job_1" filename url
echo "filename is '${filename}', url is '${url}'"
```

This works in every callback and in your application script.

<details>
<summary><strong>Fetching into differently-named variables, and non-identifier param names</strong></summary>

Each requested parameter can also be fetched into a **differently-named variable** by using the `<var_name>=<param_name>` form. This may come in useful in some cases when you want to use the param value without assigning it to the variable which matches the param name. E.g.:

```sh
local url prev_url
url="https://winamp"
job_set_params "job_1" "url=${url}"
url="https://foobar"
job_get_params "job_1" "prev_url=url"
echo "prev url is '$prev_url', current url is '$url'"
```

When the parameter name is not itself a valid shell variable name (for example when it starts with a digit), you have to fetch the param value this way, because in that case it can not be assigned to a same-named variable:

```sh
local out_file
job_get_params "job_1" out_file=2ndfile
echo "value of param '2ndfile' is '${out_file}'"
```

The plain and aliased forms may be mixed freely in a single call, e.g. `job_get_params "job_1" filename out_file=2ndfile url` — assigns corresponding values to variables `${filename}`, `${url}` and `${out_file}`.

If you want to **export** the variables set by `job_get_params`, then prepend the `-export` flag to the command:

```sh
job_get_params -export "job1" filename url
```

</details>

### Automatic parameters (`SCHED_AUTO_PARAMS`)

If you want to make job-specific parameters immediately available to each job, you can set the environment variable `SCHED_AUTO_PARAMS` to `1`. Then every job-specific parameter you have set via `job_set_params` will be fetched and exported when initializing each job, and so will be immediately available to the job — including if the job is implemented as an external command (rather than as a shell function). Note that in that case, you should not declare the variable as local and not reset its value in the **job execution callback**, because the value is assigned outside of the function implementing the callback.

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

```text
For job A, file is 'foo.bz2'.
For job B, file is 'bar.gz'.
For job C, file is ''.
```

<details>
<summary><strong>Notes: naming rules, validation, and security</strong></summary>

- When `SCHED_AUTO_PARAMS` is set to `1`, parameters are **exported** before the **job execution callback** is invoked, so corresponding variables are effectively available to the callback itself and to any commands it calls as environment variables.
- Assigning and fetching parameters is internally implemented via indirection. In order to keep the implementation compatible with BusyBox ash, this indirection requires the use of `eval`. The scheduler implementation strictly validates strings passed to these `eval` calls both at assignment time (in `job_set_params()`) and when fetching values for each job at execution time. This prevents any possibility of command injection vulnerabilities in this mechanism.
- Setting job-specific parameters via `job_set_params()` requires the **job ID** and each **param name** to contain only the following characters: `a-z`, `A-Z`, `0-9`, `_`. Param names, unlike variable names, **may** start with a digit and **may** coincide with otherwise-reserved names — a param name is only ever used as a lookup key, never assigned to directly. Retrieving a parameter, on the other hand, assigns it to a shell **variable**, so the *destination variable name* used with `job_get_params()` (either the same-named plain form, or `<var_name>` in the `<var_name>=<param_name>` form) must be a valid, non-reserved shell variable name: it must contain only `a-z`, `A-Z`, `0-9`, `_`, must not start with a digit (for compliance with the POSIX specification of valid variable names), must not start with `SCHED_`, `SCH_`, `sch_`, `_sch_`, and must not be a callback variable (`DO_JOB_CB`, `JOB_DONE_CB`) or the `IFS` variable. These prefixes and names are reserved for internal use. When any of these requirements is not met, the corresponding helper prints an error, returns code 1, and does not set the parameter or variable.
- With `SCHED_AUTO_PARAMS=1`, every registered parameter of a job is exported into a same-named variable before that job runs. All of that job's param names must therefore be valid, **non-reserved** shell variable names per the rules above (in particular, they must not start with a digit and must not use the reserved prefixes or names). If any registered parameter of a job violates these rules, that job fails during initialization: an error is reported, the **job execution callback** is never invoked, and the job completes with job return code `1` — the scheduler itself keeps running and handles the failure through the normal completion path, including invoking the **job completion callback** (`JOB_DONE_CB`) if defined. A parameter whose name is not a valid variable name can still be registered and retrieved explicitly via the `<var_name>=<param_name>` form of `job_get_params()`, but it can not be delivered through `SCHED_AUTO_PARAMS`.

</details>

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

- Callback variables must contain command names only. Arguments are not allowed.
- Invalid value of any required or optional variable causes `schedule_jobs()` to fail before starting any jobs.

## Return codes

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

## Signal handling

The scheduler installs handlers for signals `USR1`, `INT`, `TERM`. When any of these signals is received, the scheduler stops processing, performs its internal cleanup, invokes the **scheduler termination callback** (if defined), and exits with return code `83` (for `USR1`) or `84` (for `INT` or `TERM`).

## Termination of running jobs

The scheduler does not terminate running jobs by itself, including when a timeout is reached or when `USR1` is received. If your application needs to stop unfinished jobs, implement this in the **scheduler termination callback** using the list of unfinished job PIDs (`<running_pids>`) passed to it. The corresponding job IDs are also available, as `<unfinished_job_ids>`, if your cleanup or logging is keyed by job ID rather than by PID.

## Real-world example

For a real-world integration example, check out [`hagezi-fetch.sh`](hagezi-fetch.sh). It implements a concurrent downloader for DNS blocklists.

*Note 1: `wget` and `pgrep` are dependencies of this specific example, not the `shell-scheduler` library.*

*Note 2: this example script intentionally includes an invalid download URL to showcase scheduler error tracking and propagation.*

Implementation highlights you will likely need in your own projects utilizing this library:

### 1. Passing parameters to jobs

As explained in the [Job parameters](#job-parameters) section above, this example sets job-specific parameters via `job_set_params`. Setting `SCHED_AUTO_PARAMS=1` makes it so these parameters are immediately available to each job as variables inside the **job execution callback** (`DO_JOB_CB`).

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

### 2. Signal forwarding

Because the scheduler is designed to run asynchronously (in the background), terminating the application script with a signal does not automatically terminate the scheduler or its jobs, so if such termination happens, job subshells — as well as any commands started by those subshells — may continue execution.

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

### 3. Cleaning up orphaned child processes

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

### 4. Tracking state across callbacks

This example implements a rudimentary application-specific bookkeeping (incrementing `SUCCESS_CNT` for each successful job) and combines that with scheduler-backed bookkeeping (fetching and reporting the list of jobs by status, i.e. `ok_ids`, `fail_ids`, `unfinished_ids`, `undispatched_ids`).

Because, from the application point of view, `schedule_jobs` runs in a background child process, any callbacks invoked by the scheduler are isolated from the application process. Hence variable updates (e.g. incrementing `SUCCESS_CNT`) inside callbacks will not be visible in the scope of the application script. If your application needs to do bookkeeping on the running jobs, the example script shows how to implement this. Rudimentary in-flight bookkeeping is implemented in the **job completion callback** (`JOB_DONE_CB`), while final processing of the collected information is in the **scheduler termination callback** (`SCHED_FINALIZE_CB`) and utilizes both information collected by the application (`SUCCESS_CNT`) and information collected by the scheduler (`ok_ids`, `fail_ids`, `unfinished_ids`, `undispatched_ids`).
