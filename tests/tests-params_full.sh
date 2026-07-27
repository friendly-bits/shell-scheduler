#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-params_full.sh

# Category: params, full-variant only.
#   Param delivery rules that exist only in scheduler.sh (not scheduler-mini.sh),
#   where SCHED_AUTO_PARAMS gates auto-delivery. The mini variant always delivers;
#   the mirror assertions live in tests-params_mini.sh.

# This file is sourced by tests.sh; it defines test_params_full_NN functions only.

# Verify SCHED_AUTO_PARAMS activates only on the exact string '1':
#   unset and other values (including '01', which a numeric comparison would accept)
#   must leave registered params undelivered to both callbacks,
#   with the scheduler running normally.
test_params_full_01() {
	local \
		TEST_ID=params_full_01 \
		job_id='params_full_01_job' \
		AP_PARAM_VAR=apf_param

	# apf_param is deliberately not declared here: a 'local' would make it set
	local \
		AP_JOB_FILE="/tmp/sched.autoparams.off.job.${TEST_ID:?}.$$" \
		AP_DONE_FILE="/tmp/sched.autoparams.off.done.${TEST_ID:?}.$$"

	print_test_header "${TEST_ID:?}" "SCHED_AUTO_PARAMS values other than '1' disable param auto-delivery" "${job_id}"

	require_variant full || return 2

	job_set_params "${job_id}" "${AP_PARAM_VAR}=hello" ||
		{ FAIL "job_set_params failed"; return 1; }

	ap_run_variants "${job_id}" unset '__UNSET__ 0 01 true'
}
