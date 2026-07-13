#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-outcome.sh

# Category: Job Outcome Classification (ok/fail/unfinished/undispatched)
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Helpers
#

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

write_id_sets() {
	local wis_prefix="${1:?}"

	printf '%s\n' "${2}" > "${wis_prefix}.ok"
	printf '%s\n' "${3}" > "${wis_prefix}.fail"
	printf '%s\n' "${4}" > "${wis_prefix}.unfinished"
	printf '%s\n' "${5}" > "${wis_prefix}.undispatched"
}


#
# Tests
#

# Verify SCHED_FINALIZE_CB's ok/fail sets are correct on a normal completion
#   with no timeout/undispatched/unfinished jobs involved.
test_outcome_01() {
	outcome_01_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_01 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail \
		jobs='ok1 ok2 fail'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "SCHED_FINALIZE_CB ok/fail sets on normal completion" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_01_finalize_handler \
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
test_outcome_02() {
	outcome_02_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_02 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		jobs='ok fail hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "Fail set survives idle-timeout abort; running job is unfinished, not failed" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_02_finalize_handler \
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
test_outcome_03() {
	outcome_03_do_job() {
		[ "${1}" = second ] && printf 'dispatched\n' > "${SECOND_DISPATCHED_FILE:?}"
		return 0
	}

	outcome_03_dispatch_tick() {
		[ "${1}" = first ] && sleep 2
	}

	outcome_03_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
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

	rm -f "${FINALIZE_SETS_PREFIX}".* "${SECOND_DISPATCHED_FILE}"

	print_test_header "${TEST_ID:?}" "Global timeout during initial dispatch: undispatched vs. unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_03_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=outcome_03_do_job \
	SCHED_DISPATCH_TICK_CB=outcome_03_dispatch_tick \
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
test_outcome_04() {
	outcome_04_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_04 \
		sched_rv \
		schedule_pid \
		ok_raw unfinished_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok hang'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "SIGUSR1 abort: completed job stays ok, running job is unfinished" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_04_finalize_handler \
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
test_outcome_05() {
	outcome_05_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_05 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_unfinished act_unfinished \
		jobs='ok malformed'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "Malformed-record abort preserves prior ok status" "${jobs}"

	# SCHED_MAX_JOBS=1 forces sequential execution:
	#   "ok" must fully complete and be recorded before "malformed" is even dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_05_finalize_handler \
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
test_outcome_06() {
	outcome_06_do_job() {
		case "${1}" in
			hang2) do_job_default hang ;;
			*) do_job_default "${@}" ;;
		esac
	}

	outcome_06_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_06 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_ok act_ok exp_fail act_fail exp_unfinished act_unfinished \
		exp_undispatched act_undispatched \
		member_cnt \
		jobs='ok1 fail hang2 hang1'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "ok/fail/unfinished/undispatched partition the full job set" "${jobs}"

	# SCHED_MAX_JOBS=1 forces strictly sequential dispatch:
	#   ok1 and fail are each fully drained/classified before hang2 starts.
	#   hang2 is still sleeping when SCHED_TIMEOUT_S hits, so it lands in unfinished;
	#   hang1 never gets dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_06_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=outcome_06_do_job \
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
test_outcome_07() {
	outcome_07_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_07 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		jobs='<none>'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "Empty job list yields all-empty ok/fail/unfinished/undispatched sets" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_07_finalize_handler \
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
#   correct ok/fail set (not just "no crash" - test_misc_02/test_misc_03 already cover that).
test_outcome_08() {
	outcome_08_touch_inject() { touch "${INJECT_FILE:?}"; }

	outcome_08_do_job() {
		case "${1}" in
			*ok_marker*) return 0 ;;
			*) return 1 ;;
		esac
	}

	outcome_08_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_08 \
		sched_rv \
		ok_raw fail_raw \
		exp_ok act_ok exp_fail act_fail \
		ok_id fail_id \
		jobs

	ok_id='ok_marker_$(outcome_08_touch_inject)'
	fail_id='fail_marker_`outcome_08_touch_inject`'
	jobs="${ok_id} ${fail_id}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		INJECT_FILE="/tmp/sched.inject8.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX}".* "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Awkward job-ID characters land in the correct ok/fail set" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_08_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=outcome_08_do_job \
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

# Verify the union of ok/fail/unfinished/undispatched delivered to SCHED_FINALIZE_CB
#   equals the full job-ID list passed to schedule_jobs(),
#   and every job ID appears in exactly one bucket.
#   Bucket-agnostic: asserts the partition invariant, not which bucket each ID lands in
#   (test_outcome_06 checks specific membership).
test_outcome_09() {
	outcome_09_finalize_handler() {
		finalize_handler "${1}" "${2}" || return $?
		write_id_sets "${FINALIZE_SETS_PREFIX:?}" "${3}" "${4}" "${5}" "${6}"
	}

	local \
		TEST_ID=outcome_09 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw \
		exp_union act_union \
		jobs_cnt \
		member_cnt \
		jobs='ok_1 fail_1 hang_1 ok_2 ok_3'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX}".*

	print_test_header "${TEST_ID:?}" "Full job-ID list partitions across the four outcome buckets" "${jobs}"

	# shellcheck disable=SC2086
	set -- ${jobs}
	jobs_cnt="${#}"

	# SCHED_MAX_JOBS=1: ok_1 and fail_1 complete first; hang_1 is still running
	# when SCHED_TIMEOUT_S fires (unfinished); ok_2, ok_3 are never dispatched.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=outcome_09_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
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

	# Total tokens across all four buckets; exactly-once => equals the job count.
	# shellcheck disable=SC2086
	set -- ${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw}
	member_cnt="${#}"

	if [ "${sched_rv}" = 82 ] &&
		verify_id_set exp_union act_union "${jobs}" "${ok_raw} ${fail_raw} ${unfinished_raw} ${undispatched_raw}" &&
		[ "${member_cnt}" = "${jobs_cnt}" ]
	then
		PASS "union='${act_union//$'\n'/ }', member_cnt=${member_cnt}/${jobs_cnt}"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (expected 82), member_cnt=${member_cnt}, jobs_cnt=${jobs_cnt}"
		printf '%s\n%s\n%s\n' \
			"input union expected='${exp_union}'" \
			"bucket union actual  ='${act_union}'" \
			"ok='${ok_raw}' fail='${fail_raw}' unfinished='${unfinished_raw}' undispatched='${undispatched_raw}'"
		return 1
	fi
}
