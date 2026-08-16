## Test suite

### Instructions
- `tests.sh run <category>` takes either: no number (whole category), a list of numbers, or a range: `run params 34-38`.
- Category files are large (tests-params.sh ~1700 lines). To append a test, grep for the highest test_<category>_NN and read one neighbouring test for the house pattern — don't read the file end to end.
- A test's description comment sits *above* its function definition, so tracking the last-seen `test_<category>_NN()` header while grepping misattributes hits that fall in the next test's leading comment. Confirm the enclosing function before editing.
- When you need to run a certain test, run it as `bash tests/tests.sh run <category> <test_num>` (or `busybox ash tests.sh ...`).
- When writing tests, check which shared helpers are defined in tests/tests.sh (see its commented header) and use them where relevant. When adding a new shared helper, update the list of shared helpers in that commented header.
- Every test runs `schedule_jobs &`; the only foreground call sites are the TTY-gated SIGINT sub-cases of scheduler_termination 07/09. A run replaces the caller's EXIT trap and does not restore it, so anything sharing a process with a foreground run cannot use its own EXIT trap for cleanup - those two hand the killer pid out through a file and reap it after the subshell exits.
- When adding tests, give every test its own unique job ID unless the test specifically needs shared/repeated IDs (e.g. an isolation test comparing two IDs). Job-registered params and per-job timeouts persist for a job ID until `jobs_init` clears them, so reused IDs silently accumulate state from other tests.
- Put a new test helper in the category file when only that category uses it; put it in tests.sh only when tests in more than one category call it.
- Tests must observe behavior only through public interfaces - return codes of `schedule_jobs`/`jobs_init`/helpers, callback outputs, `job_get_params` results, and `SCHED_FAIL_MSG_CB` messages. Never read or assert on internal `SCH_*`/`sch_*` variables; internal names and mechanisms may change.
- Jobs are trusted, so guards exist to catch mistakes rather than attacks. Do not write tests pinning forgery or privilege-escalation scenarios.
- An ad-hoc script that sources tests.sh must live in tests/ and take no positional arguments — tests.sh resolves its sibling/parent sources from $0 and parses "$@" at source time.
- Glob-safety tests must use a *live* glob: one that matches a file guaranteed to exist (create a sentinel in a controlled dir the code runs in — e.g. `( cd "$WORK" && ... schedule_jobs 'zzsentinel*' )` with `$WORK/zzsentinelJOB` present). Make the sentinel's filename a valid job ID so expansion would produce a dispatchable id (a clean rejected-vs-dispatched signal). A non-matching glob (e.g. `*.txt` in a dir with no `.txt` files) stays literal whether or not it was expanded.
- When writing a new test, prefer passing values to helpers called by the test via arguments rather than via global variables.
- A test's outcome must start as failure and only become success once every check has passed: declare `checks_pass=0 checks_exp=<number of checks>`, write each check as `<success condition> && checks_pass=$((checks_pass + 1)) || <failure message>` (`if`/`else` when the failure branch has side effects), and gate the verdict on `[ "${checks_pass}" = "${checks_exp}" ]`. Adding a check means bumping `checks_exp`; forgetting to fails the test, which is the safe direction.
- Checks that run a variable number of times (inside a loop, or in a helper called once per sub-case) get their own counter compared against the iteration count, and that comparison is the single check counted in `checks_exp` - a later passing iteration must not be able to mask an earlier failing one.
- When every sub-case of a test is skipped, report SKIP and `return 2` rather than passing vacuously.
- `tests.sh` sources the scheduler by hardcoded filename, so the suite cannot be pointed at a copy. Mutation testing therefore has to edit the real `scheduler.sh` in place: never run it concurrently with any other test run (including other agents'), restore from a pristine copy afterwards, and verify the restore.

### Verified facts

These are facts about the suite. Keep them to suite behavior and to the minimum scheduler behavior a test author has to know - scheduler design rationale is documented separately and should not be restated here.

- tests.sh auto-discovers tests by scanning each `tests-<category>.sh` for `test_<category>_NN()` functions (NN two digits), so a new test only needs a correctly-named function. `do_job_default` selects a job's behavior from its ID prefix (text before the first `_`): e.g. `instant`=sleep 0, `ok`/`ok1`=1s, `ok2`=2s, `ok5`=5s, `hang`=30s, `fail`=1s then return 17 (also `crash`, `malformed`); name jobs accordingly to reuse it as `DO_JOB_CB`.
- A test function returns 0=pass, 1=fail, 2=skip; the runner counts anything else as a fail. A helper failure that only prints to stderr and falls through will still report PASS.
- `DEFAULT_IFS` starts with a tab, so `"$*"` in a callback joins its arguments with tabs, not spaces. A helper that must produce a space-joined line needs `local IFS=' '`.
- `get_test_pid` inside a job yields the same PID the scheduler tracks in running_pids and passes to `JOB_TERM_CB` as a seed, because the job execution callback runs in the job's own wrapper process - but only while `${SCHED_INNER_SUBSHELL}` is unset, since that option runs the callback one process below the wrapper. A job that needs the tracked PID must call `get_job_wrapper_pid`, which resolves it under either setting.
- `${SCHED_INNER_SUBSHELL}` runs the job execution callback in a subshell with fd 3 closed, so a job cannot write a completion record and cannot affect the wrapper process. Tests whose job callback writes on fd 3 pin `SCHED_INNER_SUBSHELL=` in the run's environment; `JOB_DONE_CB` and `SCHED_DISPATCH_TICK_CB` are unaffected either way, since they run in the scheduler's process.
- A test that needs to observe a late completion record must keep a separate, longer-running job alive: an aborted or expired job releases its slot at once, so the run can finish and exit before that job's own record arrives.
- Variant-specific tests are gated with `require_variant full|mini || return 2`, placed just above `print_test_header`; the runner reports them as SKIP on the other variant.
- A completion record is only acted on once capacity is full or nothing is left to dispatch. The variants reach that point differently - full reads the FIFO on every pass and queues what it finds, mini does not read it until no slot can be filled - but the observable timing is the same. For tests this means a job is not classified (OK/FAIL) the instant its record arrives; note that `JOB_DONE_CB` *does* fire while other jobs are still pending whenever the slots are full, so do not write a test assuming otherwise. To have jobs fully classified before a later timeout/abort, use SCHED_MAX_JOBS=1 for strict sequential dispatch: each dispatch fills the only slot, so the next iteration classifies before dispatching again.
- tests.sh resolves the library paths from `$0`, which a wrapper script breaks. Set `SCRIPT_DIR` to the tests directory to override that lookup: run with no arguments it only defines things, so a wrapper can source it and exercise individual helpers in isolation.

### Test categories

Consists of tests.sh and the category-specific test files. tests.sh is the launcher/entry point, the other files are categorized libraries of tests.

Categories: `dispatch`, `core`, `scheduler_termination`, `sched_env`, `params`, `params_full`, `params_mini`, `misc`, `outcome`, `timeout`, `abort`, `job_termination`, `job_termination_full`, `job_termination_mini`, `security`

Note: `sched_env` covers the scheduler's own environment configuration - `SCHED_*` and `*_CB` variables: which values are accepted or rejected, defaults, and empty/unset fallback. Behavior of per-job parameters belongs in the `params` categories even when a `SCHED_*` variable selects it (`SCHED_AUTO_PARAMS` gating is a `params_full` test, not a `sched_env` one).

Note: `abort` covers `jobs_abort()` - which jobs it acts on, how they are classified, and how an abort interacts with dispatch capacity, per-job deadlines and late completion records. Its caller-process guard (rejecting calls from `DO_JOB_CB`, `SCHED_FINALIZE_CB`, `SCHED_FAIL_MSG_CB` or outside a run) is a `security` test, and the membership rules of the `SCHED_FINALIZE_CB` ID sets remain an `outcome` concern even when one of those sets is the aborted set. Unlike `params` and `job_termination`, `abort` has no separate `*_full` / `*_mini` files: its two variant-specific tests (whether an aborted-and-killed PID appears in `SCHED_FINALIZE_CB`'s running-PIDs argument, which differs between the variants) live in `tests-abort.sh` behind `require_variant` and report SKIP on the other variant.

### Scheduler variants

The suite runs against either scheduler variant, selected by the `SCHEDULER_VARIANT` environment variable: `full` (default, `scheduler.sh`) or `mini` (`scheduler-mini.sh`), e.g. `SCHEDULER_VARIANT=mini sh ./tests.sh run`.

The `params` and `job_termination` categories hold variant-shared tests that run under both. The `*_full` categories hold tests for behavior only present in the full variant (e.g. `SCHED_AUTO_PARAMS` gating; the cgroup / children / ppid mechanisms of the helper library and the full `JOB_TERM_CB` protocol); the `*_mini` categories hold tests for mini-only behavior (always-on param auto-delivery; the simplified single-argument `JOB_TERM_CB` protocol and the built-in `sch_job_term_ppid` mechanism). Tests specific to the non-selected variant report SKIP.

Note: the `security` category consolidates the command-injection / forgery-resistance tests (job-ID and completion-record validation, param value/name and callback-value injection, and internal param-key namespace integrity).

Note: `job_termination` covers the modular job termination feature (`JOB_TERM_CB`) with variant-shared tests driving the selected variant's default mechanism, plus the shared infrastructure the `*_full` / `*_mini` files reuse. The full-variant `job_termination_full` category covers the optional helper library `job-term.sh`, which implements job termination via three different mechanisms: cgroup, `/proc` children-walk, and `/proc` PPID-walk. Each mechanism's tests are gated on that mechanism being usable in the current environment, and report SKIP otherwise (counted separately in the summary):

- cgroup tests require root or a delegated cgroup v2 subtree - e.g. run the suite via `systemd-run --user --scope sh ./tests.sh run job_termination`.
- children-walk tests require a kernel built with `CONFIG_PROC_CHILDREN` (which exposes `/proc/<pid>/task/<tid>/children`).

The core-contract tests (and the PPID-walk mechanism, which needs only `/proc` and `awk`) run everywhere.

Note: non-interference between concurrent scheduler instances is covered in two places - `core` verifies two concurrent instances do not cross-talk or leave residue, and `job_termination_full` verifies a cgroup base collision with a same-PID sibling is avoided (this second one is cgroup-gated as above).

### Shared test helpers

- Category-specific shared helpers live in that category's script.
- Cross-category shared helpers live in tests/tests.sh
- When, and only when you need to write or update tests, or understand details of tests implementation, read tests/SHARED-HELPERS.md.
- The suite's shared `SCHED_FINALIZE_CB` (`finalize_handler` in tests/tests.sh) sends SIGTERM, via a bare `kill`, to every still-running PID the scheduler reports to it.

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
