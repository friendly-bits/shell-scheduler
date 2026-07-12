#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-core.sh

# Category: Core Job Execution & Completion
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify the scheduler succeeds and calls JOB_DONE_CB for every job, even when one fails.
test_core_01() {
	TEST_ID=core_01 \
	TEST_NAME='Normal completion with failure status propagation' \
	TEST_JOBS='ok1 ok2 fail' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler succeeds and all JOB_DONE_CB callbacks run when every job succeeds.
test_core_02() {
	TEST_ID=core_02 \
	TEST_NAME='All jobs succeed' \
	TEST_JOBS='ok ok ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify a failing JOB_DONE_CB causes the scheduler to terminate with an error.
test_core_03() {
	core_03_done_handler() {
		echo "done idx='$1' rv='$2'"

		if [ "$2" != 0 ]
		then
			printf 'fail_seen\n' > "${FAILPROP_FILE:?}"
			return "${CORE_03_DONE_HANDLER_RV:?}"
		fi

		return 0
	}

	local sched_rv failprop_msg \
		TEST_ID=core_03 \
		CORE_03_DONE_HANDLER_RV=99 \
		jobs="ok fail"

	local FAILPROP_FILE="/tmp/sched.failprop.${TEST_ID:?}.$$"
	rm -f "${FAILPROP_FILE}"

	print_test_header "${TEST_ID:?}" "Failure status propagation to done_handler" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=core_03_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line failprop_msg "${FAILPROP_FILE}"
	rm -f "${FAILPROP_FILE}"

	if [ "${sched_rv}" = "${CORE_03_DONE_HANDLER_RV}" ] &&
		[ "${failprop_msg}" = "fail_seen" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify arbitrary DO_JOB_CB return codes reach JOB_DONE_CB unchanged without failing the scheduler.
test_core_04() {
	core_04_do_job() {
		return "$1"
	}

	core_04_done_handler() {
		printf '%s %s\n' "$1" "$2" >> "${STATUS_FILE:?}"

		return 0
	}

	local \
		TEST_ID=core_04 \
		sched_rv \
		actual \
		expected \
		jobs='0 1 17 42 99 255'

	local STATUS_FILE="/tmp/sched.status.${TEST_ID:?}.$$"
	rm -f "${STATUS_FILE}"

	print_test_header "${TEST_ID:?}" "DO_JOB_CB return statuses" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=core_04_done_handler \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=core_04_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?
	expected=$(cat <<EOF | sort
0 0
1 1
17 17
42 42
99 99
255 255
EOF
)

	actual=
	actual_cnt=0

	if [ -f "${STATUS_FILE}" ]
	then
		actual="$(sort "${STATUS_FILE}")"
		actual_cnt="$(wc -l < "${STATUS_FILE}")"
	fi

	rm -f "${STATUS_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual_cnt}" = 6 ] &&
		[ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, count=${actual_cnt}, actual=${actual//$'\n'/; }"
		return 1
	fi
}

# Verify DO_JOB_CB, JOB_DONE_CB, and SCHED_FINALIZE_CB observe the caller's noglob state.
test_core_05() {
	core_05_do_job() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${do_job_glob_file}"
		return 0
	}

	core_05_done_handler() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${done_glob_file}"
		return 0
	}

	core_05_finalize_handler() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac > "${finalize_glob_file}"
		return 0
	}

	local \
		TEST_ID=core_05 \
		mode \
		expect \
		sched_rv \
		pass_cnt=0 \
		parent_pre \
		parent_post \
		do_job_glob_file \
		done_glob_file \
		finalize_glob_file \
		do_job_result \
		done_result \
		finalize_result

	print_test_header "${TEST_ID:?}" "noglob state preserved in callbacks" \
		"glob-enabled and glob-disabled callers"

	for mode in glob noglob; do
		do_job_glob_file="/tmp/sched.globtest.job.${TEST_ID:?}.$$"
		done_glob_file="/tmp/sched.globtest.done.${TEST_ID:?}.$$"
		finalize_glob_file="/tmp/sched.globtest.finalize.${TEST_ID:?}.$$"
		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"

		case "${mode}" in
			glob) set +f; expect=glob ;;
			noglob) set -f; expect=noglob ;;
		esac

		parent_pre="${mode}"

		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=core_05_finalize_handler \
		JOB_DONE_CB=core_05_done_handler \
		DO_JOB_CB=core_05_do_job \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs 'ok ok ok' &

		wait "$!"
		sched_rv=$?

		parent_post=glob
		case "${-}" in
			*f*) parent_post=noglob ;;
		esac
		set +f

		do_job_result="$(sort -u "${do_job_glob_file}" 2>/dev/null | tr '\n' ' ')"
		done_result="$(sort -u "${done_glob_file}" 2>/dev/null | tr '\n' ' ')"
		finalize_result="$(cat "${finalize_glob_file}" 2>/dev/null)"

		if [ "${sched_rv}" = 0 ] &&
			[ "${parent_post}" = "${parent_pre}" ] &&
			[ "${do_job_result}" = "${expect} " ] &&
			[ "${done_result}" = "${expect} " ] &&
			[ "${finalize_result}" = "${expect}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'sub-check failed for mode=%s (sched_rv=%s, do_job=%s, done=%s, finalize=%s)\n' \
				"${mode}" "${sched_rv}" "${do_job_result}" "${done_result}" "${finalize_result}" >&2
		fi

		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"
	done

	set +f

	if [ "${pass_cnt}" = 2 ]
	then
		PASS
		return 0
	else
		FAIL "passed=${pass_cnt}/2"
		return 1
	fi
}

