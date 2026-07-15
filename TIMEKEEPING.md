# shell-scheduler — Time-keeping and Timeouts

How the scheduler measures time, the timeout mechanisms it implements, and how to perform reliable delays in callbacks. General library documentation lives in [REFERENCE.md](REFERENCE.md); if you're just getting started, read the [README](README.md) first.

## Contents

- [How the scheduler measures time](#how-the-scheduler-measures-time)
- [Global timeout](#global-timeout)
- [Idle timeout](#idle-timeout)
- [Reliable delays in callbacks](#reliable-delays-in-callbacks)
- [Per-job timeouts](#per-job-timeouts)

## How the scheduler measures time

The scheduler reads elapsed time from `/proc/uptime` with centisecond (0.01 s) resolution and performs all internal accounting in centiseconds. Because uptime is monotonic, time-keeping is immune to wall-clock changes (NTP corrections, timezone changes, manual `date` calls) — relevant on routers, which commonly boot with a wrong clock and correct it later.

Timeout *enforcement* is coarser than the accounting resolution:

- While waiting for job completions, the scheduler sleeps in `read -t` with a timeout in whole seconds (rounded up from the remaining time). A timeout is therefore never declared early, but may be declared up to about one second late.
- All callbacks except the **job execution callback** run synchronously in the scheduler process. While such a callback runs, the scheduler cannot register completions or declare timeouts — see the note in [Callbacks](REFERENCE.md#callbacks). Keep synchronous callbacks fast. Remaining time is recomputed from a fresh clock reading after each callback returns, so a slow callback delays timeout detection by at most its own duration.

## Global timeout

The global timeout (`${SCHED_TIMEOUT_S}`, default `900` seconds) limits the total time the scheduler is allowed to run. It starts when the scheduler begins execution and continues to run regardless of how many jobs are currently executing or waiting to be started.

If the global timeout is reached, the scheduler reports an error, invokes the **scheduler termination callback** (if defined), and exits with return code `82`.

## Idle timeout

The idle timeout (`${SCHED_IDLE_TIMEOUT_S}`, default `300` seconds) limits the maximum time the scheduler may go without making progress. The timeout is reset whenever the scheduler starts a job or successfully processes a job completion.

This timeout is useful for detecting situations where no progress is being made, for example because one or more jobs became stuck.

If the idle timeout is reached, the scheduler reports an error, invokes the **scheduler termination callback** (if defined), and exits with return code `81`.

Both timeout values are validated as non-zero unsigned decimal integers; leading zeros are stripped (never interpreted as octal). See the [Environment variables](REFERENCE.md#environment-variables) table for the summary.

## Per-job timeouts

### Motivation

Without per-job timeouts, a single hung job is invisible for as long as other jobs keep completing: activity keeps resetting the idle timeout, so the hung job survives until the global timeout — which then aborts the entire run, sacrificing all pending work. Meanwhile the hung job permanently occupies one of the `${SCHED_MAX_JOBS}` concurrency slots. Per-job timeouts convert "one bad job kills the batch" into "one bad job fails, the batch completes", and reclaim the occupied slot.

### Configuration

Global per-job timeouts are set via optional environment variable `${SCHED_JOB_TIMEOUT_S}`.

| Variable              | Required | Default | Description                                                                                                 |
| --------------------- | :------: | :-----: | ----------------------------------------------------------------------------------------------------------- |
| SCHED_JOB_TIMEOUT_S   |          |  unset  | Default per-job timeout in seconds ( integer >= 1 ). When unset, jobs without an individual timeout have no deadline. |

An individual job's timeout can be set (overriding `${SCHED_JOB_TIMEOUT_S}` for that job) via a dedicated helper:

```sh
job_set_timeout <job_id> <seconds>
```

Value must be non-zero unsigned decimal integer. A per-job timeout may exceed `${SCHED_TIMEOUT_S}`; such a deadline simply never fires (the global timeout wins first). When neither `${SCHED_JOB_TIMEOUT_S}` nor an individual timeout is set, the job will be allowed to run indefinitely. If such job becomes permanently stuck, the scheduler will eventually hit either the idle timeout or the global timeout and terminate with an error.

### Semantics

1. **Deadline definition.** A job's deadline is its dispatch time plus its timeout. Per the [enforcement granularity rules](#how-the-scheduler-measures-time), expiry is never declared early and may be declared up to about one second late — later still if a synchronous callback blocks the scheduler at that moment.
2. **Expiry means abandon, not kill.** The scheduler stops waiting for the job, frees its concurrency slot, classifies it as failed and calls the **job completion callback** (`JOB_DONE_CB`) — but does **not** signal the job's process, consistent with the [termination policy](REFERENCE.md#termination-of-running-jobs). The process may continue running; terminating it (and any children it spawned, e.g. via `pgrep -P`) is the application's responsibility.
3. **Notification.** A timed-out job is reported through the normal completion channel with job return code `124` and one extra argument:

   ```sh
   ${JOB_DONE_CB} <job_id> 124 <pid>
   ```

   The **presence of the third argument** marks a scheduler-synthesized timeout (vs similar return code received directly from the job). If a job genuinely exits with code `124`, this third argument will not be present. The `<pid>` enables application-side cleanup at the moment of expiry. The callback's existing contract is unchanged — a non-zero return still terminates the scheduler with that code.
4. **Arrival wins over expiry.** On each scheduler wake-up, a received completion record is processed before deadlines are checked.
5. **Scheduler timeouts take precedence.** The global and idle timeout checks run first; a job deadline never masks return codes `82` or `81`.
6. **Job expiries do not count as progress.** The idle timeout is reset when the scheduler starts a job or processes a genuine completion record — never when it processes an expiry.
7. **Late completion records are discarded.** If an abandoned job's completion record arrives after its expiry was processed, the record is silently dropped; the job's classification (timed out, code `124`) stands.
8. **Final accounting.** Timed-out job IDs appear in the `<fail_job_ids>` list passed to the **scheduler termination callback**; the guarantee that every job ID appears in exactly one outcome list is unchanged. Abandoned jobs whose process never reported by scheduler exit have their PIDs included in `<running_pids>` (they are, verbatim, "jobs the scheduler started but did not receive completion records for"); abandoned jobs whose late record was discarded do not.

### Implementation notes (internal)

- Deadlines are tracked in the scheduler process only.
- Deadline entries are encoded as `<pid>:<deadline_cs>:<job_id>`. The first two fields are unsigned integers, so the job ID is parsed as the trailing remainder and may safely contain any non-whitespace character, including `:`.
- All integration lives in the completion-wait path (`process_done_record()`): the `read -t` wait is capped by min(global remaining, idle remaining, nearest deadline remaining); expired deadlines are swept unconditionally at the end of every wake, after any received completion record has been fully processed (rule 4).
- Late-record handling (rule 7): a record whose PID is in the running list is processed normally; otherwise, if its PID **and** job ID match a recorded expiry, it is discarded and the expiry entry is delisted; otherwise it is malformed (fatal). Checking the running list first is what makes PID reuse safe: a reused PID always belongs to a currently-running job.
- Deadline bookkeeping (splitting off expired entries, slot reclamation, completion synthesis) and the record-classification decision (normal / discard / malformed) are inlined in `process_done_record()`. By test-suite policy, all of it is covered by behavior tests through the public interface only (`schedule_jobs()`, the documented helpers, environment variables and callbacks), so internal restructuring requires no test changes. The discard arm is tested deterministically by having a test `JOB_DONE_CB` forge the timed-out job's late completion record into the FIFO at the moment of the timeout notification.

## Reliable delays in callbacks

Every scheduler callback except the **job execution callback** runs inside the scheduler process, which continuously has child processes exiting as jobs complete. On BusyBox builds where `sleep` is a NOFORK shell builtin (e.g. with `CONFIG_FEATURE_SH_STANDALONE` enabled), an in-process `sleep` in such a callback can be silently cut short by the `SIGCHLD` of an exiting job.

If a callback needs a reliable delay, force a forked sleep, which is immune to this:

```sh
sleep <seconds> & wait "$!"
```

A side benefit: `wait` is interruptible by trapped signals, so the scheduler stays responsive to `USR1`/`INT`/`TERM` during the delay instead of postponing the handler until a foreground `sleep` finishes.
