#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-config_mini.sh

# Category: config, mini-variant only.
#   The mini variant always auto-delivers registered params and ignores
#   SCHED_AUTO_PARAMS entirely. This mirrors tests-config_full.sh, which
#   verifies the full variant's gated behavior.

# This file is sourced by tests.sh; it defines test_config_mini_NN functions only.

# Verify the mini variant auto-delivers registered params regardless of
#   SCHED_AUTO_PARAMS: when unset and for values other than '1' (which the full
#   variant treats as "off"), the param must still arrive as an exported var.
test_config_mini_01() {
	require_variant mini || return 2

	config_mini_01_do_job() {
		if [ -n "${cfgm_param+x}" ]
		then
			printf 'set:%s\n' "${cfgm_param}" >> "${AP_RESULT_FILE:?}"
		else
			printf 'unset\n' >> "${AP_RESULT_FILE:?}"
		fi
	}

	# Run one scheduler pass; append its rv to a counter on success.
	# 1: SCHED_AUTO_PARAMS value, or the literal '__UNSET__' to leave it unset
	run_one() {
		local sched_rv
		if [ "${1}" = __UNSET__ ]; then
			SCHED_FAIL_MSG_CB=echo \
			SCHED_FINALIZE_CB=finalize_handler \
			JOB_DONE_CB=done_handler \
			DO_JOB_CB=config_mini_01_do_job \
			SCHED_MAX_JOBS=1 \
			SCHED_TIMEOUT_S=3 \
			SCHED_IDLE_TIMEOUT_S=2 \
				schedule_jobs "${job_id}" &
		else
			SCHED_FAIL_MSG_CB=echo \
			SCHED_FINALIZE_CB=finalize_handler \
			JOB_DONE_CB=done_handler \
			DO_JOB_CB=config_mini_01_do_job \
			SCHED_MAX_JOBS=1 \
			SCHED_TIMEOUT_S=3 \
			SCHED_IDLE_TIMEOUT_S=2 \
			SCHED_AUTO_PARAMS="${1}" \
				schedule_jobs "${job_id}" &
		fi
		wait "$!"
		sched_rv=$?
		[ "${sched_rv}" = 0 ] && rv_pass_cnt=$((rv_pass_cnt + 1))
	}

	local \
		TEST_ID=config_mini_01 \
		ap_val \
		set_cnt=0 \
		line_cnt=0 \
		rv_pass_cnt=0 \
		total_cnt=0 \
		job_id='cfg_mini_01_job'

	local AP_RESULT_FILE="/tmp/sched.autoparams.on.${TEST_ID:?}.$$"
	rm -f "${AP_RESULT_FILE}"

	print_test_header "${TEST_ID:?}" "mini: registered params auto-delivered regardless of SCHED_AUTO_PARAMS" "${job_id}"

	job_set_params "${job_id}" cfgm_param=hello ||
		{ FAIL "job_set_params failed"; return 1; }

	for ap_val in __UNSET__ 0 01 true; do
		total_cnt=$((total_cnt + 1))
		run_one "${ap_val}"
	done

	if [ -f "${AP_RESULT_FILE}" ]; then
		line_cnt=$(wc -l < "${AP_RESULT_FILE}")
		set_cnt=$(grep -c '^set:hello$' "${AP_RESULT_FILE}")
	fi
	rm -f "${AP_RESULT_FILE}"

	if [ "${rv_pass_cnt}" = "${total_cnt}" ] &&
		[ "${line_cnt}" = "${total_cnt}" ] &&
		[ "${set_cnt}" = "${total_cnt}" ]
	then
		PASS "runs=${total_cnt}, all params delivered as 'hello'"
		return 0
	else
		FAIL "rv_pass=${rv_pass_cnt}/${total_cnt}, job_runs=${line_cnt}, set:hello=${set_cnt}"
		return 1
	fi
}
