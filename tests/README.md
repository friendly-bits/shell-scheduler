## Test suite

Consists of tests.sh and (currently) 7 category-specific test files. tests.sh is the entry point, the other files are like categorized libraries of tests.

Categories: dispatch, core, termination, config, params, misc, outcome

### Testing suite command line options

- `[no arguments]` - do nothing (for sourcing the script)
- `run` - run all tests, across all categories
- `run <category>` - run all tests in the given category
- `run <category> <space_separated_list_of_numbers>` - e.g. 'run params 1 3 5'
- `run <category> <test_num_start>-<test_num_end>` - run tests in a range, e.g. 'run termination 3-6'
