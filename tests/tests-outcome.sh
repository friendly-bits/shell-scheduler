#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-outcome.sh

# Category: Job Outcome Classification (ok/fail/unfinished/undispatched/expired/aborted)
# This file is sourced by tests.sh; it defines test_N functions only.

# verify_id_set / sets_finalize_handler live in tests.sh - the abort category uses them too.

#
# Tests
#

# Verify SCHED_FINALIZE_CB's ok/fail sets are correct on a normal completion
#   with no timeout/undispatched/unfinished jobs involved.
test_outcome_01() {
	local \
		TEST_ID=outcome_01 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw \
		exp_ok act_ok exp_fail act_fail \
		jobs='instant_1 instant_2 fail'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "SCHED_FINALIZE_CB ok/fail sets on normal completion" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	read_first_line --rm expired_raw "${FINALIZE_SETS_PREFIX}.expired"

	if [ "${sched_rv}" = 0 ] &&
		verify_id_set exp_ok act_ok "instant_1 instant_2" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "fail" "${fail_raw}" &&
		[ -z "${unfinished_raw}" ] &&
		[ -z "${undispatched_raw}" ] &&
		[ -z "${expired_raw}" ]
	then
		PASS "ok='${ok_raw}', fail='${fail_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'" \
			"unfinished_raw='${unfinished_raw}'" \
			"undispatched_raw='${undispatched_raw}'" \
			"expired_raw='${expired_raw}'"
		return 1
	fi
}

