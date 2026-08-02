#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-abort.sh

# Category: Job Abort (jobs_abort)
# This file is sourced by tests.sh; it defines test_N functions only.

# jobs_abort() is callable only from the scheduler's own process, so every test
#   drives it from JOB_DONE_CB or SCHED_DISPATCH_TICK_CB. The caller-process
#   guard itself is covered in the security category.

#
# Helpers
#

# Abort the job IDs in ${ABORT_TARGETS} on the first callback invocation, then
#   record the call so a test can tell a missed callback from a no-op abort.
# Used as JOB_DONE_CB (args: job ID, rv) or SCHED_DISPATCH_TICK_CB (args: job ID).
abort_on_first_cb() {
	printf '%s\n' "${1}" >> "${ABORT_CALLS_FILE:?}"

	[ -n "${ABORT_DONE}" ] && return 0
	ABORT_DONE=1

	# shellcheck disable=SC2086
	jobs_abort ${ABORT_TARGETS:?}
}

# Drop ${1} from the live-job list ${AB08_LIVE} and emit one 'leave' event for it.
# A no-op when the ID is not live, so every dispatched job leaves at most once.
# Runs in the scheduler's main process, so the assignment persists across calls.
ab08_retire() {
	local ab_id ab_new='' ab_hit=

	for ab_id in ${AB08_LIVE}; do
		if [ -z "${ab_hit}" ] && [ "${ab_id}" = "${1}" ]; then
			ab_hit=1
		else
			ab_new="${ab_new}${ab_new:+ }${ab_id}"
		fi
	done

	AB08_LIVE="${ab_new}"
	[ -n "${ab_hit}" ] && parallel_job_leave
	:
}

# Abort the job IDs in ${ABORT_TARGETS} when the callback fires for ${ABORT_AT_ID},
#   and record every call so a test can tell a missed callback from a no-op abort.
# Used as JOB_DONE_CB (args: job ID, rv) or SCHED_DISPATCH_TICK_CB (args: job ID).
abort_at_id_cb() {
	printf '%s\n' "${1}" >> "${ABORT_CALLS_FILE:?}"

	[ "${1}" = "${ABORT_AT_ID:?}" ] || return 0

	# shellcheck disable=SC2086
	jobs_abort ${ABORT_TARGETS:?}
}

# JOB_DONE_CB appending one '<job ID> <rv>' line per invocation to ${DONE_FILE}.
record_done_cb() {
	printf '%s %s\n' "${1}" "${2}" >> "${DONE_FILE:?}"
}

# SCHED_FINALIZE_CB recording the running-PID list (arg 2) to ${FIN_PIDS_FILE},
#   then recording the six ID sets like sets_finalize_handler.
pids_finalize_handler() {
	printf '%s\n' "${2}" > "${FIN_PIDS_FILE:?}"

	sets_finalize_handler "${@}"
}

# Record the PID the scheduler tracks for the running job in
#   '${PID_FILE_PREFIX}.<job ID>', so it can be matched against the PIDs the
#   scheduler itself reports.
# 1: job ID
record_job_pid() {
	local rjp_pid

	get_job_wrapper_pid rjp_pid || return 1

	printf '%s\n' "${rjp_pid}" > "${PID_FILE_PREFIX:?}.${1:?}"
}

# DO_JOB_CB recording the job's own PID, then running do_job_default.
pid_job() {
	record_job_pid "${1}" && do_job_default "${@}"
}

# Set the out var to the PID recorded by record_job_pid for a job ID; rv 1 if none.
# 1: out var
# 2: job ID
read_job_pid() {
	read_first_line --rm "${1:?}" "${PID_FILE_PREFIX:?}.${2:?}"
}

# DO_JOB_CB appending the job ID to ${START_FILE}, then running do_job_default.
# The mark is written before the job runs, so a dispatch of an empty ID shows up too.
mark_start_job() {
	printf '%s\n' "${1}" >> "${START_FILE:?}"

	do_job_default "${@}"
}

# DO_JOB_CB running do_job_default, then appending the job ID to ${MARK_FILE}.
# The mark distinguishes a job that ran to completion from one that was killed.
mark_done_job() {
	do_job_default "${@}" || return "${?}"

	printf '%s\n' "${1}" >> "${MARK_FILE:?}"
}

# Set the out var to the number of whitespace-separated items in a list.
# 1: out var
# 2: list
count_items() {
	local ci_out="${1:?}" ci_had_f

	case "${-}" in *f*) ci_had_f=1 ;; esac
	set -f
	set -- ${2}
	[ -n "${ci_had_f}" ] || set +f

	export -n "${ci_out}=${#}"
}

# Print every message recorded by record_fail_msg, numbered, for a FAIL diagnostic.
# 1: message file
print_msgs() {
	local pm_line pm_n=0

	[ -f "${1:?}" ] && {
		while IFS= read -r pm_line; do
			pm_n=$((pm_n + 1))
			printf 'msg[%s]: %s\n' "${pm_n}" "${pm_line}"
		done < "${1}"
	}

	[ "${pm_n}" = 0 ] && printf 'msg: <none recorded>\n'
	:
}

