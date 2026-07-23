#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests.sh

# Supported script arguments:
# [no arguments] - do nothing (for sourcing the script)
# 'run' - run all tests, across all categories
# 'run <category>' - run all tests in the given category
# 'run <category> <space_separated_list_of_numbers>' - e.g. 'run params 1 3 5'
# 'run <category> <test_num_start>-<test_num_end>' - run tests in a range, e.g. 'run scheduler_termination 3-6'
# Categories: dispatch, core, scheduler_termination, config, config_full, config_mini, params, misc, outcome, timeout, job_termination, job_termination_full, job_termination_mini, security
#
# Variant selection (env var SCHEDULER_VARIANT): 'full' (default, scheduler.sh) or
#   'mini' (scheduler-mini.sh). The *_full / *_mini categories hold tests specific
#   to one variant and SKIP under the other; the plain categories run against both.

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

# Select scheduler variant: full (scheduler.sh) or mini (scheduler-mini.sh)
SCHEDULER_VARIANT="${SCHEDULER_VARIANT:-full}"
case "${SCHEDULER_VARIANT}" in
	full) SCHEDULER_LIB=scheduler.sh; SCHED_IS_MINI= ;;
	mini) SCHEDULER_LIB=scheduler-mini.sh; SCHED_IS_MINI=1 ;;
	*) printf '%s\n' "Unknown SCHEDULER_VARIANT '${SCHEDULER_VARIANT}' (want 'full' or 'mini')." >&2; exit 1 ;;
esac

. "${script_dir}/../${SCHEDULER_LIB}"

# The full variant uses the standalone job-termination libraries; the mini
#   variant has its own built-in mechanism (sched_job_term_mini).
if [ -z "${SCHED_IS_MINI}" ]; then
	. "${script_dir}/../job-term-cgroup.sh"
	. "${script_dir}/../job-term-children.sh"
	. "${script_dir}/../job-term-ppid.sh"
	SCHED_TERM_CB_DEFAULT=sched_job_term_ppid
	term_default_capable() { proc_ppid_supported; }
else
	SCHED_TERM_CB_DEFAULT=sched_job_term_mini
	term_default_capable() { sch_is_cmd "${SCHED_AWK_CMD:-awk}" && [ -r /proc/self/stat ]; }
fi
TERM_DEFAULT_SKIP_REASON="default termination mechanism unsupported here - /proc or awk unavailable"


#
# Testing infrastructure functions
#

PASS() {
	printf '%s\n' "Result: ${PASS}${1:+" ("}${1}${1:+")"}"
}

FAIL() {
	printf '%s\n' "Result: ${FAIL}${1:+" ("}${1}${1:+")"}"
}

# For environment-gated tests: print a skip result line. The test must then
# 'return 2', which the run loop counts as a skip (separately in the summary).
SKIP() {
	printf '%s\n' "Result: ${SKIP_C}${1:+" ("}${1}${1:+")"}"
}

# Skip a test that only applies to the other variant: prints a skip line and
# returns non-zero so the caller can 'return 2' (counted as a skip).
# Usage: require_variant full|mini || return 2
require_variant() {
	[ "${SCHEDULER_VARIANT}" = "${1}" ] ||
		{ SKIP "needs '${1}' variant (running '${SCHEDULER_VARIANT}')"; return 1; }
}

