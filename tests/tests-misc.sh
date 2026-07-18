#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-misc.sh

# Category: Misc Integrity
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify extra args to schedule_jobs() are forwarded unchanged to DO_JOB_CB after the job ID.
test_misc_01() {
	misc_01_do_job() {
		printf '%s\n' "$*" >> "${ARGS_FILE:?}"
		return 0
	}

	local \
		TEST_ID=misc_01 \
		sched_rv \
		expected \
		actual \
		jobs='1 2 3'

	local ARGS_FILE="/tmp/sched.args.${TEST_ID:?}.$$"
	rm -f "${ARGS_FILE}"

	print_test_header "${TEST_ID:?}" "Job callback receives scheduler arguments" \
		"${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=misc_01_do_job \
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

# Verify extra args to schedule_jobs() reach DO_JOB_CB with exact boundaries/content intact:
#   empty string, embedded whitespace, glob metacharacters, leading dash.
test_misc_02() {
	misc_02_do_job() {
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
		TEST_ID=misc_02 \
		sched_rv \
		expected \
		actual \
		jobs='1 2 3'

	local ARGS_FILE="/tmp/sched.args4.${TEST_ID:?}.$$"
	rm -f "${ARGS_FILE}"

	print_test_header "${TEST_ID:?}" "Extra-argument boundary/content integrity" \
		"${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=misc_02_do_job \
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

# Verify finalize() removes the scheduler's FIFO after a normal run, no leaked file.
test_misc_03() {
	local \
		TEST_ID=misc_03 \
		sched_rv \
		scheduler_pid \
		sched_fifo \
		jobs='instant_1 instant_2 instant_3'

	print_test_header "${TEST_ID:?}" "FIFO cleanup after successful completion" "${jobs}"

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

# Verify unexpected PID is rejected as an internal-consistency error
test_misc_04() {
	misc_04_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	misc_04_do_job() {
		# Forge a well-formed record with a PID that is not the running worker.
		printf '%s %s %s\n' 999999999 0 "${1}" >&3
		sleep 1
		return 0
	}

	local \
		TEST_ID=misc_04 \
		sched_rv \
		msg \
		msg_ok \
		jobs='realjob'

	local MSG_FILE="/tmp/sched.unknownpid.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Completion record with an unknown PID is rejected" "${jobs}"

	SCHED_FAIL_MSG_CB=misc_04_fail_msg \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=misc_04_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"Unknown PID"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${sched_rv}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "sched_rv=${sched_rv}, msg='${msg}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, msg='${msg}', expected rv=1 and an 'Unknown PID' error"
		return 1
	fi
}
