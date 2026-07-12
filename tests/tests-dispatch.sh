#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-dispatch.sh

# Category: Dispatch & Concurrency Control
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Helpers
#

parallel_job_enter() {
	printf 'enter\n' >&8
}

parallel_job_leave() {
	printf 'leave\n' >&8
}

run_parallelism_test() {
	do_job_parallel() {
		parallel_job_enter
		sleep 1
		parallel_job_leave
	}

	monitor_parallel_fifo() {
		local active=0 max_active=0 msg \
			result_file="${1:?}"

		while IFS= read -r msg; do
			case "${msg}" in
				enter)
					active=$((active + 1))

					[ "${active}" -gt "${max_active}" ] &&
						max_active="${active}"
				;;

				leave)
					active=$((active - 1))
				;;
			esac
		done

		printf '%s\n' "${max_active}" > "${result_file}"
	}

	local \
		sched_rv \
		fifo="/tmp/sched.parallel.${TEST_NUM:?}.$$" \
		result_file="/tmp/sched.parallel.res.${TEST_NUM:?}.$$" \
		max_active=0 \
		scheduler_pid \
		monitor_pid

	rm -f "${fifo}" "${result_file}" &&
	mkfifo "${fifo}" || return 1

	print_test_header "${TEST_NUM:?}" "${TEST_NAME:?}" "${TEST_JOBS:?}"

	monitor_parallel_fifo "${result_file}" < "${fifo}" &
	monitor_pid=$!

	exec 8>"${fifo}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_MAX_JOBS="${TEST_SCHED_MAX_JOBS:?}" \
	SCHED_TIMEOUT_S="${SCHED_TIMEOUT_S:-3}" \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=do_job_parallel \
		schedule_jobs "${TEST_JOBS:?}" &

	scheduler_pid=$!

	exec 8>&-

	wait "${monitor_pid}"

	wait "${scheduler_pid}"
	sched_rv=$?

	read_first_line max_active "${result_file}"
	rm -f "${fifo}" "${result_file}"

	if [ "${sched_rv}" = 0 ] &&
		is_uint "${max_active}" &&
		[ "${max_active}" = "${TEST_EXPECT_MAX_JOBS:?}" ]
	then
		PASS "max_parallel=${max_active}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, max_parallel=${max_active}"
		return 1
	fi
}

#
# Tests
#

# Verify the scheduler never runs more than SCHED_MAX_JOBS workers at once.
test_dispatch_01() {
	TEST_NUM=1 \
	TEST_NAME='Parallelism limit' \
	TEST_JOBS='1 2 3 4 5' \
	TEST_SCHED_MAX_JOBS=3 \
	TEST_EXPECT_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_parallelism_test
}

# Verify SCHED_MAX_JOBS=1 causes jobs to execute strictly sequentially.
test_dispatch_02() {
	TEST_NUM=2 \
	TEST_NAME='Single worker mode' \
	TEST_JOBS='1 2 3 4' \
	TEST_SCHED_MAX_JOBS=1 \
	TEST_EXPECT_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=7 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_parallelism_test
}

# Verify job completion triggers dispatch of the next queued job until all jobs run.
test_dispatch_03() {
	test_dispatch_03_do_job() {
		sleep 1
	}

	test_dispatch_03_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${DONE_COUNT_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=3 \
		sched_rv \
		expected_cnt \
		actual_done_jobs \
		done_cnt=0 \
		jobs="1 2 3 4 5"

	local DONE_COUNT_FILE="/tmp/sched.queue.${TEST_NUM:?}.$$"
	rm -f "${DONE_COUNT_FILE}"

	print_test_header 3 "Queue refill" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_dispatch_03_done_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_dispatch_03_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		verify_recorded_set \
			_ \
			actual_done_jobs \
			expected_cnt \
			done_cnt \
			"${DONE_COUNT_FILE}" \
			"${jobs}"
	then
		rm -f "${DONE_COUNT_FILE}"
		PASS "done_cnt=${done_cnt}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected_cnt=${expected_cnt}, done_cnt=${done_cnt}, actual_done_jobs=${actual_done_jobs}"
		return 1
	fi
}

# Verify 100 jobs complete and SCHED_FINALIZE_CB receives an empty running-PID list.
test_dispatch_04() {
	test_dispatch_04_do_job() {
		sleep 0
	}

	test_dispatch_04_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${DONE_COUNT_FILE:?}"

		return 0
	}

	test_dispatch_04_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		if [ -z "${pids}" ]
		then
			printf 'empty\n' > "${LARGE_FINALIZE_FILE:?}"
		else
			printf 'nonempty\n' > "${LARGE_FINALIZE_FILE:?}"
		fi

		return 0
	}

	local \
		TEST_NUM=4 \
		sched_rv \
		expected_cnt \
		actual_done_jobs \
		actual_done_cnt=0 \
		finalize_state \
		jobs=''

	local \
		DONE_COUNT_FILE="/tmp/sched.large.${TEST_NUM:?}.$$" \
		LARGE_FINALIZE_FILE="/tmp/sched.large.finalize.${TEST_NUM:?}.$$"

	rm -f "${DONE_COUNT_FILE}" "${LARGE_FINALIZE_FILE}"

	print_test_header 4 "Large job count" "100 jobs"

	jobs=$(seq 1 100)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_dispatch_04_finalize_handler \
	JOB_DONE_CB=test_dispatch_04_done_handler \
	SCHED_MAX_JOBS=10 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_dispatch_04_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	finalize_state=
	read_first_line finalize_state "${LARGE_FINALIZE_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		verify_recorded_set \
			_ \
			actual_done_jobs \
			expected_cnt \
			actual_done_cnt \
			"${DONE_COUNT_FILE}" \
			"${jobs}" &&
		[ "${finalize_state}" = empty ]
	then
		rm -f "${DONE_COUNT_FILE}" "${LARGE_FINALIZE_FILE}"
		PASS "completed=${actual_done_cnt}"
		return 0
	else
		rm -f "${DONE_COUNT_FILE}" "${LARGE_FINALIZE_FILE}"
		FAIL "sched_rv=${sched_rv}, finalize_state=${finalize_state}, expected_cnt=${expected_cnt}, actual_done_cnt=${actual_done_cnt}, actual_done_jobs=${actual_done_jobs}"
		return 1
	fi
}

