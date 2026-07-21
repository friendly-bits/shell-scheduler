# shell-scheduler: Job termination libraries

The scheduler does not kill unfinished or expired jobs on its own. Instead it delegates that to a **job termination callback** (`JOB_TERM_CB`), invoked with the subcommands `init`, `setup`, `term`, and `cleanup` at defined points of a run.

The full callback contract - when each subcommand is called, with which arguments, and how verified kills are reported back - is specified in [REFERENCE.md](REFERENCE.md#job-termination-callback-details).

This document explains, in depth, the three callback implementations bundled with the project. For a short overview and the one-line "how do I switch it on" usage, see [REFERENCE.md](REFERENCE.md#job-termination-helper-libraries); if you are just getting started, read the [README](README.md) first.

## Contents

- [Implementations comparison](#implementations-comparison)
- [Job termination callback subcommands](#job-termination-callback-subcommands)
- [`scheduler-job-term-ppid.sh` - the /proc PPID-walk library](#scheduler-job-term-ppidsh---the-proc-ppid-walk-library)
  - [Mechanism](#mechanism)
  - [Subcommand behavior](#subcommand-behavior)
  - [Guarantees and limitations](#guarantees-and-limitations)
  - [Probing availability: `proc_ppid_supported`](#probing-availability-proc_ppid_supported)
- [`scheduler-job-term-children.sh` - the /proc children-walk library](#scheduler-job-term-childrensh---the-proc-children-walk-library)
  - [Probing availability: `proc_children_supported`](#probing-availability-proc_children_supported)
- [`scheduler-job-term-cgroup.sh` - the cgroup v2 library](#scheduler-job-term-cgroupsh---the-cgroup-v2-library)
  - [Mechanism](#mechanism-1)
  - [Subcommand behavior](#subcommand-behavior-1)
  - [Requirements](#requirements)
  - [When the scheduler can manage cgroups](#when-the-scheduler-can-manage-cgroups)
  - [Running from cron](#running-from-cron)
  - [Background: cgroup delegation](#background-cgroup-delegation)
  - [`SCHED_CGROUP_BASE`](#sched_cgroup_base)
  - [Probing availability: `cgroup_cleanup_supported`](#probing-availability-cgroup_cleanup_supported)
- [Selecting job termination mechanism at runtime](#selecting-job-termination-mechanism-at-runtime)

## Implementations comparison

The three libraries implement the same callback contract and terminate a job's whole process tree, but the mechanism differs. Two are `/proc`-based and share everything except how they discover a job's descendants; the third uses cgroup v2:

| Aspect                                       | `/proc` PPID-walk (`…-ppid.sh`)            | `/proc` children-walk (`…-children.sh`)          | `cgroup` v2 (`…-cgroup.sh`)                                             |
| -------------------------------------------- | ------------------------------------------ | ------------------------------------------------ | ---------------------------------------------------------------------- |
| Requirements                                 | `/proc` + `awk` only                       | `/proc` + `awk` + kernel `CONFIG_PROC_CHILDREN`  | cgroup v2 + `cgroup.kill` (kernel >= 5.14) + writable cgroup           |
| Finds processes reparented to init (orphans) | No                                         | No                                               | Yes                                                                    |
| Process kill verification                    | None                                       | None                                             | Kernel-verified                                                        |
| `<running_pids>` reported at cleanup         | May list PIDs whose trees are already dead | May list PIDs whose trees are already dead       | Only lists PIDs under fault conditions when process termination failed |
| Side effects on the tree                     | Brief `SIGSTOP` before the kill            | Brief `SIGSTOP` before the kill                  | None                                                                   |
| Performs per-run setup and teardown          | No                                         | No                                               | Yes                                                                    |

Rule of thumb: prefer the `cgroup`-based mechanism wherever its requirements are met (see [When the scheduler can manage cgroups](#when-the-scheduler-can-manage-cgroups)); otherwise fall back to `/proc`-based children-walk (more efficient requires `CONFIG_PROC_CHILDREN` kernel option enabled); otherwise fall back to `/proc`-based PPID-walk which needs only `/proc` and `awk`.

Use the helper `sched_job_term_select` to pick the best available mechanism automatically see [Selecting job termination mechanism at runtime](#selecting-job-termination-mechanism-at-runtime).

## Job termination callback subcommands

The scheduler calls the **job termination callback** with a specific **subcommand** at each invocation point:

| When (invocation point)                                                | Purpose                                 | Subcommand |Arguments                            |
| -----------------------------------------------------------------------| --------------------------------------  | ---------- |---------------------                |
| **Scheduler startup**, before any job is dispatched                    | Initialize termination mechanism        | `init`     |None                                 |
| **Inside each job's process**, before invoking job execution callback  | Make job-specific arrangements          | `setup`    | `<job_id> <pid>`                    |
| **Per-job timeout expiry**                                             | Kill process tree                       | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 1**, before invoking scheduler completion callback | Kill any still-running jobs + processes  | `term`     | `<verified_kills_out_var> <pid>...` |
| **Scheduler exit - 2**, before invoking scheduler completion callback | Tear down the job termination mechanism  | `cleanup`  | `<verified_kills_out_var>`          |

The below table shows the **action** taken by the helper libraries in response to each subcommand. The two `/proc`-based libraries (PPID-walk and children-walk) behave identically here; they differ only in how `term` discovers descendants.

| Subcommand | `/proc`-based libraries        | `cgroup`-based library                               |
| ---------- | ------------------------------ | ---------------------------------------------------- |
| `init`     | None                           | Create base cgroup                                   |
| `setup`    | None                           | Join per-job cgroup                                  |
| `term`     | Discover, kill job's processes | Kill specified job's process tree                    |
| `cleanup`  | None                           | Kill all remaining job process trees; remove cgroups |

## PPID-walk library (scheduler-job-term-ppid.sh)

Kills each job's process tree by reconstructing it from the kernel's `/proc` data. Only `/proc` and `awk` are required, which makes it the universal fallback - it works on essentially any Linux.

Usage: source the file after `scheduler.sh`, then set `JOB_TERM_CB=sched_job_term_ppid`; call `proc_ppid_supported` first to probe availability.

### Mechanism

Given a set of **seed** PIDs (the job wrapper PIDs handed to `term`), the library terminates each seed's entire live descendant tree in three phases:

1. **Discover.** The library reads the parent-PID field of every `/proc/<pid>/stat` to build a process-to-parent map, parsed with `awk`, then walks it outward from the seeds to a fixpoint: any process whose parent is already in the set joins it. Because it keys on the parent PID, a child is found no matter which thread of the parent forked it.

2. **Freeze and re-scan to a fixpoint.** Discovery and signal delivery cannot be atomic: a process can fork in the gap between being discovered and being stopped. To close that race, the library iterates - up to three passes:
   - `SIGSTOP` every currently-known process (seeds plus everything discovered so far). Stopping a process pins down the children the previous scan already saw so they cannot fork further.
   - Re-scan descendants. Anything forked in between is now caught and, on the next pass, itself stopped.
   - If a pass discovers nothing new, the tree has reached a fixpoint and the loop stops early.

3. **Kill.** `SIGKILL` is delivered to the whole frozen set. `SIGKILL` acts on stopped tasks, so there is no need to `SIGCONT` them first.

### Subcommand behavior

- `init`, `setup`, `cleanup` - no-ops (return success). This mechanism needs no per-run or per-job setup and holds no state between calls.
- `term <verified_kills_out_var> <pid>...` - performs the discover/freeze/kill described above for the given seed PIDs. Invalid (non-numeric) PIDs are reported and skipped. It always assigns an **empty** list to `<verified_kills_out_var>`: this mechanism cannot verify that a tree is actually gone, so it reports no verified kills.

### Guarantees and limitations

- **Orphans escape.** Only trees rooted at a still-live job process can be reconstructed. If a job's child exits and its own children are reparented to init (PID 1), those grandchildren are no longer reachable from the seed and will not be discovered or killed. This is the fundamental limitation the cgroup library does not share.
- **Kills are not verified.** Because the library reports no verified kills, the `<running_pids>` list passed to the **scheduler completion callback** (`SCHED_FINALIZE_CB`) will still contain the PIDs of expired and unfinished jobs, even though every process in their trees may already have been terminated. Treat that list as "jobs that did not complete on their own," not as "processes still alive."
- **The tree is briefly stopped.** The freeze phase delivers `SIGSTOP` to the tree before the kill. A process that installs a `SIGCONT` handler could observe this, though the window is short and the processes are killed immediately after.

### Probing availability

The helper `proc_ppid_supported`, defined by this library, returns `0` if `awk` is available and `/proc/<pid>/stat` is readable, and `1` otherwise. It emits no messages.

## Children-walk library (scheduler-job-term-children.sh)

Identical to the [PPID-walk library](#scheduler-job-term-ppidsh---the-proc-ppid-walk-library) - the same three-phase discover/freeze/kill mechanism, the same subcommand behavior, and the same guarantees and limitations - except in the discovery step: it reads each process's `/proc/<pid>/task/<tid>/children` files (iterating over *all* threads, so children forked by a non-leader thread are still found) instead of scanning parent-PID fields. Those `children` files exist only on a kernel built with `CONFIG_PROC_CHILDREN`, which is absent on some stripped kernels (e.g. typical OpenWrt builds). Reading the per-process `children` lists is more efficient than scanning every `/proc/<pid>/stat`, so prefer this mechanism over PPID-walk where the kernel option is present.

Usage: source the file after `scheduler.sh`, then set `JOB_TERM_CB=sched_job_term_children`.

### Probing availability

The helper `proc_children_supported`, defined by this library, returns `0` if the mechanism can work here - `awk` is available and the kernel exposes the `/proc/<pid>/task/<tid>/children` files - and `1` otherwise. It emits no messages.

## cgroup v2 library (scheduler-job-term-cgroup.sh)

This is the most efficient job termination mechanism but it comes with extra dependencies.

Places each job in its own **cgroup v2** and kills the whole group atomically with the kernel's `cgroup.kill`. Because cgroup membership is inherited by every descendant and outlives the process that created it, this reaches background children and orphaned grandchildren alike - things the `/proc` walk cannot see. Kills are kernel-verified, at the cost of the requirements listed below.

Usage: source the file after `scheduler.sh`, then set `JOB_TERM_CB=sched_job_term_cgroup`.

### Mechanism

A run uses a two-level cgroup layout under a writable location in the cgroup v2 hierarchy:

- A **per-run base cgroup** named `sched_<pid>`, created in response to the `init` subcommand, holds the whole batch.
- A **per-job cgroup** named `job_<pid>` under the base. Each job process joins its own cgroup in response to the `setup` subcommand; every process the job later spawns inherits that membership automatically, no matter how it forks or daemonizes.

Killing a job is then a single write to its cgroup's `cgroup.kill`, which the kernel delivers to *every* member. The kill is confirmed by `rmdir` on the cgroup directory: the kernel lets a cgroup be removed only once it is empty and all its processes have been fully reaped. A successful `rmdir` is therefore proof that the job's entire tree is gone, which is what lets the library report kernel-verified kills.

### Subcommand behavior

- `init` - locate the cgroup v2 mount (from `/proc/mounts`), choose and create the base cgroup, confirm `cgroup.kill` exists (kernel >= 5.14), and validate the whole mechanism by moving a throwaway probe process into a child cgroup. Any failure here fails the run upfront.
- `setup <job_id> <pid>` - runs *inside the job process*. It creates the job's `job_<pid>` cgroup and writes `0` to its `cgroup.procs`, which moves the writing process (the job) into it; descendants inherit the membership.
- `term <verified_kills_out_var> <pid>...` - for each job PID, write `1` to its `cgroup.kill`, then attempt to `rmdir` the cgroup. Successful `rmdir` confirms all member processes killed. PIDs of successfully terminated jobs are reported to the caller via `<verified_kills_out_var>`. Cgroups whose removal the kernel has not yet confirmed are parked and retried (on the next `term`, and finally at `cleanup`). Removals still pending from earlier `term` calls are retried first.
- `cleanup <verified_kills_out_var>` - sweep **all** remaining `job_*` cgroups, including those of jobs that completed but left background processes behind, and kill them; this is what guarantees nothing a job spawned survives the run. Pending removals are retried with a bounded wait (three passes, one second apart), then the base cgroup itself is removed. A removal that still fails is reported via the **scheduler error reporting callback** (`SCHED_FAIL_MSG_CB`). PIDs of successfully terminated jobs are reported via `<verified_kills_out_var>`.

The net guarantee: expired jobs die at their timeout, the scheduler's own exit tears down everything, and **nothing a job spawned survives the run** - even a double-forked daemon stays in its job's cgroup and is killed with it. Under normal operation the `<running_pids>` reported to the **scheduler completion callback** is empty, even when jobs timed out or the scheduler exited early.

### Requirements

Validated by the `init` subcommand, which fails the run upfront when unmet:

- cgroup v2 mounted (checked via `/proc/mounts`)
- `cgroup.kill` support (kernel >= 5.14)
- Write access to a cgroup directory, so the scheduler can create the per-run and per-job cgroups and move processes into them.

### When the scheduler can manage cgroups

The mechanism is usable in each of the situations below, none of which needs any pre-configuration. If none of them fits your environment - or arranging one is inconvenient - use a `/proc`-based library instead: `scheduler-job-term-ppid.sh` (needs only `/proc` and `awk`) works anywhere, or the more efficient `scheduler-job-term-children.sh` where the kernel provides `CONFIG_PROC_CHILDREN`. `sched_job_term_select` can automatically pick among available job termination mechanisms from whichever libraries you sourced.

- **Running as root**: works everywhere (provided the kernel supports cgroup v2 and `cgroup.kill`): in a root shell, in a system service, in a system cron job, or on an OpenWrt device (23.05 and later ships the required kernel; cgroup support is enabled in default builds except `SMALL_FLASH` targets).
- **Unprivileged, started by systemd's per-user manager**: root is not needed when the scheduler is launched *by* the systemd **user** manager - either as a systemd user service, or wrapped in `systemd-run --user --scope <cmd>`. Running it straight from an ordinary shell (interactive or SSH login) or a cron job does **not** qualify, even though you own them; prefix such commands with `systemd-run --user --scope`.
- **Inside a container (Docker, Podman, ...)**: the container process is normally root within the container's own cgroup namespace, so the *Running as root* case applies - but only when the container's cgroup filesystem is mounted **writable**. Docker mounts `/sys/fs/cgroup` read-only by default, so the `init` subcommand fails in a plain `docker run`; start the container with `--privileged` (or under user-namespace remapping) to make it writable. Podman mounts it writable by default when the container uses a private cgroup namespace.

### Running from cron

All requirements listed above apply, and in addition: a cron job does not run inside the systemd per-user manager's cgroup, so the unprivileged-with-systemd case above does not apply on its own.

- **As root** (a system crontab, or busybox `crond` on OpenWrt): nothing extra is required.
- **As an unprivileged user** (a user crontab): wrap the command so the systemd user manager runs it, and keep that manager alive across logouts with `loginctl enable-linger <user>` (run once). Setting `XDG_RUNTIME_DIR` lets `systemd-run --user` reach the manager:

```
* * * * * XDG_RUNTIME_DIR=/run/user/$(id -u) systemd-run --user --scope /path/to/run-scheduler.sh
```

The bundled `cron-cgtest.sh` is a ready-to-run example covering both cases.

### Probing availability: `cgroup_cleanup_supported`

To decide up front whether the cgroup mechanism will work - and fall back to another mechanism if not - call `cgroup_cleanup_supported`, defined by this library. It runs exactly the same validation as `init` (cgroup v2 mount, `cgroup.kill` support, base cgroup creation, and a probe process self-migration), cleans up after itself, emits no messages, honors `${SCHED_CGROUP_BASE}`, and returns `0` (supported) or `1` (not supported).

## Selecting job termination mechanism at runtime

The scheduler core provides `sched_job_term_select`, which picks the best mechanism among whichever helper libraries are currently sourced. It probes each in the fallback order **cgroup -> `/proc` children-walk -> `/proc` PPID-walk**, assigns the chosen callback name to the variable you name, and returns non-zero (clearing that variable) if none is available:

```sh
. ./scheduler.sh
. ./scheduler-job-term-ppid.sh
. ./scheduler-job-term-children.sh
. ./scheduler-job-term-cgroup.sh

sched_job_term_select JOB_TERM_CB   # cgroup, else children, else ppid
schedule_jobs "${IDS}" &
```

Only sourced libraries are considered, so include just the mechanisms you want to allow; a candidate is skipped unless its capability probe reports the mechanism usable here. The core assumes nothing about which libraries exist. To select manually instead, call the probes directly - `cgroup_cleanup_supported`, `proc_children_supported`, `proc_ppid_supported` - and set `JOB_TERM_CB` yourself.

### Background: cgroup delegation

"Write access to a cgroup" is what the kernel calls *delegation*. Per the [cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html), a cgroup subtree is delegated to a user by granting write access to its directory and its `cgroup.procs` / `cgroup.subtree_control` files; the user may then create sub-cgroups and move processes between them - exactly what this library does.

The systemd per-user manager (`user@<uid>.service`) runs with `Delegate=yes`, so everything it starts sits inside a delegated subtree. A login `session-N.scope` (created by the *system* manager) and a cron job are not, which is why they need the `systemd-run --user --scope` wrapper. In a container the delegated subtree is the container's own cgroup namespace root, usable only when the runtime mounts that filesystem read-write.

The kernel's *delegation containment* rule additionally forbids moving processes across a delegation boundary, but the first obstacle an unprivileged caller hits is simply not being allowed to create its base cgroup. For a **system** service that runs unprivileged via `User=`, add `Delegate=yes` to the unit to delegate its own cgroup.

### `SCHED_CGROUP_BASE`

By default `init` picks the base cgroup's parent by autodetection, trying in order:

1. the scheduler's own cgroup (the `0::<path>` entry in `/proc/self/cgroup`) - writable when running as root, or unprivileged inside a delegated subtree;
2. the cgroup2 mount root - writable when running as root.

Setting `${SCHED_CGROUP_BASE}` to a writable cgroup2 directory replaces this autodetection entirely, and the per-run base is created directly under it (trailing `/` characters are ignored). This is mainly for testing, but it is also the hook for unusual setups - a pre-configured subtree carrying resource limits, or an exotic container mount. It is read only by this library, not by the scheduler core.

