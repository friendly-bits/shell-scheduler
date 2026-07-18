## Test suite

Consists of tests.sh and (currently) 10 category-specific test files. tests.sh is the launcher/entry point, the other files are categorized libraries of tests.

Categories: `dispatch`, `core`, `scheduler_termination`, `config`, `params`, `misc`, `outcome`, `timeout`, `job_termination`, `security`

Note: the `security` category consolidates the command-injection / forgery-resistance tests (job-ID and completion-record validation, param value/name and callback-value injection, and internal param-key namespace integrity).

Note: the `job_termination` category covers the modular job termination feature (`JOB_TERM_CB`) and its two bundled libraries. Tests of the cgroup library require an environment where it is supported: root, or a delegated cgroup v2 subtree - e.g. run the suite via `systemd-run --user --scope sh ./tests.sh run job_termination`. In an unsupported environment those tests report SKIP (counted separately in the summary), while the core-contract and proc-library tests still run.

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
