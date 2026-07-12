#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# Supported script arguments:
# [no arguments] - do nothing (for sourcing the script)
# 'run' - run all tests
# 'run <space_separated_list_of_numbers>' - e.g. 'run 1 3 55'
# 'run <test_num_start>-<test_num_end>' - run tests in a range, e.g. 'run 33-44'

# scheduler-tests.sh

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "${script_dir}/scheduler.sh"


#
# Testing infrastructure functions
#

PASS() {
	printf '%s\n' "Result: ${green}PASS${n_c}${1:+" ("}${1}${1:+")"}"
}

FAIL() {
	printf '%s\n' "Result: ${red}FAIL${n_c}${1:+" ("}${1}${1:+")"}"
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
	printf '\n%s\n' "== ${purple}Test ${1}: ${2}${n_c} =="
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
verify_id_set() {
	local \
		vis_expected_var="${1:?}" \
		vis_actual_var="${2:?}" \
		vis_expected \
		vis_actual

	vis_expected="$(printf '%s\n' "${3//[ 	]/$'\n'}" | sed '/^$/d' | sort -u)"
	vis_actual="$(printf '%s\n' "${4//[ 	]/$'\n'}" | sed '/^$/d' | sort -u)"

	export -n \
		"${vis_expected_var}=${vis_expected}" \
		"${vis_actual_var}=${vis_actual}"

	[ "${vis_expected}" = "${vis_actual}" ]
}

# Write each whitespace-separated ID-set arg to its own file at "${1}.<suffix>".
# 1: file prefix
# 2: ok_ids  3: fail_ids  4: unfinished_ids  5: undispatched_ids
write_id_sets() {
	local wis_prefix="${1:?}"

	printf '%s\n' "${2}" > "${wis_prefix}.ok"
	printf '%s\n' "${3}" > "${wis_prefix}.fail"
	printf '%s\n' "${4}" > "${wis_prefix}.unfinished"
	printf '%s\n' "${5}" > "${wis_prefix}.undispatched"
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
	
	print_test_header "${TEST_NUM:?}" "${TEST_NAME:?}" "${TEST_JOBS:?}"

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
# Test functions
#


# Verify the scheduler succeeds and calls JOB_DONE_CB for every job, even when one fails.
test_1() {
	TEST_NUM=1 \
	TEST_NAME='Normal completion with failure status propagation' \
	TEST_JOBS='ok1 ok2 fail' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler terminates on idle timeout while a job is still running.
test_2() {
	TEST_NUM=2 \
	TEST_NAME='Idle timeout' \
	TEST_JOBS='ok ok hang' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler times out when a worker exits without sending a completion record.
test_3() {
	TEST_NUM=3 \
	TEST_NAME='Child crash before completion record' \
	TEST_JOBS='ok crash' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler treats malformed completion records as an error.
test_4() {
	TEST_NUM=4 \
	TEST_NAME='Malformed completion record' \
	TEST_JOBS='malformed' \
	TEST_EXPECT_RV=1 \
	TEST_SCHED_MAX_JOBS=1 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler never runs more than SCHED_MAX_JOBS workers at once.
test_5() {
	TEST_NUM=5 \
	TEST_NAME='Parallelism limit' \
	TEST_JOBS='1 2 3 4 5' \
	TEST_SCHED_MAX_JOBS=3 \
	TEST_EXPECT_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_parallelism_test
}

# Verify SCHED_MAX_JOBS=1 causes jobs to execute strictly sequentially.
test_6() {
	TEST_NUM=6 \
	TEST_NAME='Single worker mode' \
	TEST_JOBS='1 2 3 4' \
	TEST_SCHED_MAX_JOBS=1 \
	TEST_EXPECT_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=7 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_parallelism_test
}

# Verify the scheduler succeeds and all JOB_DONE_CB callbacks run when every job succeeds.
test_7() {
	TEST_NUM=7 \
	TEST_NAME='All jobs succeed' \
	TEST_JOBS='ok ok ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify a failing JOB_DONE_CB causes the scheduler to terminate with an error.
test_8() {
	test_8_done_handler() {
		echo "done idx='$1' rv='$2'"

		if [ "$2" != 0 ]
		then
			printf 'fail_seen\n' > "${FAILPROP_FILE:?}"
			return "${TEST_8_DONE_HANDLER_RV:?}"
		fi

		return 0
	}

	local sched_rv failprop_msg \
		TEST_NUM=8 \
		TEST_8_DONE_HANDLER_RV=99 \
		jobs="ok fail"

	local FAILPROP_FILE="/tmp/sched.failprop.${TEST_NUM:?}.$$"
	rm -f "${FAILPROP_FILE}"

	print_test_header 8 "Failure status propagation to done_handler" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_8_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line failprop_msg "${FAILPROP_FILE}"
	rm -f "${FAILPROP_FILE}"

	if [ "${sched_rv}" = "${TEST_8_DONE_HANDLER_RV}" ] &&
		[ "${failprop_msg}" = "fail_seen" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify job completion triggers dispatch of the next queued job until all jobs run.
test_9() {
	test_9_do_job() {
		sleep 1
	}

	test_9_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${DONE_COUNT_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=9 \
		sched_rv \
		expected_cnt \
		actual_done_jobs \
		done_cnt=0 \
		jobs="1 2 3 4 5"

	local DONE_COUNT_FILE="/tmp/sched.queue.${TEST_NUM:?}.$$"
	rm -f "${DONE_COUNT_FILE}"

	print_test_header 9 "Queue refill" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_9_done_handler \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_9_do_job \
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
test_10() {
	test_10_do_job() {
		sleep 0
	}

	test_10_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${DONE_COUNT_FILE:?}"

		return 0
	}

	test_10_finalize_handler() {
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
		TEST_NUM=10 \
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

	print_test_header 10 "Large job count" "100 jobs"

	jobs=$(seq 1 100)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_10_finalize_handler \
	JOB_DONE_CB=test_10_done_handler \
	SCHED_MAX_JOBS=10 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=2 \
	DO_JOB_CB=test_10_do_job \
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

# Verify the global timeout fires while workers are active and idle timeout hasn't elapsed.
test_11() {
	test_11_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=11 \
		sched_rv \
		timeout_rv \
		jobs="ok hang"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header 11 "Processing timeout" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_11_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	local sched_rv=$?

	read_first_line timeout_rv "${TIMEOUT_FILE}"
	rm -f "${TIMEOUT_FILE}"

	if [ "${sched_rv}" = 82 ] &&
		[ "${timeout_rv}" = 82 ]
	then
		PASS "timeout_rv=${timeout_rv}"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify an empty job list succeeds, calls no JOB_DONE_CB, and finalizes with empty PIDs.
test_12() {
	test_12_done_handler() {
		echo "done idx='$1' rv='$2'"

		printf '%s\n' "$1" >> "${EMPTY_DONE_FILE:?}"

		return 0
	}

	test_12_finalize_handler() {
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
		TEST_NUM=12 \
		sched_rv \
		actual_done_cnt=0 \
		finalize_state='' \
		jobs="<none>"

	local \
		EMPTY_DONE_FILE="/tmp/sched.empty.done.${TEST_NUM:?}.$$" \
		EMPTY_FINALIZE_FILE="/tmp/sched.empty.finalize.${TEST_NUM:?}.$$"

	rm -f "${EMPTY_DONE_FILE}" "${EMPTY_FINALIZE_FILE}"

	print_test_header 12 "Empty job list" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_12_finalize_handler \
	JOB_DONE_CB=test_12_done_handler \
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

# Verify SIGUSR1 terminates the scheduler, SCHED_FINALIZE_CB gets a non-empty PID list,
#   and kills the workers.
test_13() {
	test_13_finalize_handler() {
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIGUSR1_RV_FILE:?}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIGUSR1_PIDS_FILE:?}"
		fi

		finalize_handler "${rv}" "${pids}"
	}

	local \
		TEST_NUM=13 \
		sched_rv \
		callback_rv \
		pids='' \
		schedule_pid

	local \
		SIGUSR1_RV_FILE="/tmp/sched.sigusr1.rv.${TEST_NUM:?}.$$" \
		SIGUSR1_PIDS_FILE="/tmp/sched.sigusr1.pids.${TEST_NUM:?}.$$"

	rm -f "${SIGUSR1_RV_FILE}" "${SIGUSR1_PIDS_FILE}"

	print_test_header 13 "SIGUSR1 termination" "1 2"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_13_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs 'hang hang' &

	schedule_pid=$!

	sleep 1

	kill -USR1 "${schedule_pid}"

	wait "${schedule_pid}"
	sched_rv=$?

	read_first_line pids "${SIGUSR1_PIDS_FILE}"
	read_first_line callback_rv "${SIGUSR1_RV_FILE}"

	rm -f "${SIGUSR1_RV_FILE}" "${SIGUSR1_PIDS_FILE}"

	if [ "${sched_rv}" = 83 ] &&
		[ "${callback_rv}" = 83 ] &&
		[ -n "${pids}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, callback_rv=${callback_rv}, pids=${pids}"
		return 1
	fi
}

# Verify a lost completion record with another worker still active causes an idle timeout.
test_14() {
	local \
		TEST_NUM=14 \
		sched_rv \
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
	sched_rv=$?

	if [ "${sched_rv}" = 81 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 81"
		return 1
	fi
}

# Verify a failing SCHED_FINALIZE_CB overrides rv=0 but not an existing scheduler error.
test_15() {
	test_15_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" >> "${FINALIZE_RV_FILE}"

		return "${TEST_15_FINALIZE_RV:?}"
	}

	local \
		TEST_NUM=15 \
		rv_success \
		rv_failure \
		recorded_rvs \
		TEST_15_FINALIZE_RV=97

	print_test_header 15 "Failure of SCHED_FINALIZE_CB" \
		"success path and error path"

	FINALIZE_RV_FILE="/tmp/sched.finalize.fail.${TEST_NUM:?}.$$"

	rm -f "${FINALIZE_RV_FILE}"

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=test_15_finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default

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

	rm -f "${FINALIZE_RV_FILE}"

	if [ "${rv_success}" = "${TEST_15_FINALIZE_RV}" ] &&
		[ "${rv_failure}" = 81 ] &&
		[ "${recorded_rvs}" = "0 81 " ]
	then
		PASS "success_rv=${rv_success}, failure_rv=${rv_failure}"
		return 0
	else
		FAIL "success_rv=${rv_success}, failure_rv=${rv_failure}, recorded=${recorded_rvs}"
		return 1
	fi
}

# Verify invalid callback configuration is rejected before any jobs start.
test_16() {
	test_16_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	test_16_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# shellcheck disable=SC2034
	local \
		TEST_NUM=16 \
		sched_rv \
		pass_cnt=0 \
		msg_cnt=0 \
		cb bad_cb \
		\
		SCHED_FINALIZE_CB_def=finalize_handler \
		DO_JOB_CB_def=test_16_do_job \
		JOB_DONE_CB_def=done_handler \
		SCHED_FAIL_MSG_CB_def=test_16_fail_msg_handler

	local \
		FAIL_MSG_FILE="/tmp/sched.badcb.msg.${TEST_NUM:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.badcb.job.${TEST_NUM:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	local \
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

	for bad_cb in ${cb_list}; do
		for cb in ${cb_list}; do
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
		sched_rv=$?

		[ "${sched_rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	done

	[ -f "${FAIL_MSG_FILE}" ] &&
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	if [ "${pass_cnt}" = 4 ] &&
		[ "${msg_cnt}" = 3 ]
	then
		PASS
		return 0
	else
		FAIL "passed=${pass_cnt}/4, messages=${msg_cnt}"
		return 1
	fi
}

# Verify invalid scheduler numeric env vars are rejected before any jobs start.
test_17() {
	test_17_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	test_17_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# SCHED_MAX_JOBS is required (sch_check_uint's 3rd arg); SCHED_TIMEOUT_S
	# and SCHED_IDLE_TIMEOUT_S are optional, so '' is a *valid* value for
	# them (means "use default") and must not be included as a bad value.
	test_17_check_bad_value() {
		local var="${1}" bad_val="${2}" sched_rv \
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
		sched_rv=$?

		total_cnt=$((total_cnt + 1))

		[ "${sched_rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	}

	local \
		TEST_NUM=17 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		var bad_val

	local \
		FAIL_MSG_FILE="/tmp/sched.maxjobs.msg.${TEST_NUM:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.maxjobs.job.${TEST_NUM:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	print_test_header 17 "Invalid scheduler numeric env var values" \
		"SCHED_MAX_JOBS('' abc 0 -1), SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S(abc 0 -1)"

	for bad_val in '' abc 0 -1; do
		test_17_check_bad_value SCHED_MAX_JOBS "${bad_val}"
	done

	for var in SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S; do
		for bad_val in abc 0 -1; do
			test_17_check_bad_value "${var}" "${bad_val}"
		done
	done

	if [ -f "${FAIL_MSG_FILE}" ]
	then
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")
	fi

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ]
	then
		PASS "passed=${pass_cnt}/${total_cnt}"
		return 0
	else
		FAIL "passed=${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 1
	fi
}


# Verify JOB_DONE_CB may be empty and the scheduler still completes normally.
test_18() {
	JOB_DONE_CB='' \
	SCHED_FINALIZE_CB=finalize_handler \
	TEST_NUM=18 \
	TEST_NAME='Empty JOB_DONE_CB' \
	TEST_JOBS='ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=2 \
		run_generic_test
}

# Verify extra args to schedule_jobs() are forwarded unchanged to DO_JOB_CB after the job ID.
test_19() {
	test_19_do_job() {
		printf '%s\n' "$*" >> "${ARGS_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=19 \
		sched_rv \
		expected \
		actual \
		jobs='1 2 3'

	local ARGS_FILE="/tmp/sched.args.${TEST_NUM:?}.$$"
	rm -f "${ARGS_FILE}"

	print_test_header 19 "Job callback receives scheduler arguments" \
		"${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_19_do_job \
	JOB_DONE_CB='' \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" foo bar &

	wait "$!"
	sched_rv=$?

	expected=$(cat <<EOF
1 foo bar
2 foo bar
3 foo bar
EOF
)

	actual=
	[ -f "${ARGS_FILE}" ] &&
		actual="$(sort "${ARGS_FILE}")"

	rm -f "${ARGS_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify SCHED_MAX_JOBS caps concurrency under heavy load (300 jobs).
test_20() {
	test_20_do_job() {
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

	local TEST_NUM=20
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

	print_test_header 20 "Parallelism stress test" "300 jobs"

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
	DO_JOB_CB=test_20_do_job \
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

# Verify arbitrary DO_JOB_CB return codes reach JOB_DONE_CB unchanged without failing the scheduler.
test_21() {
	test_21_do_job() {
		return "$1"
	}

	test_21_done_handler() {
		printf '%s %s\n' "$1" "$2" >> "${STATUS_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=21 \
		sched_rv \
		actual \
		expected \
		jobs='0 1 17 42 99 255'

	local STATUS_FILE="/tmp/sched.status.${TEST_NUM:?}.$$"
	rm -f "${STATUS_FILE}"

	print_test_header 21 "DO_JOB_CB return statuses" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_21_done_handler \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=test_21_do_job \
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

# Verify removing the scheduler FIFO during execution causes scheduler failure.
test_22() {
	local \
		TEST_NUM=22 \
		sched_rv \
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
	sched_rv=$?

	if [ "${sched_rv}" = 1 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify idle timeout fires while workers are active and processing timeout hasn't elapsed.
test_23() {
	test_23_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=23 \
		timeout_rv \
		jobs="ok ok ok hang ok"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header 23 "Idle timeout" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_23_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	local sched_rv=$?

	read_first_line timeout_rv "${TIMEOUT_FILE}"
	rm -f "${TIMEOUT_FILE}"

	if [ "${sched_rv}" = 81 ] &&
		[ "${timeout_rv}" = 81 ]
	then
		PASS "timeout_rv=${timeout_rv}"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify the global timeout fires from scheduler start time, not from the last job completion.
test_24() {
	test_24_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=24 \
		timeout_rv \
		jobs="ok ok ok ok ok ok"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_NUM:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header 24 "Global timeout despite continuous progress" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_24_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=20 \
		schedule_jobs "${jobs}" &

	wait "$!"
	local sched_rv=$?

	read_first_line timeout_rv "${TIMEOUT_FILE}"
	rm -f "${TIMEOUT_FILE}"

	if [ "${sched_rv}" = 82 ] &&
		[ "${timeout_rv}" = 82 ]
	then
		PASS "timeout_rv=${timeout_rv}"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify the global timeout takes priority when it and the idle timeout are due simultaneously.
test_25() {
	local \
		TEST_NUM=25 \
		sched_rv \
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
	sched_rv=$?

	if [ "${sched_rv}" = 82 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 82"
		return 1
	fi
}

# Verify SCHED_MAX_JOBS greater than the job count still completes all jobs normally.
test_26() {
	TEST_NUM=26 \
	TEST_NAME='SCHED_MAX_JOBS exceeds job count' \
	TEST_JOBS='ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=10 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify SCHED_FINALIZE_CB may be empty and the scheduler still completes normally
#   (test_18).
test_27() {
	SCHED_FINALIZE_CB='' \
	JOB_DONE_CB=done_handler \
	TEST_NUM=27 \
	TEST_NAME='Empty SCHED_FINALIZE_CB' \
	TEST_JOBS='ok ok ok ok ok' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_generic_test
}

# Verify finalize() removes the scheduler's FIFO after a normal run, no leaked file.
test_28() {
	local \
		TEST_NUM=28 \
		sched_rv \
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
	sched_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		[ ! -e "${sched_fifo}" ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, fifo_exists=$([ -e "${sched_fifo}" ] && echo yes || echo no)"
		return 1
	fi
}

# Verify DO_JOB_CB, JOB_DONE_CB, and SCHED_FINALIZE_CB observe the caller's noglob state.
test_29() {
	test_29_do_job() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${do_job_glob_file}"
		return 0
	}

	test_29_done_handler() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${done_glob_file}"
		return 0
	}

	test_29_finalize_handler() {
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

	print_test_header 29 "noglob state preserved in callbacks" \
		"glob-enabled and glob-disabled callers"

	for mode in glob noglob; do
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
		SCHED_FINALIZE_CB=test_29_finalize_handler \
		JOB_DONE_CB=test_29_done_handler \
		DO_JOB_CB=test_29_do_job \
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

# Verify job IDs with arbitrary non-whitespace chars reach DO_JOB_CB/JOB_DONE_CB unchanged.
test_30() {
	test_30_do_job() {
		printf '%s\n' "$1" >> "${ARGS_FILE:?}"
		sleep 1
		return 0
	}

	test_30_done_handler() {
		printf '%s\n' "$1" >> "${DONE_FILE:?}"
		return 0
	}

	test_30_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	local \
		TEST_NUM=30 \
		sched_rv \
		expected_do_jobs \
		expected_do_cnt \
		expected_done_cnt \
		actual_do_jobs \
		actual_done_jobs \
		actual_do_cnt=0 \
		actual_done_cnt=0 \
		jobs=''

	local \
		INJECT_FILE="/tmp/sched.idchars.inject.${TEST_NUM}.$$" \
		ARGS_FILE="/tmp/sched.idchars.args.${TEST_NUM}.$$" \
		DONE_FILE="/tmp/sched.idchars.done.${TEST_NUM}.$$"

	rm -f "${ARGS_FILE}" "${DONE_FILE}" "${INJECT_FILE}"

	# Glob/quote/injection-shaped chars. Multi-line literal, not a bash array; whitespace
	#   from continuation/indentation is stripped below.

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

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_30_do_job \
	JOB_DONE_CB=test_30_done_handler \
	SCHED_MAX_JOBS=5 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		verify_recorded_set expected_do_jobs  actual_do_jobs   expected_do_cnt   actual_do_cnt   "${ARGS_FILE}" "${jobs}" &&
		verify_recorded_set        _          actual_done_jobs expected_done_cnt actual_done_cnt "${DONE_FILE}" "${jobs}" &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${ARGS_FILE}" "${DONE_FILE}" "${INJECT_FILE}"
		PASS "jobs=${actual_do_cnt}"
		return 0
	else
		rm -f "${ARGS_FILE}" "${DONE_FILE}" "${INJECT_FILE}"
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
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
		return 1
	fi
}

# Verify forged completion records (glob/injection-shaped IDs) are rejected, never executed.
test_31() {
	test_31_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	test_31_do_job() {
		local self_pid

		get_test_pid self_pid || return 1
		printf '%s %s %s\n' "${self_pid}" 0 "${SPOOF_DONE_ID:?}" >&3
		sleep 1

		return 0
	}

	test_31_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	test_31_check_forgery() {
		local job_id="${1:?}" spoof_id="${2:?}" sched_rv

		rm -f "${INJECT_FILE:?}"

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
		sched_rv=$?

		total_cnt=$((total_cnt + 1))

		if [ "${sched_rv}" = 1 ] &&
			[ ! -e "${INJECT_FILE}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'sub-check failed for job_id=%s spoof_id=%s (sched_rv=%s, inject_marker_exists=%s)\n' \
				"${job_id}" "${spoof_id}" "${sched_rv}" \
				"$([ -e "${INJECT_FILE}" ] && echo yes || echo no)" >&2
		fi
	}

	local \
		TEST_NUM=31 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0

	local \
		INJECT_FILE="/tmp/sched.forge.inject.${TEST_NUM}.$$" \
		FAIL_MSG_FILE="/tmp/sched.forge.msg.${TEST_NUM}.$$"

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	print_test_header 31 "Job-ID forgery / injection resistance" \
		"spoofed completion records with glob and shell-metacharacter IDs"

	test_31_check_forgery "realjob" "*"
	test_31_check_forgery "realjob" "\$(test_31_touch_inject)"
	test_31_check_forgery "realjob" "\`test_31_touch_inject\`"
	test_31_check_forgery "realjob" ";test_31_touch_inject"

	[ -f "${FAIL_MSG_FILE}" ] &&
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ]
	then
		PASS "passed=${pass_cnt}/${total_cnt}"
		return 0
	else
		FAIL "passed=${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 1
	fi
}

# Verify extra args to schedule_jobs() reach DO_JOB_CB with exact boundaries/content intact:
#   empty string, embedded whitespace, glob metacharacters, leading dash.
test_32() {
	test_32_do_job() {
		local id="${1}" rec

		shift

		rec="${id} $# $(
			for arg in "$@"; do
				printf '<%s>\037' "${arg//$'\n'/$'\035'}"
			done
		)"
		printf '%s\n' "${rec}" >> "${ARGS_FILE:?}"

		return 0
	}

	local \
		TEST_NUM=32 \
		sched_rv \
		expected \
		actual \
		jobs='1 2 3'

	local ARGS_FILE="/tmp/sched.args32.${TEST_NUM:?}.$$"
	rm -f "${ARGS_FILE}"

	print_test_header 32 "Extra-argument boundary/content integrity" \
		"${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=test_32_do_job \
	JOB_DONE_CB='' \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" '' 'a b' '*' '-x' c$'\n'd &

	wait "$!"
	sched_rv=$?

	expected="$(
		for id in 1 2 3; do
			printf '%s 5 <>\037<a b>\037<*>\037<-x>\037<c\035d>\037\n' \
				"${id}"
		done
	)"

	actual=
	[ -f "${ARGS_FILE}" ] &&
		actual="$(sort "${ARGS_FILE}")"

	rm -f "${ARGS_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n' \
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

		return 1
	fi
}

# Verify SIGINT/SIGTERM terminate the scheduler with SCHED_RV_INT_TERM and a non-empty PID list.
test_33() {
	test_33_finalize_handler() {
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIG_RV_FILE:?}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIG_PIDS_FILE:?}"
		fi

		finalize_handler "${rv}" "${pids}"
	}

	local \
		TEST_NUM=33 \
		sig \
		sched_rv \
		expect_rv=84 \
		callback_rv \
		pids \
		schedule_pid \
		all_ok=1

	local \
		SIG_RV_FILE="/tmp/sched.sigintterm.rv.${TEST_NUM:?}.$$" \
		SIG_PIDS_FILE="/tmp/sched.sigintterm.pids.${TEST_NUM:?}.$$"

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=test_33_finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=10 \
		SCHED_IDLE_TIMEOUT_S=5

	print_test_header 33 "SIGINT/SIGTERM termination" "1 2"

	for sig in INT TERM; do
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

		sched_rv=$?

		read_first_line pids "${SIG_PIDS_FILE}"

		if [ "${sched_rv}" = "${expect_rv}" ] &&
			read_first_line callback_rv "${SIG_RV_FILE}" &&
			[ "${callback_rv}" = "${expect_rv}" ] &&
			[ -n "${pids}" ]
		then
			printf 'SIG%s: %s\n' "${sig}" "${PASS}"
		else
			all_ok=0
			printf 'SIG%s: %s (expect_rv=%s, sched_rv=%s, callback_rv=%s, pids=%s)\n' \
				"${sig}" "${FAIL}" "${expect_rv}" "${sched_rv}" "${callback_rv}" "${pids}"
		fi
	done

	rm -f "${SIG_RV_FILE}" "${SIG_PIDS_FILE}"

	if [ "${all_ok}" = 1 ]
	then
		PASS
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify idle timeout accounts for time spent in JOB_DONE_CB, not reset to the full value.
test_34() {
	test_34_done_handler() {
		# Delay JOB_DONE_CB to consume part of the idle timeout before the next read -t.
		sleep 3
		return 0
	}

	local \
		TEST_NUM=34 \
		sched_rv \
		start_time \
		end_time \
		elapsed \
		jobs="instant hang"

	print_test_header 34 "Idle timeout accounts for elapsed callback time" "${jobs}"

	start_time=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_34_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &
	wait "$!"
	sched_rv=$?

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	# instant=0s, callback=3s: 3s elapsed, 2s idle timeout remaining, ~5s total (+1s margin).
	if [ "${sched_rv}" = 81 ] && [ "${elapsed}" -le 6 ]
	then
		PASS "elapsed=${elapsed}s"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, elapsed=${elapsed}s, expected <= 6s"
		return 1
	fi
}

# Verify SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S may be left unset, falling back to defaults
#   (test_39).
test_35() {
	local \
		TEST_NUM=35 \
		sched_rv \
		jobs='ok'

	print_test_header 35 "Unset SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S fall back to built-in defaults" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0"
		return 1
	fi
}

# Verify SIGUSR1/SIGINT/SIGTERM interrupt the scheduler promptly, not via an unrelated timeout.
test_36() {
	local \
		TEST_NUM=36 \
		sig \
		expect_rv \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		schedule_pid \
		all_ok=1

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=12 \
		SCHED_IDLE_TIMEOUT_S=10

	print_test_header 36 "Prompt termination on SIGUSR1/SIGINT/SIGTERM" "hang"

	for sig in USR1 INT TERM; do
		case "${sig}" in
			USR1) expect_rv=83 ;;
			INT|TERM) expect_rv=84 ;;
		esac

		start_s=$(date +%s)

		case "${sig}" in
			USR1|TERM)
				# Send TERM signal to background scheduler process
				(
					schedule_jobs 'hang' &
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
						kill "-${sig}" "${pid}"
					) &
					killer_pid=${!}

					trap 'kill "${killer_pid}" 2>/dev/null' EXIT

					schedule_jobs 'hang'
				)
		esac

		sched_rv=$?
		end_s=$(date +%s)

		elapsed=$((end_s - start_s))

		if [ "${sched_rv}" = "${expect_rv}" ] &&
			[ "${elapsed}" -le 3 ]
		then
			printf 'SIG%s: %s (elapsed=%ss, sched_rv=%s)\n' "${sig}" "${PASS}" "${elapsed}" "${sched_rv}"
		else
			all_ok=0
			printf 'SIG%s: %s (elapsed=%ss, expected <=3s, sched_rv=%s, expected %s)\n' \
				"${sig}" "${FAIL}" "${elapsed}" "${sched_rv}" "${expect_rv}"
		fi
	done

	if [ "${all_ok}" = 1 ]
	then
		PASS
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify idle and global timeouts fire within their configured time window, not just eventually.
test_37() {
	local \
		TEST_NUM=37 \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		all_ok=1

	print_test_header 37 "Timeouts fire within their configured window" "hang"

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs 'hang' &

	wait "$!"
	sched_rv=$?
	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	if [ "${sched_rv}" = 81 ] &&
		[ "${elapsed}" -ge 3 ] &&
		[ "${elapsed}" -le 6 ]
	then
		printf 'idle: %s (elapsed=%ss)\n' "${PASS}" "${elapsed}"
	else
		all_ok=0
		printf 'idle: %s (elapsed=%ss, sched_rv=%s, expected 3<=elapsed<=6 and sched_rv=81)\n' "${FAIL}" "${elapsed}" "${sched_rv}"
	fi

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs 'hang' &

	wait "$!"
	sched_rv=$?
	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	if [ "${sched_rv}" = 82 ] &&
		[ "${elapsed}" -ge 3 ] &&
		[ "${elapsed}" -le 6 ]
	then
		printf 'global: %s (elapsed=%ss)\n' "${PASS}" "${elapsed}"
	else
		all_ok=0
		printf 'global: %s (elapsed=%ss, sched_rv=%s, expected 3<=elapsed<=6 and sched_rv=82)\n' "${FAIL}" "${elapsed}" "${sched_rv}"
	fi

	if [ "${all_ok}" = 1 ]
	then
		PASS
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify read -t rounding doesn't overshoot at the minimum SCHED_IDLE_TIMEOUT_S=1
#   (~1s, not more).
test_38() {
	local \
		TEST_NUM=38 \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		jobs='hang'

	print_test_header 38 "Read-timeout rounding does not compound at SCHED_IDLE_TIMEOUT_S=1" "${jobs}"

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?
	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	if [ "${sched_rv}" = 81 ] &&
		[ "${elapsed}" -ge 1 ] &&
		[ "${elapsed}" -le 3 ]
	then
		PASS "elapsed=${elapsed}s"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, elapsed=${elapsed}s, expected 1<=elapsed<=3 and sched_rv=81"
		return 1
	fi
}

# Verify that explicitly empty-value SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S
#   are accepted and fall back to defaults.
test_39() {
	local \
		TEST_NUM=39 \
		sched_rv \
		jobs='ok'

	print_test_header 39 "Explicitly empty SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S accepted" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S='' \
	SCHED_IDLE_TIMEOUT_S='' \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0"
		return 1
	fi
}

# Verify the global timeout can fire inside schedule_jobs()'s initial dispatch loop.
# SCHED_DISPATCH_TICK_CB stalls past SCHED_TIMEOUT_S so the second job is never dispatched.
test_40() {
	test_40_do_job() {
		[ "${1}" = second ] && printf 'dispatched\n' > "${SECOND_DISPATCHED_FILE}"
		return 0
	}

	test_40_dispatch_tick() {
		[ "${1}" = first ] && sleep 2
	}

	local \
		TEST_NUM=40 \
		sched_rv \
		jobs='first second'

	local SECOND_DISPATCHED_FILE="/tmp/sched.dispatch_timeout.${TEST_NUM:?}.$$"
	rm -f "${SECOND_DISPATCHED_FILE}"

	print_test_header 40 "Global timeout can fire during initial dispatch" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_40_do_job \
	SCHED_DISPATCH_TICK_CB=test_40_dispatch_tick \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 82 ] &&
		[ ! -e "${SECOND_DISPATCHED_FILE}" ]
	then
		PASS "sched_rv=${sched_rv}"
		rm -f "${SECOND_DISPATCHED_FILE}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 82, second_dispatched=$([ -e "${SECOND_DISPATCHED_FILE}" ] && echo yes || echo no)"
		rm -f "${SECOND_DISPATCHED_FILE}"
		return 1
	fi
}


# Verify that a single param registered via job_set_params()
#   is delivered to DO_JOB_CB with the exact value.
test_41() {
	test_41_do_job() {
		job_get_params "${1}" FOO
		printf '%s\n' "${FOO-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=41 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.basic.${TEST_NUM}.$$" \
		job_id=job_41

	rm -f "${OUT_FILE}"

	print_test_header 41 "Single job param delivered as env var" "${job_id}"

	job_set_params "${job_id}" "FOO=bar123"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_41_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "bar123" ]
	then
		PASS "FOO='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FOO='${seen}', expected 'bar123'"
		return 1
	fi
}

# Verify multiple params registered for the same job are all delivered.
test_42() {
	test_42_do_job() {
		job_get_params "${1}" PARAM_A PARAM_B PARAM_C
		{
			printf 'A=%s\n' "${PARAM_A-<unset>}"
			printf 'B=%s\n' "${PARAM_B-<unset>}"
			printf 'C=%s\n' "${PARAM_C-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=42 \
		sched_rv \
		expected \
		actual

	local \
		OUT_FILE="/tmp/sched.params.multi.${TEST_NUM}.$$" \
		job_id=job_42

	rm -f "${OUT_FILE}"

	print_test_header 42 "Multiple job params delivered" "${job_id}"

	job_set_params "${job_id}" "PARAM_A=1" "PARAM_B=two" "PARAM_C=3three3"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_42_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	expected="$(printf 'A=1\nB=two\nC=3three3')"
	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job_get_params() returns an empty value (rv=0, no error) for a param never
#   registered for the job, and a multi-name request still fetches every requested name,
#   including ones after the unregistered one.
test_43() {
	test_43_do_job() {
		local rv
		job_get_params "${1}" GOOD1 MISSING GOOD2
		rv=$?
		{
			printf 'rv=%s\n' "${rv}"
			printf 'GOOD1=%s\n' "${GOOD1-<unset>}"
			printf 'MISSING=%s\n' "${MISSING-<unset>}"
			printf 'GOOD2=%s\n' "${GOOD2-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=43 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.unregistered.${TEST_NUM}.$$" \
		job_id=job_43

	rm -f "${OUT_FILE}"

	print_test_header 43 "job_get_params() returns empty for an unregistered param, no error" "${job_id}"

	job_set_params "${job_id}" "GOOD1=alpha" "GOOD2=beta"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_43_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	expected="$(printf 'rv=0\nGOOD1=alpha\nMISSING=\nGOOD2=beta')"

	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job_set_params() rejects invalid input at assignment time:
#   bad job ID, pair missing '=', bad/empty/leading-digit param names,
#   and accepts a leading-digit job ID (job IDs need not be valid shell identifiers).
test_44() {
	test_44_check_rejected() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_44_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	test_44_check_accepted() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_44_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" = 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly rejected: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	test_44_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=44 \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt

	local MSG_FILE="/tmp/sched.params.validate.${TEST_NUM}.$$"
	local job_id=job_44
	rm -f "${MSG_FILE}"

	print_test_header 44 "job_set_params() input validation" "(direct calls, no scheduler run)"

	test_44_check_rejected ""        "FOO=bar"      # empty job ID
	test_44_check_rejected "bad id"  "FOO=bar"       # job ID with space
	test_44_check_rejected "${job_id}" "novalue"       # pair missing '='
	test_44_check_rejected "${job_id}" "=novalue"      # empty param name
	test_44_check_rejected "${job_id}" "bad param=x"   # param name with space
	test_44_check_rejected "${job_id}" "1bad=x"        # param name starting with digit
	test_44_check_accepted "1job"    "FOO=x"         # leading-digit JOB ID is fine
	test_44_check_accepted "${job_id}" "GOOD=x"        # sanity: valid case still accepted

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	# The 6 rejected cases above should each produce exactly one message;
	# the 2 accepted cases produce none.
	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = 6 ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 1
	fi
}

# Verify job_set_params() rejects every reserved param name immediately
#   (sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|IFS): rv=1,
#   one specific message emitted per case, and nothing is stored -
#   a later job run never sees the param.
test_45() {
	test_45_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	test_45_do_job() {
		job_get_params "${1}" GOOD
		printf '%s\n' "${GOOD-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=45 \
		name \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		sched_rv \
		seen \
		msg_cnt

	local \
		MSG_FILE="/tmp/sched.params.reserved.msg.${TEST_NUM}.$$" \
		OUT_FILE="/tmp/sched.params.reserved.out.${TEST_NUM}.$$" \
		job_id=job_45

	rm -f "${MSG_FILE}" "${OUT_FILE}"

	print_test_header 45 "Reserved param names rejected at job_set_params() time" "${job_id}"

	for name in \
		sch_foo sch_job_id sch_me \
		_sch_foo _sch_job_id _sch_me \
		SCH_JOB_PARAMS_foo SCH_JOB_PARAMS \
		SCHED_ SCHED_MAX_JOBS SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S SCHED_DIR \
		SCHED_FAIL_MSG_CB SCHED_FINALIZE_CB SCHED_DISPATCH_TICK_CB \
		DO_JOB_CB JOB_DONE_CB IFS
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_45_fail_msg job_set_params "${job_id}" "${name}=x" 2>/dev/null
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted reserved name: %s\n' "${name}" >&2
		fi
	done

	# One legitimate param too, to confirm the job still runs normally.
	job_set_params "${job_id}" "GOOD=fine"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_45_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")

	rm -f "${MSG_FILE}" "${OUT_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${sched_rv}" = 0 ] &&
		[ "${seen}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, GOOD='${seen}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, sched_rv=${sched_rv}, GOOD='${seen}'"
		return 1
	fi
}

# Verify a job's params don't leak into another job's environment: two jobs registering
#   the same param name with different values must each see only their own value.
test_46() {
	test_46_do_job() {
		local out
		case "${1}" in
			"${job_id_a}") out="${J1_FILE:?}" ;;
			"${job_id_b}") out="${J2_FILE:?}" ;;
			*) return 1 ;;
		esac
		job_get_params "${1}" SHARED_NAME
		printf '%s\n' "${SHARED_NAME}" > "${out}"
		return 0
	}

	local \
		TEST_NUM=46 \
		sched_rv \
		seen1 \
		seen2

	local \
		J1_FILE="/tmp/sched.params.isolation.j1.${TEST_NUM}.$$" \
		J2_FILE="/tmp/sched.params.isolation.j2.${TEST_NUM}.$$" \
		job_id_a=job_46a \
		job_id_b=job_46b

	rm -f "${J1_FILE}" "${J2_FILE}"

	print_test_header 46 "Params are scoped per job ID" "${job_id_a} ${job_id_b}"

	job_set_params "${job_id_a}" "SHARED_NAME=only_${job_id_a}"
	job_set_params "${job_id_b}" "SHARED_NAME=only_${job_id_b}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_46_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id_a} ${job_id_b}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen1 "${J1_FILE}"
	read_first_line seen2 "${J2_FILE}"
	rm -f "${J1_FILE}" "${J2_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${seen1}" = "only_${job_id_a}" ] &&
		[ "${seen2}" = "only_${job_id_b}" ]
	then
		PASS "${job_id_a}='${seen1}', ${job_id_b}='${seen2}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, ${job_id_a}='${seen1}', ${job_id_b}='${seen2}'"
		return 1
	fi
}

# Verify that registering the same param key twice for a job
#   keeps the last value (last write wins) without error
test_47() {
	test_47_do_job() {
		job_get_params "${1}" DUPKEY
		printf '%s\n' "${DUPKEY-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=47 \
		sched_rv \
		error_seen \
		seen

	local \
		OUT_FILE="/tmp/sched.params.dup.${TEST_NUM}.$$" \
		job_id=job_47

	rm -f "${OUT_FILE}"

	print_test_header 47 "Duplicate param key: last write wins" "${job_id}"

	job_set_params "${job_id}" "DUPKEY=first" "DUPKEY=second" || error_seen=1

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_47_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "second" ] && [ -z "${error_seen}" ]
	then
		PASS "DUPKEY='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, DUPKEY='${seen}', expected 'second', error_seen='${error_seen}'"
		return 1
	fi
}

# Verify pair parsing splits only on the first '=':
#   the value may contain further '=' characters unmodified.
test_48() {
	test_48_do_job() {
		job_get_params "${1}" URL
		printf '%s\n' "${URL-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=48 \
		sched_rv \
		seen \
		expected='http://x?a=1&b=2'

	local \
		OUT_FILE="/tmp/sched.params.eqsign.${TEST_NUM}.$$" \
		job_id=job_48

	rm -f "${OUT_FILE}"

	print_test_header 48 "Value containing embedded '=' preserved intact" "${job_id}"

	job_set_params "${job_id}" "URL=${expected}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_48_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "${expected}" ]
	then
		PASS "URL='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, URL='${seen}', expected '${expected}'"
		return 1
	fi
}

# Verify param values are stored/delivered as opaque data:
#   quotes, $(), backticks, globs, spaces, empty value
#   are preserved and never executed or glob-expanded.
test_49() {
	test_49_touch_inject() { touch "${INJECT_FILE:?}"; }

	test_49_do_job() {
		job_get_params "${1}" SPACEY QUOTY CMDSUB BACKTICK GLOBBY EMPTYV
		{
			printf 'SPACEY=%s\n' "${SPACEY-<unset>}"
			printf 'QUOTY=%s\n' "${QUOTY-<unset>}"
			printf 'CMDSUB=%s\n' "${CMDSUB-<unset>}"
			printf 'BACKTICK=%s\n' "${BACKTICK-<unset>}"
			printf 'GLOBBY=%s\n' "${GLOBBY-<unset>}"
			printf 'EMPTYV=[%s]\n' "${EMPTYV-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=49 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.valfidelity.${TEST_NUM}.$$" \
		INJECT_FILE="/tmp/sched.params.valfidelity.inject.${TEST_NUM}.$$" \
		job_id=job_49

	rm -f "${OUT_FILE}" "${INJECT_FILE}"

	print_test_header 49 "Param value fidelity / no injection via value content" "${job_id}"

	# shellcheck disable=SC2016
	job_set_params "${job_id}" \
		'SPACEY=hello world' \
		"QUOTY=a'b\"c" \
		'CMDSUB=$(test_49_touch_inject)' \
		'BACKTICK=`test_49_touch_inject`' \
		'GLOBBY=*.txt' \
		'EMPTYV='

	# shellcheck disable=SC2016
	expected="SPACEY=hello world"$'\n'"QUOTY=a'b\"c"$'\n'"CMDSUB="'$(test_49_touch_inject)'$'\n'"BACKTICK="'`test_49_touch_inject`'$'\n'"GLOBBY=*.txt"$'\n'"EMPTYV=[]"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_49_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ] &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${OUT_FILE}" "${INJECT_FILE}"
		PASS
		return 0
	else
		rm -f "${OUT_FILE}" "${INJECT_FILE}"
		FAIL "sched_rv=${sched_rv}, inject_marker_exists=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		printf '%s\n%s\n%s\n' \
			"expected:" "${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job params and forwarded positional args to DO_JOB_CB coexist without interference.
test_50() {
	test_50_do_job() {
		job_get_params "${1}" COMBOPARAM
		{
			printf 'PARAM=%s\n' "${COMBOPARAM-<unset>}"
			printf 'ARGS=%s\n' "$*"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=50 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.withargs.${TEST_NUM}.$$" \
		job_id=job_50

	rm -f "${OUT_FILE}"

	print_test_header 50 "Job params coexist with forwarded extra args" "${job_id}"

	job_set_params "${job_id}" "COMBOPARAM=paramval"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_50_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" extra1 extra2 &

	wait "$!"
	sched_rv=$?

	expected="$(printf 'PARAM=paramval\nARGS=%s extra1 extra2' "${job_id}")"
	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}


# Verify job_get_params() runs its own reserved/malformed-name validation on the requested
#   param name, independent of job_set_params()'s validation at registration time.
test_51() {
	test_51_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=51 \
		name \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM \
		IFS="${IFS}"

	local \
		MSG_FILE="/tmp/sched.params.get_validate.${TEST_NUM}.$$" \
		job_id=job_51

	rm -f "${MSG_FILE}"

	print_test_header 51 "job_get_params() rejects reserved/malformed param names" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine" "AAA=1" "BBB=2"

	# "IFS" is deliberately included below: job_get_params() must reject it
	#   before reaching its eval-assignment line.
	# local IFS="${IFS}" guards from IFS corruption leak
	#
	# "AAA BBB" is deliberately built from two registered names
	for name in SCH_FOO sch_foo _sch_foo SCHED_MAX_JOBS DO_JOB_CB JOB_DONE_CB IFS 1bad "bad name" "AAA BBB"
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_51_fail_msg job_get_params "${job_id}" "${name}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: %s\n' "${name}" >&2
		fi
	done

	# Legitimate, already-registered param must still work afterward.
	job_get_params "${job_id}" REALPARAM

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${REALPARAM}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, REALPARAM='${REALPARAM}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, REALPARAM='${REALPARAM-<unset>}'"
		return 1
	fi
}

# Verify job_get_params() runs its own job-ID validation,
#   independent of job_set_params()'s job-ID validation at registration time.
test_52() {
	test_52_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=52 \
		jid \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM

	local \
		MSG_FILE="/tmp/sched.params.get_jobid.${TEST_NUM}.$$" \
		job_id=job_52

	rm -f "${MSG_FILE}"

	print_test_header 52 "job_get_params() rejects a bad/empty job ID" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	for jid in "" "bad id"; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_52_fail_msg job_get_params "${jid}" REALPARAM
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted job ID: %s\n' "${jid}" >&2
		fi
	done

	# Legitimate job ID must still work afterward
	job_get_params "${job_id}" REALPARAM

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${REALPARAM}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, REALPARAM='${REALPARAM}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, REALPARAM='${REALPARAM-<unset>}'"
		return 1
	fi
}

# Verify job_get_params() rejects a call with a valid job ID but zero requested param names,
#   and that this failure is reported with its own distinct message
#   (not conflated with the bad-job-ID message)
test_53() {
	test_53_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=53 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.get_empty.${TEST_NUM}.$$" \
		job_id=job_53

	rm -f "${MSG_FILE}"

	print_test_header 53 "job_get_params() rejects zero requested param names" "(direct call, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	SCHED_FAIL_MSG_CB=test_53_fail_msg job_get_params "${job_id}"
	rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"no params specified"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${rv}" != 0 ] && [ "${msg_cnt}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "rv=${rv}, msg='${msg}'"
		return 0
	else
		FAIL "rv=${rv}, msg_cnt=${msg_cnt}, msg='${msg}'"
		return 1
	fi
}

# Verify job_set_params() rejects a call with a valid job ID but zero key=value pairs -
#   symmetric with equivalent guard above (test_53).
test_54() {
	test_54_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=54 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.set_empty.${TEST_NUM}.$$" \
		job_id=job_54

	rm -f "${MSG_FILE}"

	print_test_header 54 "job_set_params() rejects zero key=value pairs" "(direct call, no scheduler run)"

	SCHED_FAIL_MSG_CB=test_54_fail_msg job_set_params "${job_id}"
	rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"no params specified"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${rv}" != 0 ] && [ "${msg_cnt}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "rv=${rv}, msg='${msg}'"
		return 0
	else
		FAIL "rv=${rv}, msg_cnt=${msg_cnt}, msg='${msg}'"
		return 1
	fi
}

# Verify job_get_params() always reflects the current registered value,
#   not something cached at an earlier point -
#   re-fetching after a later job_set_params() update picks up the new value.
test_55() {
	local \
		TEST_NUM=55 \
		first \
		second \
		REFETCH \
		job_id=job_55

	print_test_header 55 "job_get_params() reflects updates from a later job_set_params() call" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REFETCH=one"
	job_get_params "${job_id}" REFETCH
	first="${REFETCH}"

	job_set_params "${job_id}" "REFETCH=two"
	unset REFETCH
	job_get_params "${job_id}" REFETCH
	second="${REFETCH}"

	if [ "${first}" = "one" ] && [ "${second}" = "two" ]
	then
		PASS "first='${first}', second='${second}'"
		return 0
	else
		FAIL "first='${first}', expected 'one', second='${second}', expected 'two'"
		return 1
	fi
}

# Verify job_get_params() works when called from JOB_DONE_CB,
#   which runs in the main scheduler process (not the forked per-job subshell that runs
#   DO_JOB_CB) - confirming params are available in every callback, not just DO_JOB_CB.
test_56() {
	test_56_do_job() { return 0; }

	test_56_done() {
		job_get_params "${1}" FROMDONE
		printf '%s\n' "${FROMDONE-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=56 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.job_done_cb.${TEST_NUM}.$$" \
		job_id=job_56

	rm -f "${OUT_FILE}"

	print_test_header 56 "job_get_params() is usable from JOB_DONE_CB" "${job_id}"

	job_set_params "${job_id}" "FROMDONE=seen_in_job_done_cb"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_56_done \
	DO_JOB_CB=test_56_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "seen_in_job_done_cb" ]
	then
		PASS "FROMDONE='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FROMDONE='${seen}', expected 'seen_in_job_done_cb'"
		return 1
	fi
}

# Verify job_get_params() is usable directly in the caller's own top-level scope,
#   not only from within a scheduler callback -
#   confirming params are available in the user's application scope
test_57() {
	test_57_do_job() { return 0; }

	local \
		TEST_NUM=57 \
		sched_rv \
		seen \
		FROMSCOPE \
		job_id=job_57

	print_test_header 57 "job_get_params() is usable directly in the caller's own scope" "${job_id}"

	job_set_params "${job_id}" "FROMSCOPE=seen_in_caller_scope"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_57_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	# FROMSCOPE is declared local above so this direct (main-process) call
	# doesn't leak it into the global scope.
	unset FROMSCOPE
	job_get_params "${job_id}" FROMSCOPE
	seen="${FROMSCOPE-<unset>}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "seen_in_caller_scope" ]
	then
		PASS "FROMSCOPE='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FROMSCOPE='${seen}', expected 'seen_in_caller_scope'"
		return 1
	fi
}


# Verify that job_get_params() "sch_all" mode is a no-op success (rv=0, no params assigned)
#   when the job has never had any params registered
test_58() {
	local \
		TEST_NUM=58 \
		rv \
		job_id=job_58_noparams

	print_test_header 58 \
		"job_get_params() 'sch_all' on a job with zero registered params is a no-op success" \
		"(direct call, no scheduler run)"

	job_get_params "${job_id}" sch_all
	rv=$?

	if [ "${rv}" = 0 ]
	then
		PASS "rv=${rv}"
		return 0
	else
		FAIL "rv=${rv}, expected 0"
		return 1
	fi
}

# Verify job_get_params() "sch_all" mode returns the complete, correct set of registered params,
#   matching an explicit multi-param fetch of the same job.
# Also verifies "sch_all" mode's internal word-splitting of the registered-params list
#   does not leak or lose the caller's noglob state.
test_59() {
	local \
		TEST_NUM=59 \
		job_id=job_59 \
		P1 P2 P3 \
		explicit_ok=0 \
		all_ok=0 \
		noglob_ok=1

	print_test_header 59 "job_get_params() 'all' mode returns the full registered set" \
		"(direct calls, no scheduler run)"

	job_set_params "${job_id}" "P1=one" "P2=two" "P3=three"

	job_get_params "${job_id}" P1 P2 P3
	[ "${P1}" = one ] && [ "${P2}" = two ] && [ "${P3}" = three ] &&
		explicit_ok=1

	unset P1 P2 P3
	job_get_params "${job_id}" sch_all
	[ "${P1}" = one ] && [ "${P2}" = two ] && [ "${P3}" = three ] &&
		all_ok=1

	# Noglob preservation around "sch_all" mode's internal set -f handling:
	# caller's set -f/+f state must survive the call unchanged either way.
	set +f
	job_get_params "${job_id}" sch_all >/dev/null
	case "${-}" in *f*) noglob_ok=0 ;; esac

	set -f
	job_get_params "${job_id}" sch_all >/dev/null
	case "${-}" in *f*) ;; *) noglob_ok=0 ;; esac
	set +f

	if [ "${explicit_ok}" = 1 ] && [ "${all_ok}" = 1 ] && [ "${noglob_ok}" = 1 ]
	then
		PASS "P1='${P1}', P2='${P2}', P3='${P3}'"
		return 0
	else
		FAIL "explicit_ok=${explicit_ok}, all_ok=${all_ok}, noglob_ok=${noglob_ok}, P1='${P1}', P2='${P2}', P3='${P3}'"
		return 1
	fi
}

# Verify that job_get_params() with the "-export" flag exports into the process environment,
#   while the default (no "-export") mode only assigns in the caller's own shell scope.
test_60() {
	local \
		TEST_NUM=60 \
		job_id=job_60 \
		EXPORTPARAM \
		default_exported \
		flag_exported

	print_test_header 60 "job_get_params() '-export' flag exports to the real environment" \
		"(direct calls, no scheduler run)"

	job_set_params "${job_id}" "EXPORTPARAM=exported_val"

	unset EXPORTPARAM
	job_get_params "${job_id}" EXPORTPARAM
	default_exported="$(sh -c 'printf "%s" "${EXPORTPARAM-<unset>}"')"

	unset EXPORTPARAM
	job_get_params -export "${job_id}" EXPORTPARAM
	flag_exported="$(sh -c 'printf "%s" "${EXPORTPARAM-<unset>}"')"

	if [ "${default_exported}" = '<unset>' ] &&
		[ "${flag_exported}" = exported_val ]
	then
		PASS "default='${default_exported}', -export='${flag_exported}'"
		return 0
	else
		FAIL "default='${default_exported}', expected '<unset>'; -export='${flag_exported}', expected 'exported_val'"
		return 1
	fi
}

# Verify with SCHED_AUTO_PARAMS=1:
# - DO_JOB_CB sees its own job's registered params without job_get_params() call
# - jobs with different params stay isolated from each other
# - job_get_params() "all" doesn't 'exit 1' on empty params set
test_61() {
	test_61_do_job() {
		case "${1}" in
			withparam1)
				[ "${MYPARAM-}" = aaa ] && printf 'ok\n' > "${WP1_FILE:?}"
			;;
			withparam2)
				[ "${MYPARAM-}" = bbb ] && printf 'ok\n' > "${WP2_FILE:?}"
			;;
			noparam)
				printf 'started\n' > "${NOPARAM_STARTED_FILE:?}"
				[ -z "${MYPARAM-}" ] && printf 'ok\n' > "${NOPARAM_FILE:?}"
			;;
		esac

		return 0
	}

	local \
		TEST_NUM=61 \
		sched_rv \
		jobs='withparam1 withparam2 noparam'

	local \
		WP1_FILE="/tmp/sched.autoparams.wp1.${TEST_NUM}.$$" \
		WP2_FILE="/tmp/sched.autoparams.wp2.${TEST_NUM}.$$" \
		NOPARAM_FILE="/tmp/sched.autoparams.noparam.${TEST_NUM}.$$" \
		NOPARAM_STARTED_FILE="/tmp/sched.autoparams.noparam_started.${TEST_NUM}.$$"

	rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"

	print_test_header 61 "SCHED_AUTO_PARAMS=1: auto-export, per-job isolation, and jobs with no params" "${jobs}"

	# "noparam" deliberately has no job_set_params() call at all.
	job_set_params withparam1 "MYPARAM=aaa"
	job_set_params withparam2 "MYPARAM=bbb"

	SCHED_AUTO_PARAMS=1 \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_61_do_job \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		[ -f "${WP1_FILE}" ] &&
		[ -f "${WP2_FILE}" ] &&
		[ -f "${NOPARAM_STARTED_FILE}" ] &&
		[ -f "${NOPARAM_FILE}" ]
	then
		rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, wp1=$([ -f "${WP1_FILE}" ] && echo ok || echo missing), wp2=$([ -f "${WP2_FILE}" ] && echo ok || echo missing), noparam_started=$([ -f "${NOPARAM_STARTED_FILE}" ] && echo ok || echo missing), noparam=$([ -f "${NOPARAM_FILE}" ] && echo ok || echo missing)"
		rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"
		return 1
	fi
}


# Verify SCHED_FINALIZE_CB's ok/fail sets are correct on a normal completion
#   with no timeout/undispatched/unfinished jobs involved.
test_62() {
	test_62_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=62 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail \
		jobs='ok1 ok2 fail'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 62 "SCHED_FINALIZE_CB ok/fail sets on normal completion" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_62_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 0 ] &&
		verify_id_set exp_ok act_ok "ok1 ok2" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "fail" "${fail_raw}" &&
		[ -z "${unfinished_raw}" ] &&
		[ -z "${undispatched_raw}" ]
	then
		PASS "ok='${ok_raw}', fail='${fail_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'" \
			"unfinished_raw='${unfinished_raw}'" \
			"undispatched_raw='${undispatched_raw}'"
		return 1
	fi
}

# Verify a job recorded as failed before an idle-timeout abort stays in the fail
#   set, while a still-running job at abort time lands in unfinished, not fail.
test_63() {
	test_63_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=63 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		jobs='ok fail hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 63 "Fail set survives idle-timeout abort; running job is unfinished, not failed" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_63_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 81 ] &&
		verify_id_set exp_ok act_ok "ok" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "fail" "${fail_raw}" &&
		verify_id_set exp_unfinished act_unfinished "hang" "${unfinished_raw}" &&
		[ -z "${undispatched_raw}" ]
	then
		PASS "ok='${ok_raw}', fail='${fail_raw}', unfinished='${unfinished_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 81"
		printf '%s\n%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'" \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'" \
			"undispatched_raw='${undispatched_raw}'"
		return 1
	fi
}

# Verify a job never reached by the dispatch loop before a global-timeout abort
#   lands in undispatched, while the job dispatched just before the abort
#   (whose completion was never read) lands in unfinished.
test_64() {
	test_64_do_job() {
		[ "${1}" = second ] && printf 'dispatched\n' > "${SECOND_DISPATCHED_FILE:?}"
		return 0
	}

	test_64_dispatch_tick() {
		[ "${1}" = first ] && sleep 2
	}

	test_64_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=64 \
		sched_rv \
		unfinished_raw undispatched_raw \
		exp_unfinished act_unfinished exp_undispatched act_undispatched \
		jobs='first second'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$" \
		SECOND_DISPATCHED_FILE="/tmp/sched.dispatch64.${TEST_NUM:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX}".* "${SECOND_DISPATCHED_FILE}"

	print_test_header 64 "Global timeout during initial dispatch: undispatched vs. unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_64_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_64_do_job \
	SCHED_DISPATCH_TICK_CB=test_64_dispatch_tick \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 82 ] &&
		[ ! -e "${SECOND_DISPATCHED_FILE}" ] &&
		verify_id_set exp_unfinished act_unfinished "first" "${unfinished_raw}" &&
		verify_id_set exp_undispatched act_undispatched "second" "${undispatched_raw}"
	then
		PASS "unfinished='${unfinished_raw}', undispatched='${undispatched_raw}'"
		rm -f "${SECOND_DISPATCHED_FILE}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 82, second_dispatched=$([ -e "${SECOND_DISPATCHED_FILE}" ] && echo yes || echo no)"
		printf '%s\n%s\n' \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'" \
			"undispatched: expected='${exp_undispatched}' actual='${act_undispatched}'"
		rm -f "${SECOND_DISPATCHED_FILE}"
		return 1
	fi
}

# Verify SIGUSR1 abort: a job already completed before the signal stays ok,
#   the still-running job lands in unfinished.
test_65() {
	test_65_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=65 \
		sched_rv \
		schedule_pid \
		ok_raw unfinished_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 65 "SIGUSR1 abort: completed job stays ok, running job is unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_65_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	schedule_pid=$!

	sleep 2

	kill -USR1 "${schedule_pid}"

	wait "${schedule_pid}"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 83 ] &&
		verify_id_set exp_ok act_ok "ok" "${ok_raw}" &&
		verify_id_set exp_unfinished act_unfinished "hang" "${unfinished_raw}"
	then
		PASS "ok='${ok_raw}', unfinished='${unfinished_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 83"
		printf '%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'"
		return 1
	fi
}

# Verify a malformed-completion-record abort (sch_finalize called directly from
#   inside process_done_record, not from the normal loop exits) still preserves
#   an already-completed job's ok status; the malformed job itself is unfinished.
test_66() {
	test_66_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=66 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok malformed'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 66 "Malformed-record abort preserves prior ok status" "${jobs}"

	# SCHED_MAX_JOBS=1 forces sequential execution: "ok" must fully complete
	# and be recorded before "malformed" is even dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_66_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 1 ] &&
		verify_id_set exp_ok act_ok "ok" "${ok_raw}" &&
		[ -z "${fail_raw}" ] &&
		verify_id_set exp_unfinished act_unfinished "malformed" "${unfinished_raw}" &&
		[ -z "${undispatched_raw}" ]
	then
		PASS "ok='${ok_raw}', unfinished='${unfinished_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 1"
		printf '%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail_raw='${fail_raw}'" \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'"
		return 1
	fi
}

# Verify ok/fail/unfinished/undispatched are pairwise disjoint and jointly
#   exhaustive over the full job set, in one run where all four are populated.
test_67() {
	test_67_do_job() {
		case "${1}" in
			hang2) do_job_default hang ;;
			*) do_job_default "${@}" ;;
		esac
	}

	test_67_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=67 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		exp_undispatched act_undispatched \
		member_cnt \
		jobs='ok1 fail hang2 hang1'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 67 "ok/fail/unfinished/undispatched partition the full job set" "${jobs}"

	# SCHED_MAX_JOBS=1 forces strictly sequential dispatch: ok1 and fail are
	# each fully drained/classified before hang2 starts. hang2 is still
	# sleeping (no completion record ever read) when SCHED_TIMEOUT_S hits, so
	# it lands in unfinished; hang1 never gets dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_67_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_67_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	# shellcheck disable=SC2086
	set -- ${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw}
	member_cnt="${#}"

	if [ "${sched_rv}" = 82 ] &&
		verify_id_set exp_ok act_ok "ok1" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "fail" "${fail_raw}" &&
		verify_id_set exp_unfinished act_unfinished "hang2" "${unfinished_raw}" &&
		verify_id_set exp_undispatched act_undispatched "hang1" "${undispatched_raw}" &&
		[ "${member_cnt}" = 4 ]
	then
		PASS "ok='${ok_raw}', fail='${fail_raw}', unfinished='${unfinished_raw}', undispatched='${undispatched_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 82, member_cnt=${member_cnt}, expected 4 (no overlap/dup)"
		printf '%s\n%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'" \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'" \
			"undispatched: expected='${exp_undispatched}' actual='${act_undispatched}'"
		return 1
	fi
}

# Verify an empty job list yields all four sets empty.
test_68() {
	test_68_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=68 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		jobs='<none>'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header 68 "Empty job list yields all-empty ok/fail/unfinished/undispatched sets" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_68_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs '' &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 0 ] &&
		[ -z "${ok_raw}" ] &&
		[ -z "${fail_raw}" ] &&
		[ -z "${unfinished_raw}" ] &&
		[ -z "${undispatched_raw}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, ok='${ok_raw}', fail='${fail_raw}', unfinished='${unfinished_raw}', undispatched='${undispatched_raw}'"
		return 1
	fi
}

# Verify job IDs containing glob/injection-shaped characters still land in the
#   correct ok/fail set (not just "no crash" - test_30/test_31 already cover that).
test_69() {
	test_69_touch_inject() { touch "${INJECT_FILE:?}"; }

	test_69_do_job() {
		case "${1}" in
			*ok_marker*) return 0 ;;
			*) return 1 ;;
		esac
	}

	test_69_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_NUM=69 \
		sched_rv \
		ok_raw fail_raw \
		exp_ok act_ok exp_fail act_fail \
		ok_id fail_id \
		jobs

	ok_id='ok_marker_$(test_69_touch_inject)'
	fail_id='fail_marker_`test_69_touch_inject`'
	jobs="${ok_id} ${fail_id}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_NUM:?}.$$" \
		INJECT_FILE="/tmp/sched.inject69.${TEST_NUM:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX}".* "${INJECT_FILE}"

	print_test_header 69 "Awkward job-ID characters land in the correct ok/fail set" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=test_69_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_69_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	if [ "${sched_rv}" = 0 ] &&
		verify_id_set exp_ok act_ok "${ok_id}" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "${fail_id}" "${fail_raw}" &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${INJECT_FILE}"
		PASS "ok='${ok_raw}', fail='${fail_raw}'"
		return 0
	else
		rm -f "${INJECT_FILE}"
		FAIL "sched_rv=${sched_rv}, inject_marker_exists=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		printf '%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'"
		return 1
	fi
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

case "${1}" in
	run)
		shift
		RUN_TESTS="${*:-"$(seq 1 69)"}"
		;;
	'')
		;;
	*)
		printf '%s\n' "Unexpected argument '${1}'." >&2; exit 1
esac


if [ -n "${RUN_TESTS}" ]; then
	case "${RUN_TESTS}" in
		*-*-*) printf '%s\n' "Unexpected string '${RUN_TESTS}'."; exit 1 ;;
		*-*) RUN_TESTS=$(seq "${RUN_TESTS%%-*}" "${RUN_TESTS#*-}") || exit 1 ;;
	esac

	printf 'Scheduler tests\n'

	TESTS_RUN=0
	TESTS_PASSED=0

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