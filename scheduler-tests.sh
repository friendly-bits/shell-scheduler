#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# Supported script arguments:
# To run all tests: 'run'
# To run select tests: <space_separated_list_of_numbers>

# scheduler-tests.sh

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "${script_dir}/scheduler.sh"


#
# Testing infrastructure functions
#

is_uint()
{
	local _v
	for _v in "${@}"
	do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

read_first_line()
{
	export -n "${1:?}="
	[ -f "${2:?}" ] || return 1
	IFS= read -r "${1:?}" < "${2}"
}

set_ansi()
{
	local IFS=" "
	# shellcheck disable=SC2046
	set -- $(printf '\033[0;31m \033[0;32m \033[0;34m \033[1;33m \033[0;35m \033[0m')
	export red="${1}" green="${2}" blue="${3}" yellow="${4}" purple="${5}" n_c="${6}"
}

print_test_header() {
	printf '\n%s\n' "== ${purple}Test ${1}: ${2}${n_c} =="
	printf 'Running jobs: %s\n' "${blue}${3}${n_c}"
}

verify_recorded_set()
{
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

done_handler_default()
{
	echo "done idx='$1' rv='$2'"

	return 0
}

done_handler()
{
	"${DONE_HANDLER_CB:-done_handler_default}" "$@"
}

finalize_handler_default()
{
	local rv="${1}" pids="${2}"

	echo "finalize rv='${rv}' pids='${pids}'"

	for pid in ${pids}
	do
		kill "${pid}" 2>/dev/null
	done

	return 0
}

finalize_handler()
{
	"${FINALIZE_HANDLER_CB:-finalize_handler_default}" "$@"
}

do_job_default()
{
	local self_pid job_name="${1}"

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

get_test_pid()
{
	local __pid line

	export -n "${1:?}="

	while IFS= read -r line
	do
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

run_test()
{
	local rv
	
	print_test_header "${TEST_NUM:?}" "${TEST_NAME:?}" "${TEST_JOBS:?}"

	SCHED_FAIL_MSG_CB="${SCHED_FAIL_MSG_CB:-echo}" \
	SCHED_FINALIZE_CB="${SCHED_FINALIZE_CB-finalize_handler}" \
	JOB_DONE_CB="${JOB_DONE_CB-done_handler}" \
	DO_JOB_CB="${DO_JOB_CB:-do_job_default}" \
	SCHED_MAX_JOBS="${TEST_SCHED_MAX_JOBS:?}" \
	SCHED_TIMEOUT_S="${SCHED_TIMEOUT_S:-3}" \
	SCHED_IDLE_TIMEOUT_S="${SCHED_IDLE_TIMEOUT_S:-2}" \
		schedule_jobs "${TEST_JOBS}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = "${TEST_EXPECT_RV:?}" ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		return 0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, expected ${TEST_EXPECT_RV})"
		return 1
	fi
}

parallel_job_enter()
{
	printf 'enter\n' >&8
}

parallel_job_leave()
{
	printf 'leave\n' >&8
}

run_parallelism_test()
{
	do_job_parallel()
	{
		parallel_job_enter
		sleep 1
		parallel_job_leave
	}

	monitor_parallel_fifo()
	{
		local active=0 max_active=0 msg \
			result_file="${1:?}"

		while IFS= read -r msg
		do
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
		rv \
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

	SCHED_FAIL_MSG_CB="${SCHED_FAIL_MSG_CB:-echo}" \
	SCHED_FINALIZE_CB="${SCHED_FINALIZE_CB-finalize_handler}" \
	JOB_DONE_CB="${JOB_DONE_CB-done_handler}" \
	SCHED_MAX_JOBS="${TEST_SCHED_MAX_JOBS:?}" \
	SCHED_TIMEOUT_S="${SCHED_TIMEOUT_S:-3}" \
	SCHED_IDLE_TIMEOUT_S="${SCHED_IDLE_TIMEOUT_S:-2}" \
	DO_JOB_CB=do_job_parallel \
		schedule_jobs "${TEST_JOBS:?}" &

	scheduler_pid=$!

	exec 8>&-

	wait "${monitor_pid}"

	wait "${scheduler_pid}"
	rv=$?

	local test_pass

	if [ "${rv}" = 0 ] &&
		read_first_line max_active "${result_file}" &&
		is_uint "${max_active}" &&
		[ "${max_active}" = "${TEST_EXPECT_MAX_JOBS:?}" ]
	then
		printf '%s\n' "Result: ${PASS} (max_parallel=${max_active})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, max_parallel=${max_active})"
		test_pass=1
	fi

	rm -f "${fifo}" "${result_file}"

	return "${test_pass}"
}


#
# Test functions
#


# Verify that the scheduler completes normally when one job returns a non-zero
# status. The scheduler itself should still succeed and invoke the completion
# callback for each job.
test_1()
{
	TEST_NUM=1 \
	TEST_NAME='Normal completion with failure status propagation' \
	TEST_JOBS='ok1 ok2 fail' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_test
}

# Verify that the scheduler detects lack of progress and terminates when the
# idle timeout expires while a job is still running.
test_2()
{
	TEST_NUM=2 \
	TEST_NAME='Idle timeout' \
	TEST_JOBS='ok ok hang' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
		run_test
}

# Verify that the scheduler eventually times out when a worker exits without sending a completion record.
test_3()
{
	TEST_NUM=3 \
	TEST_NAME='Child crash before completion record' \
	TEST_JOBS='ok crash' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
		run_test
}

# Verify that the scheduler treats malformed completion records as an error.
test_4()
{
	TEST_NUM=4 \
	TEST_NAME='Malformed completion record' \
	TEST_JOBS='malformed' \
	TEST_EXPECT_RV=1 \
	TEST_SCHED_MAX_JOBS=1 \
		run_test
}

# Verify that the scheduler never runs more than SCHED_MAX_JOBS workers at the same time.
test_5()
{
	TEST_NUM=5 \
	TEST_NAME='Parallelism limit' \
	TEST_JOBS='1 2 3 4 5' \
	TEST_SCHED_MAX_JOBS=3 \
	TEST_EXPECT_MAX_JOBS=3 \
		run_parallelism_test
}

# Verify that SCHED_MAX_JOBS=1 causes jobs to execute strictly sequentially.
test_6()
{
	TEST_NUM=6 \
	TEST_NAME='Single worker mode' \
	TEST_JOBS='1 2 3 4' \
	TEST_SCHED_MAX_JOBS=1 \
	TEST_EXPECT_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=7 \
		run_parallelism_test
}

# Verify that the scheduler succeeds when all jobs complete successfully and
# all completion callbacks are executed.
test_7()
{
	TEST_NUM=7 \
	TEST_NAME='All jobs succeed' \
	TEST_JOBS='ok ok ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_test
}

# Verify that a failure returned by done_handler() causes the scheduler to
# terminate with an error.
test_8()
{
	test_8_done_handler()
	{
		echo "done idx='$1' rv='$2'"

		if [ -n "${FAILPROP_FILE}" ] && [ "$2" != 0 ]
		then
			printf 'fail_seen\n' > "${FAILPROP_FILE}"
			return "${TEST_8_DONE_HANDLER_RV:?}"
		fi

		return 0
	}

	local rv failprop_msg test_pass \
		TEST_NUM=8 \
		TEST_8_DONE_HANDLER_RV=99 \
		jobs="ok fail"


	FAILPROP_FILE="/tmp/sched.failprop.${TEST_NUM:?}.$$"

	rm -f "${FAILPROP_FILE}"

	print_test_header 8 "Failure status propagation to done_handler" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	DONE_HANDLER_CB=test_8_done_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = "${TEST_8_DONE_HANDLER_RV}" ] &&
		read_first_line failprop_msg "${FAILPROP_FILE}" &&
		[ "${failprop_msg}" = "fail_seen" ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv})"
		test_pass=1
	fi

	rm -f "${FAILPROP_FILE}"

	return "${test_pass}"
}

# Verify that completion of a running job causes the scheduler to launch the
# next queued job until all queued jobs have been processed.
test_9()
{
	test_9_do_job()
	{
		sleep 1
	}

	test_9_done_handler()
	{
		echo "done idx='$1' rv='$2'"

		[ -n "${DONE_COUNT_FILE}" ] &&
			printf '%s\n' "$1" >> "${DONE_COUNT_FILE}"

		return 0
	}

	local \
		TEST_NUM=9 \
		rv \
		expected_cnt \
		actual_done_jobs \
		done_cnt=0 \
		test_pass \
		jobs="1 2 3 4 5"

	print_test_header 9 "Queue refill" "${jobs}"

	DONE_COUNT_FILE="/tmp/sched.queue.${TEST_NUM:?}.$$"
	rm -f "${DONE_COUNT_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DONE_HANDLER_CB=test_9_done_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_9_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = 0 ] &&
		verify_recorded_set \
			_ \
			actual_done_jobs \
			expected_cnt \
			done_cnt \
			"${DONE_COUNT_FILE}" \
			"${jobs}"
	then
		printf '%s\n' "Result: ${PASS} (done_cnt=${done_cnt})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, expected_cnt=${expected_cnt}, done_cnt=${done_cnt}, actual_done_jobs=${actual_done_jobs})"
		test_pass=1
	fi

	rm -f "${DONE_COUNT_FILE}"

	return "${test_pass}"
}

# Verify scheduler behavior with a larger number of jobs and ensure that
# finalize callback receives an empty running PID list on success.
test_10()
{
	test_10_do_job()
	{
		sleep 0
	}

	test_10_done_handler()
	{
		echo "done idx='$1' rv='$2'"

		[ -n "${DONE_COUNT_FILE}" ] &&
			printf '%s\n' "$1" >> "${DONE_COUNT_FILE}"

		return 0
	}

	test_10_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		if [ -n "${LARGE_FINALIZE_FILE}" ]
		then
			if [ -z "${pids}" ]
			then
				printf 'empty\n' > "${LARGE_FINALIZE_FILE}"
			else
				printf 'nonempty\n' > "${LARGE_FINALIZE_FILE}"
			fi
		fi

		return 0
	}

	local \
		TEST_NUM=10 \
		rv \
		expected_cnt \
		actual_done_jobs \
		actual_done_cnt=0 \
		finalize_state \
		test_pass \
		jobs=''

	print_test_header 10 "Large job count" "100 jobs"

	jobs=$(seq 1 100)

	DONE_COUNT_FILE="/tmp/sched.large.${TEST_NUM:?}.$$"
	LARGE_FINALIZE_FILE="/tmp/sched.large.finalize.${TEST_NUM:?}.$$"

	rm -f "${DONE_COUNT_FILE}" "${LARGE_FINALIZE_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DONE_HANDLER_CB=test_10_done_handler \
	FINALIZE_HANDLER_CB=test_10_finalize_handler \
	SCHED_MAX_JOBS=10 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_10_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	finalize_state=
	read_first_line finalize_state "${LARGE_FINALIZE_FILE}"

	if [ "${rv}" = 0 ] &&
		verify_recorded_set \
			_ \
			actual_done_jobs \
			expected_cnt \
			actual_done_cnt \
			"${DONE_COUNT_FILE}" \
			"${jobs}" &&
		[ "${finalize_state}" = empty ]
	then
		printf '%s\n' "Result: ${PASS} (completed=${actual_done_cnt})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, finalize_state=${finalize_state}, expected_cnt=${expected_cnt}, actual_done_cnt=${actual_done_cnt}, actual_done_jobs=${actual_done_jobs})"
		test_pass=1
	fi

	rm -f "${DONE_COUNT_FILE}" "${LARGE_FINALIZE_FILE}"

	return "${test_pass}"
}

# Verify that the scheduler terminates when the overall processing timeout
# expires, even though workers are still active and the idle timeout has not
# been reached.
test_11()
{
	test_11_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		[ -n "${TIMEOUT_FILE}" ] &&
			printf '%s\n' "${rv}" > "${TIMEOUT_FILE}"

		return 0
	}

	local \
		TEST_NUM=11 \
		test_pass \
		jobs="ok hang"
	print_test_header 11 "Processing timeout" "${jobs}"

	TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	FINALIZE_HANDLER_CB=test_11_finalize_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"

	if [ "$?" = 82 ] &&
		read_first_line rv "${TIMEOUT_FILE}" &&
		[ "${rv}" = 82 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL}"
		test_pass=1
	fi

	rm -f "${TIMEOUT_FILE}"

	return "${test_pass}"
}

# Verify that an empty job list exits successfully, invokes no done_handler()
# callbacks and finalizes with an empty PID list.
test_12()
{
	test_12_done_handler()
	{
		echo "done idx='$1' rv='$2'"

		[ -n "${EMPTY_DONE_FILE}" ] &&
			printf '%s\n' "$1" >> "${EMPTY_DONE_FILE}"

		return 0
	}

	test_12_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		if [ -n "${EMPTY_FINALIZE_FILE}" ]
		then
			if [ -z "${pids}" ]
			then
				printf 'empty\n' > "${EMPTY_FINALIZE_FILE}"
			else
				printf 'nonempty\n' > "${EMPTY_FINALIZE_FILE}"
			fi
		fi

		return 0
	}

	local \
		TEST_NUM=12 \
		rv \
		actual_done_cnt=0 \
		finalize_state='' \
		test_pass \
		jobs="<none>"

	print_test_header 12 "Empty job list" "${jobs}"

	EMPTY_DONE_FILE="/tmp/sched.empty.done.${TEST_NUM:?}.$$"
	EMPTY_FINALIZE_FILE="/tmp/sched.empty.finalize.${TEST_NUM:?}.$$"

	rm -f "${EMPTY_DONE_FILE}" "${EMPTY_FINALIZE_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	DONE_HANDLER_CB=test_12_done_handler \
	FINALIZE_HANDLER_CB=test_12_finalize_handler \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs '' &

	wait "$!"
	rv=$?

	if [ -f "${EMPTY_DONE_FILE}" ]
	then
		actual_done_cnt=$(wc -l < "${EMPTY_DONE_FILE}")
	fi

	read_first_line finalize_state "${EMPTY_FINALIZE_FILE}"

	if [ "${rv}" = 0 ] &&
		[ "${actual_done_cnt}" = 0 ] &&
		[ "${finalize_state}" = empty ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, actual_done_cnt=${actual_done_cnt}, finalize=${finalize_state})"
		test_pass=1
	fi

	rm -f "${EMPTY_DONE_FILE}" "${EMPTY_FINALIZE_FILE}"

	return "${test_pass}"
}

