## Test suite

### Instructions
- tests.sh run <category> takes no number (whole category), a list of numbers, or a range: run params 34-38.
- Category files are large (tests-params.sh ~1700 lines). To append a test, grep for the highest test_<category>_NN and read one neighbouring test for the house pattern — don't read the file end to end.
- When you need to run a certain test, run it as `bash tests/tests.sh run <category> <test_num>` (or `busybox ash tests.sh ...`).
- When writing tests, check which shared helpers are defined in tests/tests.sh (see its commented header) and use them where relevant. When adding a new shared helper, update the list of shared helpers in that commented header.
- Every test runs `schedule_jobs &`; the only foreground call sites are the TTY-gated SIGINT sub-cases of scheduler_termination 07/09. Since the scheduler replaces the caller's EXIT trap, anything sharing a process with a foreground run cannot use its own EXIT trap for cleanup - those two hand the killer pid out through a file and reap it after the subshell exits.
- When adding tests, give every test its own unique job ID unless the test specifically needs shared/repeated IDs (e.g. an isolation test comparing two IDs). Job-registered params persist for a job ID across the whole test run (no teardown), so reused IDs silently accumulate state from other tests.
- Put a new test helper in the category file when only that category uses it; put it in tests.sh only when tests in more than one category call it.
- Tests must observe behavior only through public interfaces - return codes of `schedule_jobs`/`jobs_init`/helpers, callback outputs, `job_get_params` results, and `SCHED_FAIL_MSG_CB` messages. Never read or assert on internal `SCH_*`/`sch_*` variables; internal names and mechanisms may change.
- An ad-hoc script that sources tests.sh must live in tests/ and take no positional arguments — tests.sh resolves its sibling/parent sources from $0 and parses "$@" at source time.
- Glob-safety tests must use a *live* glob: one that matches a file guaranteed to exist (create a sentinel in a controlled dir the code runs in — e.g. `( cd "$WORK" && ... schedule_jobs 'zzsentinel*' )` with `$WORK/zzsentinelJOB` present). Make the sentinel's filename a valid job ID so expansion would produce a dispatchable id (a clean rejected-vs-dispatched signal). A non-matching glob (e.g. `*.txt` in a dir with no `.txt` files) stays literal whether or not it was expanded.
- When writing a new test, prefer passing values to helpers called by the test via arguments rather than via global variables.

### Verified facts
- tests.sh auto-discovers tests by scanning each `tests-<category>.sh` for `test_<category>_NN()` functions (NN two digits), so a new test only needs a correctly-named function. `do_job_default` selects a job's behavior from its ID prefix (text before the first `_`): e.g. `instant`=sleep 0, `ok`/`ok1`=1s, `ok2`=2s, `ok5`=5s, `hang`=30s, `fail`=1s then return 17 (also `crash`, `malformed`); name jobs accordingly to reuse it as `DO_JOB_CB`.
- A test function returns 0=pass, 1=fail, 2=skip; the runner counts anything else as a fail. A helper failure that only prints to stderr and falls through will still report PASS.
- schedule_jobs()'s capacity-wait while loop only calls process_done_record() until running_jobs_cnt drops below SCHED_MAX_JOBS — it drains exactly one completion, not all pending ones. A second already-finished job can stay unread in the FIFO. To get multiple jobs fully classified (OK/FAIL) before a later timeout/abort, use SCHED_MAX_JOBS=1 for strict sequential dispatch instead of relying on this loop to drain everything.

### Test categories

Consists of tests.sh and the category-specific test files. tests.sh is the launcher/entry point, the other files are categorized libraries of tests.

Categories: `dispatch`, `core`, `scheduler_termination`, `sched_env`, `params`, `params_full`, `params_mini`, `misc`, `outcome`, `timeout`, `abort`, `job_termination`, `job_termination_full`, `job_termination_mini`, `security`

