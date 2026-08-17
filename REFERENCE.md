# shell-scheduler - Reference

Complete technical reference for the `shell-scheduler` library. If you're just getting started, read the [README](README.md) first - it covers the common case in a few minutes. This document covers everything else.

## Contents

- [How to use](#how-to-use-scheduler-api)
- [Callbacks](#callbacks)
- [Job parameters](#job-parameters)
- [Aborting specific jobs from a callback](#aborting-specific-jobs-from-a-callback)
- [Aborting specific jobs externally](#aborting-specific-jobs-externally)
- [Environment variables](#environment-variables)
- [Return codes](#return-codes)
- [Timeouts](#timeouts)
- [Signal handling](#signal-handling)
- [Job termination mechanisms](#job-termination-mechanisms)
- [Job termination callback - mini](#job-termination-callback---mini)
- [Job termination callback - full](#job-termination-callback---full)
- [Built-in job termination mechanisms - full](#built-in-job-termination-mechanisms---full)

## How to use (Scheduler API)

To start the scheduler:

```sh
schedule_jobs "<job_ids>" [arg1 [arg2 ...]] &
```

- `<job_ids>` : a string containing one or more job IDs separated by any combination of spaces, tabs and newlines (prefer spaces for simplicity). A valid Job ID: only contains characters `[a-zA-Z0-9_]` and is no longer than 2020 characters (arbitrary number with a large safety margin). `schedule_jobs()` validates the list upfront and fails on any invalid or duplicate ID.
- `arg1 [arg2 ...]` : optional additional arguments. Passed as-is to every invocation of the **job execution callback** (`DO_JOB_CB`) after the job ID.

As a general rule, run the scheduler in a background process: `schedule_jobs <job_ids> & ... wait ${!}`. Alternatively, for certain use cases, running it in a foreground subshell may be preferable. Below spoiler provides more information.

<details>
<summary><strong>Background vs foreground subshell considerations</strong></summary>

`schedule_jobs()` is designed to run in a child process of your script: either in the background:
```
schedule_jobs <job_ids> &
```

or in a foreground subshell:
```
( schedule_jobs <job_ids> )
```

Both forms support the entire feature set: dispatch, concurrency, timeouts, callbacks, outcome reporting. The difference is what your script can do while the batch runs, and how signals reach the scheduler:

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

- **Background subshell: `schedule_jobs & ... wait`** - use when the application must stay in control while jobs run: doing concurrent work, supervising progress, or cancelling the batch on demand. Because your script keeps running (and `wait` is interruptible by its traps), it can react to terminal or service signals and translate them into a graceful scheduler cancellation with `kill -USR1 "${sched_pid}"` - see [Signal handling](#signal-handling). Note that a backgrounded scheduler may not see `Ctrl-C` itself, so this signal-forwarding pattern is also what connects `Ctrl-C` to the scheduler's cleanup path. This is the pattern used throughout this documentation and the accompanying examples.
- **Foreground subshell: `( schedule_jobs )`** - use for the simple synchronous case: run the batch, then continue with its return code. `Ctrl-C` handling gets simpler: the subshell runs in the terminal's foreground process group, so `SIGINT` reaches the scheduler directly and triggers its normal cleanup path (return code `84`, termination callback invoked). The trade-offs are: your script is blocked until the scheduler exits (can not do concurrent work); your script's own traps will not fire while the scheduler is running; the batch cannot be cancelled from the application side because there is no PID at hand.

In both modes, a signal delivered only to your application's PID (e.g. `kill -TERM <app_pid>`, as opposed to `Ctrl-C`, which signals the whole process group) leaves the scheduler and its jobs running as orphans. Only the background form lets you close that gap, by forwarding the signal as shown in the [EXAMPLE-HAGEZI-FETCH.md](EXAMPLE-HAGEZI-FETCH.md).

**Note**: The scheduler always terminates via the `exit` command. If the scheduler is called without a subshell, your script will exit when scheduler exits. This also clobbers your `USR1`/`INT`/`TERM`/`EXIT` traps and file descriptor `3`. So in general avoid that.

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

> **Note**: Because certain callbacks run in the scheduler's own shell process, they are able to change the values of scheduler's internal variables. Hence the API reserves variables whose names start with `sch_`, `_sch_`, `SCH_` or `SCHED_` for internal use: callbacks must not assign values to them. Best practice for callbacks is to declare their own working variables `local` in order to avoid any namespacing issues altogether. If your code ignores this advice and changes values of the scheduler's internal variables, strange things may happen.

Which process each callback runs in, and whether it can therefore change the scheduler's internal variables:

| Callback | Runs in | Can change scheduler's internal variables |
| -------- | ------- | :---------------------------: |
| **Job execution** | the job's own process, or a subshell of that process when `SCHED_INNER_SUBSHELL=1` | no |
| **Job termination**: `setup` command (only supported by the full variant) | the job's own process | no |
| **Job termination**: `init` / `term` / `cleanup` commands | the scheduler's process | yes |
| **Job completion** | the scheduler's process | yes |
| **Scheduler completion** | the scheduler's process | yes |
| **Error reporting** | a subshell of whichever process reported the error | no |

> **Note**: All callbacks, except the **job execution callback** and the **job termination callback**'s `setup` command, are invoked synchronously (in the foreground, from the scheduler's perspective). Synchronous callbacks block scheduler execution, bookkeeping and time-keeping. Previously started jobs do continue to run, but the scheduler will not launch new jobs or register job completions until the callback returns control to the scheduler. Avoid including commands which may stall for a prolonged time in such callbacks.

> **Note**: **Calling `exit` from callbacks running in scheduler's main process will end the run**. In most callbacks, calling `exit` hits the trap set up by the scheduler which triggers immediate cleanup (including termination of running jobs if configured), invocation of the **scheduler completion callback** with the exit code you passed, and scheduler exit. `exit 0` produces a run that looks entirely successful while quietly leaving jobs unfinished. Avoid calling `exit` in the **job termination callback**'s `term` or `cleanup` commands: they run during shutdown, after the scheduler removed the `exit` trap, so here `exit` skips the **scheduler completion callback** altogether. To end a run without calling `exit`, return a non-zero code from the **job completion callback** - the scheduler stops and reports that code, having finished its bookkeeping first.

### Job execution callback (required)

Defined by the value of **`${DO_JOB_CB}`**. Implements the work performed for a single job. Invoked by the scheduler this way:

```sh
${DO_JOB_CB} <job_id> [arg1 [arg2 ...]]
```

where `arg1 [arg2 ...]` are the additional arguments passed to `schedule_jobs()`.

This callback runs in a separate background process. Its exit code is considered by the scheduler to be the job's return code and is passed to the job completion callback (if defined).

### Job completion callback (optional)

Defined by the value of **`${JOB_DONE_CB}`**. Invoked by the scheduler for each job after receiving its completion record this way:

```sh
${JOB_DONE_CB} <job_id> <job_return_code> [job_pid]
```

If this callback returns a non-zero code, the scheduler terminates immediately and returns the same return code, unless the **scheduler completion callback** overrides it (see [Return codes](#return-codes)).

It can be used to e.g. collect job results or handle failures.

When the reason for calling `JOB_DONE_CB` is not a per-job time-out, `[job_pid]` is unset.

With [automatic parameters](#automatic-parameters-sched_auto_params) enabled, the job's parameters are exported for the duration of this callback.

When [per-job timeouts](TIMEKEEPING.md#per-job-timeouts) are in use, a timed-out job is reported with job return code `124` and the job's PID as the third argument. The presence of that argument is what distinguishes a timeout generated by the scheduler from a job that genuinely exited with code `124`.

### Scheduler completion callback (optional)

This callback may be used for user-defined cleanup, e.g. terminating unfinished jobs, or to implement a processing completion handler.

Under normal operation, all jobs have already finished when this callback is invoked. If you want to kill any unfinished jobs, this callback is where you should implement that.

Defined by the value of **`${SCHED_FINALIZE_CB}`**. Invoked this way immediately before the scheduler exits:

```sh
${SCHED_FINALIZE_CB} <scheduler_return_code> <running_pids> <ok_job_ids> <fail_job_ids> <unfinished_job_ids> <undispatched_job_ids> <expired_job_ids> <aborted_job_ids>
```

The callback always receives exactly 8 arguments. Categories that ended up empty are passed as empty strings.

- `<running_pids>`: PIDs corresponding to jobs that the scheduler started but did not receive completion records for. Under normal operation this is an empty string.
- `<ok_job_ids>`: job IDs whose **job execution callback** (`DO_JOB_CB`) returned code `0`.
- `<fail_job_ids>`: job IDs whose **job execution callback** returned a non-zero code.
- `<undispatched_job_ids>`: job IDs that were never started at all. Under normal operation this is an empty string; it becomes non-empty when the scheduler exits before it has dispatched every job ID from the original list.
- `<expired_job_ids>`: IDs of jobs which had hit the **per-job timeout**. Empty unless per-job timeouts are in use. Unlike a failed job, an expired job's process may still be running, and unless killed by your code or by the **job termination callback**, may even complete later. PIDs of expired jobs which the scheduler never got a completion record from (including after expiration time) and whose kill was not verified by the **job termination callback** will be included in the list of `<running_pids>` passed to the **scheduler completion callback**.
- `<unfinished_job_ids>`: dispatched jobs whose **per-job timeout** did not expire, but which had not yet completed when the scheduler exited early (e.g. because of a signal, fatal error, timeout, or a callback that called `exit`). Under normal operation this is an empty string.
- `<aborted_job_ids>`: IDs of **running** jobs cancelled by [`jobs_abort()`](#aborting-specific-jobs-from-a-callback). Empty unless `jobs_abort()` is used. Only jobs that had already been dispatched appear here - aborting a job that is still pending removes it from the queue, so it is reported as *undispatched* instead. Like an expired job, the scheduler only terminates the job's processes when the **job termination callback** is configured.

(all above lists are space-separated)

Every job ID passed to `schedule_jobs()` is guaranteed to appear in **exactly one** of the above lists. This makes it easy to implement final bookkeeping, logging or cleanup.

When this callback is implemented, its return code always becomes the scheduler's exit code.

**Notes**:
- Unconditionally returning `0` from this callback masks scheduler failures.
- The scheduler does not terminate expired, unfinished or aborted jobs on its own. See [Job termination callback](#job-termination-callback-job_term_cb).
- If your application only cares about success/failure outcomes, simply concatenate all "didn't complete successfully" category lists.

<details>
<summary><strong>Example: concatenate unsuccessful job IDs</strong></summary>

```
all_failed_lists=
for fail_list in "${fail_job_ids}" "${unfinished_job_ids}" "${undispatched_job_ids}" "${expired_job_ids}" "${aborted_job_ids}"; do
    [ -n "${fail_list}" ] && all_failed_lists="${all_failed_lists}${all_failed_lists:+ }${fail_list}"
done
```

</details>

<details>
<summary><strong>Example: reporting final summary of job statuses</strong></summary>

The example below defines a **scheduler completion callback** that unconditionally reports on every outcome category, regardless of whether a given category ended up empty. In this example, job `C` always returns a non-zero code and is therefore classified as "failed".

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
	local rv="${1}" \
		running_pids="${2}" \
		ok="${3}" fail="${4}" unfinished="${5}" \
		undispatched="${6}" expired="${7}" aborted="${8}"

	echo "Scheduler exited with code ${rv}"
	echo "Succeeded:    ${ok:-<none>}"
	echo "Failed:       ${fail:-<none>}"
	echo "Unfinished:   ${unfinished:-<none>}"
	echo "Undispatched: ${undispatched:-<none>}"
	echo "Timed out:    ${expired:-<none>}"
	echo "Aborted:      ${aborted:-<none>}"

	return "${rv}" # Return with the same error code as received from the scheduler
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
Aborted:      <none>
```

</details>

### Job termination callback (`JOB_TERM_CB`)

The scheduler can facilitate termination of **unfinished** and **expired** jobs via the **job termination callback** interface. This allows termination of any descendants (children, grandchildren etc) of processes spawned by the jobs.

This callback, as all shell-scheduler callbacks, must be implemented as a shell function.

The **full** scheduler variant invokes this callback - `JOB_TERM_CB` - like so:

```
${JOB_TERM_CB} <subcommand> [arguments]
```

The **mini** variant invokes it like so:

```
${JOB_TERM_CB} <job_pid>
```


Additional details in [Job termination callback - mini](#job-termination-callback---mini) and [Job termination callback - full](#job-termination-callback---full).

### Scheduler error reporting callback (optional)

Defined by the value of **`${SCHED_FAIL_MSG_CB}`**. Invoked whenever the scheduler needs to report an error.

```sh
${SCHED_FAIL_MSG_CB} <message>
```

If this callback is not defined, error messages are written to standard error.

**Note**: this callback runs in a subshell, so if it assigns any global variables, their values will be lost after the subshell exits.

## Job parameters

Any extra arguments passed to `schedule_jobs` (after the list of job IDs in the first argument) are forwarded unchanged to every job and are therefore shared by all jobs, available as positional parameters inside the **job execution callback** (`DO_JOB_CB`).

Assigning **per-job parameters** can be done via a dedicated helper: `job_set_params`. Syntax:

```sh
job_set_params <job_ID> <param_name_1>="<value_1>" <param_name_2>="<value_2>" ...
```

To retrieve values of previously set params, use the helper `job_get_params`:

```sh
job_get_params <job_ID> <param_name_1> <param_name_2> ...
```

This will assign the value for each specified parameter to a same-named variable.

This helper works in every callback and in your application script.

<details>
<summary><strong>job_get_params example</strong></summary>

```sh
local filename
local url
job_get_params "job_1" filename url
echo "filename is '${filename}', url is '${url}'"
```
</details>

<details>
<summary><strong>Fetching into differently-named variables</strong></summary>

Each requested parameter can also be fetched into a **differently-named variable** by using the `<var_name>=<param_name>` (aliased) form. This may come in useful in cases when you want to use the param value without assigning it to the variable which matches the param name. E.g.:

```sh
local url prev_url
url="https://winamp"
job_set_params "job_1" "url=${url}"
url="https://foobar"
job_get_params "job_1" "prev_url=url"
echo "prev url is '$prev_url', current url is '$url'"
```

When the parameter name is not a valid shell variable name (for example when it starts with a digit), or when same-named variable is reserved by the scheduler for internal use, this is the only way to fetch value:

```sh
local out_file
job_get_params "job_1" out_file=2ndfile
echo "value of param '2ndfile' is '${out_file}'"
```

The plain and aliased forms may be mixed in a single call, e.g.: `job_get_params "job_1" filename out_file=2ndfile url` assigns corresponding values to variables `${filename}`, `${url}` and `${out_file}`.

If you want to **export** the variables set by `job_get_params`, prepend the `-export` flag to the command:

```sh
job_get_params -export "job1" filename url
```

</details>

### Resetting job parameters (`jobs_init`)

Per-job parameters and timeouts are stored in process-global variables that are never cleared automatically: once set via `job_set_params()` or `job_set_timeout()`, they persist for the lifetime of your shell process. To reset them deterministically, use `jobs_init()`:

```sh
jobs_init "<job_id_list>"
```

Where `<job_id_list>` is a string containing whitespace-separated list of job IDs to reset.

For each job ID given, `jobs_init` clears everything configured for that job: the parameter list, every stored parameter value (set by `job_set_params`), and the per-job timeout (set by `job_set_timeout`). Afterwards the job falls back to the default per-job timeout (`${SCHED_JOB_TIMEOUT_S}`) if set, or to no per-job timeout if not set.

As a general rule, it is a good idea to unconditionally call `jobs_init` before setting job-specific parameters and timeouts, especially when you run more than one batch in the same process, or reuse a job ID, and want a clean slate instead of inheriting the prior configuration:

<details>
<summary><strong>jobs_init example: reconfiguring a job between runs</strong></summary>

```sh
jobs_init job1
job_set_params job1 "url=https://example.com/a"
job_set_timeout job1 60
schedule_jobs "job1" &
wait ${!}

jobs_init job1 # resets previously set parameters and individual per-job timout

job_set_params job1 "url=https://example.com/b"
# job_set_timeout() is not called this run, so per-job timeout is left unconfigured
schedule_jobs "job1" &
wait ${!}
```

Without the `jobs_init` call, `job1` would still carry the `url` from the first run. This is harmless when the second run overwrites every parameter, but a source of subtle bugs when it sets a different or smaller set of parameters and a job reads one left over from the first run.
</details>

`jobs_init` only clears the [namespace](#scheduler-namespace-sched_id) currently selected by `${SCHED_ID}`.

### Scheduler namespace (`SCHED_ID`)

Per-job parameters and timeouts set via `job_set_params` and `job_set_timeout` are keyed by job ID and live in **global variables** in the scope of your application. If using multiple schedulers in the same application, set the variable `SCHED_ID` **before calling any scheduler-provided helper** (`job_set_params`, `job_get_params`, `job_set_timeout`, `jobs_init`) and **before starting the scheduler** for each scheduler instance. Giving each scheduler instance its own `SCHED_ID` separates their namespaces:

```sh
SCHED_ID=lists job_set_params fetch "url=https://example.com/lists"
SCHED_ID=feeds job_set_params fetch "url=https://example.com/feeds"

SCHED_ID=lists ... schedule_jobs "fetch" &   # job 'fetch' gets the 'lists' url
SCHED_ID=feeds ... schedule_jobs "fetch" &   # job 'fetch' gets the 'feeds' url
```

Valid `SCHED_ID` follows the same rules as a job ID: only `[a-zA-Z0-9_]`, and max 2020 characters. Leaving it unset (or empty) selects the default, unnamed namespace.

**Note**: Params set while `SCHED_ID` is unset are invisible to a run performed with `SCHED_ID=lists`, and vice versa. The simplest way to get this right is to export `SCHED_ID` once at the top of the script, or to pass it as a prefix assignment on every scheduler-related call, as above.

### Automatic parameters (`SCHED_AUTO_PARAMS`)

**(full variant only** - the mini variant always delivers registered params to jobs and to the **job completion callback**, and ignores `SCHED_AUTO_PARAMS`.**)**

If you want to make job-specific parameters immediately available to each job (both in the **job execution callback** and in the **job completion callback**), you can set the environment variable `SCHED_AUTO_PARAMS` to `1`. Then every job-specific parameter you have set via `job_set_params` will be fetched and **exported** before either callback is invoked for that job, and so will be immediately available to the callback and to any external commands it calls. Note that when using automatic parameters, you should not declare the variable as local and not reset its value in either callback, because the value is assigned outside of the function implementing the callback.

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

- Assigning and fetching parameters is internally implemented via indirection. In order to keep the implementation compatible with BusyBox ash, this indirection requires the use of `eval`. The scheduler implementation strictly validates strings passed to these `eval` calls both at assignment time (in `job_set_params()`) and when fetching values for each job at execution time. A parameter *value* is never part of the evaluated string - it reaches the variable by parameter expansion, which the shell does not re-parse as syntax - so a value cannot be interpreted as code no matter what it contains.
- Setting job-specific parameters via `job_set_params()` requires the **job ID** and each **param name** to contain only the characters `[a-zA-Z0-9_]`. Param names, unlike variable names, **may** start with a digit and **may** coincide with otherwise-reserved names. `job_set_params()` treats param name as a **key** and the actual value is assigned to a variable with a different name. Retrieving a parameter, on the other hand, assigns it to a shell **variable**, so the *destination variable name* used with `job_get_params()` (either the same-named plain form, or `<var_name>` in the `<var_name>=<param_name>` form) must be a valid, non-reserved shell variable name: in addition to characters set restriction, it must not start with a digit, must not start with `SCHED_`, `SCH_`, `sch_`, `_sch_`, and must not be a callback variable (`DO_JOB_CB`, `JOB_DONE_CB`) or the `IFS` variable. These prefixes and names are reserved for internal use. Any job ID, param name and destination variable name may each be at most 2020 characters long. When any of these requirements are not met, the corresponding helper prints an error, returns code 1, and does not set the parameter or variable.
- With `SCHED_AUTO_PARAMS=1`, all param names previously set via `job_set_params` must be valid, **non-reserved** shell variable names (in particular, they must not start with a digit and must not use the reserved prefixes or names). If any registered parameter of a job violates these rules, that job fails during initialization. A parameter whose name is not a valid variable name can still be registered and retrieved explicitly via the `<var_name>=<param_name>` form of `job_get_params()`, but it can not be delivered through `SCHED_AUTO_PARAMS`.

</details>

## Aborting specific jobs from a callback

To abort one or more jobs from the **job completion callback**, use the built-in helper `jobs_abort`. This allows to implement internal batching logic. For example, if some of your jobs are interdependent and you want to immediately abort the whole group if any one of the interdependent jobs fails (but leave other jobs running), `jobs_abort` makes this easy.

```sh
jobs_abort <job_id> [<job_id> ...]
```

`jobs_abort()` may only be called **from the scheduler's own process**: that is, from the **job completion callback** (`JOB_DONE_CB`). It does not work (and errors out) from any other callback or from an external process.

What happens to a job depends on its state when the call is made:

- **Running** - the job is terminated (if the **job termination callback** is configured) or abandoned (if not), its concurrency slot is released, and it is later reported in `<aborted_job_ids>` to the **scheduler completion callback**.
- **Pending** (not yet dispatched) - the job is removed from the queue and later reported in `<undispatched_job_ids>`, *not* in `<aborted_job_ids>`.
- **Already completed, expired, or already aborted** - silently ignored.

**Notes**:
- When the **job termination callback** is not configured, the scheduler abandons aborted jobs. Abandoned jobs keep running and their eventual completion record is discarded.
- `jobs_abort` normally returns `0` regardless of the action taken by it. Invalid and unknown job IDs are reported through the **scheduler error reporting callback** and skipped, and the call still returns 0. When the call itself was rejected because it was not made from withing the scheduler process, the return code is `1`.
- If all jobs were aborted, the scheduler run is still a success: the scheduler returns 0.
- Calling with no arguments does nothing and returns 0.

## Aborting specific jobs externally

**(Full variant only**. Aborting from a callback with [`jobs_abort()`](#aborting-specific-jobs-from-a-callback) works in both.**)**

An external process (rather than a callback) can abort specific jobs by writing an **abort record** to the scheduler's FIFO - the same FIFO the running jobs use to report their completion.

Set `SCHED_FIFO` to a path of your choosing before the run, so the outside process knows where to write. **You must create the FIFO yourself**: with `SCHED_FIFO` set, the scheduler adopts an existing path and never creates one. A path that does not exist, or exists but is not a FIFO, is rejected: no job starts, the path is left untouched, and the failure is reported with code `1` through the **scheduler completion callback** and the **scheduler error reporting callback**.

```sh
SCHED_FIFO=/run/nightly-fetch.ipc

# The caller creates the FIFO; the scheduler adopts it and deletes it when the run ends
rm -f "${SCHED_FIFO}"
mkfifo "${SCHED_FIFO}" || exit 1

schedule_jobs "<job_ids>" &
scheduler_pid=${!}
```

The aborter - usually a separate process - then writes one record to the FIFO:

```sh
# A missing path would be silently created as a regular file by '<>', not fail
[ -p "${SCHED_FIFO}" ] || exit 1

# Using fd8, open the FIFO file read-write to prevent it from blocking on writes
exec 8<>"${SCHED_FIFO}" || exit 1
printf '\002abort job1 job3\003\n' >&8
exec 8>&-
```

Job IDs are handled exactly as in [`jobs_abort()`](#aborting-specific-jobs-from-a-callback), including the reporting of unknown IDs and the rule that a still-pending job is reported as *undispatched* rather than *aborted*.

### Record format

Every record on the FIFO, from a job or from outside, is framed:

```
<STX> <payload> <ETX> <LF>          STX = 0x02, ETX = 0x03
```

with one of two payloads:

| Payload | Written by | Meaning |
| ------- | ---------- | ------- |
| `<rv> <job_id>` | the job wrapper, on fd 3 | job finished with return code `<rv>` |
| `abort <job_id> [<job_id> ...]` | anyone | abort these jobs |

The two can never be confused: the first field of a completion record is always an unsigned integer and is never a job ID.

**A record must be written with a single `printf` and must not exceed 4096 bytes** (`PIPE_BUF`), which is what makes it atomic: the kernel guarantees writes of that size to a FIFO are never interleaved with another writer's. A caller with more job IDs than fit must split them across several records, each one framed and written separately - that is safe, since each record is applied independently.

The framing lets the scheduler distinguish a complete record from a truncated one and resynchronise after damage. A partially written record is skipped and the run carries on, as is an abort record naming job IDs that do not exist. The run fails only when what arrives is not this protocol at all: an unframed line, or a completion record that does not parse. All of these cases are reported through the **scheduler error reporting callback**.

### Notes and limitations

- **A successful write is never proof that anything was aborted.** If the run is already over, the write still succeeds: either into a leftover FIFO nobody reads, or into a regular file that `<>` creates at the missing path. Check `<aborted_job_ids>` in the **scheduler completion callback** for the actual outcome.
- **Test the path with `[ -p ]` before opening it.** This is what distinguishes the two cases above from a live run, and it also stops the aborter from littering a regular file at the path - one which a later `mkfifo` would then fail on. The scheduler makes the same check on its own side before adopting the path, for the same reason.
- **Open the FIFO read-write** (`exec 8<>`), not write-only. A write-only open blocks until a reader appears, so it would hang forever against a FIFO whose scheduler has died - including when the scheduler exits between your open and your write. Close the descriptor as soon as the record is written.
- **Create the FIFO fresh for every run.** `rm -f` before `mkfifo`, as in the example above. A leftover FIFO is adopted rather than rejected, and stale records in it can make the next run fail. Never share one path between concurrent instances, for the same reason.
- **Delivery is prompt but not preemptive.** At each scheduler wakeup, any new abort records are processed and acted on before anything else, including before processing job completions and before dispatching new jobs. Two things do delay it. The scheduler reads and processes at most 100 records per pass, so an abort queued behind 100 completion records waits for the next pass. And if the record was written while the scheduler was blocked in one of your callbacks, it is read only after that callback returns.

## Environment variables

The scheduler is configured entirely through environment variables. Required variables must be set before calling `schedule_jobs()`. All others are optional.

| Variable                  | Required | Default | Description                                                                                                                      |
| ------------------------- | :------: | :-----: | -------------------------------------------------------------------------------------------------------------------------------- |
| DO_JOB_CB                 |     *    |    -    | Command implementing the job execution callback.                                                                                 |
| JOB_DONE_CB               |          |  unset  | Command implementing the job completion callback.                                                                                |
| SCHED_FINALIZE_CB         |          |  unset  | Command implementing the scheduler completion callback.                                                                          |
| SCHED_FAIL_MSG_CB         |          |  unset  | Command implementing the scheduler error reporting callback.                                                                     |
| JOB_TERM_CB               |          |  unset  | Command implementing the job termination callback. See [Job termination callback](#job-termination-callback-job_term_cb).        |
| SCHED_MAX_JOBS            |     *    |    -    | Concurrency limit ( integer >= 1 ).                                                                                              |
| SCHED_TIMEOUT_S           |          |  `900`  | Global scheduler timeout in seconds ( integer >= 1 ).                                                                            |
| SCHED_IDLE_TIMEOUT_S      |          |  `300`  | Maximum allowed time, in seconds, without any job starts or completions ( integer >= 1 ).                                        |
| SCHED_JOB_TIMEOUT_S       |          |  unset  | Default per-job timeout in seconds ( integer >= 1 ); override per job via `job_set_timeout()`. See [TIMEKEEPING.md](TIMEKEEPING.md#per-job-timeouts). |
| SCHED_FIFO                |          |  unset  | **(full variant only)** Path to the FIFO file used for the scheduler's internal communication and for abort records externally. (see Notes below). |
| SCHED_ID                  |          |  unset  | Namespace for per-job params and timeouts, letting schedulers driven from one shell process reuse job IDs without overwriting each other's values ( same character and length rules as a job ID ). Unset or empty selects the default namespace. See [Scheduler namespace](#scheduler-namespace-sched_id). |
| SCHED_INNER_SUBSHELL      |          |  unset  | Whether to run the job execution callback one process deeper, in a subshell with the scheduler's file descriptor 3 closed ( any non-empty value to enable ). Set it when your jobs run commands you do not fully trust, or when they need fd 3 for themselves (see Notes below). |
| SCHED_AUTO_PARAMS         |          |  unset  | **(full variant only)** Whether to export job-specific params before invoking the job execution and job completion callbacks for each job ( 1 to enable, any other value to disable ). The mini variant always delivers registered params and ignores this. |
| SCHED_CGROUP_BASE         |          |  unset  | **(full variant only)** Read only by the cgroup job termination mechanism. For testing or advanced use: writable cgroup2 directory under which the per-run cgroup is created, overriding autodetection. Trailing `/` characters are ignored. |
| SCHED_AUTO_JOB_TERM       |          |  unset  | **(mini variant only)** Whether to enable the built-in job termination mechanism ( any non-empty value to enable ). Overwrites `JOB_TERM_CB` at scheduler startup. See [Job termination callback - mini](#job-termination-callback---mini). |

Notes:

- Callback variables must contain command names only. Arguments are not allowed.
- Invalid value of any required or optional variable causes `schedule_jobs()` to fail before starting any jobs.
- Timeout behavior is documented in detail in [TIMEKEEPING.md](TIMEKEEPING.md).
- `SCHED_FIFO`: This option requires you to create the FIFO file via `mkfifo` before the run. The scheduler adopts the FIFO you created, deletes it when the run ends, and rejects a path that is missing or not a FIFO. When unset, the scheduler instead creates the FIFO itself, inside a uniquely named per-run subdirectory under `/tmp`, so concurrent scheduler instances never collide. Set it when a process outside the run needs to reach the batch; see [Aborting specific jobs externally](#aborting-specific-jobs-externally). If using multiple concurrent scheduler instances, give each one a unique FIFO path. The mini variant always creates its own FIFO and ignores this.
- `SCHED_INNER_SUBSHELL`: the scheduler keeps file descriptor 3 open for the whole run - that is required for communication with job wrappers. Normally your job execution callback inherits it, so a stray write to fd 3 from a job can confuse the run, so jobs should avoid writing to that fd (i.e. avoid `command >&3`). With this option set, the callback runs in a subshell that has fd 3 closed: writes and reads on the inherited descriptor simply fail, and the fd is free for your jobs to use as they like. The cost is one extra subshell per job.
- `SCHED_UID` is **set by the scheduler, not by you**. It identifies the process running the current batch and is how the scheduler recognises calls made from its own process, such as [`jobs_abort()`](#aborting-specific-jobs-from-a-callback). It is inherited by job processes, so it is readable from a job, but changing its value - or that of any variable prefixed with `SCHED_`, `SCH_`, `sch_` or `_sch_` and not listed in the table above - is unsupported and may break the run.

## Return codes

The following table disambiguates error codes reported by the scheduler.

| Return code | Meaning                                                            |
| :---------: | ------------------------------------------------------------------ |
|     `0`     | Scheduler completed successfully.                                  |
|     `1`     | Fatal error.                                                       |
|     `81`    | Idle timeout (`${SCHED_IDLE_TIMEOUT_S}`) was reached.              |
|     `82`    | Global timeout (`${SCHED_TIMEOUT_S}`) was reached.                 |
|     `83`    | Scheduler was terminated by the `USR1` signal.                     |
|     `84`    | Scheduler was terminated by either the `INT` or the `TERM` signal. |

`schedule_jobs()` exits with one of them when **scheduler completion callback** (`SCHED_FINALIZE_CB`) is not defined; when it is defined, the return code is passed to that callback in its first argument and the **scheduler completion callback**'s own return code sets the final exit code of the scheduler.

This guarantee also covers an `exit` called from a callback that runs in the scheduler's own process (`JOB_DONE_CB`): the scheduler still performs its cleanup and invokes the **scheduler completion callback**, passing the code handed to `exit` as `<scheduler_return_code>`. Note that `exit 0` from a callback therefore yields a successful-looking run that nevertheless has unfinished jobs.

**Note**: The job execution callback (`DO_JOB_CB`) returns a **job** return code, not a scheduler return code. This value is reported to the job completion callback (`JOB_DONE_CB`) if one is defined.

## Timeouts

The scheduler implements three independent timeout mechanisms:
- **global timeout** (`${SCHED_TIMEOUT_S}`, return code `82`), limiting the scheduler's total run time
- **idle timeout** (`${SCHED_IDLE_TIMEOUT_S}`, return code `81`), limiting the time the scheduler may go without starting a job or receiving a job completion
- **per-job timeout** (configurable individually for each job via `job_set_timeout()`, defaults to `${SCHED_JOB_TIMEOUT_S}` if defined). A per-job timeout persists until overwritten or cleared with [`jobs_init()`](#resetting-job-parameters-jobs_init).

Time measurement, timeout mechanisms, and reliable delays in callbacks are documented in detail in [TIMEKEEPING.md](TIMEKEEPING.md).

## Signal handling

The scheduler installs handlers for signals `USR1`, `INT`, `TERM`. When any of these signals is received, the scheduler stops processing, performs its internal cleanup, invokes the **scheduler completion callback** (if defined), and exits with return code `83` (for `USR1`) or `84` (for `INT` or `TERM`) - unless the callback returns a different code.

## Job termination mechanisms

By default, the scheduler does not terminate running jobs by itself, including when a timeout is reached or when `USR1` is received.

If your application needs to stop timed-out and unfinished jobs, you can either configure the **job termination callback** or implement custom job termination in the **scheduler completion callback** using the list of unfinished job PIDs (`<running_pids>`) passed to it.

### TL;DR

For simple use cases with relatively few well-behaved jobs, it doesn't really matter which of the three built-in mechanisms is used.

- Unless you have a reason to prefer a particular mechanism, let `sched_use_job_term auto` pick one automatically, as explained in [Built-in job termination mechanisms](#built-in-job-termination-mechanisms---full) below. If you implement this exactly as shown in the example code snippet, it will just work (almost) anywhere without any extra configuration.
- If spawning many jobs, strongly prefer the `cgroup` mechanism because it is much more efficient.
- If spawning jobs which are prone to misbehavior, hanging or leaving orphaned processes behind, prefer the `cgroup` mechanism because it allows for more deterministic process termination.
- If the target system doesn't support the `cgroup` mechanism, use a `/proc`-based one: `ppid` needs only `/proc` and `awk` and works essentially anywhere; `children` is a more efficient variant, available where the kernel provides `CONFIG_PROC_CHILDREN`.

## Job termination callback - mini
The **mini scheduler variant** comes with the **PPID-walk** job termination mechanism built-in and **does not** implement the subcommand interface implemented by the full variant, so the mechanisms discussed below are not available in the mini variant.

To enable automatic job termination via the built-in mechanism in the **mini** variant, set `JOB_TERM_CB=sch_job_term_ppid`, or set `SCHED_AUTO_JOB_TERM` to any non-empty value.

## Job termination callback - full

The **full scheduler variant** invokes this callback at several points, with one of the **subcommands** listed below:

| When (invocation point)                                                | Purpose                                 | Subcommand |Arguments                            |
| -----------------------------------------------------------------------| --------------------------------------  | ---------- |---------------------                |
| **Scheduler startup**, before any job is dispatched                    | Initialize termination mechanism        | `init`     |None                                 |
| **Inside each job's process**, before invoking job execution callback  | Make job-specific arrangements          | `setup`    | `<job_id> <pid>`                    |
| **Per-job timeout expiry**                                             | Kill process tree                       | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 1**, before invoking scheduler completion callback  | Kill any still-running jobs + processes | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 2**, before invoking scheduler completion callback  | Tear down the job termination mechanism | `cleanup`  | `<verified_kills_out_var>`          |

The PIDs passed to `term` are job wrapper PIDs (the same PIDs reported in `<running_pids>`); the callback is responsible for terminating each job's whole process tree.

**Note**:

**`term` and `cleanup` may report verified job terminations via the output variable**: `<verified_kills_out_var>` is the name of a variable the callback may assign a whitespace-separated job PID list to. A reported job PID asserts that the job's entire process tree has been killed; the scheduler then excludes it from the `<running_pids>` passed to the **scheduler completion callback**.

## Built-in job termination mechanisms - full

**(full variant only** - the mini variant has its own equivalent mechanism, described above.**)**

`scheduler.sh` implements the **job termination callback** (`JOB_TERM_CB`) via any of three mechanisms, ready to use without writing one yourself:

- **`cgroup`** - puts each job in its own cgroup when spawning it, then kills the whole process tree - including orphaned grandchildren - via the kernel's `cgroup.kill`. Process kills are kernel-verified, so under normal operation `<running_pids>` reported to the **scheduler completion callback** is empty even after scheduler timeouts or early exit. Requires cgroup v2 with `cgroup.kill` (kernel >= 5.14) and write access to a cgroup - available when running as root, when started by the systemd user manager, or in a container with a writable cgroup mount.
- **`children`** - reconstructs each job's process tree from the kernel's `/proc/<pid>/task/<tid>/children` files, freezes all processes in the tree with `SIGSTOP`, then delivers `SIGKILL`. Those files require a kernel built with the option `CONFIG_PROC_CHILDREN` enabled. Discovers descendant PIDs more efficiently than the `ppid` mechanism, so prefer it where available.
- **`ppid`** - same mechanism, guarantees and limitations as `children`, but discovers each job's descendants by walking PPID links in `/proc/<pid>/stat` - this is slower but avoids the extra dependencies. Needs only `/proc` and `awk` - no cgroups, no root - which makes it the universal fallback that works on essentially any Linux.

Neither `/proc`-based mechanism can find orphaned processes, and neither verifies process termination, so `<running_pids>` reported to the **scheduler completion callback** may list job PIDs whose trees are already gone.

### Selecting job termination mechanism at runtime
Call `sched_use_job_term`, which probes the requested mechanism and on success sets `JOB_TERM_CB=sched_job_term_<mechanism>`:

```sh
. ./scheduler.sh

sched_use_job_term [-q] <cgroup|children|ppid|auto>
schedule_jobs "${IDS}" &
```

`auto` tests mechanisms availability in the fallback order (cgroup -> children -> ppid) and sets `JOB_TERM_CB` to the first one that works on given system. If none work (which should never happen on a healthy system), or for unexpected mechanism name, `sched_use_job_term` prints an error, assigns empty string to `JOB_TERM_CB` and returns 1. Pass `-q` as the first argument to suppress the error message and rely on the return code instead.

### Using a custom job termination mechanism
If you want to implement and use a custom job termination mechanism, simply specify the corresponding function name via the callback variable `JOB_TERM_CB` before calling `schedule_jobs`, e.g. `JOB_TERM_CB=my_job_term_func`. No need to invoke `sched_use_job_term`. Make sure that your implementation conforms with the callback [API](#job-termination-callback---full).

### Details

Each mechanism, its requirements, and how to deploy it (containers, cron, systemd, unprivileged use) are documented in **[JOB-TERMINATION.md](JOB-TERMINATION.md)**.