# Verify that SIGUSR1 causes scheduler termination with SCHED_RV_SIGNAL,
# that finalize callback receives non-empty running PID list and that the callback terminates the workers.
test_13()
{
	test_13_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIGUSR1_RV_FILE}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIGUSR1_PIDS_FILE}"
		fi

		finalize_handler_default "${rv}" "${pids}"
	}

	local \
		TEST_NUM=13 \
		rv \
		callback_rv \
		pids='' \
		test_pass \
		schedule_pid

	print_test_header 13 "SIGUSR1 termination" "1 2"

	SIGUSR1_RV_FILE="/tmp/sched.sigusr1.rv.${TEST_NUM:?}.$$"
	SIGUSR1_PIDS_FILE="/tmp/sched.sigusr1.pids.${TEST_NUM:?}.$$"

	rm -f "${SIGUSR1_RV_FILE}" "${SIGUSR1_PIDS_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	FINALIZE_HANDLER_CB=test_13_finalize_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs 'hang hang' &

	schedule_pid=$!

	sleep 1

	kill -USR1 "${schedule_pid}"

	wait "${schedule_pid}"
	rv=$?

	read_first_line pids "${SIGUSR1_PIDS_FILE}"

	if [ "${rv}" = 83 ] &&
		read_first_line callback_rv "${SIGUSR1_RV_FILE}" &&
		[ "${callback_rv}" = 83 ] &&
		[ -n "${pids}" ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, callback_rv=${callback_rv}, pids=${pids})"
		test_pass=1
	fi

	rm -f "${SIGUSR1_RV_FILE}" "${SIGUSR1_PIDS_FILE}"

	return "${test_pass}"
}