is_uint() {
	local _v
	for _v in "${@}"; do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

read_first_line() {
	export -n "${1:?}="
	[ -f "${2:?}" ] || return 1
	IFS= read -r "${1:?}" < "${2}"
}

set_ansi() {
	local IFS=" "
	# shellcheck disable=SC2046
	set -- $(printf '\033[0;31m \033[0;32m \033[0;34m \033[1;33m \033[0;35m \033[0m')
	export red="${1}" green="${2}" blue="${3}" yellow="${4}" purple="${5}" n_c="${6}"
}

print_test_header() {
	printf '\n%s\n' "${MATRIX_ID:+"[${yellow}${MATRIX_ID}${n_c}] "}== ${purple}${1%_*}:${1##*_}: ${2}${n_c} =="
	printf 'Running jobs: %s\n' "${blue}${3}${n_c}"
}

verify_recorded_set() {
	local \
		expected_items_var="${1:?}" \
		actual_items_var="${2:?}" \
		expected_cnt_var="${3:?}" \
		actual_cnt_var="${4:?}" \
		record_file="${5:?}" \
		vrs_expected_items="${6:?}" \
		vrs_actual_items \
		vrs_expected_cnt \
		vrs_actual_cnt

	# Remove duplicate expected items
	vrs_expected_items="$(printf '%s\n' "${vrs_expected_items// /$'\n'}" | sed '/^$/d' | sort -u)"

	vrs_expected_cnt="$(printf '%s\n' "${vrs_expected_items}" | sed '/^$/d' | wc -l)"

	[ -f "${record_file}" ] || return 1

	vrs_actual_cnt="$(sed '/^$/d' "${record_file}" | wc -l)"
	vrs_actual_items="$(sed '/^$/d' "${record_file}" | sort -u)"
	export -n \
		"${expected_items_var}=${vrs_expected_items}" \
		"${actual_items_var}=${vrs_actual_items}" \
		"${expected_cnt_var}=${vrs_expected_cnt}" \
		"${actual_cnt_var}=${vrs_actual_cnt}"

	[ "${vrs_expected_cnt}" = "${vrs_actual_cnt}" ] &&
		[ "${vrs_expected_items}" = "${vrs_actual_items}" ]
}

# Compare two whitespace-separated ID lists for set equality
#   (order/duplicate-insensitive). Sets OUT vars to the normalized
#   (deduped, sorted) form of each side for diagnostics on mismatch.
# 1: out var for normalized expected
# 2: out var for normalized actual
# 3: expected list (raw)
# 4: actual list (raw)

# Write each whitespace-separated ID-set arg to its own file at "${1}.<suffix>".
# 1: file prefix
# 2: ok_ids  3: fail_ids  4: unfinished_ids  5: undispatched_ids  6: expired_ids
write_id_sets() {
	local wis_prefix="${1:?}"

	printf '%s\n' "${2}" > "${wis_prefix}.ok"
	printf '%s\n' "${3}" > "${wis_prefix}.fail"
	printf '%s\n' "${4}" > "${wis_prefix}.unfinished"
	printf '%s\n' "${5}" > "${wis_prefix}.undispatched"
	printf '%s\n' "${6}" > "${wis_prefix}.expired"
}

done_handler() {
	echo "done idx='$1' rv='$2'"

	return 0
}

finalize_handler() {
	local finalize_rv="${1}" pids="${2}" pid_cnt=0

	if [ -n "${pids}" ]
	then
		set -- ${pids}
		pid_cnt="${#}"
	fi

	if [ "${pid_cnt}" -le 20 ]
	then
		echo "finalize_rv='${finalize_rv}' pids='${pids}'"
	else
		echo "finalize_rv='${finalize_rv}' running_pid_count=${pid_cnt} (list suppressed)"
	fi

	for pid in ${pids}; do
		kill "${pid}" 2>/dev/null
	done

	return 0
}

do_job_default() {
	local self_pid job_name="${1%%_*}"

	case "${job_name}" in
		instant) sleep 0 ;;
		ok|ok1) sleep 1 ;;
		ok2) sleep 2 ;;
		ok5) sleep 5 ;;
		hang) sleep 30 ;;

		crash)
			get_test_pid self_pid || return 1
			kill -9 "${self_pid}"
		;;

		fail)
			sleep 1
			return 17
		;;

		malformed)
			printf 'garbage\n' >&3
			sleep 1
		;;
		*)
			printf '%s\n' "Unexpected job name '${job_name}'." >&2
			return 1
		;;
	esac

	return 0
}

get_test_pid() {
	local __pid line

	export -n "${1:?}="

	while IFS= read -r line; do
		case "${line}" in
			Pid:*)
				__pid="${line##*[^0-9]}"
				break
			;;
		esac
	done < /proc/self/status

	is_uint "${__pid}" || return 1
	export -n "${1}=${__pid}"
}

run_generic_test() {
	local sched_rv

	print_test_header "${TEST_ID:?}" "${TEST_NAME:?}" "${TEST_JOBS:?}"

	SCHED_FAIL_MSG_CB=echo \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS="${TEST_SCHED_MAX_JOBS:?}" \
	SCHED_TIMEOUT_S="${SCHED_TIMEOUT_S:-3}" \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${TEST_JOBS}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = "${TEST_EXPECT_RV:?}" ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected ${TEST_EXPECT_RV}"
		return 1
	fi
}




#
# Source category test files
#

. "${script_dir}/tests-dispatch.sh"
. "${script_dir}/tests-core.sh"
. "${script_dir}/tests-scheduler_termination.sh"
. "${script_dir}/tests-config.sh"
. "${script_dir}/tests-params.sh"
. "${script_dir}/tests-misc.sh"
. "${script_dir}/tests-outcome.sh"
. "${script_dir}/tests-timeout.sh"
. "${script_dir}/tests-job_termination.sh"
. "${script_dir}/tests-job_termination_full.sh"
. "${script_dir}/tests-job_termination_mini.sh"
. "${script_dir}/tests-security.sh"
. "${script_dir}/tests-config_full.sh"
. "${script_dir}/tests-config_mini.sh"


#
# Category registry
#

TEST_CATEGORIES="dispatch core scheduler_termination config config_full config_mini params misc outcome timeout job_termination job_termination_full job_termination_mini security"

is_valid_cat() {
	case " ${TEST_CATEGORIES} " in
		*" ${1} "*) ;;
		*) printf '%s\n' "Unknown category '${1}'. Valid categories: ${TEST_CATEGORIES}" >&2; return 1 ;;
	esac
}

