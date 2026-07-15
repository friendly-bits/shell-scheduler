#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-config.sh

# Category: Configuration & Callback Validation
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify a failing SCHED_FINALIZE_CB overrides rv=0 but not an existing scheduler error.
test_config_01() {
	config_01_finalize_handler() {
		local rv="${1}" pids="${2}"

		finalize_handler "${rv}" "${pids}" || return $?

		printf '%s\n' "${rv}" >> "${FINALIZE_RV_FILE}"

		return "${CONFIG_01_FINALIZE_RV:?}"
	}

	local \
		TEST_ID=config_01 \
		rv_success \
		rv_failure \
		recorded_rvs \
		CONFIG_01_FINALIZE_RV=97

	print_test_header "${TEST_ID:?}" "Failure of SCHED_FINALIZE_CB" \
		"success path and error path"

	FINALIZE_RV_FILE="/tmp/sched.finalize.fail.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_RV_FILE}"

	# shellcheck disable=SC2034
	local \
		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=config_01_finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=do_job_default

	# Successful scheduler run: callback RV should become scheduler RV.
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'instant' &

	wait "$!"
	rv_success=$?

	# Scheduler error: callback failure must not overwrite scheduler RV.
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=30 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'hang' &

	wait "$!"
	rv_failure=$?

	recorded_rvs=
	[ -f "${FINALIZE_RV_FILE}" ] &&
		recorded_rvs="$(tr '\n' ' ' < "${FINALIZE_RV_FILE}")"

	rm -f "${FINALIZE_RV_FILE}"

	if [ "${rv_success}" = "${CONFIG_01_FINALIZE_RV}" ] &&
		[ "${rv_failure}" = 81 ] &&
		[ "${recorded_rvs}" = "0 81 " ]
	then
		PASS "success_rv=${rv_success}, failure_rv=${rv_failure}"
		return 0
	else
		FAIL "success_rv=${rv_success}, failure_rv=${rv_failure}, recorded=${recorded_rvs}"
		return 1
	fi
}

