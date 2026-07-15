#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-timeout.sh

# Category: Per-job timeouts (see TIMEKEEPING.md)
# This file is sourced by tests.sh; it defines test_N functions only.
# All tests exercise the public interface only: schedule_jobs(), the
# documented helpers (job_set_timeout etc.), environment variables and
# callbacks. No test depends on scheduler internals.

#
# Tests
#

# Verify job_set_timeout(): accepts valid values and rejects invalid values
#   and job IDs (API return values and error messages); behaviorally, the
#   last value set for a job wins, and a leading-zero value is treated as
#   decimal (a regression there would abort the scheduler with an arithmetic
#   error at deadline registration).
test_timeout_01() {
	timeout_01_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=timeout_01 \
		val rv rv_lsw rv_oct \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		expected_msg_cnt=10

	local MSG_FILE="/tmp/sched.jobtimeout.msg.${TEST_ID:?}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_set_timeout(): validation and behavioral effect" "hang_t01lsw / hang_t01oct"

	# Valid values (incl. leading zeros and re-setting): rv 0, no message
	for val in 5 010 0900 1; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout t01_ok "${val}"
		rv=$?
		if [ "${rv}" = 0 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpectedly rejected value '%s' (rv=%s)\n" "${val}" "${rv}" >&2
		fi
	done

	# Invalid values: rv 1, one message each
	# (stderr silenced: the out-of-range input makes the test builtin
	#  print a diagnostic on some shells)
	for val in '' 0 00 abc -1 1.5 +1 99999999999999999999; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout t01_bad "${val}" 2>/dev/null
		rv=$?
		if [ "${rv}" = 1 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpectedly accepted timeout value '%s' (rv=%s)\n" "${val}" "${rv}" >&2
		fi
	done

	# Invalid job IDs: rv 1, one message each
	for val in 'bad-id' ''; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout "${val}" 5
		rv=$?
		if [ "${rv}" = 1 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpectedly accepted job ID '%s' (rv=%s)\n" "${val}" "${rv}" >&2
		fi
	done

	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	# Behavior: the last value set wins - with the 1s override in effect the
	# hung job expires before the 3s idle timeout (rv 0); a stale first
	# value (5s) would instead end the run with rv 81
	job_set_timeout hang_t01lsw 5 &&
	job_set_timeout hang_t01lsw 1 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs 'hang_t01lsw' &

	wait "$!"
	rv_lsw=$?

	# Behavior: a leading-zero value must be handled as decimal - stored
	# verbatim, '09' would abort the scheduler at deadline registration
	# (invalid octal in arithmetic) instead of reaching the global timeout
	job_set_timeout hang_t01oct 09 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=2 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs 'hang_t01oct' &

	wait "$!"
	rv_oct=$?

	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = "${expected_msg_cnt}" ] &&
		[ "${rv_lsw}" = 0 ] && [ "${rv_oct}" = 82 ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}, rv_lsw=${rv_lsw}, rv_oct=${rv_oct}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt} (expected ${expected_msg_cnt}), rv_lsw=${rv_lsw} (expected 0), rv_oct=${rv_oct} (expected 82)"
		return 1
	fi
}

# Verify deadline-list integrity across completion wakes (regression test for
#   a real bug where each wake duplicated pending deadline entries): instant
#   jobs complete while two staggered deadlines (1s/3s) are pending; each
#   hung job must time out exactly once, with no duplicate pids reported.
test_timeout_02() {
	timeout_02_done() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"; }
	timeout_02_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "pids=$2" "fail=$4" "unfin=$5" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_02 \
		sched_rv pid_a pid_b \
		checks_ok=1 \
		jobs='hang_t02a hang_t02b instant_t02a instant_t02b instant_t02c'

	local \
		DONE_FILE="/tmp/sched.t02.done.$$" \
		FIN_FILE="/tmp/sched.t02.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Pending deadlines survive completion wakes; each job times out exactly once" "${jobs}"

	job_set_timeout hang_t02a 1 &&
	job_set_timeout hang_t02b 3 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_02_finalize \
	JOB_DONE_CB=timeout_02_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=5 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	# Exactly one timeout record per hung job (a multi-line result here
	# means duplicates and fails the uint check)
	pid_a="$(sed -n 's/^3|hang_t02a|124|\([0-9][0-9]*\)$/\1/p' "${DONE_FILE}" 2>/dev/null)"
	pid_b="$(sed -n 's/^3|hang_t02b|124|\([0-9][0-9]*\)$/\1/p' "${DONE_FILE}" 2>/dev/null)"

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	is_uint "${pid_a}" && is_uint "${pid_b}" ||
		{ checks_ok=; echo "expected exactly one timeout record per hung job: $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }
	[ "$(wc -l < "${DONE_FILE}" 2>/dev/null)" -eq 5 ] 2>/dev/null ||
		{ checks_ok=; echo "expected exactly 5 callback records: $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }
	grep -q '^expired=hang_t02a hang_t02b$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^fail=$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "outcome sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }
	grep -q "^pids=${pid_a} ${pid_b}$" "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "abandoned pids mismatch or duplicated" >&2; }

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify simultaneous multi-expiry through the public interface: three hung
#   jobs sharing a 1s default budget - with IDs containing ':' and glob
#   characters - are all classified as timed out: one (id, 124, pid) callback
#   each, exact expired set, all abandoned pids reported, scheduler exits 0.
test_timeout_03() {
	timeout_03_done() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"; }
	timeout_03_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "pids=$2" "fail=$4" "unfin=$5" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_03 \
		sched_rv pid_cnt \
		checks_ok=1 \
		jobs='hang_t03a hang_t03:q:r hang_t03*g'

	local \
		DONE_FILE="/tmp/sched.t03.done.$$" \
		FIN_FILE="/tmp/sched.t03.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Simultaneous expiries with adversarial job IDs (SCHED_JOB_TIMEOUT_S)" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_03_finalize \
	JOB_DONE_CB=timeout_03_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
	SCHED_JOB_TIMEOUT_S=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	[ "$(grep -c -F '|124|' "${DONE_FILE}" 2>/dev/null)" = 3 ] &&
	grep -q -F '3|hang_t03a|124|' "${DONE_FILE}" 2>/dev/null &&
	grep -q -F '3|hang_t03:q:r|124|' "${DONE_FILE}" 2>/dev/null &&
	grep -q -F '3|hang_t03*g|124|' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "expected one timeout record per job: $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }
	grep -qxF 'expired=hang_t03a hang_t03:q:r hang_t03*g' "${FIN_FILE}" 2>/dev/null &&
	grep -qxF 'fail=' "${FIN_FILE}" 2>/dev/null &&
	grep -qxF 'unfin=' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "outcome sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }
	pid_cnt="$(sed -n 's/^pids=//p' "${FIN_FILE}" 2>/dev/null | wc -w)"
	[ "${pid_cnt}" = 3 ] ||
		{ checks_ok=; echo "expected 3 abandoned pids, got '${pid_cnt}'" >&2; }

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify a completed job's pending deadline is retired with it: ok1 (1s run,
#   2s budget) completes and must never be reported as timed out, while a
#   second hung job (3s budget) keeps the scheduler alive past the retired
#   deadline and then drains normally.
test_timeout_04() {
	timeout_04_done() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"; }
	timeout_04_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "ok=$3" "fail=$4" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_04 \
		sched_rv \
		checks_ok=1 \
		jobs='ok1_t04 hang_t04'

	local \
		DONE_FILE="/tmp/sched.t04.done.$$" \
		FIN_FILE="/tmp/sched.t04.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "A completed job's deadline is retired (no late timeout for it)" "${jobs}"

	job_set_timeout ok1_t04 2 &&
	job_set_timeout hang_t04 3 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_04_finalize \
	JOB_DONE_CB=timeout_04_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	grep -q '^2|ok1_t04|0|$' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "missing normal completion record for ok1_t04" >&2; }
	[ "$(grep -c -F '|124|' "${DONE_FILE}" 2>/dev/null)" = 1 ] &&
	grep -q '^3|hang_t04|124|' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "expected exactly one timeout record (hang_t04): $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }
	grep -q '^ok=ok1_t04$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^fail=$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^expired=hang_t04$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "outcome sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify the late-record discard path (see TIMEKEEPING.md): when a timed-out
#   job's completion record arrives after its expiry was processed, the record
#   is dropped, the timeout classification stands, and the job is delisted
#   from the abandoned set (so finalize's <running_pids> is empty).
#   Determinism: JOB_DONE_CB forges the late record into the completion FIFO
#   the moment it receives the synthesized timeout notification -
#   byte-for-byte what the real late record would be.
test_timeout_05() {
	timeout_05_done() {
		[ "${2}" = 124 ] && [ -n "${3:-}" ] &&
			printf '%s 0 %s\n' "${3}" "${1}" >&3
		printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"
		return 0
	}
	timeout_05_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "pids=$2" "fail=$4" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_05 \
		sched_rv hung_pid \
		checks_ok=1 \
		jobs='hang_t05x ok2_t05'

	local \
		DONE_FILE="/tmp/sched.t05.done.$$" \
		FIN_FILE="/tmp/sched.t05.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Late completion record from a timed-out job is discarded" "${jobs}"

	job_set_timeout hang_t05x 1 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_05_finalize \
	JOB_DONE_CB=timeout_05_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	[ "$(grep -c '^3|hang_t05x|124|' "${DONE_FILE}" 2>/dev/null)" = 1 ] ||
		{ checks_ok=; echo "expected exactly one timeout record for hang_t05x" >&2; }
	grep -q '^2|ok2_t05|0|$' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "missing ok record for ok2_t05" >&2; }
	[ "$(wc -l < "${DONE_FILE}" 2>/dev/null)" -eq 2 ] 2>/dev/null ||
		{ checks_ok=; echo "unexpected extra callback invocations: $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }
	grep -q '^expired=hang_t05x$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^fail=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "expired/fail set mismatch (job classified twice?)" >&2; }
	grep -q '^pids=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "abandoned pid not delisted after record discard" >&2; }

	# The hung job's process is still sleeping; clean it up
	hung_pid="$(sed -n 's/^3|hang_t05x|124|\([0-9][0-9]*\)$/\1/p' "${DONE_FILE}" 2>/dev/null)"
	is_uint "${hung_pid}" && kill "${hung_pid}" 2>/dev/null

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify batch survival: a hung job with a per-job timeout is classified as
#   timed out (JOB_DONE_CB gets rv 124 plus the pid as a third argument),
#   healthy jobs complete, the scheduler exits 0, and the abandoned pid is
#   reported to the finalize callback in <running_pids>.
test_timeout_06() {
	timeout_06_done() {
		printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"
	}
	timeout_06_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "pids=$2" "ok=$3" "fail=$4" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_06 \
		sched_rv done_pid \
		checks_ok=1 \
		jobs='hang_t06 instant_t06a instant_t06b'

	local \
		DONE_FILE="/tmp/sched.t06.done.$$" \
		FIN_FILE="/tmp/sched.t06.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Hung job times out (rv 124 + pid), batch completes with rv 0" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_06_finalize \
	JOB_DONE_CB=timeout_06_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
	SCHED_JOB_TIMEOUT_S=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	# Timed-out job: 3 args, rv 124, uint pid
	done_pid="$(sed -n 's/^3|hang_t06|124|\([0-9][0-9]*\)$/\1/p' "${DONE_FILE}" 2>/dev/null)"

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	is_uint "${done_pid}" || { checks_ok=; echo "no timeout record with uint pid in DONE_FILE" >&2; }
	grep -q '^2|instant_t06a|0|$' "${DONE_FILE}" 2>/dev/null &&
	grep -q '^2|instant_t06b|0|$' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "missing 2-arg ok records in DONE_FILE" >&2; }
	grep -q "^expired=hang_t06$" "${FIN_FILE}" 2>/dev/null &&
	grep -q "^fail=$" "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "finalize expired/fail-set mismatch" >&2; }
	grep -q "^pids=${done_pid}$" "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "finalize running_pids != pid reported to JOB_DONE_CB" >&2; }

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}, abandoned_pid=${done_pid}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify slot reclamation: with SCHED_MAX_JOBS=1, a hung job's expiry inside
#   the capacity-wait loop frees the slot and the queued job gets dispatched.
#   Also guards the deadline cap on the completion-wait read timeout: without
#   the cap, the wait would sleep past the 1s deadline and hit the 3s idle
#   timeout (rv 81).
test_timeout_07() {
	timeout_07_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "ok=$3" "expired=$7" "undisp=$6" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_07 \
		sched_rv \
		checks_ok=1 \
		jobs='hang_t07 instant_t07'

	local FIN_FILE="/tmp/sched.t07.fin.$$"
	rm -f "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Expiry in the capacity-wait loop reclaims the slot (SCHED_MAX_JOBS=1)" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_07_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=3 \
	SCHED_JOB_TIMEOUT_S=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	grep -q '^ok=instant_t07$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "queued job did not complete" >&2; }
	grep -q '^expired=hang_t07$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "hung job not classified as expired" >&2; }
	grep -q '^undisp=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "undispatched set not empty" >&2; }

	rm -f "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify a per-job timeout (job_set_timeout) overrides ${SCHED_JOB_TIMEOUT_S}:
#   with a default far beyond ${SCHED_TIMEOUT_S}, only the override can expire
#   the hung job before the global timeout would abort the run.
test_timeout_08() {
	local \
		TEST_ID=timeout_08 \
		sched_rv \
		jobs='hang_t08 instant_t08'

	print_test_header "${TEST_ID:?}" "job_set_timeout() overrides SCHED_JOB_TIMEOUT_S" "${jobs}"

	job_set_timeout hang_t08 1 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=4 \
	SCHED_IDLE_TIMEOUT_S=3 \
	SCHED_JOB_TIMEOUT_S=20 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0 (override did not fire before global timeout)"
		return 1
	fi
}

# Verify a job that genuinely exits with code 124 is reported to JOB_DONE_CB
#   with exactly two arguments (no pid), even while per-job timeouts are active.
test_timeout_09() {
	timeout_09_do_job() {
		[ "${1}" = t09_g124 ] && return 124
		return 0
	}
	timeout_09_done() {
		printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"
	}

	local \
		TEST_ID=timeout_09 \
		sched_rv \
		checks_ok=1 \
		jobs='t09_g124'

	local DONE_FILE="/tmp/sched.t09.done.$$"
	rm -f "${DONE_FILE}"

	print_test_header "${TEST_ID:?}" "Genuine job exit code 124 is reported without a pid argument" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=timeout_09_done \
	DO_JOB_CB=timeout_09_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
	SCHED_JOB_TIMEOUT_S=8 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 0" >&2; }
	grep -q '^2|t09_g124|124|$' "${DONE_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "expected 2-arg record with rv 124, got: $(cat "${DONE_FILE}" 2>/dev/null)" >&2; }

	rm -f "${DONE_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify scheduler timeouts outrank job deadlines: a global timeout due before
#   any job deadline exits with rv 82, the job stays unfinished (not failed),
#   and no timeout completion is synthesized.
test_timeout_10() {
	timeout_10_done() {
		printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"
	}
	timeout_10_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "fail=$4" "unfin=$5" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_10 \
		sched_rv \
		checks_ok=1 \
		jobs='hang_t10'

	local \
		DONE_FILE="/tmp/sched.t10.done.$$" \
		FIN_FILE="/tmp/sched.t10.fin.$$"
	rm -f "${DONE_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Global timeout (1s) outranks a later job deadline (3s)" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_10_finalize \
	JOB_DONE_CB=timeout_10_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_JOB_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 82 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 82" >&2; }
	[ ! -s "${DONE_FILE}" ] ||
		{ checks_ok=; echo "unexpected completion records: $(cat "${DONE_FILE}")" >&2; }
	grep -q '^fail=$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=hang_t10$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "finalize sets mismatch" >&2; }

	rm -f "${DONE_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify idle-timeout semantics vs job deadlines (see TIMEKEEPING.md):
#   expiries do NOT reset the idle timeout. Draining hung jobs with staggered
#   1s/3s deadlines: a 2s idle timeout fires after the first expiry (rv 81,
#   half-drained outcome sets), while an idle timeout larger than the biggest
#   job budget (5s > 3s) lets every deadline fire first (rv 0, full drain).
#   Also guards the deadline cap on the completion-wait read timeout: without
#   the cap, the first wake in sub-check 2 would be at the 5s idle limit.
test_timeout_11() {
	timeout_11_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "expired=$7" "unfin=$5" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_11 \
		rv_abort rv_drain \
		checks_ok=1 \
		jobs='hang_t11a hang_t11b'

	local FIN_FILE="/tmp/sched.t11.fin.$$"
	rm -f "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Expiries do not reset the idle timeout; idle > max budget drains fully" "${jobs}"

	job_set_timeout hang_t11a 1 &&
	job_set_timeout hang_t11b 3 || { FAIL "job_set_timeout failed"; return 1; }

	# Sub-check 1: idle (2s) < max budget (3s). The 1s expiry does not reset
	# the idle clock (anchored at dispatch), so rv 81 fires at ~2s, before
	# hang_t11b's 3s deadline: half-drained outcome sets
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_11_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv_abort=$?

	[ "${rv_abort}" = 81 ] || { checks_ok=; echo "rv_abort=${rv_abort}, expected 81" >&2; }
	grep -q '^expired=hang_t11a$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=hang_t11b$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "half-drained sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }

	rm -f "${FIN_FILE}"

	# Sub-check 2: idle (5s) > max budget (3s): every deadline fires before
	# the idle timeout can, the run drains and exits 0 with both jobs expired
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_11_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	rv_drain=$?

	[ "${rv_drain}" = 0 ] || { checks_ok=; echo "rv_drain=${rv_drain}, expected 0" >&2; }
	grep -q '^expired=hang_t11a hang_t11b$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "full-drain sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }

	rm -f "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv_abort=${rv_abort}, rv_drain=${rv_drain}"
		return 0
	else
		FAIL "rv_abort=${rv_abort}, rv_drain=${rv_drain}"
		return 1
	fi
}

# Verify a non-zero JOB_DONE_CB return on a synthesized timeout notification
#   (rv 124 + pid, invoked from the deadline sweep) aborts the scheduler with
#   the callback's code; the timed-out job is already in the expired set and its
#   abandoned pid is in <running_pids>. The normal-completion counterpart of
#   this contract is covered by core_03.
test_timeout_12() {
	timeout_12_done() {
		if [ "${2}" = 124 ]; then
			printf '%s\n' "${3:-}" > "${PID_FILE:?}"
			return 98
		fi
		return 0
	}
	timeout_12_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "pids=$2" "expired=$7" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_12 \
		sched_rv cb_pid \
		checks_ok=1 \
		jobs='hang_t12'

	local \
		PID_FILE="/tmp/sched.t12.pid.$$" \
		FIN_FILE="/tmp/sched.t12.fin.$$"
	rm -f "${PID_FILE}" "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Non-zero JOB_DONE_CB return on a timeout notification aborts the scheduler" "${jobs}"

	job_set_timeout hang_t12 1 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_12_finalize \
	JOB_DONE_CB=timeout_12_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line cb_pid "${PID_FILE}"

	[ "${sched_rv}" = 98 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 98" >&2; }
	grep -q '^expired=hang_t12$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "expired set mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }
	is_uint "${cb_pid}" && grep -q "^pids=${cb_pid}$" "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "abandoned pid mismatch: cb saw '${cb_pid}'" >&2; }

	rm -f "${PID_FILE}" "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify a job start resets the idle timeout: with dispatches staggered by a
#   1s tick stall, a 2s idle timeout survives the whole dispatch phase (all
#   jobs dispatched, none left undispatched) and fires only ~2s after the
#   last dispatch (~4s total). Without the reset, the run would abort
#   mid-dispatch (~2s), leaving the last job undispatched.
test_timeout_13() {
	timeout_13_dispatch_tick() {
		# 'sleep N & wait' forces a forked sleep: an in-process NOFORK builtin
		# sleep would be cut short by SIGCHLD from an exiting job
		sleep 1 & wait "$!"
	}
	timeout_13_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "unfin=$5" "undisp=$6" > "${FIN_FILE:?}"
	}

	local \
		TEST_ID=timeout_13 \
		sched_rv start_s end_s elapsed \
		checks_ok=1 \
		jobs='hang_t13a hang_t13b hang_t13c'

	local FIN_FILE="/tmp/sched.t13.fin.$$"
	rm -f "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Job starts reset the idle timeout (staggered dispatch survives 2s idle)" "${jobs}"

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=timeout_13_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_DISPATCH_TICK_CB=timeout_13_dispatch_tick \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?
	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	[ "${sched_rv}" = 81 ] || { checks_ok=; echo "sched_rv=${sched_rv}, expected 81" >&2; }
	grep -q '^undisp=$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "job left undispatched: dispatch did not reset the idle timeout" >&2; }
	grep -q '^unfin=hang_t13a hang_t13b hang_t13c$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "unfinished set mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }
	[ "${elapsed}" -ge 3 ] && [ "${elapsed}" -le 6 ] ||
		{ checks_ok=; echo "elapsed=${elapsed}s, expected 3..6" >&2; }

	rm -f "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}, elapsed=${elapsed}s"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, elapsed=${elapsed}s"
		return 1
	fi
}

# Verify a job's deadline is anchored at its dispatch time (not scheduler
#   start) and never fires early: a job with a 1s budget dispatched ~1s in
#   (capacity-delayed behind ok1) must expire at ~2s, so the run lasts at
#   least 2s and drains to rv 0.
test_timeout_14() {
	local \
		TEST_ID=timeout_14 \
		sched_rv start_s end_s elapsed \
		jobs='ok1_t14 hang_t14'

	print_test_header "${TEST_ID:?}" "Deadline anchored at dispatch time (capacity-delayed job)" "${jobs}"

	job_set_timeout hang_t14 1 || { FAIL "job_set_timeout failed"; return 1; }

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?
	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	if [ "${sched_rv}" = 0 ] &&
		[ "${elapsed}" -ge 2 ] && [ "${elapsed}" -le 4 ]
	then
		PASS "sched_rv=${sched_rv}, elapsed=${elapsed}s"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, elapsed=${elapsed}s, expected rv 0 and 2<=elapsed<=4 (elapsed<2 means the deadline was anchored before dispatch or fired early)"
		return 1
	fi
}
