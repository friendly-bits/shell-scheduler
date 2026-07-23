#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-config_full.sh

# Category: config, full-variant only.
#   Behavior that exists only in scheduler.sh (not scheduler-mini.sh),
#   where SCHED_AUTO_PARAMS gates auto-delivery. In the mini variant params
#   are always auto-delivered; the mirror assertions live in tests-config_mini.sh.

# This file is sourced by tests.sh; it defines test_config_full_NN functions only.

# Verify SCHED_AUTO_PARAMS activates only on the exact string '1':
#   other values (including '01', which a numeric comparison would accept)
#   must leave registered params undelivered, with the scheduler running normally.
test_config_full_01() {
	require_variant full || return 2

	config_full_01_do_job() {
		if [ -n "${cfg10_param+x}" ]
		then
			printf 'set:%s\n' "${cfg10_param}" >> "${AP_RESULT_FILE:?}"
		else
			printf 'unset\n' >> "${AP_RESULT_FILE:?}"
		fi
	}

	local \
		TEST_ID=config_full_01 \
		ap_val \
		sched_rv \
		unset_cnt=0 \
		line_cnt=0 \
		rv_pass_cnt=0 \
		total_cnt=0 \
		job_id='cfg_full_01_job'

	local AP_RESULT_FILE="/tmp/sched.autoparams.off.${TEST_ID:?}.$$"
	rm -f "${AP_RESULT_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_AUTO_PARAMS values other than '1' disable param auto-delivery" "${job_id}"

	job_set_params "${job_id}" cfg10_param=hello ||
		{ FAIL "job_set_params failed"; return 1; }

	for ap_val in 0 01 true; do
		total_cnt=$((total_cnt + 1))

		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=config_full_01_do_job \
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
