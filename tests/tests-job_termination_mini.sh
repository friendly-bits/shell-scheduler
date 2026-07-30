#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-job_termination_mini.sh

# Category: job termination, mini-variant only.
#   The mini variant uses a simplified JOB_TERM_CB protocol - the callback is
#   invoked as 'CB <pid>...' (no init/setup/term/cleanup subcommands, no
#   out-var) - and ships a built-in ppid-walk mechanism, sched_job_term_mini.
#   Shared infrastructure (do_job_default, is_uint, ...) comes from tests.sh.

# This file is sourced by tests.sh; it defines test_job_termination_mini_NN functions only.

# The mini JOB_TERM_CB protocol passes job PIDs directly as positional args:
#   a USR1 abort of a running job must invoke the callback with a PID as $1
#   (never a 'term'/'setup'/... subcommand word, as the full protocol would).
test_job_termination_mini_01() {
	mini_01_cb() {
		printf 'argc=%s arg1=%s\n' "${#}" "${1}" >> "${REC_FILE:?}"
		kill -KILL "${@}" 2>/dev/null
		:
	}

	local \
		TEST_ID=job_termination_mini_01 \
		sched_pid sched_rv checks_pass=0 checks_exp=3 rec argc arg1 \
		recs=0 argc_ok=0 arg1_ok=0 \
		job_id='hang_m01'

	local REC_FILE="/tmp/sched.job_termination_mini.rec.${TEST_ID}.$$"
	rm -f "${REC_FILE}"

	print_test_header "${TEST_ID}" "mini: JOB_TERM_CB invoked as 'CB <pid>...' (simplified protocol)" "${job_id}"

	require_variant mini || return 2

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	JOB_TERM_CB=mini_01_cb \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
		schedule_jobs "${job_id}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	if [ -f "${REC_FILE}" ]; then
		while IFS= read -r rec; do
			recs=$((recs + 1))
			argc="${rec#argc=}"; argc="${argc%% *}"
			arg1="${rec##* arg1=}"
			[ "${argc}" -ge 1 ] 2>/dev/null && argc_ok=$((argc_ok + 1)) ||
				echo "callback argc='${argc}' (want >=1)"
			is_uint "${arg1}" && arg1_ok=$((arg1_ok + 1)) ||
				echo "callback \$1='${arg1}' is not a PID (full-protocol subcommand leaked?)"
		done < "${REC_FILE}"
	fi
	rm -f "${REC_FILE}"

	# recs=0 means the callback was never invoked
	[ "${recs}" -ge 1 ] && [ "${argc_ok}" = "${recs}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "argc ok in ${argc_ok} of ${recs} callback records"
	[ "${recs}" -ge 1 ] && [ "${arg1_ok}" = "${recs}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "\$1 was a PID in ${arg1_ok} of ${recs} callback records"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "rv=83, callback received PIDs as positional args"
		return 0
	else
		FAIL
		return 1
	fi
}

# sched_job_term_mini ignores invalid (non-uint) PID args with a warning and
#   still kills the valid seed. Direct helper call - no scheduler run.
test_job_termination_mini_02() {
	local \
		TEST_ID=job_termination_mini_02 \
		checks_pass=0 checks_exp=2 victim msg_cnt=0

	local MSG_FILE="/tmp/sched.job_termination_mini.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	mini_02_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	print_test_header "${TEST_ID}" "mini: sched_job_term_mini warns on invalid PID, kills valid seed" "(no jobs)"

	require_variant mini || return 2

	sleep 30 &
	victim=${!}

	SCHED_FAIL_MSG_CB=mini_02_fail_msg sched_job_term_mini notanumber "${victim}"

	sleep 1
	if kill -0 "${victim}" 2>/dev/null; then
		echo "valid seed ${victim} survived"
		kill -KILL "${victim}" 2>/dev/null
	else
		checks_pass=$((checks_pass + 1))
	fi

	[ -f "${MSG_FILE}" ] && msg_cnt=$(grep -c "invalid PID 'notanumber'" "${MSG_FILE}")
	[ "${msg_cnt}" -ge 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "no 'invalid PID' warning emitted (msg_cnt=${msg_cnt})"
	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "invalid PID warned, valid seed killed"
		return 0
	else
		FAIL
		return 1
	fi
}

# With the /proc scan disabled (awk missing), sched_job_term_mini reports the
#   scan failure but still kills the seed PIDs. Direct helper call - no scheduler run.
test_job_termination_mini_03() {
	local \
		TEST_ID=job_termination_mini_03 \
		checks_pass=0 checks_exp=2 victim msg_cnt=0

	local MSG_FILE="/tmp/sched.job_termination_mini.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	mini_03_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	print_test_header "${TEST_ID}" "mini: sched_job_term_mini kills seeds even when /proc scan fails" "(no jobs)"

	require_variant mini || return 2

	sleep 30 &
	victim=${!}

	SCHED_AWK_CMD=/nonexistent/nope SCHED_FAIL_MSG_CB=mini_03_fail_msg \
		sched_job_term_mini "${victim}"

	sleep 1
	if kill -0 "${victim}" 2>/dev/null; then
		echo "seed ${victim} survived a scan failure"
		kill -KILL "${victim}" 2>/dev/null
	else
		checks_pass=$((checks_pass + 1))
	fi

	[ -f "${MSG_FILE}" ] && msg_cnt=$(grep -c '/proc scan failed' "${MSG_FILE}")
	[ "${msg_cnt}" -ge 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "no '/proc scan failed' message emitted (msg_cnt=${msg_cnt})"
	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "scan failure reported, seed killed"
		return 0
	else
		FAIL
		return 1
	fi
}
