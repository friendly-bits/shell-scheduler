## Test suite

Consists of tests.sh and (currently) 8 category-specific test files. tests.sh is the launcher/entry point, the other files are categorized libraries of tests.

Categories: `dispatch`, `core`, `termination`, `config`, `params`, `misc`, `outcome`, `timeout`

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
- `run <category> <test_num_start>-<test_num_end>` - run tests in a range, e.g. 'run termination 3-6'
