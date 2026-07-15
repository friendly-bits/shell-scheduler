#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-timeout.sh

# Category: Per-job timeouts (see TIMEKEEPING.md)
# This file is sourced by tests.sh; it defines test_N functions only.
# Tests 01-04 use direct helper calls (no scheduler runs);
# tests 05+ are scheduler-level behavior tests.

#
# Tests
#

# Verify job_set_timeout(): accepts and decimal-normalizes valid values,
#   rejects invalid values and invalid job IDs without setting anything.
test_timeout_01() {
	timeout_01_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=timeout_01 \
		tc rv stored bad \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		expected_msg_cnt=10

	local MSG_FILE="/tmp/sched.jobtimeout.msg.${TEST_ID:?}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_set_timeout(): validation and normalization" "(direct calls, no scheduler run)"

	# Valid values: rv 0, normalized decimal stored (t01_a set twice: override)
	for tc in "t01_a 5 5" "t01_b 010 10" "t01_a 7 7" "t01_c 0900 900"; do
		# shellcheck disable=SC2086
		set -- ${tc}
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout "${1}" "${2}"
		rv=$?
		eval "stored=\"\${SCH_TIMEOUT_JOB_${1}}\""
		if [ "${rv}" = 0 ] && [ "${stored}" = "${3}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpected result for id '%s' value '%s': rv=%s, stored='%s' (expected rv=0, stored='%s')\n" \
				"${1}" "${2}" "${rv}" "${stored}" "${3}" >&2
		fi
	done

	# Invalid values: rv 1, one message each, nothing stored
	# (stderr silenced: the out-of-range input makes the test builtin
	#  print a diagnostic on some shells)
	for bad in '' 0 00 abc -1 1.5 +1 99999999999999999999; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout t01_d "${bad}" 2>/dev/null
		rv=$?
		if [ "${rv}" = 1 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpectedly accepted timeout value '%s' (rv=%s)\n" "${bad}" "${rv}" >&2
		fi
	done

	total_cnt=$((total_cnt + 1))
	if [ -z "${SCH_TIMEOUT_JOB_t01_d+x}" ]; then
		pass_cnt=$((pass_cnt + 1))
	else
		printf "SCH_TIMEOUT_JOB_t01_d unexpectedly set to '%s'\n" "${SCH_TIMEOUT_JOB_t01_d}" >&2
	fi

	# Invalid job IDs: rv 1, one message each
	for bad in 'bad-id' ''; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=timeout_01_fail_msg job_set_timeout "${bad}" 5
		rv=$?
		if [ "${rv}" = 1 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpectedly accepted job ID '%s' (rv=%s)\n" "${bad}" "${rv}" >&2
		fi
	done

	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = "${expected_msg_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt} (expected ${expected_msg_cnt})"
		return 1
	fi
}

# Verify sch_sweep_deadlines() list bookkeeping: sweeps with nothing expired
#   are no-ops (in particular, repeated sweeps must not duplicate pending
#   entries - regression test for a real bug), and a mixed list splits
#   cleanly with order preserved on both sides. Direct calls, no scheduler run.
test_timeout_02() {
	timeout_02_done() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"; }

	# 1: description  2: expected  3: actual
	timeout_02_check() {
		total_cnt=$((total_cnt + 1))
		if [ "${3}" = "${2}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "%s: got '%s', expected '%s'\n" "${1}" "${3}" "${2}" >&2
		fi
	}

	local \
		TEST_ID=timeout_02 \
		now e_a e_b e_gone e_xy \
		pass_cnt=0 \
		total_cnt=0 \
		SCH_RUNNING_PIDS SCH_RUNNING_JOBS_CNT \
		SCH_DEADLINES SCH_EXPIRED SCH_FAIL_IDS

	local DONE_FILE="/tmp/sched.t02.done.$$"
	rm -f "${DONE_FILE}"

	print_test_header "${TEST_ID:?}" "sch_sweep_deadlines(): no-op and split bookkeeping" "(direct calls, no scheduler run)"

	sch_get_uptime_cs now || { FAIL "sch_get_uptime_cs failed"; return 1; }

	# Pending deadlines are 600+ s in the future; expired ones are <= now
	# (the sweep re-reads the clock, which can only move forward)
	e_a="11:$((now + 60000)):t02_a"
	e_b="22:$((now + 70000)):t02:b:c"
	e_gone="44:$((now - 100)):t02_gone"
	e_xy="55:${now}:t02:x:y"

	# Pending-only list: two consecutive sweeps must change nothing
	SCH_DEADLINES="${e_a} ${e_b}"
	SCH_EXPIRED='' SCH_FAIL_IDS=''
	SCH_RUNNING_PIDS="11 22" SCH_RUNNING_JOBS_CNT=2

	sch_sweep_deadlines timeout_02_done
	timeout_02_check "deadlines after 1st no-op sweep" "${e_a} ${e_b}" "${SCH_DEADLINES}"
	sch_sweep_deadlines timeout_02_done
	timeout_02_check "deadlines after 2nd no-op sweep" "${e_a} ${e_b}" "${SCH_DEADLINES}"
	timeout_02_check "count untouched" 2 "${SCH_RUNNING_JOBS_CNT}"
	timeout_02_check "pids untouched" "11 22" "${SCH_RUNNING_PIDS}"
	timeout_02_check "expired list untouched" "" "${SCH_EXPIRED}"
	timeout_02_check "fail ids untouched" "" "${SCH_FAIL_IDS}"
	timeout_02_check "no callbacks invoked" "" "$(cat "${DONE_FILE}" 2>/dev/null)"

	# Mixed list: expired entries (deadline <= now) leave, pending survive
	# exactly once, order preserved on both sides
	SCH_DEADLINES="${e_gone} ${e_a} ${e_xy} ${e_b}"
	SCH_EXPIRED='' SCH_FAIL_IDS=''
	SCH_RUNNING_PIDS="44 11 55 22" SCH_RUNNING_JOBS_CNT=4

	sch_sweep_deadlines timeout_02_done
	timeout_02_check "pending survive once, in order" "${e_a} ${e_b}" "${SCH_DEADLINES}"
	timeout_02_check "count decremented by expired count" 2 "${SCH_RUNNING_JOBS_CNT}"
	timeout_02_check "expired pids removed" "11 22" "${SCH_RUNNING_PIDS}"
	timeout_02_check "expired entries recorded in order" "${e_gone} ${e_xy}" "${SCH_EXPIRED}"
	timeout_02_check "fail ids in order" "t02_gone t02:x:y" "${SCH_FAIL_IDS}"
	timeout_02_check "callback records (id, 124, pid)" "3|t02_gone|124|44
3|t02:x:y|124|55" "$(cat "${DONE_FILE}" 2>/dev/null)"

	rm -f "${DONE_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}"
		return 1
	fi
}

# Verify sch_sweep_deadlines() expiry effects: exact multi-expiry accounting
#   (counter, pid removal), callback arguments (id, 124, pid), and
#   accumulation onto pre-existing SCH_EXPIRED/SCH_FAIL_IDS state.
#   Direct calls, no scheduler run.
test_timeout_03() {
	timeout_03_done() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}" >> "${DONE_FILE:?}"; }

	# 1: description  2: expected  3: actual
	timeout_03_check() {
		total_cnt=$((total_cnt + 1))
		if [ "${3}" = "${2}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "%s: got '%s', expected '%s'\n" "${1}" "${3}" "${2}" >&2
		fi
	}

	local \
		TEST_ID=timeout_03 \
		now e_p e_qr e_glob \
		pass_cnt=0 \
		total_cnt=0 \
		SCH_RUNNING_PIDS SCH_RUNNING_JOBS_CNT \
		SCH_DEADLINES SCH_EXPIRED SCH_FAIL_IDS

	local DONE_FILE="/tmp/sched.t03.done.$$"
	rm -f "${DONE_FILE}"

	print_test_header "${TEST_ID:?}" "sch_sweep_deadlines(): multi-expiry accounting and callbacks" "(direct calls, no scheduler run)"

	sch_get_uptime_cs now || { FAIL "sch_get_uptime_cs failed"; return 1; }

	e_p="77:$((now - 300)):t03_p"
	e_qr="88:$((now - 200)):t03:q:r"
	e_glob="99:$((now - 100)):*"

	SCH_DEADLINES="${e_p} ${e_qr} ${e_glob}"
	SCH_EXPIRED="9:1:t03_old"
	SCH_FAIL_IDS="t03_old"
	SCH_RUNNING_PIDS="500 77 88 99" SCH_RUNNING_JOBS_CNT=4

	sch_sweep_deadlines timeout_03_done

	timeout_03_check "all deadlines consumed" "" "${SCH_DEADLINES}"
	timeout_03_check "count decremented by 3" 1 "${SCH_RUNNING_JOBS_CNT}"
	timeout_03_check "unrelated pid kept" 500 "${SCH_RUNNING_PIDS}"
	timeout_03_check "expired accumulates onto existing state" \
		"9:1:t03_old ${e_p} ${e_qr} ${e_glob}" "${SCH_EXPIRED}"
	timeout_03_check "fail ids accumulate in order" "t03_old t03_p t03:q:r *" "${SCH_FAIL_IDS}"
	timeout_03_check "callback records (id, 124, pid)" "3|t03_p|124|77
3|t03:q:r|124|88
3|*|124|99" "$(cat "${DONE_FILE}" 2>/dev/null)"

	rm -f "${DONE_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}"
		return 1
	fi
}

# Verify sch_deadline_rm_pid(): exact pid match only, order preserved,
#   absent pid reported via return code.
test_timeout_04() {
	# 1: description  2: expected rv  3: expected list  4: actual rv  5: actual list
	timeout_04_check() {
		total_cnt=$((total_cnt + 1))
		if [ "${4}" = "${2}" ] && [ "${5}" = "${3}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "%s: got rv=%s list='%s', expected rv=%s list='%s'\n" \
				"${1}" "${4}" "${5}" "${2}" "${3}" >&2
		fi
	}

	local \
		TEST_ID=timeout_04 \
		tl_list="12:100:t04_a 123:200:t04:b 45:300:*" \
		tl_out rv \
		pass_cnt=0 \
		total_cnt=0

	print_test_header "${TEST_ID:?}" "sch_deadline_rm_pid(): exact match and ordering" "(direct calls, no scheduler run)"

	# Exact pid match: pid 12 must not match entry with pid 123
	sch_deadline_rm_pid tl_out 12 "${tl_list}"
	timeout_04_check "remove pid 12 (not 123)" 0 "123:200:t04:b 45:300:*" "$?" "${tl_out}"

	sch_deadline_rm_pid tl_out 123 "${tl_list}"
	timeout_04_check "remove middle pid 123" 0 "12:100:t04_a 45:300:*" "$?" "${tl_out}"

	sch_deadline_rm_pid tl_out 45 "${tl_list}"
	timeout_04_check "remove last pid 45" 0 "12:100:t04_a 123:200:t04:b" "$?" "${tl_out}"

	sch_deadline_rm_pid tl_out 999 "${tl_list}"
	timeout_04_check "absent pid" 1 "${tl_list}" "$?" "${tl_out}"

	sch_deadline_rm_pid tl_out 12 ""
	timeout_04_check "remove from empty list" 1 "" "$?" "${tl_out}"

	if [ "${pass_cnt}" = "${total_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}"
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
		printf '%s\n' "pids=$2" "fail=$4" > "${FIN_FILE:?}"
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
	grep -q '^fail=hang_t05x$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "fail set mismatch (job classified twice?)" >&2; }
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
		printf '%s\n' "pids=$2" "ok=$3" "fail=$4" > "${FIN_FILE:?}"
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
	grep -q "^fail=hang_t06$" "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "finalize fail-set mismatch" >&2; }
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
		printf '%s\n' "ok=$3" "fail=$4" "undisp=$6" > "${FIN_FILE:?}"
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
	grep -q '^fail=hang_t07$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "hung job not classified as failed" >&2; }
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
		printf '%s\n' "fail=$4" "unfin=$5" > "${FIN_FILE:?}"
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
	grep -q '^fail=hang_t11a$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=hang_t11b$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "half-drained sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }

	rm -f "${FIN_FILE}"

	# Sub-check 2: idle (5s) > max budget (3s): every deadline fires before
	# the idle timeout can, the run drains and exits 0 with both jobs failed
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
	grep -q '^fail=hang_t11a hang_t11b$' "${FIN_FILE}" 2>/dev/null &&
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
#   the callback's code; the timed-out job is already in the fail set and its
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
		printf '%s\n' "pids=$2" "fail=$4" > "${FIN_FILE:?}"
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
	grep -q '^fail=hang_t12$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "fail set mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }
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