Note: `sched_env` covers the scheduler's own environment configuration - `SCHED_*` and `*_CB` variables: which values are accepted or rejected, defaults, and empty/unset fallback. Behavior of per-job parameters belongs in the `params` categories even when a `SCHED_*` variable selects it (`SCHED_AUTO_PARAMS` gating is a `params_full` test, not a `sched_env` one).

Note: `abort` covers `jobs_abort()` - which jobs it acts on, how they are classified, and how an abort interacts with dispatch capacity, per-job deadlines and late completion records. Its caller-process guard (rejecting calls from `DO_JOB_CB`, `SCHED_FINALIZE_CB`, `SCHED_FAIL_MSG_CB` or outside a run) is a `security` test, and the membership rules of the `SCHED_FINALIZE_CB` ID sets remain an `outcome` concern even when one of those sets is the aborted set. Unlike `params` and `job_termination`, `abort` has no separate `*_full` / `*_mini` files: its two variant-specific tests (whether an aborted-and-killed PID appears in `SCHED_FINALIZE_CB`'s running-PIDs argument, which differs between the variants) live in `tests-abort.sh` behind `require_variant` and report SKIP on the other variant.

### Scheduler variants

The suite runs against either scheduler variant, selected by the `SCHEDULER_VARIANT` environment variable: `full` (default, `scheduler.sh`) or `mini` (`scheduler-mini.sh`), e.g. `SCHEDULER_VARIANT=mini sh ./tests.sh run`.

The `params` and `job_termination` categories hold variant-shared tests that run under both. The `*_full` categories hold tests for behavior only present in the full variant (e.g. `SCHED_AUTO_PARAMS` gating; the cgroup / children / ppid mechanisms of the helper library and the full `JOB_TERM_CB` protocol); the `*_mini` categories hold tests for mini-only behavior (always-on param auto-delivery; the simplified single-argument `JOB_TERM_CB` protocol and the built-in `sched_job_term_mini` mechanism). Tests specific to the non-selected variant report SKIP.

Note: the `security` category consolidates the command-injection / forgery-resistance tests (job-ID and completion-record validation, param value/name and callback-value injection, and internal param-key namespace integrity).

Note: `job_termination` covers the modular job termination feature (`JOB_TERM_CB`) with variant-shared tests driving the selected variant's default mechanism, plus the shared infrastructure the `*_full` / `*_mini` files reuse. The full-variant `job_termination_full` category covers the optional helper library `job-term.sh`, which implements job termination via three different mechanisms: cgroup, `/proc` children-walk, and `/proc` PPID-walk. Each mechanism's tests are gated on that mechanism being usable in the current environment, and report SKIP otherwise (counted separately in the summary):

- cgroup tests require root or a delegated cgroup v2 subtree - e.g. run the suite via `systemd-run --user --scope sh ./tests.sh run job_termination`.
- children-walk tests require a kernel built with `CONFIG_PROC_CHILDREN` (which exposes `/proc/<pid>/task/<tid>/children`).

The core-contract tests (and the PPID-walk mechanism, which needs only `/proc` and `awk`) run everywhere.

Note: non-interference between concurrent scheduler instances is covered in two places - `core` verifies two instances sharing one `SCHED_DIR` do not cross-talk or leave residue, and `job_termination_full` verifies a cgroup base collision with a same-PID sibling is avoided (this second one is cgroup-gated as above).

### Shared test helpers

- Category-specific shared helpers live in that category's script.
- Cross-category shared helpers live in tests/tests.sh

Update the list below when changing, adding or removing cross-category shared helpers.

Shared helpers in tests.sh: PASS/FAIL/SKIP, require_variant, print_test_header, `read_first_line [--rm] <out_var> <file>` (`--rm` consumes the file), is_uint, mk_name_of_len, done_handler, finalize_handler, do_job_default, verify_recorded_set, write_id_sets, NL, and for delayed signals `start_bg_killer <out_var> <pid> <secs> [sig]` (signal defaults to 9) / `stop_bg_killer <pid>`.

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