# Run the abort-with-termination scenario shared by the two variant tests: two
#   jobs at SCHED_MAX_JOBS=2, the 5 s one aborted from the 1 s one's completion
#   callback, with a JOB_TERM_CB that kills whatever the abort hands it.
# Sets, for the caller to check (the caller must declare all of them local):
#   sched_rv msg_cnt term_calls target_pid fin_pids, plus the six read_id_sets vars.
# Reads ${TEST_ID} and the file-path vars ${FINALIZE_SETS_PREFIX},
#   ${FIN_PIDS_FILE}, ${PID_FILE_PREFIX}, ${TERM_CALLS_FILE}, ${MSG_FILE}
#   from the caller's scope.
# 1: JOB_TERM_CB command
# 2: job ID to abort (5 s)
# 3: driver job ID (1 s)
run_abort_term_scenario() {
	local \
		rats_term_cb="${1:?}" \
		ABORT_DONE='' \
		ABORT_TARGETS="${2:?}" \
		driver_job_id="${3:?}" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${PID_FILE_PREFIX:?}".* \
		"${FIN_PIDS_FILE:?}" "${TERM_CALLS_FILE:?}" "${MSG_FILE:?}" "${ABORT_CALLS_FILE}"

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=pids_finalize_handler \
	JOB_DONE_CB=abort_on_first_cb \
	DO_JOB_CB=pid_job \
	JOB_TERM_CB="${rats_term_cb}" \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${ABORT_TARGETS} ${driver_job_id}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm term_calls "${TERM_CALLS_FILE}"
	read_first_line --rm fin_pids "${FIN_PIDS_FILE}"
	read_job_pid target_pid "${ABORT_TARGETS}"

	rm -f "${PID_FILE_PREFIX:?}".* "${MSG_FILE}" "${ABORT_CALLS_FILE}"
	:
}

#
# Tests
#

