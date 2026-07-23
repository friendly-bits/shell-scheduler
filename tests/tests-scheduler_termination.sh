#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# Category: Timeouts & Signal Termination
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify the scheduler terminates on idle timeout while a job is still running.
test_scheduler_termination_01() {
	TEST_ID=scheduler_termination_01 \
	TEST_NAME='Idle timeout' \
	TEST_JOBS='ok_1 ok_2 hang_1' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the global timeout fires while workers are active and idle timeout hasn't elapsed.
test_scheduler_termination_02() {
	scheduler_termination_02_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_ID=scheduler_termination_02 \
		sched_rv \
		timeout_rv \
		jobs="ok hang"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_ID:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header "${TEST_ID:?}" "Processing timeout" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=scheduler_termination_02_finalize_handler \
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

# Verify SIGUSR1 terminates the scheduler, SCHED_FINALIZE_CB gets a non-empty PID list, and kills the workers.
test_scheduler_termination_03() {
	scheduler_termination_03_finalize_handler() {
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIGUSR1_RV_FILE:?}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIGUSR1_PIDS_FILE:?}"
		fi

		finalize_handler "${rv}" "${pids}"
	}

	local \
		TEST_ID=scheduler_termination_03 \
		sched_rv \
		callback_rv \
		pids='' \
		schedule_pid

	local \
		SIGUSR1_RV_FILE="/tmp/sched.sigusr1.rv.${TEST_ID:?}.$$" \
		SIGUSR1_PIDS_FILE="/tmp/sched.sigusr1.pids.${TEST_ID:?}.$$"

	rm -f "${SIGUSR1_RV_FILE}" "${SIGUSR1_PIDS_FILE}"

	print_test_header "${TEST_ID:?}" "SIGUSR1 termination" "1 2"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=scheduler_termination_03_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs 'hang_1 hang_2' &

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

# Verify idle timeout fires while workers are active and processing timeout hasn't elapsed.
test_scheduler_termination_04() {
	scheduler_termination_04_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_ID=scheduler_termination_04 \
		timeout_rv \
		jobs="ok_1 ok_2 ok_3 hang_1 ok_4"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_ID:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header "${TEST_ID:?}" "Idle timeout" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=scheduler_termination_04_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=2 \
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
test_scheduler_termination_05() {
	scheduler_termination_05_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" > "${TIMEOUT_FILE:?}"

		return 0
	}

	local \
		TEST_ID=scheduler_termination_05 \
		timeout_rv \
		jobs="ok_1 ok_2 ok_3 ok_4 ok_5 ok_6"

	local TIMEOUT_FILE="/tmp/sched.timeout.${TEST_ID:?}.$$"
	rm -f "${TIMEOUT_FILE}"

	print_test_header "${TEST_ID:?}" "Global timeout despite continuous progress" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=scheduler_termination_05_finalize_handler \
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
test_scheduler_termination_06() {
	local \
		TEST_ID=scheduler_termination_06 \
		sched_rv \
		jobs='hang'

	print_test_header "${TEST_ID:?}" "Simultaneous global/idle timeout - global wins" "${jobs}"

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

# Verify SIGINT/SIGTERM terminate the scheduler with SCHED_RV_INT_TERM and a non-empty PID list.
test_scheduler_termination_07() {
	scheduler_termination_07_finalize_handler() {
		local rv="${1}" pids="${2}"

		printf '%s\n' "${rv}" > "${SIG_RV_FILE:?}"

		if [ -n "${pids}" ]
		then
			printf '%s\n' "${pids}" > "${SIG_PIDS_FILE:?}"
		fi

		finalize_handler "${rv}" "${pids}"
	}

	local \
		TEST_ID=scheduler_termination_07 \
		sig \
		sched_rv \
		expect_rv=84 \
		callback_rv \
		pids \
		schedule_pid \
		all_ok=1

	local \
		SIG_RV_FILE="/tmp/sched.sigintterm.rv.${TEST_ID:?}.$$" \
		SIG_PIDS_FILE="/tmp/sched.sigintterm.pids.${TEST_ID:?}.$$"

	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=scheduler_termination_07_finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=10 \
		SCHED_IDLE_TIMEOUT_S=5

	print_test_header "${TEST_ID:?}" "SIGINT/SIGTERM termination" "1 2"

	for sig in INT TERM; do
		rm -f "${SIG_RV_FILE}" "${SIG_PIDS_FILE}"

		case "${sig}" in
			TERM)
				# Send TERM signal to background scheduler process
				(
					schedule_jobs 'hang_1 hang_2' &
					schedule_pid=$!

					sleep 1

					kill "-${sig}" "${schedule_pid}"

					wait "${schedule_pid}"
				)
				;;
			INT)
				[ -t 0 ] ||
				{ printf '%s\n' "SIG${sig}: ${SKIP_C} (output is not routed to TTY)"; continue; }

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

					schedule_jobs 'hang_1 hang_2'
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
test_scheduler_termination_08() {
	scheduler_termination_08_done_handler() {
		# Delay JOB_DONE_CB to consume part of the idle timeout before the next read -t.
		# 'sleep N & wait' forces a forked sleep:
		#   an in-process NOFORK builtin sleep would be cut short by SIGCHLD from the exiting job
		sleep 2 & wait "$!"
		return 0
	}

	local \
		TEST_ID=scheduler_termination_08 \
		sched_rv \
		start_time \
		end_time \
		elapsed \
		jobs="instant hang"

	print_test_header "${TEST_ID:?}" "Idle timeout accounts for elapsed callback time" "${jobs}"

	start_time=$(date +%s)

	# MAX_JOBS=2: both jobs dispatch upfront,
	#   so no later job start resets the idle clock (job starts count as progress)
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=scheduler_termination_08_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &
	wait "$!"
	sched_rv=$?

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	# instant=0s, callback=2s: 2s elapsed, 1s idle timeout remaining, ~3s total (+1s margin).
	if [ "${sched_rv}" = 81 ] && [ "${elapsed}" -le 4 ]
	then
		PASS "elapsed=${elapsed}s"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, elapsed=${elapsed}s, expected <= 4s"
		return 1
	fi
}

# Verify SIGUSR1/SIGINT/SIGTERM interrupt the scheduler promptly, not via an unrelated timeout.
test_scheduler_termination_09() {
	local \
		TEST_ID=scheduler_termination_09 \
		sig \
		expect_rv \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		schedule_pid \
		all_ok=1

	# shellcheck disable=SC2034
	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=12 \
		SCHED_IDLE_TIMEOUT_S=10

	print_test_header "${TEST_ID:?}" "Prompt termination on SIGUSR1/SIGINT/SIGTERM" "hang"

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
				[ -t 0 ] ||
					{ printf '%s\n' "SIG${sig}: ${SKIP_C} (output is not routed to TTY)"; continue; }
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
test_scheduler_termination_10() {
	local \
		TEST_ID=scheduler_termination_10 \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		all_ok=1

	print_test_header "${TEST_ID:?}" "Timeouts fire within their configured window" "hang"

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
test_scheduler_termination_11() {
	local \
		TEST_ID=scheduler_termination_11 \
		sched_rv \
		start_s \
		end_s \
		elapsed \
		jobs='hang'

	print_test_header "${TEST_ID:?}" "Read-timeout rounding does not compound at SCHED_IDLE_TIMEOUT_S=1" "${jobs}"

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

# Verify the global timeout can fire inside schedule_jobs()'s initial dispatch loop.
# SCHED_DISPATCH_TICK_CB stalls past SCHED_TIMEOUT_S so the second job is never dispatched.
test_scheduler_termination_12() {
	scheduler_termination_12_do_job() {
		[ "${1}" = second ] && printf 'dispatched\n' > "${SECOND_DISPATCHED_FILE}"
		return 0
	}

	scheduler_termination_12_dispatch_tick() {
		# 'sleep N & wait' forces a forked sleep: an in-process NOFORK builtin
		# sleep would be cut short by SIGCHLD from the exiting job
		[ "${1}" = first ] && { sleep 2 & wait "$!"; }
	}

	local \
		TEST_ID=scheduler_termination_12 \
		sched_rv \
		jobs='first second'

	local SECOND_DISPATCHED_FILE="/tmp/sched.dispatch_timeout.${TEST_ID:?}.$$"
	rm -f "${SECOND_DISPATCHED_FILE}"

	print_test_header "${TEST_ID:?}" "Global timeout can fire during initial dispatch" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=scheduler_termination_12_do_job \
	SCHED_DISPATCH_TICK_CB=scheduler_termination_12_dispatch_tick \
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

# Verify the scheduler times out when a worker exits without sending a completion record.
test_scheduler_termination_13() {
	TEST_ID=scheduler_termination_13 \
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
test_scheduler_termination_14() {
	TEST_ID=scheduler_termination_14 \
	TEST_NAME='Malformed completion record' \
	TEST_JOBS='malformed' \
	TEST_EXPECT_RV=1 \
	TEST_SCHED_MAX_JOBS=1 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}
# Verify a lost completion record with another worker still active causes an idle timeout.
test_scheduler_termination_15() {
	local \
		TEST_ID=scheduler_termination_15 \
		sched_rv \
		jobs='crash hang'

	print_test_header "${TEST_ID:?}" \
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
# Verify removing the scheduler FIFO during execution causes scheduler failure.
test_scheduler_termination_16() {
	local \
		TEST_ID=scheduler_termination_16 \
		sched_rv \
		scheduler_pid \
		jobs="ok5_1 ok5_2"

	print_test_header "${TEST_ID:?}" "FIFO disappearance during execution" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	# The FIFO lives in the scheduler's per-run dir under SCHED_DIR (/tmp),
	#   whose '.<n>' suffix is chosen at runtime; match it by a PID-scoped glob
	sleep 1
	rm -f /tmp/sched_"${scheduler_pid}".*/ipc

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

# Verify sch_finalize() runs with a correct IFS when a signal fires while the scheduler is blocked in `IFS= read`:
#   the read's IFS= prefix assignment must not leak into the trap handler.
# A leaked empty IFS collapses the finalize callback's running_pids/unfinished_ids into a single field.
# With 3 concurrent jobs, SIGUSR1 mid-wait must yield running_pids and unfinished_ids that split into 3 fields each.
test_scheduler_termination_17() {
	scheduler_termination_17_do_job() { sleep 30; return 0; }

	scheduler_termination_17_finalize_handler() {
		local rv="${1}" pids="${2}" unfinished="${5}" pid_cnt=0 unf_cnt=0

		# Split with the IFS that is live inside sch_finalize (the property under test)
		[ -z "${pids}" ] || { set -- ${pids}; pid_cnt=$#; }
		[ -z "${unfinished}" ] || { set -- ${unfinished}; unf_cnt=$#; }
		printf '%s %s %s\n' "${rv}" "${pid_cnt}" "${unf_cnt}" > "${OUT_FILE:?}"

		# Reuse the shared handler to kill the workers
		finalize_handler "${rv}" "${pids}"
	}

	local \
		TEST_ID=scheduler_termination_17 \
		sched_rv \
		out fin_rv pid_cnt unf_cnt \
		schedule_pid \
		jobs='ifsfin_1 ifsfin_2 ifsfin_3'

	local OUT_FILE="/tmp/sched.ifsfinalize.${TEST_ID:?}.$$"
	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Correct IFS in sch_finalize on signal during read" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=scheduler_termination_17_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=scheduler_termination_17_do_job \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=15 \
		schedule_jobs "${jobs}" &

	schedule_pid=$!

	# Let all 3 jobs dispatch and the scheduler settle into the read wait
	sleep 2
	kill -USR1 "${schedule_pid}"

	wait "${schedule_pid}"
	sched_rv=$?

	read_first_line out "${OUT_FILE}"
	rm -f "${OUT_FILE}"
	# The test body's IFS is the default, so this split is reliable
	set -- ${out}
	fin_rv="${1}" pid_cnt="${2}" unf_cnt="${3}"

	if [ "${sched_rv}" = 83 ] &&
		[ "${fin_rv}" = 83 ] &&
		[ "${pid_cnt}" = 3 ] &&
		[ "${unf_cnt}" = 3 ]
	then
		PASS "pid_cnt=${pid_cnt}, unf_cnt=${unf_cnt}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, fin_rv=${fin_rv}, pid_cnt=${pid_cnt}, unf_cnt=${unf_cnt}, out='${out}'"
		return 1
	fi
}
