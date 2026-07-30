#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-sched_env.sh

# Category: Scheduler environment variables (SCHED_*) and callback vars (*_CB):
#   accepted/rejected values, defaults, empty/unset fallback.
#   Per-job parameter behavior belongs in the 'params' categories, even when a
#   SCHED_* variable is what selects it.
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify the SCHED_FINALIZE_CB return value always becomes the scheduler exit code,
#   including a zero return masking a scheduler error, and that the callback receives
#   the scheduler's own rv as ${1}.
test_sched_env_01() {
	sched_env_01_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}"

		printf '%s\n' "${rv}" >> "${FINALIZE_RV_FILE}"

		return "${SCHED_ENV_01_FINALIZE_RV:?}"
	}

	local \
		TEST_ID=sched_env_01 \
		rv_success \
		rv_failure \
		rv_masked \
		recorded_rvs \
		SCHED_ENV_01_FINALIZE_RV=97

	print_test_header "${TEST_ID:?}" \
		"SCHED_FINALIZE_CB return value always becomes the scheduler exit code" \
		"success path, error path and masked error path"

	FINALIZE_RV_FILE="/tmp/sched.finalize.fail.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_RV_FILE}"

	# shellcheck disable=SC2034
	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=sched_env_01_finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default

	# Successful scheduler run: callback rv becomes scheduler rv, callback sees rv 0
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	SCHED_ENV_01_FINALIZE_RV=97 \
		schedule_jobs 'instant_se01' &

	wait "$!"
	rv_success=$?

	# Idle timeout: callback rv overrides the scheduler rv, callback sees rv 81
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=2 \
	SCHED_ENV_01_FINALIZE_RV=97 \
		schedule_jobs 'hang_se01a' &

	wait "$!"
	rv_failure=$?

	# Idle timeout: a zero-returning callback masks the scheduler error
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=2 \
	SCHED_ENV_01_FINALIZE_RV=0 \
		schedule_jobs 'hang_se01b' &

	wait "$!"
	rv_masked=$?

	read_flat --rm recorded_rvs "${FINALIZE_RV_FILE}"

	if [ "${rv_success}" = "${SCHED_ENV_01_FINALIZE_RV}" ] &&
		[ "${rv_failure}" = "${SCHED_ENV_01_FINALIZE_RV}" ] &&
		[ "${rv_masked}" = 0 ] &&
		[ "${recorded_rvs}" = "0 81 81" ]
	then
		PASS "success_rv=${rv_success}, failure_rv=${rv_failure}, masked_rv=${rv_masked}"
		return 0
	else
		FAIL "success_rv=${rv_success}, failure_rv=${rv_failure}, masked_rv=${rv_masked}, recorded=${recorded_rvs}"
		return 1
	fi
}