# Verify invalid callback configuration is rejected before any jobs start.
test_config_02() {
	config_02_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	config_02_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# shellcheck disable=SC2034
	local \
		TEST_ID=config_02 \
		sched_rv \
		pass_cnt=0 \
		msg_cnt=0 \
		cb bad_cb \
		\
		SCHED_FINALIZE_CB_def=finalize_handler \
		DO_JOB_CB_def=config_02_do_job \
		JOB_DONE_CB_def=done_handler \
		SCHED_FAIL_MSG_CB_def=config_02_fail_msg_handler

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
test_config_03() {
	config_03_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	config_03_do_job() {
		printf 'started\n' > "${JOB_STARTED_FILE:?}"
		return 0
	}

	# SCHED_MAX_JOBS is required (sch_normalize_uint's 3rd arg); SCHED_TIMEOUT_S,
	# SCHED_IDLE_TIMEOUT_S and SCHED_JOB_TIMEOUT_S are optional, so '' is a
	# *valid* value for them (means "use default" / "unset") and must not be
	# included as a bad value.
	config_03_check_bad_value() {
		# shellcheck disable=SC2034
		local var="${1}" bad_val="${2}" sched_rv \
			SCHED_MAX_JOBS=1 \
			SCHED_TIMEOUT_S=3 \
			SCHED_IDLE_TIMEOUT_S=2

		local "${var}=${bad_val}"

		SCHED_FAIL_MSG_CB=config_03_fail_msg_handler \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=config_03_do_job \
			schedule_jobs '1' &

		wait "$!"
		sched_rv=$?

		total_cnt=$((total_cnt + 1))

		[ "${sched_rv}" = 1 ] &&
		[ ! -f "${JOB_STARTED_FILE}" ] &&
			pass_cnt=$((pass_cnt + 1))

		rm -f "${JOB_STARTED_FILE}"
	}

	local \
		TEST_ID=config_03 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		var bad_val

	local \
		FAIL_MSG_FILE="/tmp/sched.maxjobs.msg.${TEST_ID:?}.$$" \
		JOB_STARTED_FILE="/tmp/sched.maxjobs.job.${TEST_ID:?}.$$"

	rm -f "${FAIL_MSG_FILE}" "${JOB_STARTED_FILE}"

	print_test_header "${TEST_ID:?}" "Invalid scheduler numeric env var values" \
		"SCHED_MAX_JOBS('' abc 0 -1), SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S/SCHED_JOB_TIMEOUT_S(abc 0 -1)"

	for bad_val in '' abc 0 -1; do
		config_03_check_bad_value SCHED_MAX_JOBS "${bad_val}"
	done

	for var in SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S SCHED_JOB_TIMEOUT_S; do
		for bad_val in abc 0 -1; do
			config_03_check_bad_value "${var}" "${bad_val}"
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
test_config_04() {
	JOB_DONE_CB='' \
	SCHED_FINALIZE_CB=finalize_handler \
	TEST_ID=config_04 \
	TEST_NAME='Empty JOB_DONE_CB' \
	TEST_JOBS='instant_1 instant_2 instant_3' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=2 \
		run_generic_test
}

# Verify SCHED_FINALIZE_CB may be empty and the scheduler still completes normally
#   (test_config_04).
test_config_05() {
	SCHED_FINALIZE_CB='' \
	JOB_DONE_CB=done_handler \
	TEST_ID=config_05 \
	TEST_NAME='Empty SCHED_FINALIZE_CB' \
	TEST_JOBS='instant_1 instant_2 instant_3 instant_4 instant_5' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
		run_generic_test
}

# Verify SCHED_TIMEOUT_S/SCHED_IDLE_TIMEOUT_S may be left unset, falling back to defaults
#   (test_config_07).
test_config_06() {
	local \
		TEST_ID=config_06 \
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
test_config_07() {
	local \
		TEST_ID=config_07 \
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

# Verify SCHED_DIR: a custom directory (with a trailing slash) is used for the FIFO and cleaned up afterward,
#   and a directory that normalizes to empty is rejected before any job starts.
test_config_08() {
	local \
		TEST_ID=config_08 \
		sched_rv \
		bad_rv \
		scheduler_pid \
		sched_fifo \
		fifo_in_dir=no \
		custom_dir \
		jobs='ok2'

	custom_dir="/tmp/sched.customdir.${TEST_ID}.$$"
	rm -rf "${custom_dir}"

	print_test_header "${TEST_ID:?}" "SCHED_DIR: custom dir used and cleaned up; empty-normalized dir rejected" "${jobs}"

	# Sub-check 1: custom SCHED_DIR with a trailing slash.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
	SCHED_DIR="${custom_dir}/" \
		schedule_jobs "${jobs}" &

	scheduler_pid=$!
	sched_fifo="${custom_dir}/sched_ipc_${scheduler_pid}"

	# Observe the FIFO exists in the custom dir while the job runs.
	sleep 1
	[ -p "${sched_fifo}" ] && fifo_in_dir=yes

	wait "${scheduler_pid}"
	sched_rv=$?

	# Sub-check 2: SCHED_DIR='///' -> empty after trailing-slash strip -> rejected.
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	SCHED_DIR='///' \
		schedule_jobs 'ok_1' &
	wait "$!"
	bad_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		[ "${fifo_in_dir}" = yes ] &&
		[ ! -e "${sched_fifo}" ] &&
		[ "${bad_rv}" = 1 ]
	then
		rm -rf "${custom_dir}"
		PASS "fifo_in_dir=${fifo_in_dir}, sched_rv=${sched_rv}, bad_rv=${bad_rv}"
		return 0
	else
		rm -rf "${custom_dir}"
		FAIL "sched_rv=${sched_rv}, fifo_in_dir=${fifo_in_dir}, fifo_left=$([ -e "${sched_fifo}" ] && echo yes || echo no), bad_rv=${bad_rv}"
		return 1
	fi
}

# Verify sch_normalize_uint(): accepts non-zero uints, stripping leading zeros
#   (which would otherwise trigger octal interpretation in $(( )) arithmetic);
#   rejects and clears the out var for anything else.
#   Direct calls, no scheduler run.
test_config_09() {
	config_09_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	# 1: in value
	# 2: required flag ('' or 'required')
	# 3: expected rv
	# 4: expected out var value
	config_09_check() {
		# out var preset to a sentinel: the helper must always overwrite it
		local rv SCH_C09_OUT=preset

		# stderr silenced: the out-of-range input makes the test builtin
		# print a diagnostic on some shells
		SCHED_FAIL_MSG_CB=config_09_fail_msg \
			sch_normalize_uint SCH_C09_OUT "${1}" ${2} 2>/dev/null
		rv=$?

		total_cnt=$((total_cnt + 1))
		if [ "${rv}" = "${3}" ] && [ "${SCH_C09_OUT}" = "${4}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf "Unexpected result for input '%s'%s: rv=%s, out='%s' (expected rv=%s, out='%s')\n" \
				"${1}" "${2:+" (required)"}" "${rv}" "${SCH_C09_OUT}" "${3}" "${4}" >&2
		fi
	}

	local \
		TEST_ID=config_09 \
		bad_val \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0 \
		expected_msg_cnt

	local MSG_FILE="/tmp/sched.normuint.msg.${TEST_ID:?}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "sch_normalize_uint(): decimal normalization and rejection" "(direct calls, no scheduler run)"

	# Valid inputs: rv 0, decimal-normalized value assigned
	config_09_check 1      ''       0 1
	config_09_check 900    ''       0 900
	config_09_check 010    ''       0 10
	config_09_check 09     ''       0 9
	config_09_check 000700 ''       0 700
	config_09_check 010    required 0 10

	# Empty input: valid (assigns empty) unless required
	config_09_check ''     ''       0 ''
	config_09_check ''     required 1 ''

	# Invalid inputs: rv 1, out var cleared, one message each
	for bad_val in abc 9x +1 -1 1.5 '1 2' 0 00 99999999999999999999; do
		config_09_check "${bad_val}" '' 1 ''
	done

	# 1 message for empty-required + 1 per invalid input
	expected_msg_cnt=10

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

# Regression: leading-zero numeric env values are treated as decimal, not octal.
#   Before normalization was added, SCHED_IDLE_TIMEOUT_S=09 killed the scheduler
#   with a fatal 'arithmetic syntax error' (09 is invalid octal) on the first
#   remaining-time computation, and 010 silently meant 8 seconds.
test_config_10() {
	local \
		TEST_ID=config_10 \
		sched_rv \
		jobs='instant_c10a instant_c10b instant_c10c'

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

# Verify SCHED_AUTO_PARAMS activates only on the exact string '1':
#   other values (including '01', which a numeric comparison would accept)
#   must leave registered params undelivered, with the scheduler running normally.
test_config_11() {
	config_11_do_job() {
		if [ -n "${cfg11_param+x}" ]
		then
			printf 'set:%s\n' "${cfg11_param}" >> "${AP_RESULT_FILE:?}"
		else
			printf 'unset\n' >> "${AP_RESULT_FILE:?}"
		fi
	}

	local \
		TEST_ID=config_11 \
		ap_val \
		sched_rv \
		unset_cnt=0 \
		line_cnt=0 \
		rv_pass_cnt=0 \
		total_cnt=0 \
		job_id='cfg11_job'

	local AP_RESULT_FILE="/tmp/sched.autoparams.off.${TEST_ID:?}.$$"
	rm -f "${AP_RESULT_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_AUTO_PARAMS values other than '1' disable param auto-delivery" "${job_id}"

	job_set_params "${job_id}" cfg11_param=hello ||
		{ FAIL "job_set_params failed"; return 1; }

	for ap_val in 0 01 true; do
		total_cnt=$((total_cnt + 1))

		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=config_11_do_job \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
		SCHED_AUTO_PARAMS="${ap_val}" \
			schedule_jobs "${job_id}" &

		wait "$!"
		sched_rv=$?

		[ "${sched_rv}" = 0 ] && rv_pass_cnt=$((rv_pass_cnt + 1))
	done

	if [ -f "${AP_RESULT_FILE}" ]; then
		line_cnt=$(wc -l < "${AP_RESULT_FILE}")
		unset_cnt=$(grep -c '^unset$' "${AP_RESULT_FILE}")
	fi
	rm -f "${AP_RESULT_FILE}"

	if [ "${rv_pass_cnt}" = "${total_cnt}" ] &&
		[ "${line_cnt}" = "${total_cnt}" ] &&
		[ "${unset_cnt}" = "${total_cnt}" ]
	then
		PASS "runs=${total_cnt}, all params undelivered"
		return 0
	else
		FAIL "rv_pass=${rv_pass_cnt}/${total_cnt}, job_runs=${line_cnt}, unset=${unset_cnt}"
		return 1
	fi
}
