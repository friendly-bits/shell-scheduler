## shell-scheduler

The goal of this project is to implement a reliable, reusable, flexible and reasonably comprehensive library for parallelization in shell scripts - and keep it small, lightweight and self-contained.

> If you find this niche little project useful, please take a second to give it a star on GitHub - this helps other people to find it.

## Contents

- [Motivation](#motivation)
- [Features](#features)
- [Dependencies](#dependencies)
- [Variants](#variants)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Security](#security)
- [Full reference](#full-reference)
- [Real-world examples](#real-world-examples)
- [Code authorship and the use of generative AI](#code-authorship-and-the-use-of-generative-ai)

## Motivation
This library is designed to solve the following problems:
1. Separate parallelization code from application-specific code.
2. Allow implementing jobs as shell functions.
3. Provide application-specific context to jobs.
4. Easily track job completions (and timeouts) and act on them in real time.
5. Minimum dependencies: Linux kernel, compatible shell, `mkfifo`, `mkdir` and `rm` - that's it.

## Features

- **Parallel job scheduling**: execute independent jobs concurrently, up to a configurable maximum number of running jobs
- **Callback-based API** facilitates easy integration with a shell-based application
- **Configurable per-job parameters**
- **Configurable global, idle and per-job timeouts**
- **Job cancellation**: abort specific running or queued jobs mid-flight
- **Validity checks and error handling** of everything that can go wrong, including configuration, callback definitions and internal scheduler state
- Optional **automatic job termination**
- **Extensive test suite** validates that every promise made by the API holds in practice
- **Negligible performance overhead** for almost any feasible use case. Very few invocations of external binaries, very few filesystem operations, and minimum spawned subshells
- Supports running **multiple scheduler instances** in parallel on the same machine, including fun stuff like multiple levels of schedulers nested inside each other.

## Dependencies

- **Linux** - required for its reliance on `/proc` to read PIDs and system uptime. Should be not too complicated to port to any other Unix-like system.
- **Bash or BusyBox ash or [shed](https://github.com/km-clay/shed)**. Other shells are not supported. Could be conceivably ported to POSIX-compliant code.
- The utilities `mkfifo`, `mkdir`, and `rm`. No other binary utilities are used by the library.

## Variants

shell-scheduler comes in two variants: full (`scheduler.sh`) and mini (`scheduler-mini.sh`). The differences are listed below:

- **Job termination**: the full variant hands this off to a separate helper library (`job-term.sh`), which implements three selectable job termination mechanisms (cgroup, children-walk, PPID-walk). The mini variant has the PPID-walk mechanism built in and uses a simplified job termination callback protocol, which makes it incompatible with the helper library.
- **Per-job parameters**: the full variant exports registered params to jobs and to the job completion callback only when you opt in with `SCHED_AUTO_PARAMS=1`; the mini variant always exports them.
- **Aborting jobs from outside**: only the full variant can do this. Both variants can abort jobs from the job completion callback.
- **Code comments**: the mini version removes a lot of them to reduce the size.

Everything else (callbacks, timeouts, per-job parameters and helpers) is identical. Pick mini if file size is important and the PPID-walk job termination mechanism is sufficient for your application; or if you prefer a single file. Pick full if you want all three job termination mechanisms available, want to abort jobs from outside the scheduler, or want control over whether parameters are automatically passed to jobs.

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
schedule_jobs "<job_ids>" &
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
- Before the scheduler **exits**, it calls your optional **scheduler completion callback** (`SCHED_FINALIZE_CB`), which reports every job ID in exactly one outcome category: succeeded, failed, unfinished, undispatched (never started), expired or aborted.
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

Before setting per-job parameters and timeouts - and especially before reconfiguring and re-running jobs in the same process - it is good practice to **reset the job configuration** via `jobs_init`.

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

If your application needs to run more than one scheduler instance, see [Scheduler namespace](REFERENCE.md#scheduler-namespace-sched_id).

-----

You can terminate the scheduler when needed by sending it a signal: USR1 or TERM or INT (the latter only works if the scheduler is running in the foreground). See [Signal handling](REFERENCE.md#signal-handling)

To **abort specific jobs** while the batch is running without terminating the scheduler, you can implement logic in the **job completion callback** which would conditionally call the helper `jobs_abort`. See [Aborting specific jobs from a callback](REFERENCE.md#aborting-specific-jobs-from-a-callback).

In order to be able to abort specific jobs **from outside the scheduler** (full variant only), create a FIFO with `mkfifo` and set `SCHED_FIFO` to its path before starting the scheduler. Then when your code wants to abort specific jobs, it can write an abort record to that FIFO. See [Aborting specific jobs externally](REFERENCE.md#aborting-specific-jobs-externally).

Note that job's processes are only killed if the **job termination callback** is configured.

-----

**Note**: The scheduler is intended to run in a separate process. This may be a background process (with the `&` after `schedule_jobs`), or a foreground subshell, e.g.:
```sh
( DO_JOB_CB=my_exec SCHED_MAX_JOBS=10 schedule_jobs "1 2 3" )
```

While technically you *can* run the scheduler in the same process as your application, that would make your script exit when the scheduler does and replace any `USR1`/`INT`/`TERM`/`EXIT` `trap`s your application might have set up. So as a general rule, avoid that.

## Security

By default, shell-scheduler assumes that your application and jobs specified by your application are trusted code. It performs validity checks where it makes sense and tries to resist user mistakes, but it can not prevent you from running untrusted code and if you tell shell-scheduler to run such code, it will. Such untrusted code could, in theory, mess with scheduler's internal state: to a larger degree when this happens in scheduler's main process, and to a lesser degree when this happens in a callback which runs in a subshell (e.g. the **job execution callback**). See [REFERENCE.md](REFERENCE.md#callbacks) for a list of callbacks and a table showing which process each callback runs in. See [Running untrusted jobs](#running-untrusted-jobs) below for additional information.

**File permissions**: when the scheduler creates its own working directory and the FIFO inside it, both are made accessible to the owner only (i.e. the user under which your application is running). A FIFO you supply yourself via `SCHED_FIFO` is created by you, so you control its permissions. To restrict access to your user only, create the FIFO file with permissions `600`, e.g. `mkfifo -m 600 /tmp/myfifo` if `mkfifo` supports the `-m` switch, or `( umask 077; mkfifo /tmp/myfifo )` if not (the subshell + `umask` guarantees atomicity).

### Running untrusted jobs

If some of your jobs run code you do not fully trust, the practical way to contain it is to run that code as a different user with fewer privileges.

To implement this, run untrusted commands inside your **job execution callback** via one of the common utilites that can start a process under another user: `su`, `sudo`, `doas`, `setpriv`, `runuser` or `start-stop-daemon`. Dropping permissions should restrict the job's ability to kill the scheduler via signals, or to access sensitive files, including the FIFO file used for scheduler's communication with the job wrappers.

Besides file permissions, a job inherits the file descriptor which the scheduler creates to access the FIFO file, and its ability to write and read to/from this file descriptor is not affected by the permissions it runs with. So it can disrupt this communication channel, abort jobs or report job completions which never happened.

To close all the mentioned gaps, in addition to running untrusted code with reduced permissions, it is important to get two things right:

- **Set `SCHED_INNER_SUBSHELL=1`** in order to prevent untrusted commands from being able to read and write to/from the file descriptor opened by the scheduler. With this variable set, the jobs are started inside a second subshell and this allows the scheduler to close that file descriptor before the **job execution callback** runs, so jobs will not be able to reuse the file descriptor. Setting the same environment variable also frees up fd 3 for legitimate use by the jobs (otherwise you should avoid using that file descriptor).
- **Mind the FIFO's permissions if you supply your own.** The scheduler's own FIFO is owner-only, so a process running as another user can not open it by path. One you create yourself is only as protected as you make it.

It is also worth clearing the environment for the untrusted command, with `env -i` or by unsetting the variables you care about. This does not protect the scheduler - its state lives in its own process, not in variables a child could reach - but per-job parameters are handed to jobs as environment variables (always in the mini variant, and with `SCHED_AUTO_PARAMS=1` in the full one), so any command the job starts inherits all of them, along with whatever else your application keeps in its environment. If any of that is sensitive, an untrusted command has no business seeing it. Note that `env -i` clears *everything*, so the command may need `PATH` and a few others put back explicitly.

**Notes**:
- The implementation uses `eval` in a few places to emulate associative array functionality and for code compactness. To avoid command injection vulnerabilities, the code validates variable names passed to `eval` and makes sure that untrusted values can not be interpreted as code.
- Job IDs, parameter names and destination variable names are validated by the helper that receives them, before they are ever used to build an internal variable name, and separately before every use in `eval`.
- The implementation is likewise careful about **globbing**. When any unquoted word split is required, this is done with the `noglob` shell option turned on (i.e. filename expansion is disabled), so a value containing `*` or `?` cannot expand into filenames. The original `noglob` value is restored afterwards.
- The test suite includes tests which specifically check for command injection and forgery resistance (`tests/tests-security.sh`), and for correct noglob behavior.

## Full reference

The above information, along with the below example, should be enough for most basic use cases. For additional options, technical details and examples, see **[REFERENCE.md](REFERENCE.md)**:

- **[How to use (Scheduler API)](REFERENCE.md#how-to-use-scheduler-api)**
- **[Callbacks](REFERENCE.md#callbacks)**
- **[Job parameters](REFERENCE.md#job-parameters)**
- **[Environment variables](REFERENCE.md#environment-variables)**
- **[Return codes](REFERENCE.md#return-codes)**
- **[Timeouts](REFERENCE.md#timeouts)**
- **[Signal handling](REFERENCE.md#signal-handling)**
- **[Job termination mechanisms](REFERENCE.md#job-termination-mechanisms)**

Time measurement and timeout behavior are covered in depth in **[TIMEKEEPING.md](TIMEKEEPING.md)**. The optional job termination helper library and its three mechanisms are documented in **[JOB-TERMINATION-LIBRARY.md](JOB-TERMINATION-LIBRARY.md)**.

## Real-world examples

For a complete integration example, see [`EXAMPLE-HAGEZI-FETCH.md`](EXAMPLE-HAGEZI-FETCH.md) - a concurrent downloader for DNS blocklists. It demonstrates per-job parameters, signal forwarding, cleanup of orphaned child processes, and bookkeeping across callbacks.

For another complete (and quite involved) integration example, see [`test-matrix.sh`](tests/test-matrix.sh) - a script which runs multiple instances of the test suite in parallel with Bash, Busybox ash and shed, across the full and mini variants of the scheduler, using the scheduler itself to orchestrate the parallelization.

## Code authorship and the use of generative AI

TL;DR: AI was used as an assistant when developing this project, but it is not vibe-coded.

This project started as a generalizing refactor of code I wrote for [adblock-lean](https://github.com/lynxthecat/adblock-lean). That code was entirely written by hand. I am planning to contribute this generalized and refactored code back to adblock-lean and to re-integrate it into that project. While working on the refactor and further development, I used AI for correctness verification, bug detection and initial documentation. Later, while working on some especially tricky features, I co-developed them with AI. Specifically: some parts of the timeout handling code were co-developed with AI; some parts of the job termination code were initially implemented by AI with my supervision, then I rewrote some of it, again using AI as code reviewer and bug-checker.

**Every line of code and every command** in the three main scripts (scheduler.sh, scheduler-mini.sh and job-term.sh) was either written by me or checked by me.

Testing infrastructure was co-developed with AI. Tests themselves were written by AI following my prompts and, for the most part, verified by me and, where bugs were discovered, manually fixed.

Documentation was initially written by AI and later mostly re-written by me, using AI as a grammar and correctness checker.
