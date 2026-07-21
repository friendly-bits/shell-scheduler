## shell-scheduler

The goal of this project is to implement a reliable, reusable, flexible and reasonably comprehensive library for parallelization in shell scripts - and keep it small, lightweight and self-contained.

> If you find this niche little project useful, please take a second to give it a star on GitHub - this helps other people to find it.

## Motivation
This library is designed to solve the following problems:
1. Separate parallelization orchestration code from application-specific code.
2. Allow implementing jobs as shell functions.
3. Provide application-specific context to jobs.
4. Easily track job completions (and timeouts) and act on them in real time.
5. Minimum dependencies: Linux kernel, compatible shell, `mkfifo`, `mkdir` and `rm` - that's it.

## Features

- **Parallel job scheduling**: execute independent jobs concurrently, up to a configurable maximum number of running jobs
- **Callback-based API** facilitates easy integration with a shell-based application while keeping parallelization orchestration code separate from application-specific code
- **Configurable per-job parameters**
- **Configurable global, idle and per-job timeouts**
- **Validity checks and error handling** of everything that can go wrong, including configuration, callback definitions and internal scheduler state
- Optional **automatic job termination**
- **Extensive test suite** validates that every promise made by the API holds in practice
- **Negligible performance overhead** for almost any feasible use case. Very few invocations of external binaries, very few filesystem operations, and minimum spawned subshells
- Supports running **multiple scheduler instances** in parallel on the same machine

## Dependencies

- **Linux** - required for its reliance on `/proc` to read PIDs and system uptime. Should be not too complicated to port to any other Unix-like system.
- **Bash or BusyBox ash**. Other shells are not supported. Could be conceivably ported to POSIX-compliant code.
- The utilities `mkfifo`, `mkdir`, and `rm`. No other binary utilities are used by the library.

## Quick start

A minimal setup needs to source the library, write one callback that does the work for a single job, set two variables, and call `schedule_jobs()` with a list of job IDs:

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

This runs five jobs, up to three at a time: jobs 1, 2, 3 start almost simultaneously, and 4 and 5 wait for a slot to free up.

## How it works

_Note: this is the TL;DR version. For more details, see REFERENCE.md and TIMEKEEPING.md._

The scheduler is started via the call to `schedule_jobs` with the list of **job IDs** as the first argument:

```SH
schedule_jobs <job_ids> &
```

The scheduler is configured via environment variables.

- `SCHED_MAX_JOBS` configures the number of parallel execution **slots**. The queue of job IDs is configured via the first argument passed to `schedule_jobs`. The scheduler starts jobs in the background in the same order as they appear in the list, and whenever a slot frees up it starts the next pending job to fill it. The scheduler keeps running until every job has finished, or it hits a timeout, or receives a signal, or encounters a fatal error.
- If you want to tune **global scheduler timeouts**, set `SCHED_TIMEOUT_S` (defaults to 900s) and `SCHED_IDLE_TIMEOUT_S` (max allowed time with no job starts and completions, defaults to 300s).
- If you want to enable **global per-job timeouts**, set `SCHED_JOB_TIMEOUT_S`.

-----
Your code can hook in five places by implementing **callbacks**. Each callback can be implemented as a shell function in your application. To configure a callback, set the value of a corresponding variable to the name of the shell function implementing the callback (see example below).

- For **job implementation**, specify the **job execution callback** as the value of `${DO_JOB_CB}`. When invoking this callback, the scheduler passes the corresponding job ID in the first argument.
- When a **job completes**, the scheduler calls your optional **job completion callback** (`JOB_DONE_CB`) with the job ID and its return code.
- If a **job hangs** and hits a per-job timeout, or when either the **global scheduler timeout** or the **idle timeout** is exceeded, the scheduler calls your optional **job termination callback** (`JOB_TERM_CB`).
- Before the scheduler **exits**, it calls your optional **scheduler completion callback** (`SCHED_FINALIZE_CB`).
- When the scheduler **encounters an error**, it calls your optional **error reporting callback** (`SCHED_FAIL_MSG_CB`) - if not defined, errors are printed to STDERR.

For example, for the **job execution callback**, implement the callback function and set the environment variable `DO_JOB_CB` to the name of that function before calling `schedule_jobs`:

```sh
my_job_exec() {
	...
}

DO_JOB_CB=my_job_exec
schedule_jobs "<job_ids>" &
```

-----

