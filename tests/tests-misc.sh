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
		sched_run_dir \
		fifo_seen=no \
		checks_pass=0 checks_exp=4 \
		jobs='ok2_m03a ok2_m03b'

	print_test_header "${TEST_ID:?}" "Run dir and FIFO are removed after successful completion" "${jobs}"

	# Jobs must outlive the observation below, so they are 2s each rather than instant
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	# Observe the FIFO while the jobs still run: without proof that the path once
	#   existed, the post-run 'is it gone' checks would pass for any wrong path
	sleep 1
	sched_fifo_path sched_fifo "${scheduler_pid}"
	sched_run_dir="${sched_fifo%/ipc}"
	[ -p "${sched_fifo}" ] && fifo_seen=yes

	wait "${scheduler_pid}"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${fifo_seen}" = yes ] && checks_pass=$((checks_pass + 1)) ||
		echo "FIFO not observed during the run at '${sched_fifo}'" >&2
	[ ! -e "${sched_fifo}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "FIFO left behind: '${sched_fifo}'" >&2
	[ ! -d "${sched_run_dir}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "run dir left behind: '${sched_run_dir}'" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, FIFO observed during the run, then removed with its run dir"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify a completion record naming a job that is not currently running
#   is rejected as an internal-consistency error
test_misc_04() {
	misc_04_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	misc_04_do_job() {
		# Forge a well-formed record for a registered job that has not been dispatched yet.
		# SCHED_MAX_JOBS=1 keeps pending_m04 undispatched while realjob_m04 runs.
		write_done_rec 0 pending_m04
		sleep 1
		return 0
	}

	local \
		TEST_ID=misc_04 \
		sched_rv \
		msg \
		msg_ok \
		jobs='realjob_m04 pending_m04'

	local MSG_FILE="/tmp/sched.unexpectedrec.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Completion record for a job that is not running is rejected" "${jobs}"

	# The job forges the record on fd 3, which SCHED_INNER_SUBSHELL closes
	SCHED_FAIL_MSG_CB=misc_04_fail_msg \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=misc_04_do_job \
	SCHED_INNER_SUBSHELL='' \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"Unexpected completion record"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${sched_rv}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "sched_rv=${sched_rv}, msg='${msg}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, msg='${msg}', expected rv=1 and an 'Unexpected completion record' error"
		return 1
	fi
}

# Verify the run directory and the FIFO the scheduler creates for itself are readable by their owner only.
# Also verify the umask that makes them owner-only does not outlive their creation:
#   a file the scheduler completion callback creates must use the caller's umask,
#   since that callback runs in the scheduler's own process well after the FIFO was made.
test_misc_05() {
	misc_05_finalize() {
		: > "${M05_PROBE_FILE:?}"

		finalize_handler "${1}" "${2}"
		return "${1}"
	}

	# Set the out var to the 10-character permission string of a path
	# 1: out var
	# 2: path
	misc_05_mode() {
		local m05_m

		m05_m="$(ls -ld "${2}" 2>/dev/null)" || return 1
		m05_m="${m05_m%% *}"
		# Drop a trailing SELinux/ACL marker
		export -n "${1:?}=${m05_m%[.+]}"
	}

	local \
		TEST_ID=misc_05 \
		sched_rv scheduler_pid sched_fifo sched_run_dir prev_umask \
		fifo_mode='<unread>' dir_mode='<unread>' probe_mode='<unread>' \
		fifo_seen=no \
		checks_pass=0 checks_exp=5 \
		jobs='ok2_m05a ok2_m05b'

	local M05_PROBE_FILE="/tmp/sched.umaskprobe.${TEST_ID:?}.$$"

	rm -f "${M05_PROBE_FILE}"

	print_test_header "${TEST_ID:?}" "Run dir and FIFO are owner-only, and the umask does not outlive them" "${jobs}"

	# A known caller umask, so the probe file below has an unambiguous expected mode
	prev_umask="$(umask)"
	umask 022

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=misc_05_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	# The 2s jobs keep the run alive while the FIFO is inspected
	sleep 1
	sched_fifo_path sched_fifo "${scheduler_pid}"
	sched_run_dir="${sched_fifo%/ipc}"
	[ -p "${sched_fifo}" ] && fifo_seen=yes
	misc_05_mode fifo_mode "${sched_fifo}"
	misc_05_mode dir_mode "${sched_run_dir}"

	wait "${scheduler_pid}"
	sched_rv=$?

	umask "${prev_umask}"

	misc_05_mode probe_mode "${M05_PROBE_FILE}"
	rm -f "${M05_PROBE_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# Without this, a wrong path would make the mode checks fail for the wrong reason
	[ "${fifo_seen}" = yes ] && checks_pass=$((checks_pass + 1)) ||
		echo "FIFO not observed during the run at '${sched_fifo}'" >&2
	[ "${fifo_mode}" = 'prw-------' ] && checks_pass=$((checks_pass + 1)) ||
		echo "FIFO mode='${fifo_mode}' (want 'prw-------')" >&2
	[ "${dir_mode}" = 'drwx------' ] && checks_pass=$((checks_pass + 1)) ||
		echo "run dir mode='${dir_mode}' (want 'drwx------')" >&2
	# 0600 here would mean the scheduler kept umask 077 for the rest of the run
	[ "${probe_mode}" = '-rw-r--r--' ] && checks_pass=$((checks_pass + 1)) ||
		echo "file created by SCHED_FINALIZE_CB under umask 022 has mode='${probe_mode}' (want '-rw-r--r--')" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "fifo=${fifo_mode}, run dir=${dir_mode}, callback-created file=${probe_mode}"
		return 0
	else
		FAIL
		return 1
	fi
}