# Verify a running job aborted from JOB_DONE_CB is classified as aborted and
#   nothing else, and that the run still completes successfully.
test_abort_01() {
	local \
		TEST_ID=abort_01 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		abort_calls \
		checks_pass=0 checks_exp=5 \
		ABORT_DONE='' \
		ABORT_TARGETS=ok5_abort01 \
		jobs='ok5_abort01 ok1_abort01b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}"

	print_test_header "${TEST_ID:?}" "Running job aborted from JOB_DONE_CB lands in the aborted set" "${jobs}"

	# ok1_abort01b completes first and aborts ok5_abort01 from its completion callback
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=abort_on_first_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	read_flat --rm abort_calls "${ABORT_CALLS_FILE}"

	# The abort must have been driven by a real callback invocation, not by a
	#   callback that never ran and an aborted set that was empty anyway
	[ "${abort_calls}" = 'ok1_abort01b' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${abort_calls}' (want 'ok1_abort01b')" >&2
	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	verify_id_set exp_ok act_ok 'ok1_abort01b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort01' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, ok='${ok_raw}', aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify a job aborted while still pending is reported as undispatched rather
#   than aborted, is never handed to DO_JOB_CB, and does not stop the remaining
#   pending jobs from being dispatched.
test_abort_02() {
	local \
		TEST_ID=abort_02 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_undisp act_undisp exp_starts act_starts \
		tick_calls starts \
		checks_pass=0 checks_exp=8 \
		ABORT_DONE='' \
		ABORT_TARGETS=instant_abort02b \
		jobs='ok1_abort02 instant_abort02b instant_abort02c'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		START_FILE="/tmp/sched.starts.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${START_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "A job aborted while pending lands in undispatched, not aborted" "${jobs}"

	# SCHED_MAX_JOBS=1: on the first dispatch tick both other jobs are still pending
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=mark_start_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"
	read_flat --rm starts "${START_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# Aborting a known, pending job is silent
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	# The aborted job is skipped, the one after it still dispatches
	[ "${tick_calls}" = 'ok1_abort02 instant_abort02c' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok1_abort02 instant_abort02c')" >&2
	verify_id_set exp_starts act_starts 'ok1_abort02 instant_abort02c' "${starts}" && checks_pass=$((checks_pass + 1)) ||
		echo "started jobs: expected='${exp_starts}' actual='${act_starts}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort02 instant_abort02c' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	verify_id_set exp_undisp act_undisp 'instant_abort02b' "${undispatched_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "undispatched: expected='${exp_undisp}' actual='${act_undisp}'" >&2
	[ -z "${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted='${aborted_raw}' (want empty)" >&2
	[ -z "${fail_raw}${unfinished_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, started='${starts}', undispatched='${undispatched_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify one jobs_abort call mixing a pending, a running, a completed, an unknown
#   and a syntactically invalid job ID: the two live jobs are handled, the rest
#   are skipped, rv is 0 and exactly two messages are raised.
test_abort_03() {
	# One mixed abort call, recording its rv
	ab03_done_cb() {
		local ab_rv

		printf '%s\n' "${1}" >> "${ABORT_CALLS_FILE:?}"

		jobs_abort ok5_abort03c ok5_abort03b instant_abort03 nosuch_abort03 'bad-id-abort03'
		ab_rv=${?}

		printf '%s\n' "${ab_rv}" > "${RV_FILE:?}"
	}

	local \
		TEST_ID=abort_03 \
		sched_rv msg_cnt abort_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted exp_undisp act_undisp \
		done_calls \
		checks_pass=0 checks_exp=10 \
		jobs='instant_abort03 ok5_abort03b ok5_abort03c'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${RV_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "One jobs_abort call mixing pending, running, completed, unknown and invalid IDs" "${jobs}"

	# SCHED_MAX_JOBS=2: when instant_abort03 completes, ok5_abort03b is running and ok5_abort03c is still pending.
	# Relies on the priority ladder:
	#   instant_abort03's record is only queued while a slot is free,
	#   so JOB_DONE_CB cannot fire before ok5_abort03b is dispatched
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=ab03_done_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm done_calls "${ABORT_CALLS_FILE}"
	read_first_line --rm abort_rv "${RV_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# Neither the unknown nor the invalid ID makes jobs_abort fail
	[ "${abort_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "jobs_abort rv='${abort_rv}' (want 0)" >&2
	[ "${done_calls}" = 'instant_abort03' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'instant_abort03')" >&2
	# The completed ID is skipped silently, so only two IDs are reported
	[ "${msg_cnt}" = 2 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 2)" >&2; print_msgs "${MSG_FILE}" >&2; }
	msgs_have "${MSG_FILE}" "unknown job ID 'nosuch_abort03'" && checks_pass=$((checks_pass + 1)) ||
		{ echo "no message for the unknown ID" >&2; print_msgs "${MSG_FILE}" >&2; }
	msgs_have "${MSG_FILE}" "job ID 'bad-id-abort03'" && checks_pass=$((checks_pass + 1)) ||
		{ echo "no message for the invalid ID" >&2; print_msgs "${MSG_FILE}" >&2; }
	verify_id_set exp_aborted act_aborted 'ok5_abort03b' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_undisp act_undisp 'ok5_abort03c' "${undispatched_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "undispatched: expected='${exp_undisp}' actual='${act_undisp}'" >&2
	verify_id_set exp_ok act_ok 'instant_abort03' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, jobs_abort rv=${abort_rv}, msg_cnt=${msg_cnt}, aborted='${aborted_raw}', undispatched='${undispatched_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify a jobs_abort call with no arguments returns 0, raises no message and
#   changes nothing.
test_abort_04() {
	# Call jobs_abort with no arguments, recording its rv on every completion
	ab04_done_cb() {
		local ab_rv

		record_done_cb "${@}"

		jobs_abort
		ab_rv=${?}

		printf '%s\n' "${ab_rv}" >> "${RV_FILE:?}"
	}

	local \
		TEST_ID=abort_04 \
		sched_rv msg_cnt abort_rvs \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok \
		done_calls \
		checks_pass=0 checks_exp=6 \
		jobs='ok1_abort04 instant_abort04b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		DONE_FILE="/tmp/sched.done.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${DONE_FILE}" "${RV_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "jobs_abort with no arguments returns 0 and changes nothing" "${jobs}"

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=ab04_done_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm done_calls "${DONE_FILE}"
	read_flat --rm abort_rvs "${RV_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${abort_rvs}" = '0 0' ] && checks_pass=$((checks_pass + 1)) ||
		echo "jobs_abort rvs='${abort_rvs}' (want '0 0')" >&2
	# Both jobs still ran to completion
	[ "${done_calls}" = 'ok1_abort04 0 instant_abort04b 0' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'ok1_abort04 0 instant_abort04b 0')" >&2
	verify_id_set exp_ok act_ok "${jobs}" "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired/aborted must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, jobs_abort rvs='${abort_rvs}', ok='${ok_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify a second abort of an already aborted running job is a silent no-op:
#   rv 0, no message, no duplicate entry in the aborted set, and no lost or
#   double-counted concurrency slot.
test_abort_05() {
	# Abort the same running job twice, recording the rv of each call
	ab05_done_cb() {
		local ab_rv1 ab_rv2

		printf '%s\n' "${1}" >> "${ABORT_CALLS_FILE:?}"

		jobs_abort ok5_abort05
		ab_rv1=${?}
		jobs_abort ok5_abort05
		ab_rv2=${?}

		printf '%s %s\n' "${ab_rv1}" "${ab_rv2}" > "${RV_FILE:?}"
	}

	local \
		TEST_ID=abort_05 \
		sched_rv msg_cnt abort_rvs aborted_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		done_calls \
		checks_pass=0 checks_exp=8 \
		jobs='ok5_abort05 ok1_abort05b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${RV_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "A second abort of the same running job is a silent no-op" "${jobs}"

	# ok1_abort05b completes first and aborts ok5_abort05 twice
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=ab05_done_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	count_items aborted_cnt "${aborted_raw}"
	read_flat --rm done_calls "${ABORT_CALLS_FILE}"
	read_first_line --rm abort_rvs "${RV_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# A lost or doubled slot count would trip the 'Not all jobs are done' check
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${abort_rvs}" = '0 0' ] && checks_pass=$((checks_pass + 1)) ||
		echo "jobs_abort rvs='${abort_rvs}' (want '0 0')" >&2
	[ "${done_calls}" = 'ok1_abort05b' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'ok1_abort05b')" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort05' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	# verify_id_set is duplicate-insensitive: count separately
	[ "${aborted_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted holds ${aborted_cnt} item(s) (want 1): '${aborted_raw}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort05b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, abort rvs='${abort_rvs}', aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting a job that already completed successfully is a silent no-op:
#   it stays in the ok set and never appears in the aborted set.
test_abort_06() {
	# Abort the already completed ok1_abort06 from every completion callback
	ab06_done_cb() {
		record_done_cb "${@}"

		jobs_abort ok1_abort06
	}

	local \
		TEST_ID=abort_06 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok \
		done_calls \
		checks_pass=0 checks_exp=6 \
		jobs='ok1_abort06 instant_abort06b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		DONE_FILE="/tmp/sched.done.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${DONE_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Aborting an already completed job leaves it in the ok set" "${jobs}"

	# SCHED_MAX_JOBS=1: ok1_abort06 is classified ok before either callback runs
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=ab06_done_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm done_calls "${DONE_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	# Both jobs ran: the abort neither killed nor unscheduled anything
	[ "${done_calls}" = 'ok1_abort06 0 instant_abort06b 0' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'ok1_abort06 0 instant_abort06b 0')" >&2
	verify_id_set exp_ok act_ok "${jobs}" "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted='${aborted_raw}' (want empty)" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, ok='${ok_raw}', aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting the only running job from SCHED_DISPATCH_TICK_CB frees its
#   concurrency slot at once: the next pending job starts immediately rather
#   than after the aborted job's natural 5 s duration.
test_abort_07() {
	local \
		TEST_ID=abort_07 \
		sched_rv start_s end_s elapsed \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		tick_calls \
		checks_pass=0 checks_exp=6 \
		ABORT_DONE='' \
		ABORT_TARGETS=ok5_abort07 \
		jobs='ok5_abort07 instant_abort07'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}"

	print_test_header "${TEST_ID:?}" "Abort from SCHED_DISPATCH_TICK_CB frees the slot for the next pending job at once" "${jobs}"

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# 5 s or more means the slot was only reclaimed by the aborted job's own completion
	[ "${elapsed}" -le 2 ] && checks_pass=$((checks_pass + 1)) ||
		echo "elapsed=${elapsed}s (want <= 2)" >&2
	# Both dispatches happened, in order
	[ "${tick_calls}" = 'ok5_abort07 instant_abort07' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok5_abort07 instant_abort07')" >&2
	verify_id_set exp_ok act_ok 'instant_abort07' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort07' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, elapsed=${elapsed}s, aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting a running job on every completion keeps concurrency within
#   SCHED_MAX_JOBS and classifies every job exactly once.
test_abort_08() {
	# One 'enter' per dispatched job, emitted from the job's own process
	ab08_do_job() {
		parallel_job_enter
		sleep 1
	}

	# Record the dispatched job as live (runs in the scheduler's main process)
	ab08_tick_cb() {
		AB08_LIVE="${AB08_LIVE}${AB08_LIVE:+ }${1}"
	}

	# Retire the completed job, then abort the youngest job still live.
	# The youngest is the least likely to have been classified already,
	#   which keeps the abort path exercised rather than silently no-opping.
	ab08_done_cb() {
		local ab_id ab_target=

		ab08_retire "${1}"

		for ab_id in ${AB08_LIVE}; do ab_target="${ab_id}"; done
		[ -n "${ab_target}" ] || return 0

		jobs_abort "${ab_target}"
		ab08_retire "${ab_target}"
	}

	local \
		TEST_ID=abort_08 \
		sched_rv sched_pid monitor_pid max_active \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		i=1 aborted_cnt \
		checks_pass=0 checks_exp=4 \
		max_jobs=3 \
		jobs='' \
		AB08_LIVE=

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		fifo="/tmp/sched.conc.${TEST_ID:?}.$$" \
		result_file="/tmp/sched.conc.res.${TEST_ID:?}.$$"

	while [ "${i}" -le 20 ]; do
		jobs="${jobs}${jobs:+ }ab08_${i}"
		i=$((i + 1))
	done

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${fifo}" "${result_file}" &&
	mkfifo "${fifo}" || { FAIL "failed to create FIFO '${fifo}'"; return 1; }

	print_test_header "${TEST_ID:?}" "Repeated abort of a running job keeps concurrency within SCHED_MAX_JOBS" "20 jobs (ab08_1..ab08_20)"

	monitor_job_conc_fifo "${result_file}" < "${fifo}" &
	monitor_pid=$!

	exec 8>"${fifo}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=ab08_tick_cb \
	JOB_DONE_CB=ab08_done_cb \
	DO_JOB_CB=ab08_do_job \
	SCHED_MAX_JOBS="${max_jobs}" \
	SCHED_TIMEOUT_S=40 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	sched_pid=$!

	exec 8>&-

	wait "${monitor_pid}"

	wait "${sched_pid}"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	read_first_line --rm max_active "${result_file}"
	rm -f "${fifo}"

	count_items aborted_cnt "${aborted_raw}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	is_uint "${max_active}" && [ "${max_active}" -le "${max_jobs}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "peak concurrency='${max_active}' (want an integer <= ${max_jobs})" >&2
	verify_id_partition "${jobs}" && checks_pass=$((checks_pass + 1)) ||
		echo "the six ID sets do not partition the 20 job IDs" >&2
	# Without this the run could pass with no abort ever taking effect
	[ "${aborted_cnt}" -ge 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted set is empty - no abort took effect" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, peak=${max_active}, aborted_cnt=${aborted_cnt}"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify emptying the pending list from SCHED_DISPATCH_TICK_CB ends the dispatch
#   loop cleanly: no further dispatch, no dispatch of an empty job ID, and every
#   aborted-while-pending job reported as undispatched.
test_abort_09() {
	local \
		TEST_ID=abort_09 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_undisp act_undisp exp_starts act_starts \
		tick_calls starts \
		checks_pass=0 checks_exp=8 \
		ABORT_DONE='' \
		ABORT_TARGETS='instant_abort09b instant_abort09c instant_abort09d' \
		jobs='ok1_abort09 instant_abort09b instant_abort09c instant_abort09d'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		START_FILE="/tmp/sched.starts.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${START_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Aborting every pending job from SCHED_DISPATCH_TICK_CB ends the dispatch loop" "${jobs}"

	# SCHED_MAX_JOBS covers the whole job set: without the abort all four dispatch
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=mark_start_job \
	SCHED_MAX_JOBS=4 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"
	read_flat --rm starts "${START_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	# Exactly one dispatch: an empty-ID dispatch would show as a trailing tick
	[ "${tick_calls}" = 'ok1_abort09' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok1_abort09')" >&2
	# DO_JOB_CB records its job ID before running, so an empty ID would appear here
	verify_id_set exp_starts act_starts 'ok1_abort09' "${starts}" && checks_pass=$((checks_pass + 1)) ||
		echo "started jobs: expected='${exp_starts}' actual='${act_starts}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort09' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	verify_id_set exp_undisp act_undisp "${ABORT_TARGETS}" "${undispatched_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "undispatched: expected='${exp_undisp}' actual='${act_undisp}'" >&2
	# Aborting a pending job reports it as undispatched, never as aborted
	[ -z "${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted='${aborted_raw}' (want empty)" >&2
	[ -z "${fail_raw}${unfinished_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, started='${starts}', undispatched='${undispatched_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting every remaining running job from JOB_DONE_CB ends the run at
#   once and is reported as success: rv 0 with the whole remainder aborted.
test_abort_10() {
	local \
		TEST_ID=abort_10 \
		sched_rv msg_cnt start_s end_s elapsed \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		done_calls \
		checks_pass=0 checks_exp=7 \
		ABORT_DONE='' \
		ABORT_TARGETS='ok5_abort10b ok5_abort10c ok5_abort10d' \
		jobs='instant_abort10 ok5_abort10b ok5_abort10c ok5_abort10d'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Aborting all remaining running jobs from JOB_DONE_CB exits at once with rv 0" "${jobs}"

	start_s=$(date +%s)

	# instant_abort10 completes first and aborts the three 5 s jobs.
	# Relies on the priority ladder: its record is only queued while slots are free,
	#   so JOB_DONE_CB cannot fire until all four are dispatched -
	#   otherwise the targets would still be pending and report undispatched, not aborted
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=abort_on_first_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=4 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=15 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm done_calls "${ABORT_CALLS_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# 5 s or more means the run waited the aborted jobs out
	[ "${elapsed}" -le 2 ] && checks_pass=$((checks_pass + 1)) ||
		echo "elapsed=${elapsed}s (want <= 2)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	# Only the completed job reaches JOB_DONE_CB
	[ "${done_calls}" = 'instant_abort10' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'instant_abort10')" >&2
	verify_id_set exp_aborted act_aborted "${ABORT_TARGETS}" "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'instant_abort10' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, elapsed=${elapsed}s, aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify that with no JOB_TERM_CB an abort is pure bookkeeping: the aborted job
#   keeps running to completion, its genuine completion record is discarded
#   silently, and it stays classified as aborted.
test_abort_11() {
	local \
		TEST_ID=abort_11 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted exp_marks act_marks \
		tick_calls done_calls marks \
		checks_pass=0 checks_exp=8 \
		ABORT_DONE='' \
		ABORT_TARGETS=ok2_abort11 \
		jobs='ok2_abort11 ok5_abort11b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		DONE_FILE="/tmp/sched.done.${TEST_ID:?}.$$" \
		MARK_FILE="/tmp/sched.marks.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${DONE_FILE}" "${MARK_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Without JOB_TERM_CB an aborted job is not killed and its record is discarded" "${jobs}"

	# No JOB_TERM_CB: ok2_abort11 is aborted on its dispatch tick but keeps running,
	#   and ok5_abort11b keeps the run alive past ok2_abort11's own completion
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=record_done_cb \
	DO_JOB_CB=mark_done_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=15 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"
	read_flat --rm done_calls "${DONE_FILE}"
	read_flat --rm marks "${MARK_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# A discarded record is silent - any message here means it was not recognized
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${tick_calls}" = 'ok2_abort11 ok5_abort11b' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok2_abort11 ok5_abort11b')" >&2
	# The aborted job must not reach JOB_DONE_CB
	[ "${done_calls}" = 'ok5_abort11b 0' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'ok5_abort11b 0')" >&2
	# Both marks present: the aborted job ran its full 2 s and was never killed
	verify_id_set exp_marks act_marks "${jobs}" "${marks}" && checks_pass=$((checks_pass + 1)) ||
		echo "completion marks: expected='${exp_marks}' actual='${act_marks}'" >&2
	verify_id_set exp_aborted act_aborted 'ok2_abort11' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok5_abort11b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, marks='${marks}', aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify the aborted job's discard token is single-use: a sibling forging a
#   completion record for it consumes the token silently, the run continues, and
#   its own genuine record later reads as unexpected and is fatal.
# instant_abort12c is the witness: it can only be dispatched and classified if the
#   forged record was absorbed without ending the run, which is what distinguishes
#   a consumed token from there being no discard step at all.
# ok5_abort12d keeps the run alive past ok2_abort12's own 2 s completion; without it
#   the scheduler finishes before the genuine record arrives, since an aborted job
#   is no longer counted among the running jobs.
test_abort_12() {
	local \
		TEST_ID=abort_12 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_aborted act_aborted exp_ok act_ok exp_unfin act_unfin \
		tick_calls \
		checks_pass=0 checks_exp=7 \
		ABORT_DONE='' \
		ABORT_TARGETS=ok2_abort12 \
		SPOOF_DONE_ID=ok2_abort12 \
		SPOOF_FROM_ID=instant_abort12b \
		SPOOF_DONE_RV=0 \
		jobs='ok2_abort12 instant_abort12b instant_abort12c ok5_abort12d'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "A forged record for an aborted job consumes its discard token" "${jobs}"

	# ok2_abort12 is aborted on its own dispatch tick, freeing the slot while it
	#   still runs; instant_abort12b then forges its record and completes, letting
	#   instant_abort12c run before ok2_abort12 reports for real at ~2s
	# The forge goes out on fd 3, which SCHED_INNER_SUBSHELL closes
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=spoof_done_job_from \
	SCHED_INNER_SUBSHELL='' \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"

	[ "${sched_rv}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 1)" >&2
	msgs_have "${MSG_FILE}" "Unexpected completion record for job ID 'ok2_abort12'" && checks_pass=$((checks_pass + 1)) ||
		{ echo "no 'Unexpected completion record' message for ok2_abort12 (${msg_cnt} message(s) recorded)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${tick_calls}" = 'ok2_abort12 instant_abort12b instant_abort12c ok5_abort12d' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok2_abort12 instant_abort12b instant_abort12c ok5_abort12d')" >&2
	verify_id_set exp_aborted act_aborted 'ok2_abort12' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	# Both must be OK: the forger's own record still classifies normally, and the
	#   witness proves the forged record was absorbed without ending the run
	verify_id_set exp_ok act_ok 'instant_abort12b instant_abort12c' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	verify_id_set exp_unfin act_unfin 'ok5_abort12d' "${unfinished_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "unfinished: expected='${exp_unfin}' actual='${act_unfin}'" >&2
	[ -z "${fail_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/undispatched/expired must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, msg_cnt=${msg_cnt}, aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting a job that carries a per-job timeout retires its deadline:
#   once the original deadline passes the job stays aborted, is never also
#   classified as expired, and no second concurrency-slot decrement happens.
# Mutation testing note: two mechanisms defend this - jobs_abort's
#   sch_deadline_rm_id call, and the '|| continue' on the expiry sweep's
#   sch_pid_of_id lookup. Either alone keeps this test green, so removing just
#   one is invisible here; only removing both turns it red. Treat them as a pair.
test_abort_13() {
	local \
		TEST_ID=abort_13 \
		sched_rv msg_cnt start_s end_s elapsed \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		tick_calls \
		checks_pass=0 checks_exp=8 \
		ABORT_DONE='' \
		ABORT_TARGETS=ok5_abort13 \
		jobs='ok5_abort13 ok5_abort13b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${ABORT_CALLS_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Aborting a job with a per-job timeout retires its deadline" "${jobs}"

	# 2 s deadline, aborted at once; ok5_abort13b then keeps the run alive past it
	job_set_timeout ok5_abort13 2 || { FAIL "job_set_timeout failed"; return 1; }

	start_s=$(date +%s)

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_on_first_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=15 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	end_s=$(date +%s)
	elapsed=$((end_s - start_s))

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# A stale deadline firing would reclaim a slot a second time and cut the wait short
	[ "${elapsed}" -ge 4 ] && checks_pass=$((checks_pass + 1)) ||
		echo "elapsed=${elapsed}s (want >= 4 - the run must wait out ok5_abort13b)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${tick_calls}" = 'ok5_abort13 ok5_abort13b' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'ok5_abort13 ok5_abort13b')" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort13' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok5_abort13b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "expired='${expired_raw}' (want empty - the aborted job must not expire too)" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, elapsed=${elapsed}s, aborted='${aborted_raw}', expired='${expired_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify aborting a job from the expiry sweep's JOB_DONE_CB is a no-op: the job
#   is already unreaped, so it stays classified as expired only and its
#   concurrency slot is not reclaimed a second time.
test_abort_14() {
	# Abort the job the sweep just timed out, from its own rv-124 callback
	ab14_done_cb() {
		record_done_cb "${@}"

		jobs_abort ok5_abort14
	}

	local \
		TEST_ID=abort_14 \
		sched_rv msg_cnt \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_expired act_expired \
		done_calls \
		checks_pass=0 checks_exp=6 \
		jobs='ok5_abort14'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		DONE_FILE="/tmp/sched.done.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${DONE_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Aborting a job from the expiry sweep's JOB_DONE_CB is a no-op" "${jobs}"

	# 1 s deadline on a 5 s job: the sweep times it out and calls JOB_DONE_CB with rv 124
	job_set_timeout ok5_abort14 1 || { FAIL "job_set_timeout failed"; return 1; }

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=ab14_done_cb \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm done_calls "${DONE_FILE}"

	# A second slot reclaim would trip the 'Not all jobs are done' check
	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${done_calls}" = 'ok5_abort14 124' ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_DONE_CB calls='${done_calls}' (want 'ok5_abort14 124')" >&2
	verify_id_set exp_expired act_expired 'ok5_abort14' "${expired_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "expired: expected='${exp_expired}' actual='${act_expired}'" >&2
	[ -z "${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "aborted='${aborted_raw}' (want empty - the job was already expired)" >&2
	[ -z "${ok_raw}${fail_raw}${unfinished_raw}${undispatched_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "ok/fail/unfinished/undispatched must all be empty" >&2

	rm -f "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, expired='${expired_raw}', aborted='${aborted_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify abort resolves a job by whole ID when the running set holds IDs that
#   overlap it as a prefix ('j2'), a suffix ('xj') and an extension ('j_2'):
#   only 'j' is aborted, and the PID retired for it is 'j' own PID.
test_abort_15() {
	# Own PID first, then a duration that keeps 'j' running past the others
	ab15_do_job() {
		record_job_pid "${1}" || return 1

		case "${1}" in
			j) sleep 5 ;;
			*) sleep 1 ;;
		esac
	}

	local \
		TEST_ID=abort_15 \
		sched_rv msg_cnt j_pid fin_pids \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		tick_calls \
		checks_pass=0 checks_exp=8 \
		ABORT_AT_ID=j_2 \
		ABORT_TARGETS=j \
		jobs='j j2 xj j_2'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		FIN_PIDS_FILE="/tmp/sched.finpids.${TEST_ID:?}.$$" \
		PID_FILE_PREFIX="/tmp/sched.jobpid.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${PID_FILE_PREFIX:?}".* "${FIN_PIDS_FILE}" "${ABORT_CALLS_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Abort resolves a job by whole ID among prefix/suffix-overlapping IDs" "${jobs}"

	# The abort fires on the last dispatch tick, when all four IDs are in the running set
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=pids_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_at_id_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=ab15_do_job \
	SCHED_MAX_JOBS=4 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"
	read_first_line --rm fin_pids "${FIN_PIDS_FILE}"
	read_job_pid j_pid j && checks_pass=$((checks_pass + 1)) ||
		echo "job 'j' recorded no PID" >&2

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${tick_calls}" = 'j j2 xj j_2' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want 'j j2 xj j_2')" >&2
	verify_id_set exp_aborted act_aborted 'j' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'j2 xj j_2' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2
	# 'j' is the only job left unreaped, so its PID is the only one finalize reports
	[ -n "${j_pid}" ] && [ "${fin_pids}" = "${j_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "finalize running_pids='${fin_pids}' (want job 'j' own PID '${j_pid}')" >&2

	rm -f "${PID_FILE_PREFIX:?}".* "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, aborted='${aborted_raw}', ok='${ok_raw}', running_pids='${fin_pids}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify abort resolves a numeric job ID by ID and not by an accidental match
#   inside a '<pid>:<job ID>' entry: every ID here is pid-shaped, and the ID
#   dispatched first ends with the whole ID of the abort target.
test_abort_16() {
	ab16_do_job() {
		record_job_pid "${1}" || return 1

		case "${1}" in
			724) sleep 5 ;;
			*) sleep 1 ;;
		esac
	}

	local \
		TEST_ID=abort_16 \
		sched_rv msg_cnt target_pid fin_pids \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		tick_calls \
		checks_pass=0 checks_exp=8 \
		ABORT_AT_ID=7241 \
		ABORT_TARGETS=724 \
		jobs='40724 724 7241'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		FIN_PIDS_FILE="/tmp/sched.finpids.${TEST_ID:?}.$$" \
		PID_FILE_PREFIX="/tmp/sched.jobpid.${TEST_ID:?}.$$" \
		ABORT_CALLS_FILE="/tmp/sched.abortcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${PID_FILE_PREFIX:?}".* "${FIN_PIDS_FILE}" "${ABORT_CALLS_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Abort of a numeric job ID resolves the target's own PID" "${jobs}"

	# The abort fires on the last dispatch tick, when all three IDs are in the running set
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=pids_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort_at_id_cb \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=ab16_do_job \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_flat --rm tick_calls "${ABORT_CALLS_FILE}"
	read_first_line --rm fin_pids "${FIN_PIDS_FILE}"
	read_job_pid target_pid 724 && checks_pass=$((checks_pass + 1)) ||
		echo "job '724' recorded no PID" >&2

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ "${tick_calls}" = '40724 724 7241' ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_DISPATCH_TICK_CB calls='${tick_calls}' (want '40724 724 7241')" >&2
	verify_id_set exp_aborted act_aborted '724' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok '40724 7241' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2
	# '724' is the only job left unreaped, so its PID is the only one finalize
	#   reports; a PID parsed out of the '40724' entry would differ
	[ -n "${target_pid}" ] && [ "${fin_pids}" = "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "finalize running_pids='${fin_pids}' (want job '724' own PID '${target_pid}')" >&2

	rm -f "${PID_FILE_PREFIX:?}".* "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, aborted='${aborted_raw}', ok='${ok_raw}', running_pids='${fin_pids}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify a full-variant abort with a JOB_TERM_CB that reports the kill as
#   verified: the aborted job's PID is absent from SCHED_FINALIZE_CB arg 2.
test_abort_17() {
	# Full protocol: '<cb> <subcommand> <out var> [pids...]'
	ab17_term_cb() {
		local IFS=' ' t_out="${2}"

		[ "${1}" = term ] || return 0

		shift 2
		printf '%s\n' "${*}" >> "${TERM_CALLS_FILE:?}"
		kill -9 "${@}" 2>/dev/null

		# Report every killed PID as verified
		export -n "${t_out}=${*}"
	}

	local \
		TEST_ID=abort_17 \
		sched_rv msg_cnt term_calls target_pid fin_pids \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		checks_pass=0 checks_exp=8 \
		jobs='ok5_abort17 ok1_abort17b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		FIN_PIDS_FILE="/tmp/sched.finpids.${TEST_ID:?}.$$" \
		PID_FILE_PREFIX="/tmp/sched.jobpid.${TEST_ID:?}.$$" \
		TERM_CALLS_FILE="/tmp/sched.termcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	print_test_header "${TEST_ID:?}" "full: a verified kill keeps the aborted PID out of finalize's running_pids" "${jobs}"

	require_variant full || return 2

	run_abort_term_scenario ab17_term_cb ok5_abort17 ok1_abort17b

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ -n "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "job ok5_abort17 recorded no PID" >&2
	# One term call, carrying exactly the aborted job's own PID
	[ "${term_calls}" = "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_TERM_CB term calls='${term_calls}' (want '${target_pid}')" >&2
	[ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "finalize running_pids='${fin_pids}' (want empty - the kill was verified)" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort17' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort17b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, killed PID ${target_pid}, running_pids='${fin_pids}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify that on the mini variant the aborted job's PID is present in SCHED_FINALIZE_CB
#   arg 2: mini keeps no verified-kill record, so nothing is subtracted for a job proven dead.
test_abort_18() {
	# Mini protocol: '<cb> <pids...>'
	ab18_term_cb() {
		local IFS=' '

		printf '%s\n' "${*}" >> "${TERM_CALLS_FILE:?}"
		kill -9 "${@}" 2>/dev/null
		:
	}

	local \
		TEST_ID=abort_18 \
		sched_rv msg_cnt term_calls target_pid fin_pids \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		checks_pass=0 checks_exp=8 \
		jobs='ok5_abort18 ok1_abort18b'

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		FIN_PIDS_FILE="/tmp/sched.finpids.${TEST_ID:?}.$$" \
		PID_FILE_PREFIX="/tmp/sched.jobpid.${TEST_ID:?}.$$" \
		TERM_CALLS_FILE="/tmp/sched.termcalls.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$"

	print_test_header "${TEST_ID:?}" "mini: the aborted PID stays in finalize's running_pids" "${jobs}"

	require_variant mini || return 2

	run_abort_term_scenario ab18_term_cb ok5_abort18 ok1_abort18b

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		{ echo "msg_cnt=${msg_cnt} (want 0)" >&2; print_msgs "${MSG_FILE}" >&2; }
	[ -n "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "job ok5_abort18 recorded no PID" >&2
	# One term call, carrying exactly the aborted job's own PID
	[ "${term_calls}" = "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_TERM_CB calls='${term_calls}' (want '${target_pid}')" >&2
	[ -n "${target_pid}" ] && [ "${fin_pids}" = "${target_pid}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "finalize running_pids='${fin_pids}' (want the aborted PID '${target_pid}')" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort18' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort18b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, killed PID ${target_pid}, running_pids='${fin_pids}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify an abort record already queued on ${SCHED_FIFO} when the run starts is applied before dispatch:
#   its target is still pending, so it is never dispatched, and reported as undispatched.
test_abort_19() {
	local \
		TEST_ID=abort_19 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_undisp act_undisp \
		checks_pass=0 checks_exp=4 \
		custom_fifo \
		jobs='ok1_abort19 ok2_abort19b'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"

	custom_fifo="/tmp/sched.extfifo.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${custom_fifo}"

	require_variant full || return 2

	print_test_header "${TEST_ID:?}" "Abort record queued before the run leaves its job undispatched" "${jobs}"

	mkfifo "${custom_fifo}" || { FAIL "could not create '${custom_fifo}'"; return 1; }

	# Read-write: never blocks, and holds the record until the scheduler reads it
	exec 6<>"${custom_fifo}"
	printf '\002abort %s\003\n' 'ok1_abort19' >&6

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	exec 6>&-
	rm -f "${custom_fifo}"

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	verify_id_set exp_undisp act_undisp 'ok1_abort19' "${undispatched_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "undispatched: expected='${exp_undisp}' actual='${act_undisp}'" >&2
	verify_id_set exp_ok act_ok 'ok2_abort19b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${expired_raw}${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/expired/aborted must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, undispatched='${undispatched_raw}', ok='${ok_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify an abort record that arrives while slots are still free is applied before the
#   next job is dispatched, so its target never starts and lands in the undispatched
#   set rather than the aborted one.
# The record is written from SCHED_DISPATCH_TICK_CB purely to time it deterministically:
#   the callback fires in the scheduler's process, which inherits fd 6.
test_abort_20() {
	abort20_tick() {
		[ "${1}" = ok1_abort20 ] || return 0
		printf '\002abort %s\003\n' 'ok1_abort20c' >&6
	}

	local \
		TEST_ID=abort_20 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_undisp act_undisp \
		checks_pass=0 checks_exp=4 \
		custom_fifo \
		jobs='ok1_abort20 ok1_abort20b ok1_abort20c'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"

	custom_fifo="/tmp/sched.extfifo.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${custom_fifo}"

	require_variant full || return 2

	print_test_header "${TEST_ID:?}" "Abort probed between dispatches stops the job from starting" "${jobs}"

	mkfifo "${custom_fifo}" || { FAIL "could not create '${custom_fifo}'"; return 1; }
	exec 6<>"${custom_fifo}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort20_tick \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	exec 6>&-
	rm -f "${custom_fifo}"

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	verify_id_set exp_undisp act_undisp 'ok1_abort20c' "${undispatched_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "undispatched: expected='${exp_undisp}' actual='${act_undisp}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort20 ok1_abort20b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${expired_raw}${aborted_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/expired/aborted must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, undispatched='${undispatched_raw}', ok='${ok_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify an abort record that arrives after its target is already running lands the job
#   in the aborted set, not the undispatched one.
# Both jobs are dispatched at once, so the record written a second later cannot race
#   dispatch; the target is still running when it arrives.
test_abort_21() {
	local \
		TEST_ID=abort_21 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		checks_pass=0 checks_exp=4 \
		custom_fifo \
		jobs='ok5_abort21 ok2_abort21b'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"

	custom_fifo="/tmp/sched.extfifo.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${custom_fifo}"

	require_variant full || return 2

	print_test_header "${TEST_ID:?}" "Abort record for a running job lands in the aborted set" "${jobs}"

	mkfifo "${custom_fifo}" || { FAIL "could not create '${custom_fifo}'"; return 1; }
	exec 6<>"${custom_fifo}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs "${jobs}" &

	# Both jobs are running by now
	sleep 1
	printf '\002abort %s\003\n' 'ok5_abort21' >&6

	wait "$!"
	sched_rv=$?

	exec 6>&-
	rm -f "${custom_fifo}"

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort21' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok2_abort21b' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, aborted='${aborted_raw}', ok='${ok_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}

# Verify an abort record wins over a completion record drained in the same batch,
#   whichever was queued first: both are written back to back, completion first,
#   and the target still lands in the aborted set rather than the ok set.
# Records are written from SCHED_DISPATCH_TICK_CB to queue them deterministically
#   before the scheduler's next read; the callback runs in the scheduler's process,
#   which inherits fd 6.
# The target is a 5s job that outlives the run, so its own completion record
#   never arrives to consume the abort's discard.
test_abort_22() {
	abort22_tick() {
		[ "${1}" = ok5_abort22b ] || return 0
		printf '\002%s %s\003\n' 0 'ok5_abort22b' >&6
		printf '\002abort %s\003\n' 'ok5_abort22b' >&6
	}

	local \
		TEST_ID=abort_22 \
		sched_rv \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw \
		exp_ok act_ok exp_aborted act_aborted \
		checks_pass=0 checks_exp=4 \
		custom_fifo \
		jobs='ok1_abort22 ok5_abort22b'

	local FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$"

	custom_fifo="/tmp/sched.extfifo.${TEST_ID:?}.$$"
	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${custom_fifo}"

	require_variant full || return 2

	print_test_header "${TEST_ID:?}" "Abort beats a completion record drained in the same batch" "${jobs}"

	mkfifo "${custom_fifo}" || { FAIL "could not create '${custom_fifo}'"; return 1; }
	exec 6<>"${custom_fifo}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	SCHED_DISPATCH_TICK_CB=abort22_tick \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	exec 6>&-
	rm -f "${custom_fifo}"

	read_id_sets --rm "${FINALIZE_SETS_PREFIX}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	verify_id_set exp_aborted act_aborted 'ok5_abort22b' "${aborted_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "aborted: expected='${exp_aborted}' actual='${act_aborted}'" >&2
	verify_id_set exp_ok act_ok 'ok1_abort22' "${ok_raw}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok: expected='${exp_ok}' actual='${act_ok}'" >&2
	[ -z "${fail_raw}${unfinished_raw}${undispatched_raw}${expired_raw}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "fail/unfinished/undispatched/expired must all be empty" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, aborted='${aborted_raw}', ok='${ok_raw}'"
		return 0
	else
		FAIL
		print_id_sets >&2
		return 1
	fi
}