# Verify that loss of a completion record while another worker still holds the FIFO open
# eventually causes an idle timeout instead of being mistaken for normal completion due to EOF.
test_14()
{
	local \
		TEST_NUM=14 \
		rv \
		test_pass \
		jobs='crash hang'

	print_test_header 14 \
		"Missing completion record with active writer" \
		"${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = 81 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, expected 81)"
		test_pass=1
	fi

	return "${test_pass}"
}

# Verify that a failing SCHED_FINALIZE_CB overrides rv=0 but does not
# overwrite an existing scheduler error.
test_15()
{
	test_15_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" >> "${FINALIZE_RV_FILE}"

		return "${TEST_15_FINALIZE_RV:?}"
	}

	local \
		TEST_NUM=15 \
		rv_success \
		rv_failure \
		recorded_rvs \
		test_pass \
		TEST_15_FINALIZE_RV=97

	print_test_header 15 "Failure of SCHED_FINALIZE_CB" \
		"success path and error path"

	FINALIZE_RV_FILE="/tmp/sched.finalize.fail.${TEST_NUM:?}.$$"

	rm -f "${FINALIZE_RV_FILE}"

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		FINALIZE_HANDLER_CB=test_15_finalize_handler

	# Successful scheduler run: callback RV should become scheduler RV.
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'ok' &

	wait "$!"
	rv_success=$?

	# Scheduler error: callback failure must not overwrite scheduler RV.
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'hang' &

	wait "$!"
	rv_failure=$?

	recorded_rvs=
	[ -f "${FINALIZE_RV_FILE}" ] &&
		recorded_rvs="$(tr '\n' ' ' < "${FINALIZE_RV_FILE}")"

	if [ "${rv_success}" = "${TEST_15_FINALIZE_RV}" ] &&
		[ "${rv_failure}" = 81 ] &&
		[ "${recorded_rvs}" = "0 81 " ]
	then
		printf '%s\n' "Result: ${PASS} (success_rv=${rv_success}, failure_rv=${rv_failure})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (success_rv=${rv_success}, failure_rv=${rv_failure}, recorded=${recorded_rvs})"
		test_pass=1
	fi

	rm -f "${FINALIZE_RV_FILE}"

	return "${test_pass}"
}

