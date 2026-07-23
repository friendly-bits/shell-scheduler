## Test suite

Consists of tests.sh and the category-specific test files. tests.sh is the launcher/entry point, the other files are categorized libraries of tests.

Categories: `dispatch`, `core`, `scheduler_termination`, `config`, `config_full`, `config_mini`, `params`, `misc`, `outcome`, `timeout`, `job_termination`, `job_termination_full`, `job_termination_mini`, `security`

### Scheduler variants

The suite runs against either scheduler variant, selected by the `SCHEDULER_VARIANT` environment variable: `full` (default, `scheduler.sh`) or `mini` (`scheduler-mini.sh`), e.g. `SCHEDULER_VARIANT=mini sh ./tests.sh run`.

The `config` and `job_termination` categories hold variant-shared tests that run under both. The `*_full` categories hold tests for behavior only present in the full variant (e.g. `SCHED_AUTO_PARAMS` gating; the cgroup / children / ppid helper libraries and the full `JOB_TERM_CB` protocol); the `*_mini` categories hold tests for mini-only behavior (always-on param auto-delivery; the simplified single-argument `JOB_TERM_CB` protocol and the built-in `sched_job_term_mini` mechanism). Tests specific to the non-selected variant report SKIP.

Note: the `security` category consolidates the command-injection / forgery-resistance tests (job-ID and completion-record validation, param value/name and callback-value injection, and internal param-key namespace integrity).

Note: `job_termination` covers the modular job termination feature (`JOB_TERM_CB`) with variant-shared tests driving the selected variant's default mechanism, plus the shared infrastructure the `*_full` / `*_mini` files reuse. The full-variant `job_termination_full` category covers the three optional helper libraries implementing job termination via three different mechanisms: cgroup (`job-term-cgroup.sh`), `/proc` children-walk (`job-term-children.sh`), and `/proc` PPID-walk (`job-term-ppid.sh`). Each mechanism's tests are gated on that mechanism being usable in the current environment, and report SKIP otherwise (counted separately in the summary):

- cgroup tests require root or a delegated cgroup v2 subtree - e.g. run the suite via `systemd-run --user --scope sh ./tests.sh run job_termination`.
- children-walk tests require a kernel built with `CONFIG_PROC_CHILDREN` (which exposes `/proc/<pid>/task/<tid>/children`).

The core-contract tests (and the PPID-walk mechanism, which needs only `/proc` and `awk`) run everywhere.

Note: non-interference between concurrent scheduler instances is covered in two places - `core` verifies two instances sharing one `SCHED_DIR` do not cross-talk or leave residue, and `job_termination_full` verifies a cgroup base collision with a same-PID sibling is avoided (this second one is cgroup-gated as above).

### Testing suite command line options

Usage:

On Busybox ash:
```sh
sh ./tests.sh [options]
```

On Bash:
```bash
bash ./tests.sh [options]
```

Options:
- `[no arguments]` - do nothing (for sourcing the script)
- `run` - run all tests, across all categories
- `run <category>` - run all tests in the given category
- `run <category> <space_separated_list_of_numbers>` - e.g. 'run params 1 3 5'
- `run <category> <test_num_start>-<test_num_end>` - run tests in a range, e.g. 'run scheduler_termination 3-6'
