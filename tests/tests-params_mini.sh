#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-params_mini.sh

# Category: params, mini-variant only.
#   The mini variant always auto-delivers registered params and ignores
#   SCHED_AUTO_PARAMS entirely. This mirrors tests-params_full.sh, which
#   verifies the full variant's gated behavior.

# This file is sourced by tests.sh; it defines test_params_mini_NN functions only.

# Verify the mini variant auto-delivers registered params to both the job and the
#   completion callback regardless of SCHED_AUTO_PARAMS: when unset and for values
#   other than '1' (which the full variant treats as "off"), the param must still
#   arrive as an exported var.
test_params_mini_01() {
	local \
		TEST_ID=params_mini_01 \
		job_id='params_mini_01_job' \
		AP_PARAM_VAR=apm_param

	# apm_param is deliberately not declared here: a 'local' would make it set
	local \
		AP_JOB_FILE="/tmp/sched.autoparams.on.job.${TEST_ID:?}.$$" \
		AP_DONE_FILE="/tmp/sched.autoparams.on.done.${TEST_ID:?}.$$"

	print_test_header "${TEST_ID:?}" "mini: registered params auto-delivered to both callbacks regardless of SCHED_AUTO_PARAMS" "${job_id}"

	require_variant mini || return 2

	job_set_params "${job_id}" "${AP_PARAM_VAR}=hello" ||
		{ FAIL "job_set_params failed"; return 1; }

	ap_run_variants "${job_id}" set:hello '__UNSET__ 0 01 true'
}
