# shell-scheduler - Reference

Complete technical reference for the `shell-scheduler` library. If you're just getting started, read the [README](README.md) first - it covers the common case in a few minutes. This document covers everything else.

## Contents

- [How to use](#how-to-use-scheduler-api)
- [Callbacks](#callbacks)
- [Job parameters](#job-parameters)
- [Environment variables](#environment-variables)
- [Return codes](#return-codes)
- [Timeouts](#timeouts)
- [Signal handling](#signal-handling)
- [Termination of running jobs](#termination-of-running-jobs)
- [Job termination callback (details)](#job-termination-callback-details)

## How to use (Scheduler API)

To start the scheduler:

```sh
schedule_jobs "<job_id_list>" [arg1 [arg2 ...]] &
```

- `<job_id_list>` : a string containing one or more job IDs separated by any combination of spaces, tabs and newlines (prefer spaces for simplicity). Job IDs must be non-empty and may only contain the characters `a-z`, `A-Z`, `0-9`, `_` (a leading digit is allowed). `schedule_jobs()` validates the list upfront and fails (return code `1`, nothing dispatched) on any invalid or duplicate ID.
- `arg1 [arg2 ...]` : optional additional arguments. Passed as-is to every invocation of the **job execution callback** (`DO_JOB_CB`) after the job ID.

As a general rule, run the scheduler in a background process: `schedule_jobs <job_ids> & ... wait ${!}`. Alternatively, for certain use cases, running it in a foreground subshell may be preferable. Below spoiler provides more information.

<details>
<summary><strong>Background vs foreground subshell considerations</summary></strong>

`schedule_jobs()` is designed to run in a child process of your script: either in the background: `schedule_jobs <job_ids> &`; or in a foreground subshell: `( schedule_jobs <job_ids> )`. The scheduler always terminates via the `exit` command. Called plainly (not in the background or subshell), your script will exit when scheduler exits; this also clobbers your `USR1`/`INT`/`TERM` traps and file descriptor `3`. So in general avoid that.

Both forms support the entire feature set - dispatch, concurrency, timeouts, callbacks, outcome reporting all live inside the scheduler process and behave identically. The difference is what your script can do while the batch runs, and how signals reach the scheduler:

```sh
# Background: asynchronous - your script keeps control while the batch runs
schedule_jobs "A B C" &
sched_pid=$!
# ... concurrent work, monitoring, cancellation via kill -USR1 "${sched_pid}" ...
wait "${sched_pid}"
rv=$?
```

```sh
# Foreground subshell: synchronous - blocks until the batch is done
( schedule_jobs "A B C" )
rv=$?
```

- **Background (`& ... wait`)** - use when the application must stay in control while jobs run: doing concurrent work, supervising progress, or cancelling the batch on demand. Because your script keeps running (and `wait` is interruptible by its traps), it can react to terminal or service signals and translate them into a graceful scheduler cancellation with `kill -USR1 "${sched_pid}"` - see [Signal handling](#signal-handling). Note that a backgrounded scheduler may not see `Ctrl-C` itself, so this signal-forwarding pattern is also what connects `Ctrl-C` to the scheduler's cleanup path. This is the pattern used throughout this documentation and the accompanying examples.
- **Foreground subshell (`( ... )`)** - use for the simple synchronous case: run the batch, then continue with its return code. `Ctrl-C` handling gets simpler: the subshell runs in the terminal's foreground process group, so `SIGINT` reaches the scheduler directly and triggers its normal cleanup path (return code `84`, termination callback invoked). The trade-offs: your script is blocked until the scheduler exits - it cannot do concurrent work, and its own traps will not run until then - and there is no scheduler PID at hand, so the batch cannot be cancelled from the application side.

In both modes, a signal delivered only to your application's PID (e.g. `kill -TERM <app_pid>`, as opposed to `Ctrl-C`, which signals the whole process group) leaves the scheduler and its jobs running as orphans. Only the background form lets you close that gap, by forwarding the signal as shown in the [EXAMPLE-HAGEZI-FETCH.md](EXAMPLE-HAGEZI-FETCH.md).

</details>

Before calling `schedule_jobs()`, the following variables must be set:

- `${DO_JOB_CB}`: **job execution callback** implementing a single job. Typically this is the name of a shell function implemented in your script.
- `${SCHED_MAX_JOBS}`: maximum number of jobs that may execute concurrently.

You can set these values inline with the call to `schedule_jobs()` if you want to avoid extra local variable declarations, e.g.:

```sh
DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3" &
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

All callbacks are specified by assigning the callback name to the corresponding environment variable before calling `schedule_jobs()`. Callback values must be command names only - arguments are not allowed.

shell-scheduler expects each callback to be implemented in your script as a shell function. If you want to use external commands for your callbacks, wrap them in a shell function.

> **Note**: All callbacks, except the **job execution callback**, are invoked synchronously (in the foreground, from the scheduler's perspective). Synchronous callbacks block scheduler execution, bookkeeping and time-keeping. Previously started jobs do continue to run, but the scheduler will not launch new jobs or register job completions until the callback returns control to the scheduler. Avoid including commands which may stall for a prolonged time in such callbacks.
>
> Because synchronous callbacks run in the scheduler's own shell process, they are able to change the values of scheduler's internal variables. Hence the API reserves variables whose names start with `sch_`, `_sch_`, `SCH_` or `SCHED_` for internal use: callbacks must not assign values to them. Best practice for callbacks is to declare their own working variables `local` in order to avoid any namespacing issues altogether. If your code ignores this advice and changes values of the scheduler's internal variables, strange things may happen.

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

If this callback returns a non-zero code, the scheduler terminates immediately with the same return code (after invoking the **scheduler completion callback**).

It can be used to e.g. collect job results or handle failures.

When [per-job timeouts](TIMEKEEPING.md#per-job-timeouts) are in use, a timed-out job is reported with job return code `124` and the job's PID as an extra third argument - the presence of that argument is what distinguishes a scheduler-synthesized timeout from a job that genuinely exited with code `124`.

### Scheduler completion callback (optional)

This callback may be used for user-defined cleanup, e.g. terminating unfinished jobs, or to implement a processing completion handler.

Under normal operation, all jobs have already finished when this callback is invoked. If you want to kill any unfinished jobs, this callback is where you should implement that.

Defined by the value of **`${SCHED_FINALIZE_CB}`**. Invoked this way immediately before the scheduler exits:

```sh
${SCHED_FINALIZE_CB} <scheduler_return_code> <running_pids> <ok_job_ids> <fail_job_ids> <unfinished_job_ids> <undispatched_job_ids> <expired_job_ids>
```

- `<running_pids>`: PIDs corresponding to jobs that the scheduler started but did not receive completion records for. Under normal operation this is an empty string.
- `<ok_job_ids>`: job IDs whose **job execution callback** (`DO_JOB_CB`) returned code `0`.
- `<fail_job_ids>`: job IDs whose **job execution callback** returned a non-zero code.
- `<undispatched_job_ids>`: job IDs that were never started at all. Under normal operation this is an empty string; it becomes non-empty when the scheduler exits before it has dispatched every job ID from the original list.
- `<expired_job_ids>`: job IDs abandoned via a [per-job timeout](TIMEKEEPING.md#per-job-timeouts). Empty unless per-job timeouts are in use. Unlike a failed job, an expired job's process may still be running at this point - and unless your code kills it, may even complete later (with a [job termination callback](#job-termination-callback-job_term_cb) configured, the scheduler kills it at expiry time instead). The PIDs of expired jobs which the scheduler never got a completion record from (including after expiration time) will be included in the list of `<running_pids>` - except those whose kill was verified by the termination callback.
- `<unfinished_job_ids>`: dispatched jobs whose [per-job timeout](TIMEKEEPING.md#per-job-timeouts) did not expire, but which had not yet completed when the scheduler exited early - because of a signal, a fatal error, a timeout (global or idle), or a non-zero return code from `JOB_DONE_CB`. Under normal operation this is an empty string. Note that the scheduler exiting does not by itself terminate these jobs' processes - see [Termination of running jobs](#termination-of-running-jobs).

(all above lists are space-separated)

If this callback returns a non-zero code while `<scheduler_return_code>` is `0`, the scheduler exits with the callback's return code instead. Otherwise, the scheduler's return code is unchanged.

**Notes**:
- every job ID passed to `schedule_jobs()` is guaranteed to appear in **exactly one** of `<ok_job_ids>`, `<fail_job_ids>`, `<unfinished_job_ids>`, `<undispatched_job_ids>`, `<expired_job_ids>`. This makes them a convenient basis for final bookkeeping, logging, or cleanup in the **scheduler completion callback**, without having to separately track job status yourself.
- The scheduler does not terminate expired and unfinished jobs on its own. See [Termination of running jobs](#termination-of-running-jobs).
- If your application only cares about success/failure outcomes, simply concatenate all "didn't complete successfully" job IDs.

<details>
<summary><strong>Example: concatenate unsuccessful job IDs</strong></summary>

```
all_failed_ids=
for fail_list in "${fail_job_ids}" "${unfinished_job_ids}" "${undispatched_job_ids}" "${expired_job_ids}"; do
    [ -n "${fail_list}" ] && all_failed_lists="${all_failed_lists}${all_failed_lists: }${fail_list}"
done
```

</details>

<details>
<summary><strong>Example: inspecting final job status</strong></summary>

The example below defines a **scheduler completion callback** that unconditionally reports on every outcome category, regardless of whether a given category ended up empty. It does not manufacture any failure or timeout scenario; job `C` simply returns a non-zero code on its own, like any job might in practice.

```sh
#!/bin/sh

. ./scheduler.sh

do_job() {
	local job_id="${1}"
	# Simulates job C failure
	[ "${job_id}" = C ] && return 1
	return 0
}

report_results() {
	local rv="${1}" running_pids="${2}" ok_ids="${3}" fail_ids="${4}" \
		unfinished_ids="${5}" undispatched_ids="${6}" expired_ids="${7}"

	echo "Scheduler exited with code ${rv}"
	echo "Succeeded:    ${ok_ids:-<none>}"
	echo "Failed:       ${fail_ids:-<none>}"
	echo "Unfinished:   ${unfinished_ids:-<none>}"
	echo "Undispatched: ${undispatched_ids:-<none>}"
	echo "Timed out:    ${expired_ids:-<none>}"
}

DO_JOB_CB=do_job
SCHED_FINALIZE_CB=report_results
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
Timed out:    <none>
```

Since all five jobs run to completion in this example, `<unfinished_job_ids>`, `<undispatched_job_ids>` and `<expired_job_ids>` are all empty - see the [Timeouts](#timeouts) and [Signal handling](#signal-handling) sections below for cases where the first two are populated, and [per-job timeouts](TIMEKEEPING.md#per-job-timeouts) for the third.

</details>

### Job termination callback (`JOB_TERM_CB`)

This callback exists to support implementing scheduler-assisted termination of **expired** and **unfinished** jobs. Details in [Job termination callback (details)](#job-termination-callback-details).

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

`job_get_params` will assign the value for each specified parameter to a same-named variable.

<details>
<summary><strong>job_get_params example</strong></summary>

```sh
local filename
local url
job_get_params "job_1" filename url
echo "filename is '${filename}', url is '${url}'"
```
</details>

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

The plain and aliased forms may be mixed freely in a single call, e.g. `job_get_params "job_1" filename out_file=2ndfile url` - assigns corresponding values to variables `${filename}`, `${url}` and `${out_file}`.

If you want to **export** the variables set by `job_get_params`, then prepend the `-export` flag to the command:

```sh
job_get_params -export "job1" filename url
```

</details>

### Resetting job parameters (`jobs_init`)

Per-job parameters and timeouts are stored in process-global variables that have no automatic teardown: once set via `job_set_params()` or `job_set_timeout()`, they persist for the lifetime of your shell process - across repeated `schedule_jobs()` runs and across any reuse of the same job ID. To reset them deterministically, use `jobs_init()`:

```sh
jobs_init "<job_id_list>"
```

Each argument is a whitespace-separated list of job IDs (spaces, tabs or newlines), mirroring the list accepted by `schedule_jobs()`; you may also spread IDs across several arguments. So `jobs_init "${my_job_ids}"`, `jobs_init A B C`, and combinations such as `jobs_init "a b" c` all work. Pass lists **quoted** - `jobs_init` splits them internally with globbing disabled, so the caller does not have to.

For each job ID given, `jobs_init` clears everything configured for that job: the parameter list and every stored parameter value (set by `job_set_params`), and the per-job timeout (set by `job_set_timeout`). Afterwards a `job_get_params` for that job returns nothing, and the job falls back to the default per-job timeout (`${SCHED_JOB_TIMEOUT_S}`).

As a general rule, it is a good idea to unconditionally call `jobs_init` before setting job-specific parameters and timeouts, especially when you run more than one batch in the same process, or reuse a job ID, and want a clean slate instead of inheriting the prior configuration:

<details>
<summary><strong>jobs_init example: reconfiguring a job between runs</strong></summary>

```sh
jobs_init job1
job_set_params job1 "url=https://example.com/a"
job_set_timeout job1 60
schedule_jobs "job1" &
wait ${!}

jobs_init job1
job_set_params job1 "url=https://example.com/b"
# job_set_timeout() is not called this run, so per-job timeout is left unconfigured
schedule_jobs "job1" &
wait ${!}
```

Without the `jobs_init` call, `job1` would still carry the `url` from the first run. This is harmless when the second run overwrites every parameter, but a source of subtle bugs when it sets a different or smaller set of parameters and a job reads one left over from the first run.
</details>

### Automatic parameters (`SCHED_AUTO_PARAMS`)

If you want to make job-specific parameters immediately available to each job, you can set the environment variable `SCHED_AUTO_PARAMS` to `1`. Then every job-specific parameter you have set via `job_set_params` will be fetched and exported when initializing each job, and so will be immediately available to the job and any external commands it calls. Note that when using automatic parameters, you should not declare the variable as local and not reset its value in the **job execution callback**, because the value is assigned outside of the function implementing the callback.

<details>
<summary><strong>Example with `SCHED_AUTO_PARAMS=1`</strong></summary>

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

</details>

<details>
<summary><strong>Example with `SCHED_AUTO_PARAMS` unset</strong></summary>

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

</details>

<details>
<summary><strong>Output in both cases</strong></summary>

```text
For job A, file is 'foo.bz2'.
For job B, file is 'bar.gz'.
For job C, file is ''.
```

</details>

<details>
<summary><strong>Notes: naming rules, validation, and security</strong></summary>

- When `SCHED_AUTO_PARAMS` is set to `1`, parameters are **exported** before the **job execution callback** is invoked, so corresponding variables are effectively available to the callback itself and to any commands it calls as environment variables.
- Assigning and fetching parameters is internally implemented via indirection. In order to keep the implementation compatible with BusyBox ash, this indirection requires the use of `eval`. The scheduler implementation strictly validates strings passed to these `eval` calls both at assignment time (in `job_set_params()`) and when fetching values for each job at execution time. This prevents any possibility of command injection vulnerabilities in this mechanism.
- Setting job-specific parameters via `job_set_params()` requires the **job ID** and each **param name** to contain only the following characters: `a-z`, `A-Z`, `0-9`, `_`. Param names, unlike variable names, **may** start with a digit and **may** coincide with otherwise-reserved names. `job_set_params()` treats param name as a **key** and the actual value is assigned to a variable with a different name. Retrieving a parameter, on the other hand, assigns it to a shell **variable**, so the *destination variable name* used with `job_get_params()` (either the same-named plain form, or `<var_name>` in the `<var_name>=<param_name>` form) must be a valid, non-reserved shell variable name: it must contain only `a-z`, `A-Z`, `0-9`, `_`, must not start with a digit (for compliance with the POSIX specification of valid variable names), must not start with `SCHED_`, `SCH_`, `sch_`, `_sch_`, and must not be a callback variable (`DO_JOB_CB`, `JOB_DONE_CB`) or the `IFS` variable. These prefixes and names are reserved for internal use. When any of these requirements is not met, the corresponding helper prints an error, returns code 1, and does not set the parameter or variable.
- With `SCHED_AUTO_PARAMS=1`, every registered parameter of a job is exported into a same-named variable before that job runs. All of that job's param names must therefore be valid, **non-reserved** shell variable names per the rules above (in particular, they must not start with a digit and must not use the reserved prefixes or names). If any registered parameter of a job violates these rules, that job fails during initialization: an error is reported, the **job execution callback** is never invoked, and the job completes with job return code `1` - the scheduler itself keeps running and handles the failure through the normal completion path, including invoking the **job completion callback** (`JOB_DONE_CB`) if defined. A parameter whose name is not a valid variable name can still be registered and retrieved explicitly via the `<var_name>=<param_name>` form of `job_get_params()`, but it can not be delivered through `SCHED_AUTO_PARAMS`.

</details>

## Environment variables

The scheduler is configured entirely through environment variables. Required variables must be set before calling `schedule_jobs()`. All others are optional.

| Variable                  | Required | Default | Description                                                                                                                      |
| ------------------------- | :------: | :-----: | -------------------------------------------------------------------------------------------------------------------------------- |
| DO_JOB_CB                 |     *    |    -    | Command implementing the job execution callback.                                                                                 |
| JOB_DONE_CB               |          |  unset  | Command implementing the job completion callback.                                                                                |
| SCHED_FINALIZE_CB         |          |  unset  | Command implementing the scheduler completion callback.                                                                          |
| SCHED_FAIL_MSG_CB         |          |  unset  | Command implementing the scheduler error reporting callback.                                                                     |
| JOB_TERM_CB               |          |  unset  | Command implementing the job termination callback. See [Termination of running jobs](#termination-of-running-jobs).        |
| SCHED_MAX_JOBS            |     *    |    -    | Concurrency limit ( integer >= 1 ).                                                                                              |
| SCHED_TIMEOUT_S           |          |  `900`  | Global scheduler timeout in seconds ( integer >= 1 ).                                                                            |
| SCHED_IDLE_TIMEOUT_S      |          |  `300`  | Maximum allowed time, in seconds, without any job starts or completions ( integer >= 1 ).                                        |
| SCHED_JOB_TIMEOUT_S       |          |  unset  | Default per-job timeout in seconds ( integer >= 1 ); override per job via `job_set_timeout()`. See [TIMEKEEPING.md](TIMEKEEPING.md#per-job-timeouts). |
| SCHED_DIR                 |          |  `/tmp` | Directory in which the scheduler creates its FIFO used for communication with running jobs. Trailing `/` characters are ignored. |
| SCHED_AUTO_PARAMS         |          |  unset  | Whether to export job-specific params when initializing each job ( 1 to enable, any other value to disable ).                    |
| SCHED_CGROUP_BASE         |          |  unset  | Read by the `scheduler-job-term-cgroup.sh` library, not by the scheduler core. For testing or advanced use: writable cgroup2 directory under which the per-run cgroup is created, overriding autodetection. Trailing `/` characters are ignored. |

Notes:

- Callback variables must contain command names only. Arguments are not allowed.
- Invalid value of any required or optional variable causes `schedule_jobs()` to fail before starting any jobs.
- Timeout behavior is documented in detail in [TIMEKEEPING.md](TIMEKEEPING.md).

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

If the job completion callback (`JOB_DONE_CB`) returns a non-zero code, the scheduler terminates immediately and returns the same code (after invoking the scheduler completion callback, if defined).

The **scheduler completion callback** (`SCHED_FINALIZE_CB`) is always invoked before the scheduler exits, except when the scheduler failed with a fatal error during early initialization - in that case it exits with code `1` without starting any jobs and without invoking the callback. Normally the scheduler exits with the same return code that is passed to the **scheduler completion callback**. The only exception is when the scheduler itself would otherwise return `0` but the **scheduler completion callback** returns a non-zero code. In that case, the scheduler exits with the callback's return code instead.

## Timeouts

The scheduler implements three independent timeout mechanisms:
- **global timeout** (`${SCHED_TIMEOUT_S}`, return code `82`), limiting the scheduler's total run time
- **idle timeout** (`${SCHED_IDLE_TIMEOUT_S}`, return code `81`), limiting the time the scheduler may go without starting a job or receiving a job completion
- **per-job timeout** (configurable individually for each job via `job_set_timeout()`, defaults to `${SCHED_JOB_TIMEOUT_S}` if defined). A per-job timeout persists until overwritten or cleared with [`jobs_init()`](#resetting-job-parameters-jobs_init).

Time measurement, timeout mechanisms, and reliable delays in callbacks are documented in detail in [TIMEKEEPING.md](TIMEKEEPING.md).

## Signal handling

The scheduler installs handlers for signals `USR1`, `INT`, `TERM`. When any of these signals is received, the scheduler stops processing, performs its internal cleanup, invokes the **scheduler completion callback** (if defined), and exits with return code `83` (for `USR1`) or `84` (for `INT` or `TERM`).

## Termination of running jobs

By default, the scheduler does not terminate running jobs by itself, including when a timeout is reached or when `USR1` is received.

If your application needs to stop expired and unfinished jobs, you can either set up the **job termination callback** (see next section) or implement custom job termination in the **scheduler completion callback** using the list of unfinished job PIDs (`<running_pids>`) passed to it. The corresponding job IDs are also available - in `<unfinished_job_ids>` and, for jobs abandoned via [per-job timeout](TIMEKEEPING.md#per-job-timeouts), in `<expired_job_ids>` - if your cleanup or logging is keyed by job ID rather than by PID.

## Job termination callback (details)

The scheduler can facilitate termination of unfinished and expired jobs via the **job termination callback** interface. This allows termination of any descendants (children, grandchildren etc) of processes spawned by the jobs.

This callback, as all shell-scheduler callbacks, must be implemented as a shell function.

The scheduler invokes this callback - `JOB_TERM_CB` - like so:

```
${JOB_TERM_CB} <subcommand> [arguments]
```

A specific **subcommand** is used at each invocation point:

| When (invocation point)                                                | Purpose                                 | Subcommand |Arguments                            |
| -----------------------------------------------------------------------| --------------------------------------  | ---------- |---------------------                |
| **Scheduler startup**, before any job is dispatched                    | Initialize termination mechanism        | `init`     |None                                 |
| **Inside each job's process**, before invoking job execution callback  | Make job-specific arrangements          | `setup`    | `<job_id> <pid>`                    |
| **Per-job timeout expiry**                                             | Kill process tree                       | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 1**, before invoking scheduler completion callback  | Kill any still-running jobs + processes | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 2**, before invoking scheduler completion callback  | Tear down the job termination mechanism | `cleanup`  | `<verified_kills_out_var>`          |

The PIDs passed to `term` are job wrapper PIDs (the same PIDs reported in `<running_pids>`); the callback is responsible for terminating each job's whole process tree.

**Note**:

**`term` and `cleanup` may report verified job terminations via the output variable**: `<verified_kills_out_var>` is the name of a variable the callback may assign a whitespace-separated job PID list to - `export -n "${verified_kills_out_var}=<pids>"` - following the same indirection convention as the library's own helpers. A reported job PID asserts that the job's entire process tree has been killed; the scheduler then excludes it from the `<running_pids>` passed to the **scheduler completion callback**.

## Job termination helper libraries

The project includes two helper libraries, each one implementing the **job termination callback** (`JOB_TERM_CB`) differently.

### TL;DR

For simple use cases with relatively few well-behaved jobs running, it doesn't really matter which mechanism of the two discussed below is used in practice.

- If an extra file and ~10KiB doesn't make or break your project, include both helper libraries with your application and implement automatic job termination mechanism selection as explained in [Selecting job termination mechanism at runtime](#selecting-job-termination-mechanism-at-runtime) below.
- If spawning many jobs, strongly prefer the cgroups-based library because it is much more efficient.
- If spawning jobs which are prone to misbehavior, hanging or leaving orphaned processes behind, prefer the cgroups-based library because it allows for more deterministic process termination.
- If you need to pick only one of the helper libraries: prefer the cgroups-based library if your target systems support it.
- Otherwise just include the proc-based helper library and use the proc-based mechanism.

### Short version

#### Helper library: `scheduler-job-term-proc.sh`

Reconstructs each job's process tree by walking `/proc/<pid>/task/<tid>/children`, freezes it with `SIGSTOP` (re-scanning to catch races), then delivers `SIGKILL`. Works wherever `/proc` and `awk` are available - no cgroups, no root. It cannot find processes reparented to init, and does not verify process termination, so `<running_pids>` reported to the **scheduler completion callback** may list job PIDs whose trees are already gone.

Usage: source the file after `scheduler.sh`, then set `JOB_TERM_CB=sched_job_term_proc`.

#### Helper library: `scheduler-job-term-cgroup.sh`

When spawning jobs, puts each job in its own **cgroup v2**. When terminating jobs, kills the whole process tree - including orphaned grandchildren - via the kernel's `cgroup.kill`. Process kills are kernel-verified, so under normal operation `<running_pids>` reported to the **scheduler completion callback** is empty even after timeouts or an early exit. Requires cgroup v2 with `cgroup.kill` (kernel >= 5.14) and write access to a cgroup - available when running as root, when started by the systemd user manager, or in a container with a writable cgroup mount.

Usage: source the file after `scheduler.sh`, then set `JOB_TERM_CB=sched_job_term_cgroup`; call `cgroup_cleanup_supported` first to probe availability.

### Details

The full mechanism of each library, its requirements, and how to deploy it (containers, cron, systemd, unprivileged use) are documented in **[JOB-TERMINATION-LIBRARIES.md](JOB-TERMINATION-LIBRARIES.md)**.

### Selecting job termination mechanism at runtime

Your application can select the mechanism automatically from what the environment supports, using `cgroup_cleanup_supported` as the test:

```sh
. ./scheduler.sh
. ./scheduler-job-term-cgroup.sh # provides the helper 'cgroup_cleanup_supported'
. ./scheduler-job-term-proc.sh

if cgroup_cleanup_supported; then
    JOB_TERM_CB=sched_job_term_cgroup
else
    JOB_TERM_CB=sched_job_term_proc
fi
schedule_jobs "${IDS}" &
```
