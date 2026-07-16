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

- **Parallel job scheduling**: execute independent jobs concurrently, up to a configurable maximum number of running jobs.
- **Callback-based API** allows for easy integration with a shell-based application while keeping parallelization orchestration code separate from application-specific code.
- **Extensive test suite** validates that every promise made by the API holds in practice.
- **Validity checks and error handling** of everything that can go wrong, including configuration, callback definitions and internal scheduler state.
- **Configurable global, idle and per-job timeouts**
- **Bash and BusyBox ash** support
- **Negligible performance overhead** for almost any feasible use case. Very few invocations of external binaries, very few filesystem operations, and minimum spawned subshells.

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

`SCHED_MAX_JOBS` configures the number of parallel execution **slots**. The queue of job IDs is configured via the first argument passed to `schedule_jobs`. The scheduler starts jobs in the background in the same order as they appear in the list, and whenever a slot frees up it starts the next pending job to fill it. The scheduler keeps running until every job has finished, or it hits a timeout, or receives a signal, or encounters a fatal error.

Your code can hook in four places:

- For **each job**, specify the execution callback (`DO_JOB_CB`) - this is the job implementation. When invoking this callback, the scheduler passes the corresponding job ID in the first argument.
- When a **job completes**, the scheduler calls your optional completion callback (`JOB_DONE_CB`) with the job ID and its return code.
- Before the scheduler **exits**, it calls your optional scheduler termination callback (`SCHED_FINALIZE_CB`).
- When the scheduler **encounters an error**, it calls your optional error reporting callback (`SCHED_FAIL_MSG_CB`) - if not defined, errors are printed to STDERR.

## Essentials

To get going, you need to set two variables before calling `schedule_jobs()`:

| Variable         | Required | Description                                     |
| ---------------- | :------: | ----------------------------------------------- |
| `DO_JOB_CB`      |    *     | Command that performs the work for one job (typically a shell function). |
| `SCHED_MAX_JOBS` |    *     | How many jobs may run concurrently (integer ≥ 1). |

If you want to tune global timeouts, also set `SCHED_TIMEOUT_S` (defaults to 900s) and `SCHED_IDLE_TIMEOUT_S` (max allowed time with no job starts and completions, defaults to 300s).

You can set variables inline with the call to `schedule_jobs`:

```sh
DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3" &
wait ${!}
```

**Note**: The scheduler is intended to run in a separate process. This may be a background process (with the `&` after `schedule_jobs`), or a foreground subshell, e.g.:
```
( DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3" )
```

While technically you *can* run the scheduler in the same process as your application, that would make your script exit when the scheduler does and interfere with any `trap`s your application might have set up. So as a general rule, avoid that.

## Full reference

The above information, along with the below example, should be enough for most basic use cases. For additional options, technical details and examples, see **[REFERENCE.md](REFERENCE.md)**:

- **[How to use (Scheduler API)](REFERENCE.md#how-to-use-scheduler-api)**
- **[Callbacks](REFERENCE.md#callbacks)**
- **[Job parameters](REFERENCE.md#job-parameters)**
- **[Environment variables](REFERENCE.md#environment-variables)**
- **[Return codes](REFERENCE.md#return-codes)**
- **[Timeouts](REFERENCE.md#timeouts)**
- **[Signal handling](REFERENCE.md#signal-handling)**
- **[Terminating running jobs](REFERENCE.md#termination-of-running-jobs)**

Time measurement and timeout behavior are covered in depth in **[TIMEKEEPING.md](TIMEKEEPING.md)**.

## Real-world example

For a complete integration example, see [`hagezi-fetch.sh`](hagezi-fetch.sh) - a concurrent downloader for DNS blocklists. It demonstrates per-job parameters, signal forwarding, cleanup of orphaned child processes, and bookkeeping across callbacks. A full walkthrough of these patterns is in the [reference](REFERENCE.md#real-world-example).