# Verify that invalid callback configuration is rejected before any jobs are
# started.
test_16()
{
	test_16_fail_msg_handler()
	{
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE}"
	}

	test_16_do_job()
	{
		printf 'started\n' > "${JOB_STARTED_FILE}"
		return 0
	}

	# shellcheck disable=SC2034
	local \
		TEST_NUM=16 \
		rv \
		pass_cnt=0 \
		msg_cnt=0 \
		test_pass \
		cb bad_cb \
		\
		SCHED_FINALIZE_CB_def=finalize_handler \
		DO_JOB_CB_def=test_16_do_job \
		JOB_DONE_CB_def=done_handler \
		SCHED_FAIL_MSG_CB_def=test_16_fail_msg_handler \
		\
		cb_list=" \
			SCHED_FINALIZE_CB \
			DO_JOB_CB \
			JOB_DONE_CB \
			SCHED_FAIL_MSG_CB"

	set -- ${cb_list}
	local IFS=" "
	cb_list="${*}"
	IFS=${DEFAULT_IFS}


	print_test_header 16 "Invalid callback configuration" "${cb_list}"

	FAIL_MSG_FILE="/tmp/sched.badcb.msg.${TEST_NUM:?}.$$"
	JOB_STARTED_FILE="/tmp/sched.badcb.job.${TEST_NUM:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	for bad_cb in ${cb_list}
	do
		for cb in ${cb_list}
		do
			if [ "${cb}" = "${bad_cb}" ]; then
				local "${cb}=does_not_exist"
			else
				eval "local ${cb}=\"\${${cb}_def}\""
			fi
		done

		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs '1' &
		wait "$!"
		rv=$?

		[ "${rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	done

	[ -f "${FAIL_MSG_FILE}" ] &&
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")

	if [ "${pass_cnt}" = 4 ] &&
		[ "${msg_cnt}" = 3 ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (passed=${pass_cnt}/4, messages=${msg_cnt})"
		test_pass=1
	fi

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	return "${test_pass}"
}

# Verify that invalid values of SCHED_MAX_JOBS are rejected before any jobs
# are started.
test_17()
{
	test_17_fail_msg_handler()
	{
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE}"
	}

	test_17_do_job()
	{
		printf 'started\n' > "${JOB_STARTED_FILE}"
		return 0
	}

	# SCHED_MAX_JOBS is required (sch_check_uint's 3rd arg); SCHED_TIMEOUT_S
	# and SCHED_IDLE_TIMEOUT_S are optional, so '' is a *valid* value for
	# them (means "use default") and must not be included as a bad value.
	test_17_check_bad_value()
	{
		local var="${1}" bad_val="${2}" rv \
			SCHED_MAX_JOBS=1 \
			SCHED_TIMEOUT_S=3 \
			SCHED_IDLE_TIMEOUT_S=2

		local "${var}=${bad_val}"

		SCHED_FAIL_MSG_CB=test_17_fail_msg_handler \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=test_17_do_job \
			schedule_jobs '1' &

		wait "$!"
		rv=$?

		total_cnt=$((total_cnt + 1))

		[ "${rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	}

	local \
		TEST_NUM=17 \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		test_pass \
		var bad_val

	print_test_header 17 "Invalid scheduler numeric env var values" \
		"SCHED_MAX_JOBS('' abc 0 -1), SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S(abc 0 -1)"

	FAIL_MSG_FILE="/tmp/sched.maxjobs.msg.${TEST_NUM:?}.$$"
	JOB_STARTED_FILE="/tmp/sched.maxjobs.job.${TEST_NUM:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	for bad_val in '' abc 0 -1
	do
		test_17_check_bad_value SCHED_MAX_JOBS "${bad_val}"
	done

	for var in SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S
	do
		for bad_val in abc 0 -1
		do
			test_17_check_bad_value "${var}" "${bad_val}"
		done
	done

	if [ -f "${FAIL_MSG_FILE}" ]
	then
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")
	fi

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ]
	then
		printf '%s\n' "Result: ${PASS} (passed=${pass_cnt}/${total_cnt})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (passed=${pass_cnt}/${total_cnt}, messages=${msg_cnt})"
		test_pass=1
	fi

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	return "${test_pass}"
}


# Verify that JOB_DONE_CB may be empty and that successful execution still
# completes normally.
test_18()
{
	JOB_DONE_CB='' \
	TEST_NUM=18 \
	TEST_NAME='Empty JOB_DONE_CB' \
	TEST_JOBS='ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=2 \
		run_test
}

# Test 19
# Verify that additional arguments passed to schedule_jobs() are forwarded unchanged to DO_JOB_CB after the job ID.
test_19()
{
	test_19_do_job()
	{
		printf '%s\n' "$*" >> "${ARGS_FILE}"
		return 0
	}

	local \
		TEST_NUM=19 \
		rv \
		expected \
		actual \
		test_pass \
		jobs='1 2 3'

	print_test_header 19 "Job callback receives scheduler arguments" \
		"${jobs}"

	ARGS_FILE="/tmp/sched.args.${TEST_NUM:?}.$$"
	rm -f "${ARGS_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_19_do_job \
	JOB_DONE_CB='' \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" foo bar &

	wait "$!"
	rv=$?

	expected=$(cat <<EOF
1 foo bar
2 foo bar
3 foo bar
EOF
)

	actual=
	[ -f "${ARGS_FILE}" ] &&
		actual="$(sort "${ARGS_FILE}")"

	if [ "${rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv})"
		test_pass=1
	fi

	rm -f "${ARGS_FILE}"

	return "${test_pass}"
}

# Large parallelism stress test
# Verify that scheduler enforces SCHED_MAX_JOBS under heavy concurrency
# and that maximum observed parallelism never exceeds the configured limit.
test_20()
{
	test_20_do_job()
	{
		parallel_job_enter

		case $(( $1 % 2 )) in
			0) sleep 0 ;;
			*) sleep 1 ;;
		esac

		parallel_job_leave
	}

	monitor_stress_fifo()
	{
		local active=0 max_active=0 msg \
			result_file="${1:?}"

		while IFS= read -r msg
		do
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

	local TEST_NUM=20
	local \
		rv \
		fifo="/tmp/sched.stress.${TEST_NUM:?}.$$" \
		result_file="/tmp/sched.stress.res.${TEST_NUM:?}.$$" \
		scheduler_pid \
		monitor_pid \
		max_active=0 \
		test_pass \
		jobs \
		i=0 \
		N=300

	print_test_header 20 "Parallelism stress test" "300 jobs"

	rm -f "${fifo}" "${result_file}" &&
	mkfifo "${fifo}" || return 1

	monitor_stress_fifo "${result_file}" < "${fifo}" &
	monitor_pid=$!

	exec 8>"${fifo}"

	# generate large job set
	jobs=
	while [ "${i}" -lt "${N}" ]
	do
		i=$((i + 1))
		jobs="${jobs} ${i}"
	done

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	SCHED_MAX_JOBS=20 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=test_20_do_job \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	exec 8>&-

	wait "${scheduler_pid}"
	rv=$?

	wait "${monitor_pid}"

	if \
		read_first_line max_active "${result_file}" &&
		is_uint "${max_active}" &&
		[ "${rv}" = 0 ] &&
		[ "${max_active}" -le 20 ]
	then
		printf '%s\n' "Result: ${PASS} (max_parallel=${max_active})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, max_parallel=${max_active})"
		test_pass=1
	fi

	rm -f "${fifo}" "${result_file}"

	return "${test_pass}"
}

# Verify that arbitrary DO_JOB_CB return codes are propagated unchanged to
# JOB_DONE_CB and that non-zero job failures do not cause scheduler failure.
test_21()
{
	test_21_do_job()
	{
		return "$1"
	}

	test_21_done_handler()
	{
		printf '%s %s\n' "$1" "$2" >> "${STATUS_FILE}"

		return 0
	}

	local \
		TEST_NUM=21 \
		rv \
		actual \
		expected \
		test_pass \
		jobs='0 1 17 42 99 255'

	print_test_header 21 "DO_JOB_CB return statuses" "${jobs}"

	STATUS_FILE="/tmp/sched.status.${TEST_NUM:?}.$$"

	rm -f "${STATUS_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DONE_HANDLER_CB=test_21_done_handler \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=test_21_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?
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

	if [ "${rv}" = 0 ] &&
		[ "${actual_cnt}" = 6 ] &&
		[ "${actual}" = "${expected}" ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, count=${actual_cnt}, actual=${actual//$'\n'/; })"
		test_pass=1
	fi

	rm -f "${STATUS_FILE}"

	return "${test_pass}"
}

# Verify that removal of the scheduler FIFO during execution is detected and causes scheduler failure.
test_22()
{
	local \
		TEST_NUM=22 \
		rv \
		test_pass \
		scheduler_pid \
		sched_fifo \
		jobs="ok5 ok5"

	print_test_header 22 "FIFO disappearance during execution" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	sched_fifo="/tmp/sched_ipc_${scheduler_pid}"

	sleep 1
	rm -f "${sched_fifo}"

	wait "${scheduler_pid}"
	rv=$?

	if [ "${rv}" = 1 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv})"
		test_pass=1
	fi

	return "${test_pass}"
}

# Verify that the scheduler terminates when the idle timeout
# expires, even though workers are still active and the processing timeout has not
# been reached.
test_23()
{
	test_23_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		[ -n "${TIMEOUT_FILE}" ] &&
			printf '%s\n' "${rv}" > "${TIMEOUT_FILE}"

		return 0
	}

	local \
		TEST_NUM=23 \
		test_pass \
		jobs="ok ok ok hang ok"
	print_test_header 23 "Idle timeout" "${jobs}"

	TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	FINALIZE_HANDLER_CB=test_23_finalize_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"

	if [ "$?" = 81 ] &&
		read_first_line rv "${TIMEOUT_FILE}" &&
		[ "${rv}" = 81 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL}"
		test_pass=1
	fi

	rm -f "${TIMEOUT_FILE}"

	return "${test_pass}"
}

# Verify that the global processing timeout fires based on elapsed time since
# scheduler start, not since the last job completion — i.e. continuous
# progress must not indefinitely postpone it.
test_24()
{
	test_24_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		finalize_handler_default "${rv}" "${pids}" || return $?

		[ -n "${TIMEOUT_FILE}" ] &&
			printf '%s\n' "${rv}" > "${TIMEOUT_FILE}"

		return 0
	}

	local \
		TEST_NUM=24 \
		test_pass \
		jobs="ok ok ok ok ok ok"

	print_test_header 24 "Global timeout despite continuous progress" "${jobs}"

	TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	FINALIZE_HANDLER_CB=test_24_finalize_handler \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=20 \
		schedule_jobs "${jobs}" &

	wait "$!"

	if [ "$?" = 82 ] &&
		read_first_line rv "${TIMEOUT_FILE}" &&
		[ "${rv}" = 82 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL}"
		test_pass=1
	fi

	rm -f "${TIMEOUT_FILE}"

	return "${test_pass}"
}

