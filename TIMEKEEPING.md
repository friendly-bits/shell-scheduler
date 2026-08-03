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

- While waiting for job completions, the scheduler uses a timeout set in whole seconds (rounded up from the remaining time). A timeout is therefore never declared early, but may be declared up to about one second late. The wait is capped by whichever of the global remaining time, the idle remaining time and the nearest per-job deadline comes first, so no deadline is ever slept through.
- All callbacks except the **job execution callback** run synchronously in the scheduler process. While a synchronous callback runs, the scheduler cannot register completions or declare timeouts. So it's best to avoid slow commands in synchronous callbacks. The clock is read once per wake-up, before any callback runs, and remaining time is not recomputed until everything that wake-up brought has been handled - so a wake-up carrying several completions delays timeout detection by the combined duration of their callbacks, not just the longest one.

## Global timeout

The global timeout (`${SCHED_TIMEOUT_S}`) limits the total time the scheduler is allowed to run. It starts when the scheduler begins execution and continues to run regardless of how many jobs are currently executing or waiting to be started.

If the global timeout is reached, the scheduler reports an error, invokes the **scheduler completion callback** (if defined), and exits with return code `82` - unless the callback returns a different code.

| Variable                  | Default | Description                                           |
| ------------------------- | :-----: | ----------------------------------------------------- |
| SCHED_TIMEOUT_S           |  `900`  | Global scheduler timeout in seconds ( integer >= 1 ). |

## Idle timeout

The idle timeout (`${SCHED_IDLE_TIMEOUT_S}`) limits the maximum time the scheduler may go without making progress. The timeout is reset whenever the scheduler starts a job or successfully processes a job completion.

The value it resets to is the moment the scheduler woke up and collected the records, read before any of your callbacks run. So when a single wake-up brings several completions, the time their callbacks spend is charged against the idle budget rather than excused from it.

This timeout is useful for detecting situations where no progress is being made, for example because one or more jobs became stuck.

If the idle timeout is reached, the scheduler reports an error, invokes the **scheduler completion callback** (if defined), and exits with return code `81` - unless the callback returns a different code.

Both timeout values are validated as non-zero unsigned decimal integers; leading zeros are stripped (never interpreted as octal).

| Variable                  | Default | Description                                                                               |
| ------------------------- | :-----: | ----------------------------------------------------------------------------------------- |
| SCHED_IDLE_TIMEOUT_S      |  `300`  | Maximum allowed time, in seconds, without any job starts or completions ( integer >= 1 ). |

## Per-job timeouts

### Motivation

Without per-job timeouts, the scheduler will wait for a single permanently hung job until either the idle or the global scheduler timeout is hit, at which point the scheduler will terminate with an error. Meanwhile the hung job permanently occupies one of the `${SCHED_MAX_JOBS}` concurrency slots. Per-job timeouts convert "one bad job kills the batch" into "one bad job times out, the batch completes", and reclaim the occupied slot.

### Configuration

Global per-job timeouts are set via optional environment variable `${SCHED_JOB_TIMEOUT_S}`.

| Variable              | Default | Description                                                                                                           |
| --------------------- | :-----: | --------------------------------------------------------------------------------------------------------------------- |
| SCHED_JOB_TIMEOUT_S   |  unset  | Default per-job timeout in seconds ( integer >= 1 ). When unset, jobs without an individual timeout have no deadline. |

An individual job's timeout can be set (overriding `${SCHED_JOB_TIMEOUT_S}` for that job) via a dedicated helper:

```sh
job_set_timeout <job_id> <seconds>
```

Timeout value must be integer >= 1. A per-job timeout may exceed `${SCHED_TIMEOUT_S}` but such deadline simply never fires (the global scheduler timeout fires first). When neither `${SCHED_JOB_TIMEOUT_S}` nor an individual timeout is set, the job will be allowed to run indefinitely.

Like per-job parameters, an individual timeout is stored under the namespace selected by `${SCHED_ID}`, and applies only to runs performed with the same `${SCHED_ID}` - see [Scheduler namespace](REFERENCE.md#scheduler-namespace-sched_id).

### Notes

1. **Expiry timing**: Per the [enforcement granularity rules](#how-the-scheduler-measures-time), expiry is never declared early and may be declared up to about one second late - later still if a synchronous callback blocks the scheduler at that moment.
2. **Expiry handling**: when a job-specific timeout occurs, the scheduler stops waiting for the expired job, frees its concurrency slot and classifies it as timed out. When  the **job termination callback** (`JOB_TERM_CB`) is configured, the scheduler then calls it, passing the PID of the job's process. Otherwise no action is taken to kill the lingering job processes. Next, the **job completion callback** (`JOB_DONE_CB`) is called.
3. **Expiry notification**: a timed-out job is reported via a call to `${JOB_DONE_CB}` with job return code `124` and one extra argument:

   ```sh
   ${JOB_DONE_CB} <job_id> 124 <pid>
   ```

   The **presence of the third argument** marks a scheduler-synthesized timeout (vs similar return code received directly from the job). If a job itself genuinely exits with code `124`, this third argument will not be present. The `<pid>` enables application-side cleanup at the moment of expiry.
4. **Completion record arrival wins over expiry.** On each scheduler wake-up, every record received on that wake-up is processed before deadlines are checked.
5. **Job expiries do not count as progress.** The idle timeout is reset when the scheduler starts a job or processes a genuine completion record - never when it processes an expiry.
6. **Late completion records are discarded.** If an abandoned job's completion record arrives after its expiry was processed, the record is silently dropped; the job's classification (timed out, code `124`) stands. The job's PID is removed from the list of `<running_pids>`.
7. **Final accounting.** Timed-out job IDs appear in the dedicated `<expired_job_ids>` list passed to the **scheduler completion callback** - not in `<fail_job_ids>`. Abandoned jobs whose process never reported back before scheduler exit have their PIDs included in `<running_pids>`; abandoned jobs whose late record was discarded do not, and neither do jobs whose kill was verified by the [job termination callback](REFERENCE.md#job-termination-callback---full).

## Reliable delays in callbacks

Every scheduler callback runs inside the scheduler process except the **job execution callback** and the **job termination callback**'s `setup` subcommand, which run in the job's own wrapper process. The scheduler process continuously has child processes exiting as jobs complete. On BusyBox builds where `sleep` is a NOFORK shell builtin (e.g. with `CONFIG_FEATURE_SH_STANDALONE` enabled), an in-process `sleep` in a callback that runs there can be silently cut short by the `SIGCHLD` of an exiting job.

If a callback needs a reliable delay, force a forked sleep, which is immune to this:

```sh
sleep <seconds> & wait "$!"
```

A side benefit: `wait` is interruptible by trapped signals, so the scheduler stays responsive to `USR1`/`INT`/`TERM` during the delay instead of postponing the handler until a foreground `sleep` finishes.