Before setting per-job parameters and timeouts, and particularly before reconfiguring and re-running jobs in the same process, a good practice is to **reset jobs configuration** via `jobs_init`.

```sh
jobs_init "<job_id_list>"
```

To set **per-job parameters**, use the helper `job_set_params` before calling `schedule_jobs`:

```sh
job_set_params <job_id> <param_1>="<param_value_1>" <param_2>="<param_value_2>" ...
```

To fetch per-job parameters in each job, either set `SCHED_AUTO_PARAMS=1` to have per-job parameters automatically passed to each job as environment variables or use the helper `job_get_params` in the implementation of your job execution callback (`DO_JOB_CB`):

```sh
my_job_exec() {
	local param_1 param_2
	local job_id="${1}"
	job_get_params "${job_id}" param_1 param_2
	echo "The value of param_1 for job '${job_id}' is '${param_1}'."
}

SCHED_MAX_JOBS=2
DO_JOB_CB=my_job_exec
job_set_params job_1 param_1=apple param_2=orange
job_set_params job_2 param_1=foo   param_2=bar
schedule_jobs "job_1 job_2" &
wait ${!}
```

To set **individual timeout for a job** (overriding `SCHED_JOB_TIMEOUT_S` for that job), use the helper `job_set_timeout`:

```sh
job_set_timeout <job_id> <seconds>
```

-----

**Note**: The scheduler is intended to run in a separate process. This may be a background process (with the `&` after `schedule_jobs`), or a foreground subshell, e.g.:
```sh
( DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3" )
```

While technically you *can* run the scheduler in the same process as your application, that would make your script exit when the scheduler does and interfere with any `trap`s your application might have set up. So as a general rule, avoid that.

## Security

The implementation uses `eval` in a few places to emulate associative arrays functionality. Expressions passed to `eval` are carefully constructed to avoid command injection vulnerabilities: variable names are vetted, and values are expanded via parameter expansion rather than interpolated into the code string, so they cannot be interpreted as code. E.g.:

```sh
# Vet the value of ${sch_job_id}
sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1
...
# Get parameters list for job ${sch_job_id}
eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_job_id}}\""
```

(`sch_check_name()` performs string safety validation)

This follows the [recommendation](https://www.shellcheck.net/wiki/SC2082) by shellcheck for getting values via indirection on POSIX shells.

This mechanism and all relevant code has been checked, double-checked and triple-checked by the author and by various AIs.

The test suite includes tests which specifically check for command injection vulnerabilities (`tests/tests-security.sh`).

The author firmly believes that these precautions are sufficient.

-----

The implementation is careful about **globbing**. Every place which might be subject to unwanted/unsafe globbing uses the following construct:

```sh
# Save earlier noglob state
local had_f
sch_had_f && had_f=1

# Disable globbing
set -f

# Do something which is subject to unwanted globbing, e.g. a "for" loop
# ...

# Restore noglob state
[ -n "${had_f}" ] || set +f
```

where `sch_had_f()` is:

```sh
sch_had_f() {
	case "${-}" in
		*f*) return 0 ;;
		*) return 1
	esac
}
```

## Full reference

The above information, along with the below example, should be enough for most basic use cases. For additional options, technical details and examples, see **[REFERENCE.md](REFERENCE.md)**:

- **[How to use (Scheduler API)](REFERENCE.md#how-to-use-scheduler-api)**
- **[Callbacks](REFERENCE.md#callbacks)**
- **[Job parameters](REFERENCE.md#job-parameters)**
- **[Environment variables](REFERENCE.md#environment-variables)**
- **[Return codes](REFERENCE.md#return-codes)**
- **[Timeouts](REFERENCE.md#timeouts)**
- **[Signal handling](REFERENCE.md#signal-handling)**
- **[Termination of running jobs](REFERENCE.md#termination-of-running-jobs)**

Time measurement and timeout behavior are covered in depth in **[TIMEKEEPING.md](TIMEKEEPING.md)**. The three optional job termination helper libraries are documented in **[JOB-TERMINATION-LIBRARIES.md](JOB-TERMINATION-LIBRARIES.md)**.

## Real-world example

For an integration example, see [`EXAMPLE-HAGEZI-FETCH.md`](EXAMPLE-HAGEZI-FETCH.md) - a concurrent downloader for DNS blocklists. It demonstrates per-job parameters, signal forwarding, cleanup of orphaned child processes, and bookkeeping across callbacks.