# Verify that when the global processing timeout and the idle timeout are due
# at the same instant, the global timeout takes priority (if/elif ordering).
test_25()
{
	local \
		TEST_NUM=25 \
		rv \
		test_pass \
		jobs='hang'

	print_test_header 25 "Simultaneous global/idle timeout - global wins" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=2 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = 82 ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, expected 82)"
		test_pass=1
	fi

	return "${test_pass}"
}

# Verify that SCHED_MAX_JOBS greater than the job count never enters the
# concurrency-limiting wait loop, and all jobs still complete normally.
test_26()
{
	TEST_NUM=26 \
	TEST_NAME='SCHED_MAX_JOBS exceeds job count' \
	TEST_JOBS='ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=10 \
		run_test
}

# Verify that SCHED_FINALIZE_CB may be empty and that successful execution
# still completes normally (symmetric to test_18's empty JOB_DONE_CB).
test_27()
{
	SCHED_FINALIZE_CB='' \
	TEST_NUM=27 \
	TEST_NAME='Empty SCHED_FINALIZE_CB' \
	TEST_JOBS='ok ok ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_test
}

# Verify that finalize() removes the scheduler's FIFO after a normal
# (non-error) run, leaving no leaked file behind.
test_28()
{
	local \
		TEST_NUM=28 \
		rv \
		test_pass \
		scheduler_pid \
		sched_fifo \
		jobs='ok ok ok'

	print_test_header 28 "FIFO cleanup after successful completion" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	sched_fifo="/tmp/sched_ipc_${scheduler_pid}"

	wait "${scheduler_pid}"
	rv=$?

	if [ "${rv}" = 0 ] &&
		[ ! -e "${sched_fifo}" ]
	then
		printf '%s\n' "Result: ${PASS} (rv=${rv})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, fifo_exists=$([ -e "${sched_fifo}" ] && echo yes || echo no))"
		test_pass=1
	fi

	return "${test_pass}"
}

