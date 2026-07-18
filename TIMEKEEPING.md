# shell-scheduler: Time-keeping and Timeouts

How the scheduler measures time, the timeout mechanisms it implements, and how to perform reliable delays in callbacks. General library documentation lives in [REFERENCE.md](REFERENCE.md); if you're just getting started, read the [README](README.md) first.

## Contents

- [How the scheduler measures time](#how-the-scheduler-measures-time)
- [Global timeout](#global-timeout)
- [Idle timeout](#idle-timeout)
- [Per-job timeouts](#per-job-timeouts)
- [Reliable delays in callbacks](#reliable-delays-in-callbacks)

## How the scheduler measures time

The scheduler reads elapsed time from `/proc/uptime` with centisecond (0.01 s) resolution and performs all internal accounting in centiseconds. Because uptime is monotonic, time-keeping is immune to wall-clock changes (NTP corrections, timezone changes, manual `date` calls).

Timeout *enforcement* is coarser than the accounting resolution:

- While waiting for job completions, the scheduler sleeps in `read -t` with a timeout in whole seconds (rounded up from the remaining time). A timeout is therefore never declared early, but may be declared up to about one second late.
- All callbacks except the **job execution callback** run synchronously in the scheduler process. While such a callback runs, the scheduler cannot register completions or declare timeouts - see the note in [Callbacks](REFERENCE.md#callbacks). Keep synchronous callbacks fast. Remaining time is recomputed from a fresh clock reading after each callback returns, so a slow callback delays timeout detection by at most its own duration.

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

Without per-job timeouts, the scheduler will wait for a single permanently hung job until either the idle or the global scheduler timeout is hit, at which point the scheduler will terminate with an error. Meanwhile the hung job permanently occupies one of the `${SCHED_MAX_JOBS}` concurrency slots. Per-job timeouts convert "one bad job kills the batch" into "one bad job times out, the batch completes", and reclaim the occupied slot.

### Configuration

Global per-job timeouts are set via optional environment variable `${SCHED_JOB_TIMEOUT_S}`.

| Variable              | Required | Default | Description                                                                                                 |
| --------------------- | :------: | :-----: | ----------------------------------------------------------------------------------------------------------- |
| SCHED_JOB_TIMEOUT_S   |          |  unset  | Default per-job timeout in seconds ( integer >= 1 ). When unset, jobs without an individual timeout have no deadline. |

An individual job's timeout can be set (overriding `${SCHED_JOB_TIMEOUT_S}` for that job) via a dedicated helper:

```sh
job_set_timeout <job_id> <seconds>
```

Timeout value must be integer >= 1. A per-job timeout may exceed `${SCHED_TIMEOUT_S}` but such deadline simply never fires (the global scheduler timeout fires first). When neither `${SCHED_JOB_TIMEOUT_S}` nor an individual timeout is set, the job will be allowed to run indefinitely.

### Notes

1. **Expiry timing**: Per the [enforcement granularity rules](#how-the-scheduler-measures-time), expiry is never declared early and may be declared up to about one second late - later still if a synchronous callback blocks the scheduler at that moment.
2. **Expiry handling**: when a job-specific timeout occurs, the scheduler stops waiting for the expired job, frees its concurrency slot and classifies it as timed out. When  the **job termination callback** (`JOB_TERM_CB`) is configured, the scheduler then calls it, passing the PID of the job's process. Otherwise no action is taken to kill the lingering job processes. Next, the **job completion callback** (`JOB_DONE_CB`) is called.
3. **Expiry notification**: a timed-out job is reported via a call to `${JOB_DONE_CB}` with job return code `124` and one extra argument:

   ```sh
   ${JOB_DONE_CB} <job_id> 124 <pid>
   ```

   The **presence of the third argument** marks a scheduler-synthesized timeout (vs similar return code received directly from the job). If a job itself genuinely exits with code `124`, this third argument will not be present. The `<pid>` enables application-side cleanup at the moment of expiry.
4. **Completion record arrival wins over expiry.** On each scheduler wake-up, a received completion record is processed before deadlines are checked.
5. **Job expiries do not count as progress.** The idle timeout is reset when the scheduler starts a job or processes a genuine completion record - never when it processes an expiry.
6. **Late completion records are discarded.** If an abandoned job's completion record arrives after its expiry was processed, the record is silently dropped; the job's classification (timed out, code `124`) stands. The job's PID is removed from the list of `<running_pids>`.
7. **Final accounting.** Timed-out job IDs appear in the dedicated `<expired_job_ids>` list passed to the **scheduler termination callback** - not in `<fail_job_ids>`, which is reserved for jobs that exited with a non-zero code. Abandoned jobs whose process never reported back before scheduler exit have their PIDs included in `<running_pids>`; abandoned jobs whose late record was discarded do not, and neither do jobs whose kill was verified by the [job termination callback](REFERENCE.md#job-termination-callback-details).

### Implementation notes (internal)

- Deadlines are tracked in the scheduler process only.
- Deadline entries are encoded as `<pid>:<deadline_cs>:<job_id>`. The first two fields are unsigned integers and job IDs contain neither `:` nor whitespace, so the job ID is parsed unambiguously as the trailing remainder.
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