get_category_tests_list() {
	is_valid_cat "${1}" || return 1
	sed -En "/^\s*test_${1}_[0-9]+\s*\(\)/{s/\(\).*//;p}" "${script_dir}/tests-${1}.sh" | grep . ||
		{ printf '%s\n' "Failed to get list of tests for category '${1}'." >&2; return 1; }
}



# 1: out var
# 2: category short name
# Prints the number of tests in that category, or fails for an unknown category.
get_category_test_cnt() {
	local cnt

	is_valid_cat "${1}" || exit 1
	cnt=$(grep -cE "[ \t]test_${1}_[0-9]+" "${SCRIPT_DIR}/tests/tests-${1}.sh" ) ||
		{ printf '%s\n' "Failed to get list of tests for category '${1}'."; return 1; }

	export -n "${1}=${cnt}"
}

# 1: out var
# 2: category short name
# 3: space-separated test numbers within that category (no zero-padding required)
build_run_list_for_category() {
	local brl_out_var="${1:?}" brl_cat="${2:?}" brl_nums="${3:?}" brl_n brl_list

	for brl_n in ${brl_nums}; do
		sch_is_uint "${brl_n}" || { printf '%s\n' "Invalid test number '${brl_n}' for category '${brl_cat}'." >&2; return 1; }
		brl_list="${brl_list}${brl_list:+" "}test_${brl_cat}_$(printf '%02d' "${brl_n}")"
	done

	export -n "${brl_out_var}=${brl_list}"
}


#
# Inline test code starts here.
#

NL=$'\n'
DEFAULT_IFS=$'\t'" ${NL}"
IFS="${DEFAULT_IFS}"

set_ansi

export -n \
	PASS="${green}PASS${n_c}" \
	FAIL="${red}FAIL${n_c}" \
	SKIP_C="${yellow}SKIP${n_c}"

RUN_TESTS=
RUN_CAT=

case "${1}" in
	run)
		shift

		if [ "${#}" -eq 0 ]; then
			# No category given: run every test, in every category, in category order.
			for CAT in ${TEST_CATEGORIES}; do
				CAT_TESTS=$(get_category_tests_list "${CAT}") || exit 1
				RUN_TESTS="${RUN_TESTS}${RUN_TESTS:+" "}${CAT_TESTS//$'\n'/ }"
			done
		else
			RUN_CAT="${1}"
			is_valid_cat "${RUN_CAT}" || exit 1
			shift

			if [ -n "${*}" ]; then
				case "${*}" in
					*-*-*) printf '%s\n' "Unexpected string '${*}'." >&2; exit 1 ;;
					*-*)
						RUN_RANGE="${*}"
						RUN_TESTS=$(
							for test_num in $(seq "${RUN_RANGE%%-*}" "${RUN_RANGE#*-}"); do
								printf 'test_%s_%02d\n' "${RUN_CAT}" "${test_num}"
							done |
							grep .
						)
						;;
					*)
						RUN_TESTS=$(
							for test_num in "${@}"; do
								[ -n "${test_num}" ] || continue
								is_uint "${test_num}" || { printf '%s\n' "Invalid number '${test_num}'."; exit 1; }
								printf 'test_%s_%02d\n' "${RUN_CAT}" "${test_num}"
							done
						)
						;;
				esac &&
				[ -n "${RUN_TESTS}" ] || { printf '%s\n' "Failed to construct a list of tests to run."; exit 1; }
			else
				RUN_TESTS=$(get_category_tests_list "${RUN_CAT}") || exit 1
			fi

			RUN_TESTS="${RUN_TESTS//$'\n'/ }"
		fi
		;;
	'')
		;;
	*)
		printf '%s\n' "Unexpected argument '${1}'." >&2; exit 1
esac

if [ -n "${RUN_TESTS}" ]; then
	TESTS_RUN=0
	TESTS_PASSED=0
	TESTS_SKIPPED=0

	for RUN_TEST in ${RUN_TESTS}; do
		TESTS_RUN=$((TESTS_RUN + 1))
		TEST_CAT="${RUN_TEST#test_}"
		TEST_CAT="${TEST_CAT%_*}"

		"${RUN_TEST}"
		test_rv=${?}
		case "${test_rv}" in
			0) TESTS_PASSED=$((TESTS_PASSED + 1)) ;;
			1) ;;
			2) TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
		esac

		# Under test-matrix.sh, emit a delimiter after each test so the matrix
		#   drainer can print each test's block contiguously (${TEST_BLOCK_END}
		#   is supplied via the environment).
		[ -z "${MATRIX_ID}" ] || printf '%s\n' "${TEST_BLOCK_END}"
	done

	printf '\n%s\n' "${MATRIX_ID:+"[${yellow}${MATRIX_ID}${n_c}] "}== ${purple}Summary${n_c} =="
	printf 'Ran: %s, Passed: %s, Skipped: %s, Failed: %s\n' \
		"${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_SKIPPED}" "$((TESTS_RUN - TESTS_PASSED - TESTS_SKIPPED))"
fi

[ "$((TESTS_RUN - TESTS_PASSED - TESTS_SKIPPED))" -eq 0 ]