# Verify that the caller's original noglob state (glob-enabled or
# glob-disabled) is what DO_JOB_CB, JOB_DONE_CB, and SCHED_FINALIZE_CB
# observe, regardless of schedule_jobs()'s internal set -f handling.
test_29()
{
	test_29_do_job()
	{
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${do_job_glob_file}"
		return 0
	}

	test_29_done_handler()
	{
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${done_glob_file}"
		return 0
	}

	test_29_finalize_handler()
	{
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac > "${finalize_glob_file}"
		return 0
	}

	local \
		TEST_NUM=29 \
		mode \
		expect \
		rv \
		pass_cnt=0 \
		test_pass \
		parent_pre \
		parent_post \
		do_job_glob_file \
		done_glob_file \
		finalize_glob_file \
		do_job_result \
		done_result \
		finalize_result

	print_test_header 29 "noglob state preserved in callbacks" \
		"glob-enabled and glob-disabled callers"

	for mode in glob noglob
	do
		do_job_glob_file="/tmp/sched.globtest.job.${TEST_NUM:?}.$$"
		done_glob_file="/tmp/sched.globtest.done.${TEST_NUM:?}.$$"
		finalize_glob_file="/tmp/sched.globtest.finalize.${TEST_NUM:?}.$$"
		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"

		case "${mode}" in
			glob) set +f; expect=glob ;;
			noglob) set -f; expect=noglob ;;
		esac

		parent_pre="${mode}"

		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=test_29_do_job \
		DONE_HANDLER_CB=test_29_done_handler \
		FINALIZE_HANDLER_CB=test_29_finalize_handler \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs 'ok ok ok' &

		wait "$!"
		rv=$?

		parent_post=glob
		case "${-}" in
			*f*) parent_post=noglob ;;
		esac
		set +f

		do_job_result="$(sort -u "${do_job_glob_file}" 2>/dev/null | tr '\n' ' ')"
		done_result="$(sort -u "${done_glob_file}" 2>/dev/null | tr '\n' ' ')"
		finalize_result="$(cat "${finalize_glob_file}" 2>/dev/null)"

		if [ "${rv}" = 0 ] &&
			[ "${parent_post}" = "${parent_pre}" ] &&
			[ "${do_job_result}" = "${expect} " ] &&
			[ "${done_result}" = "${expect} " ] &&
			[ "${finalize_result}" = "${expect}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'sub-check failed for mode=%s (rv=%s, do_job=%s, done=%s, finalize=%s)\n' \
				"${mode}" "${rv}" "${do_job_result}" "${done_result}" "${finalize_result}" >&2
		fi

		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"
	done

	set +f

	if [ "${pass_cnt}" = 2 ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (passed=${pass_cnt}/2)"
		test_pass=1
	fi

	return "${test_pass}"
}

# Verify job IDs can contain arbitrary non-whitespace characters and are
# passed to DO_JOB_CB/JOB_DONE_CB unchanged.
test_30()
{
	test_30_do_job()
	{
		printf '%s\n' "$1" >> "${ARGS_FILE}"
		sleep 1
		return 0
	}

	test_30_done_handler()
	{
		printf '%s\n' "$1" >> "${DONE_FILE}"
		return 0
	}

	test_30_touch_inject()
	{
		touch "${INJECT_FILE}"
	}

	local \
		TEST_NUM=30 \
		rv \
		expected_do_jobs \
		expected_do_cnt \
		expected_done_cnt \
		actual_do_jobs \
		actual_done_jobs \
		actual_do_cnt=0 \
		actual_done_cnt=0 \
		test_pass \
		jobs=''

	local \
		INJECT_FILE="/tmp/sched.idchars.inject.${TEST_NUM}.$$" \
		ARGS_FILE="/tmp/sched.idchars.args.${TEST_NUM}.$$" \
		DONE_FILE="/tmp/sched.idchars.done.${TEST_NUM}.$$"

	# Glob/quote/injection-shaped characters. Multi-line literal (not a
	# bash array); whitespace from continuation/indentation is stripped
	# below.

	jobs="
		plain1 \
		star*id \
		quest?id \
		brk[et]s \
		brace{d} \
		paren(ed) \
		dollarsign\$x \
		backtick\`x\` \
		semi;colon \
		pipe|line \
		amp&and \
		ltgt<>x \
		eqsign=x \
		hashtag#x \
		bangmark!x \
		tildeish~x \
		atsign@x \
		carethat^x \
		percentsign%x \
		colonok:x \
		dotdot.x \
		commasep,x \
		apos'trophe \
		dquo\"te \
		bslash\\x \
		cmdsub\$(test_30_touch_inject) \
		subshelltick\`test_30_touch_inject\` \
		semiexec;test_30_touch_inject \
		andexec&&test_30_touch_inject \
		pipeexec|test_30_touch_inject \
	"

	jobs="${jobs//[$'\n'$'\t']/}"

	print_test_header 30 "Arbitrary characters in job IDs" \
		"30 IDs covering glob/quote/injection-shaped characters"

	rm -f "${ARGS_FILE}" "${DONE_FILE}" "${INJECT_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_30_do_job \
	JOB_DONE_CB=test_30_done_handler \
	SCHED_MAX_JOBS=5 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv=$?

	if [ "${rv}" = 0 ] &&
		verify_recorded_set expected_do_jobs  actual_do_jobs   expected_do_cnt   actual_do_cnt   "${ARGS_FILE}" "${jobs}" &&
		verify_recorded_set        _          actual_done_jobs expected_done_cnt actual_done_cnt "${DONE_FILE}" "${jobs}" &&
		[ ! -e "${INJECT_FILE}" ]
	then
		printf '%s\n' "Result: ${PASS} (jobs=${actual_do_cnt})"
		test_pass=0
	else
		printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
			"Result: ${FAIL} (rv=${rv})" \
			"expected_do_cnt=${expected_do_cnt}, actual_do_cnt=${actual_do_cnt}" \
			"expected_done_cnt=${expected_done_cnt}, actual_done_cnt=${actual_done_cnt}" \
			"inject_marker_exists=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)" \
			"" \
			"expected jobs:" \
			"${expected_do_jobs}" \
			"" \
			"actual_do_jobs:" \
			"${actual_do_jobs}" \
			"" \
			"actual_done_jobs:" \
			"${actual_done_jobs}"
		test_pass=1
	fi

	rm -f "${ARGS_FILE}" "${DONE_FILE}" "${INJECT_FILE}"

	return "${test_pass}"
}

# Verify forged completion records (glob "*", or shell-injection-shaped
# IDs) are rejected as unknown/malformed, never accepted or executed.
test_31()
{
	test_31_touch_inject()
	{
		touch "${INJECT_FILE}"
	}

	test_31_do_job()
	{
		local self_pid

		get_test_pid self_pid || return 1
		printf '%s %s %s\n' "${self_pid}" 0 "${SPOOF_DONE_ID:?}" >&3
		sleep 1

		return 0
	}

	test_31_fail_msg_handler()
	{
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE}"
	}

	test_31_check_forgery()
	{
		local job_id="${1:?}" spoof_id="${2:?}" rv

		rm -f "${INJECT_FILE}"

		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=test_31_do_job \
		SCHED_FAIL_MSG_CB=test_31_fail_msg_handler \
		SPOOF_DONE_ID="${spoof_id}" \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=5 \
		SCHED_IDLE_TIMEOUT_S=5 \
			schedule_jobs "${job_id}" &

		wait "$!"
		rv=$?

		total_cnt=$((total_cnt + 1))

		if [ "${rv}" = 1 ] &&
			[ ! -e "${INJECT_FILE}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'sub-check failed for job_id=%s spoof_id=%s (rv=%s, inject_marker_exists=%s)\n' \
				"${job_id}" "${spoof_id}" "${rv}" \
				"$([ -e "${INJECT_FILE}" ] && echo yes || echo no)" >&2
		fi
	}

	local \
		TEST_NUM=31 \
		pass_cnt=0 \
		total_cnt=0 \
		test_pass \
		msg_cnt=0

	local \
		INJECT_FILE="/tmp/sched.forge.inject.${TEST_NUM}.$$" \
		FAIL_MSG_FILE="/tmp/sched.forge.msg.${TEST_NUM}.$$"

	print_test_header 31 "Job-ID forgery / injection resistance" \
		"spoofed completion records with glob and shell-metacharacter IDs"

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	test_31_check_forgery "realjob" "*"
	test_31_check_forgery "realjob" "\$(test_31_touch_inject)"
	test_31_check_forgery "realjob" "\`test_31_touch_inject\`"
	test_31_check_forgery "realjob" ";test_31_touch_inject"

	[ -f "${FAIL_MSG_FILE}" ] &&
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ]
	then
		printf '%s\n' "Result: ${PASS} (passed=${pass_cnt}/${total_cnt})"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (passed=${pass_cnt}/${total_cnt}, messages=${msg_cnt})"
		test_pass=1
	fi

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	return "${test_pass}"
}

# Verify that additional arguments passed to schedule_jobs() preserve exact
# argument boundaries and content when forwarded to DO_JOB_CB - an
# empty-string arg, an arg with embedded whitespace, a glob-metacharacter
# arg, and a leading-dash arg - regardless of caller noglob state.
test_32()
{
	test_32_do_job()
	{
		local id="${1}" rec

		shift

		rec="${id} $# $(
			for arg in "$@"; do
				printf '<%s>\037' "${arg//$'\n'/$'\035'}"
			done
		)"
		printf '%s\n' "${rec}" >> "${ARGS_FILE}"

		return 0
	}

	local \
		TEST_NUM=32 \
		rv \
		expected \
		actual \
		test_pass \
		jobs='1 2 3'

	local ARGS_FILE="/tmp/sched.args32.${TEST_NUM:?}.$$"

	print_test_header 32 "Extra-argument boundary/content integrity" \
		"${jobs}"

	rm -f "${ARGS_FILE}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_32_do_job \
	JOB_DONE_CB='' \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" '' 'a b' '*' '-x' c$'\n'd &

	wait "$!"
	rv=$?

	expected="$(
		for id in 1 2 3
		do
			printf '%s 5 <>\037<a b>\037<*>\037<-x>\037<c\035d>\037\n' \
				"${id}"
		done
	)"

	actual=
	[ -f "${ARGS_FILE}" ] &&
		actual="$(sort "${ARGS_FILE}")"

	if [ "${rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' \
			"Result: ${FAIL} (rv=${rv})" \
			"expected:" \
			"'${expected}'" \
			"actual:" \
			"'${actual}'"

		if command -v hexdump 1>/dev/null; then
			printf 'expected (hex):\n'
			printf '%s' "${expected}" | hexdump
			printf 'actual (hex):\n'
			printf '%s' "${actual}" | hexdump
		else
			printf '%s\n' "Can not show expected vs actual hex because hexdump util is not found."
		fi

		test_pass=1
	fi

	rm -f "${ARGS_FILE}"

	return "${test_pass}"
}

# Verify that SIGINT and SIGTERM both terminate the scheduler with SCHED_RV_INT_TERM,
# and that the finalize callback receives that rv plus a non-empty running-PID list.
test_33()
{
	test_33_finalize_handler()
	{
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIG_RV_FILE}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIG_PIDS_FILE}"
		fi

		finalize_handler_default "${rv}" "${pids}"
	}

	local \
		TEST_NUM=33 \
		sig \
		rv \
		expect_rv=84 \
		callback_rv \
		pids \
		schedule_pid \
		test_pass \
		all_ok=1

	local \
		SIG_RV_FILE="/tmp/sched.sigintterm.rv.${TEST_NUM:?}.$$" \
		SIG_PIDS_FILE="/tmp/sched.sigintterm.pids.${TEST_NUM:?}.$$"

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		FINALIZE_HANDLER_CB=test_33_finalize_handler \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=10 \
		SCHED_IDLE_TIMEOUT_S=5

	print_test_header 33 "SIGINT/SIGTERM termination" "1 2"

	for sig in INT TERM
	do
		rm -f "${SIG_RV_FILE}" "${SIG_PIDS_FILE}"

		case "${sig}" in
			TERM)
				# Send TERM signal to background scheduler process
				(
					schedule_jobs 'hang hang' &
					schedule_pid=$!

					sleep 1

					kill "-${sig}" "${schedule_pid}"

					wait "${schedule_pid}"
				)
				;;
			INT)
				# Send INT signal to foreground scheduler process
				(
					local pid killer_pid

					get_test_pid pid
					(
						sleep 1
						kill "-${sig}" "$pid"
					) &
					killer_pid=${!}

					trap 'kill "${killer_pid}" 2>/dev/null' EXIT

					schedule_jobs 'hang hang'
				)
		esac

		rv=$?

		read_first_line pids "${SIG_PIDS_FILE}"

		if [ "${rv}" = "${expect_rv}" ] &&
			read_first_line callback_rv "${SIG_RV_FILE}" &&
			[ "${callback_rv}" = "${expect_rv}" ] &&
			[ -n "${pids}" ]
		then
			printf 'SIG%s: %s\n' "${sig}" "${PASS}"
		else
			all_ok=0
			printf 'SIG%s: %s (expect_rv=%s, rv=%s, callback_rv=%s, pids=%s)\n' \
				"${sig}" "${FAIL}" "${expect_rv}" "${rv}" "${callback_rv}" "${pids}"
		fi
	done

	if [ "${all_ok}" = 1 ]
	then
		printf '%s\n' "Result: ${PASS}"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL}"
		test_pass=1
	fi

	rm -f "${SIG_RV_FILE}" "${SIG_PIDS_FILE}"

	return "${test_pass}"
}

# Verify that the idle timeout correctly accounts for time elapsed during job completion callbacks,
# rather than resetting to the full IDLE_TIMEOUT_S.
test_34()
{
	test_34_done_handler()
	{
		# Artificially delay the callback to consume a portion of the idle timeout before the next read -t call.
		sleep 3
		return 0
	}

	local \
		TEST_NUM=34 \
		rv \
		start_time \
		end_time \
		elapsed \
		test_pass \
		jobs="instant hang"

	print_test_header 34 "Idle timeout accounts for elapsed callback time" "${jobs}"

	start_time=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	DONE_HANDLER_CB=test_34_done_handler \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &
	wait "$!"
	rv=$?

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	# instant takes 0s, callback takes 3s (total 3s elapsed since start).
	# Remaining idle timeout is 2s. Expected total ~5s. Adding 1s margin.
	if [ "${rv}" = 81 ] && [ "${elapsed}" -le 6 ]
	then
		printf '%s\n' "Result: ${PASS} (elapsed=${elapsed}s)"
		test_pass=0
	else
		printf '%s\n' "Result: ${FAIL} (rv=${rv}, elapsed=${elapsed}s, expected <= 6s)"
		test_pass=1
	fi

	return "${test_pass}"
}


#
# Inline test code starts here.
#

NL=$'\n'
DEFAULT_IFS=$'\t'" ${NL}"
IFS="${DEFAULT_IFS}"

set_ansi

PASS="${green}PASS${n_c}"
FAIL="${red}FAIL${n_c}"


RUN_TESTS="${*}"

if [ -n "${RUN_TESTS}" ]; then
	printf 'Scheduler tests\n'

	TESTS_RUN=0
	TESTS_PASSED=0

	[ "${RUN_TESTS}" = "run" ] &&
		RUN_TESTS="$(seq 1 34)"

	for RUN_TEST in ${RUN_TESTS}; do
		TESTS_RUN=$((TESTS_RUN + 1))

		if "test_${RUN_TEST}"
		then
			TESTS_PASSED=$((TESTS_PASSED + 1))
		fi
	done

	printf '\n%s\n' "== ${purple}Summary${n_c} =="
	printf 'Ran: %s, Passed: %s, Failed: %s\n' \
		"${TESTS_RUN}" "${TESTS_PASSED}" "$((TESTS_RUN - TESTS_PASSED))"
fi

:
