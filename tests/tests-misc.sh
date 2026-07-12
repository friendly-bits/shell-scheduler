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

# Verify job IDs with arbitrary non-whitespace chars reach DO_JOB_CB/JOB_DONE_CB unchanged.
test_misc_02() {
	misc_02_do_job() {
		printf '%s\n' "$1" >> "${ARGS_FILE:?}"
		sleep 1
		return 0
	}

	misc_02_done_handler() {
		printf '%s\n' "$1" >> "${DONE_FILE:?}"
		return 0
	}

	misc_02_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	local \
		TEST_ID=misc_02 \
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
		INJECT_FILE="/tmp/sched.idchars.inject.${TEST_ID}.$$" \
		ARGS_FILE="/tmp/sched.idchars.args.${TEST_ID}.$$" \
		DONE_FILE="/tmp/sched.idchars.done.${TEST_ID}.$$"

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
		cmdsub\$(misc_02_touch_inject) \
		subshelltick\`misc_02_touch_inject\` \
		semiexec;misc_02_touch_inject \
		andexec&&misc_02_touch_inject \
		pipeexec|misc_02_touch_inject \
	"

	jobs="${jobs//[$'\n'$'\t']/}"

	print_test_header "${TEST_ID:?}" "Arbitrary characters in job IDs" \
		"30 IDs covering glob/quote/injection-shaped characters"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	DO_JOB_CB=misc_02_do_job \
	JOB_DONE_CB=misc_02_done_handler \
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
		jobs='ok ok ok'

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