# Verify a job recorded as failed before an idle-timeout abort stays in the fail set,
#   while a still-running job at abort time lands in unfinished, not fail.
test_outcome_02() {
	local \
		TEST_ID=outcome_02 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		jobs='instant_o02 fail hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "Fail set survives idle-timeout abort; running job is unfinished, not failed" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"

	if [ "${sched_rv}" = 81 ] &&
		verify_id_set exp_ok act_ok "instant_o02" "${ok_raw}" &&
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

# Verify a job never reached by the dispatch loop before a global-timeout abort lands in undispatched,
#   while the job dispatched just before the abort (whose completion was never read) lands in unfinished.
test_outcome_03() {
	outcome_03_do_job() {
		[ "${1}" = second ] && printf 'dispatched\n' > "${SECOND_DISPATCHED_FILE:?}"
		return 0
	}

	outcome_03_dispatch_tick() {
		# 'sleep N & wait' forces a forked sleep: an in-process NOFORK builtin
		# sleep would be cut short by SIGCHLD from the exiting job
		[ "${1}" = first ] && { sleep 2 & wait "$!"; }
	}

	local \
		TEST_ID=outcome_03 \
		sched_rv \
		unfinished_raw undispatched_raw \
		exp_unfinished act_unfinished exp_undispatched act_undispatched \
		jobs='first second'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		SECOND_DISPATCHED_FILE="/tmp/sched.dispatch3.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${SECOND_DISPATCHED_FILE}"

	print_test_header "${TEST_ID:?}" "Global timeout during initial dispatch: undispatched vs. unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=outcome_03_do_job \
	SCHED_DISPATCH_TICK_CB=outcome_03_dispatch_tick \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"

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
test_outcome_04() {
	local \
		TEST_ID=outcome_04 \
		sched_rv \
		schedule_pid \
		ok_raw unfinished_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "SIGUSR1 abort: completed job stays ok, running job is unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
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

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"

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

# Verify a malformed-completion-record abort
#   (sch_finalize called directly from inside sch_drain_fifo_records, not from the normal loop exit)
#   still preserves an already-completed job's ok status;
#   the malformed job itself is unfinished.
test_outcome_05() {
	local \
		TEST_ID=outcome_05 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok malformed'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "Malformed-record abort preserves prior ok status" "${jobs}"

	# SCHED_MAX_JOBS=1 forces sequential execution:
	#   "ok" must fully complete and be recorded before "malformed" is even dispatched.
	# The 'malformed' job writes on fd 3, which SCHED_INNER_SUBSHELL closes
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_INNER_SUBSHELL='' \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"

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

# Verify ok/fail/unfinished/undispatched/expired are pairwise disjoint
#   and jointly exhaustive over the full job set, in one run where all five are populated.
test_outcome_06() {
	outcome_06_do_job() {
		case "${1}" in
			hang2) do_job_default hang ;;
			*) do_job_default "${@}" ;;
		esac
	}

	local \
		TEST_ID=outcome_06 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		exp_undispatched act_undispatched exp_expired act_expired \
		member_cnt \
		jobs='ok1 fail hang_o06x hang2 hang1'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "ok/fail/unfinished/undispatched/expired partition the full job set" "${jobs}"

	job_set_timeout hang_o06x 1 || { FAIL "job_set_timeout failed"; return 1; }

	# SCHED_MAX_JOBS=1 forces strictly sequential dispatch:
	#   ok1 and fail are each fully drained/classified before hang_o06x starts;
	#   hang_o06x expires on its 1s budget, freeing the slot for hang2.
	#   hang2 is still sleeping when SCHED_TIMEOUT_S hits, so it lands in unfinished;
	#   hang1 never gets dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=outcome_06_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	read_first_line --rm expired_raw "${FINALIZE_SETS_PREFIX}.expired"

	# shellcheck disable=SC2086
	set -- ${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw} ${expired_raw}
	member_cnt="${#}"

	if [ "${sched_rv}" = 82 ] &&
		verify_id_set exp_ok act_ok "ok1" "${ok_raw}" &&
		verify_id_set exp_fail act_fail "fail" "${fail_raw}" &&
		verify_id_set exp_unfinished act_unfinished "hang2" "${unfinished_raw}" &&
		verify_id_set exp_undispatched act_undispatched "hang1" "${undispatched_raw}" &&
		verify_id_set exp_expired act_expired "hang_o06x" "${expired_raw}" &&
		[ "${member_cnt}" = 5 ]
	then
		PASS "ok='${ok_raw}', fail='${fail_raw}', unfinished='${unfinished_raw}', undispatched='${undispatched_raw}', expired='${expired_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 82, member_cnt=${member_cnt}, expected 5 (no overlap/dup)"
		printf '%s\n%s\n%s\n%s\n%s\n' \
			"ok: expected='${exp_ok}' actual='${act_ok}'" \
			"fail: expected='${exp_fail}' actual='${act_fail}'" \
			"unfinished: expected='${exp_unfinished}' actual='${act_unfinished}'" \
			"undispatched: expected='${exp_undispatched}' actual='${act_undispatched}'" \
			"expired: expected='${exp_expired}' actual='${act_expired}'"
		return 1
	fi
}

# Verify an empty job list yields all five sets empty.
test_outcome_07() {
	local \
		TEST_ID=outcome_07 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw \
		jobs='<none>'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "Empty job list yields all-empty ok/fail/unfinished/undispatched/expired sets" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs '' &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	read_first_line --rm expired_raw "${FINALIZE_SETS_PREFIX}.expired"

	if [ "${sched_rv}" = 0 ] &&
		[ -z "${ok_raw}" ] &&
		[ -z "${fail_raw}" ] &&
		[ -z "${unfinished_raw}" ] &&
		[ -z "${undispatched_raw}" ] &&
		[ -z "${expired_raw}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, ok='${ok_raw}', fail='${fail_raw}', unfinished='${unfinished_raw}', undispatched='${undispatched_raw}', expired='${expired_raw}'"
		return 1
	fi
}

# Verify the union of ok/fail/unfinished/undispatched/expired delivered to SCHED_FINALIZE_CB
#   equals the full job-ID list passed to schedule_jobs(), and every job ID appears in exactly one bucket.
# Bucket-agnostic: asserts the partition invariant, not which bucket each ID lands in.
test_outcome_08() {
	local \
		TEST_ID=outcome_08 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw \
		exp_union act_union \
		jobs_cnt \
		member_cnt \
		jobs='ok_1 fail_1 hang_o09x hang_1 ok_2 ok_3'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "Full job-ID list partitions across the five outcome buckets" "${jobs}"

	job_set_timeout hang_o09x 1 || { FAIL "job_set_timeout failed"; return 1; }

	# shellcheck disable=SC2086
	set -- ${jobs}
	jobs_cnt="${#}"

	# SCHED_MAX_JOBS=1:
	#   ok_1 and fail_1 complete first;
	#   hang_o09x expires on its 1s budget;
	#   hang_1 is still running when SCHED_TIMEOUT_S fires (unfinished);
	#   ok_2, ok_3 are never dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	read_first_line --rm unfinished_raw "${FINALIZE_SETS_PREFIX}.unfinished"
	read_first_line --rm undispatched_raw "${FINALIZE_SETS_PREFIX}.undispatched"
	read_first_line --rm expired_raw "${FINALIZE_SETS_PREFIX}.expired"

	# Total tokens across all five buckets; exactly-once => equals the job count.
	# shellcheck disable=SC2086
	set -- ${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw} ${expired_raw}
	member_cnt="${#}"

	if [ "${sched_rv}" = 82 ] &&
		verify_id_set exp_union act_union "${jobs}" "${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw} ${expired_raw}" &&
		[ "${member_cnt}" = "${jobs_cnt}" ]
	then
		PASS "union='${act_union//$'\n'/ }', member_cnt=${member_cnt}/${jobs_cnt}"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (expected 82), member_cnt=${member_cnt}, jobs_cnt=${jobs_cnt}"
		printf '%s\n%s\n%s\n' \
			"input union expected='${exp_union}'" \
			"bucket union actual  ='${act_union}'" \
			"ok='${ok_raw}' fail='${fail_raw}' unfinished='${unfinished_raw}' undispatched='${undispatched_raw}' expired='${expired_raw}'"
		return 1
	fi
}

# Verify the SCHED_FINALIZE_CB argument contract over two runs, one with an abort and one without:
#   exactly 8 arguments both times, and argument 8 is the aborted set.
# With no aborts, only '${8+x}' separates an empty argument 8 from an absent one -
#   '${8:+x}' is empty either way, so both are recorded.
test_outcome_09() {
	# SCHED_FINALIZE_CB recording the argument contract; passes the scheduler rv through
	outcome_09_finalize() {
		printf '%s\n' "${#}"    > "${ARG_PROBE_PREFIX:?}.argc"
		printf '%s\n' "${8+x}"  > "${ARG_PROBE_PREFIX}.set8"
		printf '%s\n' "${8:+x}" > "${ARG_PROBE_PREFIX}.nonempty8"
		printf '%s\n' "${8}"    > "${ARG_PROBE_PREFIX}.arg8"

		finalize_handler "${1}" "${2}"
		return "${1}"
	}

	# JOB_DONE_CB aborting ${ABORT_ID} on its first invocation
	outcome_09_done() {
		done_handler "${1}" "${2}"

		[ -n "${ABORT_FIRED}" ] && return 0
		ABORT_FIRED=1

		jobs_abort "${ABORT_ID:?}"
	}

	outcome_09_read() {
		read_first_line argc "${ARG_PROBE_PREFIX:?}.argc"
		read_first_line set8 "${ARG_PROBE_PREFIX}.set8"
		read_first_line nonempty8 "${ARG_PROBE_PREFIX}.nonempty8"
		read_first_line arg8 "${ARG_PROBE_PREFIX}.arg8"
	}

	# 1: pass label
	# 2: expected argument 8
	# 4 checks per call, called once per pass
	outcome_09_check() {
		[ "${argc}" = 8 ] && checks_pass=$((checks_pass + 1)) ||
			echo "${1}: \$#=${argc} (want 8)" >&2
		# Set even when empty: the only signal that argument 8 was passed at all
		[ "${set8}" = x ] && checks_pass=$((checks_pass + 1)) ||
			echo "${1}: \${8+x}='${set8}' (want 'x' - argument 8 was not passed)" >&2
		[ "${nonempty8}" = "${2:+x}" ] && checks_pass=$((checks_pass + 1)) ||
			echo "${1}: \${8:+x}='${nonempty8}' (want '${2:+x}')" >&2
		[ "${arg8}" = "${2}" ] && checks_pass=$((checks_pass + 1)) ||
			echo "${1}: argument 8='${arg8}' (want '${2}')" >&2
	}

	local \
		TEST_ID=outcome_09 \
		sched_rv argc set8 nonempty8 arg8 \
		checks_pass=0 checks_exp=10 \
		ABORT_FIRED='' \
		ABORT_ID=ok5_outcome09b \
		plain_jobs='instant_outcome09' \
		abort_jobs='ok1_outcome09 ok5_outcome09b'

	local ARG_PROBE_PREFIX="/tmp/sched.finargs.${TEST_ID:?}.$$"

	rm -f "${ARG_PROBE_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "SCHED_FINALIZE_CB gets exactly 8 arguments, the 8th being the aborted set" "${plain_jobs} / ${abort_jobs}"

	# Pass 1: no aborts
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_09_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${plain_jobs}" &

	wait "$!"
	sched_rv=$?

	outcome_09_read
	rm -f "${ARG_PROBE_PREFIX:?}".*

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "no-abort run: sched_rv=${sched_rv} (want 0)" >&2
	outcome_09_check 'no-abort run' ''

	# Pass 2: ok1_outcome09 completes and aborts the still-running ok5_outcome09b
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_09_finalize \
	JOB_DONE_CB=outcome_09_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${abort_jobs}" &

	wait "$!"
	sched_rv=$?

	outcome_09_read
	rm -f "${ARG_PROBE_PREFIX:?}".*

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "abort run: sched_rv=${sched_rv} (want 0)" >&2
	outcome_09_check 'abort run' 'ok5_outcome09b'

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "argc=${argc}, arg8='${arg8}'"
		return 0
	else
		FAIL "argc=${argc}, set8='${set8}', nonempty8='${nonempty8}', arg8='${arg8}'"
		return 1
	fi
}

# Verify the six outcome sets partition the job list over a single run producing all six outcomes:
#   every job ID in exactly one set, no unlisted IDs,
#   and every set non-empty so the run really did mix all six.
test_outcome_10() {
	# SCHED_DISPATCH_TICK_CB aborting the job it was just called for, when that
	#   job is ${ABORT_ID}. The tick runs after dispatch, so the job is running.
	outcome_10_tick() {
		[ "${1}" = "${ABORT_ID:?}" ] || return 0

		jobs_abort "${1}"
	}

	local \
		TEST_ID=outcome_10 \
		sched_rv name empty_sets='' \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_aborted act_aborted \
		checks_pass=0 checks_exp=4 \
		ABORT_ID=ok5_outcome10 \
		jobs='ok1_outcome10 fail_outcome10 ok5_outcome10 hang_outcome10x hang_outcome10 ok_outcome10a ok_outcome10b'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".*

	print_test_header "${TEST_ID:?}" "All six outcome sets partition the job list" "${jobs}"

	job_set_timeout hang_outcome10x 1 || { FAIL "job_set_timeout failed"; return 1; }

	# SCHED_MAX_JOBS=1 dispatches strictly in order, so each job is fully classified before the next starts:
	#   ok1_outcome10 -> ok;
	#   fail_outcome10 -> fail;
	#   ok5_outcome10 aborted on its own dispatch tick, freeing its slot at once;
	#   hang_outcome10x expires on its 1 s budget;
	#   hang_outcome10 is still running when SCHED_TIMEOUT_S fires -> unfinished;
	#   ok_outcome10a, ok_outcome10b are never dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=outcome_10_tick \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=30 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"

	for name in ok fail unfinished undispatched expired aborted; do
		eval "[ -n \"\${${name}_raw}\" ]" ||
			empty_sets="${empty_sets}${empty_sets:+ }${name}"
	done

	[ "${sched_rv}" = 82 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 82)" >&2
	verify_id_partition "${jobs}" && checks_pass=$((checks_pass + 1)) ||
		echo "the six ID sets do not partition the ${TEST_ID} job IDs" >&2
	[ -z "${empty_sets}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "empty set(s): ${empty_sets} - the run did not produce all six outcomes" >&2
	verify_id_set exp_aborted act_aborted "${ABORT_ID}" "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, aborted='${aborted_raw}', expired='${expired_raw}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		print_id_sets >&2
		return 1
	fi
}