# Verify an empty job list succeeds, calls no JOB_DONE_CB, and finalizes with empty PIDs.
test_dispatch_05() {
	test_dispatch_05_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${EMPTY_DONE_FILE:?}"

		return 0
	}

	test_dispatch_05_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		if [ -z "${pids}" ]
		then
			printf 'empty\n' > "${EMPTY_FINALIZE_FILE:?}"
		else
			printf 'nonempty\n' > "${EMPTY_FINALIZE_FILE:?}"
		fi

		return 0
	}

	local \
		TEST_NUM=5 \
		sched_rv \
		actual_done_cnt=0 \
		finalize_state='' \
		jobs="<none>"

	local \
		EMPTY_DONE_FILE="/tmp/sched.empty.done.${TEST_NUM:?}.$$" \
		EMPTY_FINALIZE_FILE="/tmp/sched.empty.finalize.${TEST_NUM:?}.$$"

	rm -f "${EMPTY_DONE_FILE}" "${EMPTY_FINALIZE_FILE}"

	print_test_header 5 "Empty job list" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_dispatch_05_finalize_handler \
	JOB_DONE_CB=test_dispatch_05_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs '' &

	wait "$!"
	sched_rv=$?

	if [ -f "${EMPTY_DONE_FILE}" ]
	then
		actual_done_cnt=$(wc -l < "${EMPTY_DONE_FILE}")
	fi

	read_first_line finalize_state "${EMPTY_FINALIZE_FILE}"

	rm -f "${EMPTY_DONE_FILE}" "${EMPTY_FINALIZE_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual_done_cnt}" = 0 ] &&
		[ "${finalize_state}" = empty ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, actual_done_cnt=${actual_done_cnt}, finalize=${finalize_state}"
		return 1
	fi
}

# Verify SCHED_MAX_JOBS caps concurrency under heavy load (300 jobs).
test_dispatch_06() {
	test_dispatch_06_do_job() {
		parallel_job_enter

		case $(( $1 % 2 )) in
			0) sleep 0 ;;
			*) sleep 1 ;;
		esac

		parallel_job_leave
	}

	monitor_stress_fifo() {
		local active=0 max_active=0 msg \
			result_file="${1:?}"

		while IFS= read -r msg; do
			case "${msg}" in
				enter)
					active=$((active + 1))

					[ "${active}" -gt "${max_active}" ] &&
						max_active="${active}"
				;;

				leave)
					active=$((active - 1))
				;;
			esac
		done

		printf '%s\n' "${max_active}" > "${result_file}"
	}

	local TEST_NUM=6
	local \
		sched_rv \
		fifo="/tmp/sched.stress.${TEST_NUM:?}.$$" \
		result_file="/tmp/sched.stress.res.${TEST_NUM:?}.$$" \
		scheduler_pid \
		monitor_pid \
		max_active=0 \
		jobs \
		i=0 \
		N=300

	print_test_header 6 "Parallelism stress test" "300 jobs"

	rm -f "${fifo}" "${result_file}" &&
	mkfifo "${fifo}" || return 1

	monitor_stress_fifo "${result_file}" < "${fifo}" &
	monitor_pid=$!

	exec 8>"${fifo}"

	# generate large job set
	jobs=
	while [ "${i}" -lt "${N}" ]; do
		i=$((i + 1))
		jobs="${jobs} ${i}"
	done

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	SCHED_MAX_JOBS=20 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=test_dispatch_06_do_job \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	exec 8>&-

	wait "${scheduler_pid}"
	sched_rv=$?

	wait "${monitor_pid}"

	read_first_line max_active "${result_file}"
	rm -f "${fifo}" "${result_file}"

	if \
		[ "${sched_rv}" = 0 ] &&
		is_uint "${max_active}" &&
		[ "${max_active}" -le 20 ]
	then
		PASS "max_parallel=${max_active}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, max_parallel=${max_active}"
		return 1
	fi
}

# Verify SCHED_MAX_JOBS greater than the job count still completes all jobs normally.
test_dispatch_07() {
	TEST_NUM=7 \
	TEST_NAME='SCHED_MAX_JOBS exceeds job count' \
	TEST_JOBS='ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=10 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}
