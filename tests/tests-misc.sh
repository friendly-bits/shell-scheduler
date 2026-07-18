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

# Verify job-ID validation: IDs are restricted to [a-zA-Z0-9_]. Each list
#   containing an ID with any other character is rejected upfront: rv 1, one
#   error message, nothing dispatched (a valid ID in the same list must not
#   run), and injection-shaped IDs are never executed. A control run with
#   valid IDs (including a leading digit) still succeeds.
test_misc_02() {
	misc_02_do_job() {
		printf '%s\n' "$1" >> "${ARGS_FILE:?}"
		return 0
	}

	misc_02_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	misc_02_fail_msg() {
		printf '%s\n' "$*" >> "${MSG_FILE:?}"
	}

	local \
		TEST_ID=misc_02 \
		sched_rv bad_id bad_cnt=0 msg_cnt=0 \
		checks_ok=1

	local \
		INJECT_FILE="/tmp/sched.idchars.inject.${TEST_ID}.$$" \
		ARGS_FILE="/tmp/sched.idchars.args.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.idchars.msg.${TEST_ID}.$$"

	rm -f "${ARGS_FILE}" "${MSG_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Job ID validation: only [a-zA-Z0-9_] accepted" \
		"(30 invalid IDs rejected + 1 valid control run)"

	# Glob/quote/injection-shaped chars: every one of these IDs must be
	#   rejected. IDs contain no whitespace, so a plain for-list is safe here.
	for bad_id in \
		'star*id' \
		'quest?id' \
		'brk[et]s' \
		'brace{d}' \
		'paren(ed)' \
		'dollarsign$x' \
		'backtick`x`' \
		'semi;colon' \
		'pipe|line' \
		'amp&and' \
		'ltgt<>x' \
		'eqsign=x' \
		'hashtag#x' \
		'bangmark!x' \
		'tildeish~x' \
		'atsign@x' \
		'carethat^x' \
		'percentsign%x' \
		'colonsep:x' \
		'dotdot.x' \
		'commasep,x' \
		'dash-ed' \
		"apos'trophe" \
		'dquo"te' \
		'bslash\x' \
		'cmdsub$(misc_02_touch_inject)' \
		'subshelltick`misc_02_touch_inject`' \
		'semiexec;misc_02_touch_inject' \
		'andexec&&misc_02_touch_inject' \
		'pipeexec|misc_02_touch_inject'
	do
		bad_cnt=$((bad_cnt + 1))
		SCHED_FAIL_MSG_CB=misc_02_fail_msg \
		DO_JOB_CB=misc_02_do_job \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs "validok ${bad_id}" &
		wait "$!"
		sched_rv=$?
		[ "${sched_rv}" = 1 ] ||
			{ checks_ok=; echo "id '${bad_id}': sched_rv=${sched_rv}, expected 1" >&2; }
	done

	# Nothing may be dispatched from a rejected list - not even the valid ID
	[ ! -s "${ARGS_FILE}" ] ||
		{ checks_ok=; echo "jobs ran despite rejection: $(cat "${ARGS_FILE}")" >&2; }

	# Injection-shaped IDs must never be executed
	[ ! -e "${INJECT_FILE}" ] ||
		{ checks_ok=; echo "injection marker exists" >&2; }

	# One error message per rejected list
	[ -f "${MSG_FILE}" ] && msg_cnt="$(wc -l < "${MSG_FILE}")"
	[ "${msg_cnt}" -eq "${bad_cnt}" ] ||
		{ checks_ok=; echo "expected ${bad_cnt} error messages, got ${msg_cnt}" >&2; }

	# Control: valid IDs, including one with a leading digit, still run
	SCHED_FAIL_MSG_CB=misc_02_fail_msg \
	DO_JOB_CB=misc_02_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'plain_ok 0digit_ok' &
	wait "$!"
	sched_rv=$?
	[ "${sched_rv}" = 0 ] && [ "$(sed '/^$/d' "${ARGS_FILE}" 2>/dev/null | wc -l)" = 2 ] ||
		{ checks_ok=; echo "control run: sched_rv=${sched_rv}, jobs run: $(cat "${ARGS_FILE}" 2>/dev/null)" >&2; }

	rm -f "${ARGS_FILE}" "${MSG_FILE}" "${INJECT_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "${bad_cnt} invalid IDs rejected, control run ok"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify forged completion records (glob/injection-shaped IDs) are rejected, never executed.
test_misc_03() {
	misc_03_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	misc_03_do_job() {
		local self_pid

		get_test_pid self_pid || return 1
		printf '%s %s %s\n' "${self_pid}" 0 "${SPOOF_DONE_ID:?}" >&3
		sleep 1

		return 0
	}

	misc_03_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	misc_03_check_forgery() {
		local job_id="${1:?}" spoof_id="${2:?}" sched_rv

		rm -f "${INJECT_FILE:?}"

		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=misc_03_do_job \
		SCHED_FAIL_MSG_CB=misc_03_fail_msg_handler \
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
		TEST_ID=misc_03 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0

	local \
		INJECT_FILE="/tmp/sched.forge.inject.${TEST_ID}.$$" \
		FAIL_MSG_FILE="/tmp/sched.forge.msg.${TEST_ID}.$$"

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Job-ID forgery / injection resistance" \
		"spoofed completion records with glob and shell-metacharacter IDs"

	misc_03_check_forgery "realjob" "*"
	misc_03_check_forgery "realjob" "\$(misc_03_touch_inject)"
	misc_03_check_forgery "realjob" "\`misc_03_touch_inject\`"
	misc_03_check_forgery "realjob" ";misc_03_touch_inject"

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
test_misc_04() {
	misc_04_do_job() {
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
		TEST_ID=misc_04 \
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
	DO_JOB_CB=misc_04_do_job \
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
test_misc_05() {
	local \
		TEST_ID=misc_05 \
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
test_misc_06() {
	misc_06_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	misc_06_do_job() {
		# Forge a well-formed record with a PID that is not the running worker.
		printf '%s %s %s\n' 999999999 0 "${1}" >&3
		sleep 1
		return 0
	}

	local \
		TEST_ID=misc_06 \
		sched_rv \
		msg \
		msg_ok \
		jobs='realjob'

	local MSG_FILE="/tmp/sched.unknownpid.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Completion record with an unknown PID is rejected" "${jobs}"

	SCHED_FAIL_MSG_CB=misc_06_fail_msg \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=misc_06_do_job \
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