# Verify invalid callback configuration is rejected before any jobs start.
test_sched_env_02() {
	sched_env_02_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	sched_env_02_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# shellcheck disable=SC2034
	local \
		TEST_ID=sched_env_02 \
		sched_rv \
		pass_cnt=0 \
		msg_cnt=0 \
		cb bad_cb \
		\
		SCHED_FINALIZE_CB_def=finalize_handler \
		DO_JOB_CB_def=sched_env_02_do_job \
		JOB_DONE_CB_def=done_handler \
		SCHED_FAIL_MSG_CB_def=sched_env_02_fail_msg_handler

	local \
		FAIL_MSG_FILE="/tmp/sched.badcb.msg.${TEST_ID:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.badcb.job.${TEST_ID:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	local \
		cb_list=" \
			SCHED_FINALIZE_CB \
			DO_JOB_CB \
			JOB_DONE_CB \
			SCHED_FAIL_MSG_CB"

	set -- ${cb_list}
	local IFS=" "
	cb_list="${*}"
	IFS=${DEFAULT_IFS}


	print_test_header "${TEST_ID:?}" "Invalid callback configuration" "${cb_list}"

	for bad_cb in ${cb_list}; do
		for cb in ${cb_list}; do
			if [ "${cb}" = "${bad_cb}" ]; then
				local "${cb}=does_not_exist"
			else
				eval "local ${cb}=\"\${${cb}_def}\""
			fi
		done

		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs '1' &
		wait "$!"
		sched_rv=$?

		[ "${sched_rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	done

	[ -f "${FAIL_MSG_FILE}" ] &&
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	if [ "${pass_cnt}" = 4 ] &&
		[ "${msg_cnt}" = 3 ]
	then
		PASS
		return 0
	else
		FAIL "passed=${pass_cnt}/4, messages=${msg_cnt}"
		return 1
	fi
}

# Verify invalid scheduler numeric env vars are rejected before any jobs start.
test_sched_env_03() {
	sched_env_03_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	sched_env_03_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# SCHED_MAX_JOBS is required (sch_normalize_uint's 3rd arg).
	# SCHED_TIMEOUT_S, SCHED_IDLE_TIMEOUT_S and SCHED_JOB_TIMEOUT_S are optional,
	#   so '' is a *valid* value for them (means "use default" / "unset")
	#   and must not be included as a bad value.
	sched_env_03_check_bad_value() {
		# shellcheck disable=SC2034
		local var="${1}" bad_val="${2}" sched_rv \
			SCHED_MAX_JOBS=1 \
			SCHED_TIMEOUT_S=3 \
			SCHED_IDLE_TIMEOUT_S=2

		local "${var}=${bad_val}"

		# stderr silenced: out-of-range values make the test builtin print a diagnostic on some shells
		SCHED_FAIL_MSG_CB=sched_env_03_fail_msg_handler \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=sched_env_03_do_job \
			schedule_jobs '1' 2>/dev/null &

		wait "$!"
		sched_rv=$?

		total_cnt=$((total_cnt + 1))

		[ "${sched_rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	}

	local \
		TEST_ID=sched_env_03 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		var bad_val

	local \
		FAIL_MSG_FILE="/tmp/sched.maxjobs.msg.${TEST_ID:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.maxjobs.job.${TEST_ID:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	print_test_header "${TEST_ID:?}" "Invalid scheduler numeric env var values" \
		"SCHED_MAX_JOBS(full malformed-uint matrix), SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S/SCHED_JOB_TIMEOUT_S(abc 0 -1)"

	# Full malformed-uint matrix on the required var;
	#   all four vars share the same validation, so the other three get representative classes
	for bad_val in '' abc 0 -1 00 1.5 +1 9x '1 2' 99999999999999999999; do
		sched_env_03_check_bad_value SCHED_MAX_JOBS "${bad_val}"
	done

	for var in SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S SCHED_JOB_TIMEOUT_S; do
		for bad_val in abc 0 -1; do
			sched_env_03_check_bad_value "${var}" "${bad_val}"
		done
	done

	if [ -f "${FAIL_MSG_FILE}" ]
	then
		msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")
	fi

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

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

# Verify JOB_DONE_CB may be empty and the scheduler still completes normally.
test_sched_env_04() {
	JOB_DONE_CB='' \
	SCHED_FINALIZE_CB=finalize_handler \
	TEST_ID=sched_env_04 \
	TEST_NAME='Empty JOB_DONE_CB' \
	TEST_JOBS='instant_1 instant_2 instant_3' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=2 \
		run_generic_test
}

# Verify SCHED_FINALIZE_CB may be empty and the scheduler still completes normally
#   (test_sched_env_04).
test_sched_env_05() {
	SCHED_FINALIZE_CB='' \
	JOB_DONE_CB=done_handler \
	TEST_ID=sched_env_05 \
	TEST_NAME='Empty SCHED_FINALIZE_CB' \
	TEST_JOBS='instant_1 instant_2 instant_3 instant_4 instant_5' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_generic_test
}

# Verify SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S may be left unset, falling back to defaults
#   (test_sched_env_07).
test_sched_env_06() {
	local \
		TEST_ID=sched_env_06 \
		sched_rv \
		jobs='instant'

	print_test_header "${TEST_ID:?}" "Unset SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S fall back to built-in defaults" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0"
		return 1
	fi
}

# Verify that explicitly empty-value SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S
#   are accepted and fall back to defaults.
test_sched_env_07() {
	local \
		TEST_ID=sched_env_07 \
		sched_rv \
		jobs='instant'

	print_test_header "${TEST_ID:?}" "Explicitly empty SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S accepted" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S='' \
	SCHED_IDLE_TIMEOUT_S='' \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0"
		return 1
	fi
}

# Verify SCHED_FIFO: the FIFO is created at exactly that path and removed afterward,
#   a value with a trailing slash is rejected, and an already existing path is not reused.
test_sched_env_08() {
	local \
		TEST_ID=sched_env_08 \
		sched_rv \
		bad_rv \
		busy_rv \
		scheduler_pid \
		custom_fifo \
		fifo_at_path=no \
		fifo_left=yes \
		jobs='ok2'

	custom_fifo="/tmp/sched.customfifo.${TEST_ID}.$$"
	rm -f "${custom_fifo}"

	print_test_header "${TEST_ID:?}" "SCHED_FIFO: exact path used and cleaned up; trailing slash and existing path rejected" "${jobs}"

	# Sub-check 1: the FIFO is created at the given path, not under /tmp/sched_*
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!

	sleep 1
	[ -p "${custom_fifo}" ] && fifo_at_path=yes

	wait "${scheduler_pid}"
	sched_rv=$?

	# Captured before sub-check 3 re-creates the path
	[ -e "${custom_fifo}" ] || fifo_left=no

	# Sub-check 2: trailing slash -> rejected
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	SCHED_FIFO="${custom_fifo}/" \
		schedule_jobs 'ok_1' &
	wait "$!"
	bad_rv=$?

	# Sub-check 3: a leftover FIFO is not reused
	rm -f "${custom_fifo}"
	mkfifo "${custom_fifo}" || { FAIL "could not create '${custom_fifo}'"; return 1; }

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	SCHED_FIFO="${custom_fifo}" \
		schedule_jobs 'ok_1' &
	wait "$!"
	busy_rv=$?
	rm -f "${custom_fifo}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${fifo_at_path}" = yes ] &&
		[ "${fifo_left}" = no ] &&
		[ "${bad_rv}" = 1 ] &&
		[ "${busy_rv}" = 1 ]
	then
		PASS "fifo_at_path=${fifo_at_path}, sched_rv=${sched_rv}, bad_rv=${bad_rv}, busy_rv=${busy_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, fifo_at_path=${fifo_at_path}, fifo_left=${fifo_left}, bad_rv=${bad_rv}, busy_rv=${busy_rv}"
		return 1
	fi
}

# Regression: leading-zero numeric env values are treated as decimal, not octal.
# Before normalization was added, SCHED_IDLE_TIMEOUT_S=09 killed the scheduler
#   with a fatal 'arithmetic syntax error' (09 is invalid octal)
#   on the first remaining-time computation, and 010 silently meant 8 seconds.
test_sched_env_09() {
	local \
		TEST_ID=sched_env_09 \
		sched_rv \
		jobs='instant_c09a instant_c09b instant_c09c'

	print_test_header "${TEST_ID:?}" "Leading-zero numeric env values are treated as decimal" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=02 \
	SCHED_TIMEOUT_S=010 \
	SCHED_IDLE_TIMEOUT_S=09 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ]
	then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, expected 0"
		return 1
	fi
}

# Verify SCHED_ID validation: a malformed namespace fails the run before dispatch,
#   a valid one (including unset and empty) is accepted.
test_sched_env_10() {
	sched_env_10_do_job() { printf 'started\n' > "${JOB_STARTED_FILE:?}"; return 0; }
	sched_env_10_fail_msg() { printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"; }

	# 1: SCHED_ID value, 2: expected scheduler rv, 3: 1 if the job must have started
	sched_env_10_run() {
		local sched_rv

		rm -f "${JOB_STARTED_FILE}"
		total_cnt=$((total_cnt + 1))

		SCHED_ID="${1}" \
		SCHED_FAIL_MSG_CB=sched_env_10_fail_msg \
		SCHED_FINALIZE_CB=finalize_handler \
		DO_JOB_CB=sched_env_10_do_job \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=5 \
		SCHED_IDLE_TIMEOUT_S=5 \
			schedule_jobs "${JOB_ID}" &

		wait "$!"
		sched_rv=$?

		if [ "${sched_rv}" = "${2}" ] &&
			{ { [ "${3}" = 1 ] && [ -f "${JOB_STARTED_FILE}" ]; } ||
			  { [ "${3}" != 1 ] && [ ! -f "${JOB_STARTED_FILE}" ]; }; }
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "SCHED_ID='%s': rv=%s (want %s), started=%s (want %s)\n" \
				"${1}" "${sched_rv}" "${2}" \
				"$([ -f "${JOB_STARTED_FILE}" ] && echo yes || echo no)" "${3}" >&2
		fi

		rm -f "${JOB_STARTED_FILE}"
	}

	local \
		TEST_ID=sched_env_10 \
		pass_cnt=0 total_cnt=0 bad_cnt=0 msg_cnt=0 \
		bad long_id

	local \
		JOB_ID=sched_env_10_job \
		FAIL_MSG_FILE="/tmp/sched.schedid.msg.${TEST_ID:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.schedid.job.${TEST_ID:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_ID validation" "${JOB_ID}"

	mk_name_of_len long_id 2021 "${TEST_ID}" ||
		{ FAIL "mk_name_of_len failed"; return 1; }

	# The command-substitution value doubles as an injection check: executing it
	#   would create ${JOB_STARTED_FILE}, which the "job must not start" leg catches
	for bad in 'a b' 'a-b' 'a.b' 'a/b' '$(sched_env_10_do_job)' "${long_id}"; do
		bad_cnt=$((bad_cnt + 1))
		sched_env_10_run "${bad}" 1 0
	done

	# Empty (no namespace) and well-formed values are accepted
	sched_env_10_run '' 0 1
	sched_env_10_run "${TEST_ID}_ns" 0 1

	[ -f "${FAIL_MSG_FILE}" ] && msg_cnt=$(wc -l < "${FAIL_MSG_FILE}")
	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = "${bad_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt} (want ${bad_cnt})"
		return 1
	fi
}

# Verify an empty SCHED_FINALIZE_CB leaves a non-zero scheduler return code intact.
test_sched_env_11() {
	SCHED_FINALIZE_CB='' \
	JOB_DONE_CB=done_handler \
	SCHED_TIMEOUT_S=30 \
	TEST_ID=sched_env_11 \
	TEST_NAME='Empty SCHED_FINALIZE_CB preserves the scheduler return code' \
	TEST_JOBS='hang_se11' \
	TEST_EXPECT_RV=81 \
	TEST_SCHED_MAX_JOBS=1 \
		run_generic_test
}

#
# Helpers for the SCHED_FAIL_MSG_CB tests below
#

# SCHED_DISPATCH_TICK_CB producing exactly one scheduler failure message per
#   dispatched job, from a public helper called with an invalid value.
fail_msg_on_dispatch() {
	job_set_timeout "${1}" 'not-a-uint'
	return 0
}

# Verify the SCHED_FAIL_MSG_CB re-entry guard: a callback that itself fails into the
#   scheduler's message path is entered once, the nested message goes to stderr with
#   exactly one recursion warning, and the run still completes normally.
test_sched_env_12() {
	sched_env_12_fail_msg() {
		record_fail_msg "${@}"
		# Fail into the message path from inside the callback
		job_set_timeout "${SE12_JOB:?}" 'not-a-uint'
		return 0
	}

	local \
		TEST_ID=sched_env_12 \
		sched_rv sched_pid killer_pid msg_cnt warn_cnt \
		checks_pass=0 checks_exp=3 \
		SE12_JOB=ok1_se12 \
		jobs='ok1_se12'

	local \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$" \
		ERR_FILE="/tmp/sched.err.${TEST_ID:?}.$$"

	rm -f "${MSG_FILE}" "${ERR_FILE}"

	print_test_header "${TEST_ID:?}" "Recursive SCHED_FAIL_MSG_CB is entered once and warns once" "${jobs}"

	SCHED_FAIL_MSG_CB=sched_env_12_fail_msg \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_DISPATCH_TICK_CB=fail_msg_on_dispatch \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" 2>"${ERR_FILE}" &

	sched_pid="${!}"
	start_bg_killer killer_pid "${sched_pid}" 20

	wait "${sched_pid}"
	sched_rv=$?
	stop_bg_killer "${killer_pid}"

	count_msgs msg_cnt "${MSG_FILE}"
	warn_cnt=0
	[ -f "${ERR_FILE}" ] &&
		warn_cnt="$(grep -cF 'Warning: stopping infinite SCHED_FAIL_MSG_CB recursion.' "${ERR_FILE}")"
	rm -f "${MSG_FILE}" "${ERR_FILE}"

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	# The nested message must bypass the callback entirely
	[ "${msg_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_FAIL_MSG_CB invocations=${msg_cnt} (want 1)" >&2
	[ "${warn_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "recursion warnings on stderr=${warn_cnt} (want 1)" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, cb_calls=${msg_cnt}, warnings=${warn_cnt}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, cb_calls=${msg_cnt}, warnings=${warn_cnt}"
		return 1
	fi
}

# Verify SCHED_FAIL_MSG_CB runs in a subshell: a variable it assigns is not visible to
#   the scheduler afterwards, and an exit inside it does not end the run.
test_sched_env_13() {
	sched_env_13_fail_msg() {
		record_fail_msg "${@}"
		SE13_ESCAPED=yes
		exit 7
	}
	sched_env_13_finalize() {
		finalize_handler "${1}" "${2}"
		printf 'escaped=%s\n' "${SE13_ESCAPED-unset}" > "${FIN_FILE:?}"
		return "${1}"
	}

	local \
		TEST_ID=sched_env_13 \
		sched_rv sched_pid killer_pid msg_cnt escaped \
		checks_pass=0 checks_exp=3 \
		jobs='ok1_se13'

	local \
		MSG_FILE="/tmp/sched.msgs.${TEST_ID:?}.$$" \
		FIN_FILE="/tmp/sched.fin.${TEST_ID:?}.$$"

	rm -f "${MSG_FILE}" "${FIN_FILE}"
	unset SE13_ESCAPED

	print_test_header "${TEST_ID:?}" "SCHED_FAIL_MSG_CB side effects stay in its subshell" "${jobs}"

	SCHED_FAIL_MSG_CB=sched_env_13_fail_msg \
	SCHED_FINALIZE_CB=sched_env_13_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_DISPATCH_TICK_CB=fail_msg_on_dispatch \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	sched_pid="${!}"
	start_bg_killer killer_pid "${sched_pid}" 20

	wait "${sched_pid}"
	sched_rv=$?
	stop_bg_killer "${killer_pid}"

	count_msgs msg_cnt "${MSG_FILE}"
	read_first_line escaped "${FIN_FILE}" || escaped='<finalize never ran>'
	rm -f "${MSG_FILE}"

	[ "${msg_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "SCHED_FAIL_MSG_CB invocations=${msg_cnt} (want 1)" >&2
	# An escaping 'exit 7' would end the run before SCHED_FINALIZE_CB
	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "sched_rv=${sched_rv} (want 0)" >&2
	[ "${escaped}" = 'escaped=unset' ] && checks_pass=$((checks_pass + 1)) ||
		echo "finalize saw '${escaped}' (want 'escaped=unset')" >&2

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "sched_rv=${sched_rv}, cb_calls=${msg_cnt}, ${escaped}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, cb_calls=${msg_cnt}, ${escaped}"
		return 1
	fi
}
