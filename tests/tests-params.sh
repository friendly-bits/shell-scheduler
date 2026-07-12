#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# Category: Job Parameters API (job_set_params / job_get_params)
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify that a single param registered via job_set_params()
#   is delivered to DO_JOB_CB with the exact value.
test_params_01() {
	test_params_01_do_job() {
		job_get_params "${1}" FOO
		printf '%s\n' "${FOO-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=1 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.basic.${TEST_NUM}.$$" \
		job_id=params_1_job

	rm -f "${OUT_FILE}"

	print_test_header 1 "Single job param delivered as env var" "${job_id}"

	job_set_params "${job_id}" "FOO=bar123"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_01_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "bar123" ]
	then
		PASS "FOO='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FOO='${seen}', expected 'bar123'"
		return 1
	fi
}

# Verify multiple params registered for the same job are all delivered.
test_params_02() {
	test_params_02_do_job() {
		job_get_params "${1}" PARAM_A PARAM_B PARAM_C
		{
			printf 'A=%s\n' "${PARAM_A-<unset>}"
			printf 'B=%s\n' "${PARAM_B-<unset>}"
			printf 'C=%s\n' "${PARAM_C-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=2 \
		sched_rv \
		expected \
		actual

	local \
		OUT_FILE="/tmp/sched.params.multi.${TEST_NUM}.$$" \
		job_id=params_2_job

	rm -f "${OUT_FILE}"

	print_test_header 2 "Multiple job params delivered" "${job_id}"

	job_set_params "${job_id}" "PARAM_A=1" "PARAM_B=two" "PARAM_C=3three3"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_02_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	expected="$(printf 'A=1\nB=two\nC=3three3')"
	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job_get_params() returns an empty value (rv=0, no error) for a param never
#   registered for the job, and a multi-name request still fetches every requested name,
#   including ones after the unregistered one.
test_params_03() {
	test_params_03_do_job() {
		local rv
		job_get_params "${1}" GOOD1 MISSING GOOD2
		rv=$?
		{
			printf 'rv=%s\n' "${rv}"
			printf 'GOOD1=%s\n' "${GOOD1-<unset>}"
			printf 'MISSING=%s\n' "${MISSING-<unset>}"
			printf 'GOOD2=%s\n' "${GOOD2-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=3 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.unregistered.${TEST_NUM}.$$" \
		job_id=params_3_job

	rm -f "${OUT_FILE}"

	print_test_header 3 "job_get_params() returns empty for an unregistered param, no error" "${job_id}"

	job_set_params "${job_id}" "GOOD1=alpha" "GOOD2=beta"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_03_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	expected="$(printf 'rv=0\nGOOD1=alpha\nMISSING=\nGOOD2=beta')"

	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job_set_params() rejects invalid input at assignment time:
#   bad job ID, pair missing '=', bad/empty/leading-digit param names,
#   and accepts a leading-digit job ID (job IDs need not be valid shell identifiers).
test_params_04() {
	test_params_04_check_rejected() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_params_04_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	test_params_04_check_accepted() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_params_04_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" = 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly rejected: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	test_params_04_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=4 \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt

	local MSG_FILE="/tmp/sched.params.validate.${TEST_NUM}.$$"
	local job_id=params_4_job
	rm -f "${MSG_FILE}"

	print_test_header 4 "job_set_params() input validation" "(direct calls, no scheduler run)"

	test_params_04_check_rejected ""        "FOO=bar"      # empty job ID
	test_params_04_check_rejected "bad id"  "FOO=bar"       # job ID with space
	test_params_04_check_rejected "${job_id}" "novalue"       # pair missing '='
	test_params_04_check_rejected "${job_id}" "=novalue"      # empty param name
	test_params_04_check_rejected "${job_id}" "bad param=x"   # param name with space
	test_params_04_check_rejected "${job_id}" "1bad=x"        # param name starting with digit
	test_params_04_check_accepted "1job"    "FOO=x"         # leading-digit JOB ID is fine
	test_params_04_check_accepted "${job_id}" "GOOD=x"        # sanity: valid case still accepted

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	# The 6 rejected cases above should each produce exactly one message;
	# the 2 accepted cases produce none.
	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = 6 ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 1
	fi
}

# Verify job_set_params() rejects every reserved param name immediately
#   (sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|IFS): rv=1,
#   one specific message emitted per case, and nothing is stored -
#   a later job run never sees the param.
test_params_05() {
	test_params_05_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	test_params_05_do_job() {
		job_get_params "${1}" GOOD
		printf '%s\n' "${GOOD-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=5 \
		name \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		sched_rv \
		seen \
		msg_cnt

	local \
		MSG_FILE="/tmp/sched.params.reserved.msg.${TEST_NUM}.$$" \
		OUT_FILE="/tmp/sched.params.reserved.out.${TEST_NUM}.$$" \
		job_id=params_5_job

	rm -f "${MSG_FILE}" "${OUT_FILE}"

	print_test_header 5 "Reserved param names rejected at job_set_params() time" "${job_id}"

	for name in \
		sch_foo sch_job_id sch_me \
		_sch_foo _sch_job_id _sch_me \
		SCH_JOB_PARAMS_foo SCH_JOB_PARAMS \
		SCHED_ SCHED_MAX_JOBS SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S SCHED_DIR \
		SCHED_FAIL_MSG_CB SCHED_FINALIZE_CB SCHED_DISPATCH_TICK_CB \
		DO_JOB_CB JOB_DONE_CB IFS
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_params_05_fail_msg job_set_params "${job_id}" "${name}=x" 2>/dev/null
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted reserved name: %s\n' "${name}" >&2
		fi
	done

	# One legitimate param too, to confirm the job still runs normally.
	job_set_params "${job_id}" "GOOD=fine"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_05_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")

	rm -f "${MSG_FILE}" "${OUT_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${sched_rv}" = 0 ] &&
		[ "${seen}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, GOOD='${seen}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, sched_rv=${sched_rv}, GOOD='${seen}'"
		return 1
	fi
}

# Verify a job's params don't leak into another job's environment: two jobs registering
#   the same param name with different values must each see only their own value.
test_params_06() {
	test_params_06_do_job() {
		local out
		case "${1}" in
			"${job_id_a}") out="${J1_FILE:?}" ;;
			"${job_id_b}") out="${J2_FILE:?}" ;;
			*) return 1 ;;
		esac
		job_get_params "${1}" SHARED_NAME
		printf '%s\n' "${SHARED_NAME}" > "${out}"
		return 0
	}

	local \
		TEST_NUM=6 \
		sched_rv \
		seen1 \
		seen2

	local \
		J1_FILE="/tmp/sched.params.isolation.j1.${TEST_NUM}.$$" \
		J2_FILE="/tmp/sched.params.isolation.j2.${TEST_NUM}.$$" \
		job_id_a=params_6_job_a \
		job_id_b=params_6_job_b

	rm -f "${J1_FILE}" "${J2_FILE}"

	print_test_header 6 "Params are scoped per job ID" "${job_id_a} ${job_id_b}"

	job_set_params "${job_id_a}" "SHARED_NAME=only_${job_id_a}"
	job_set_params "${job_id_b}" "SHARED_NAME=only_${job_id_b}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_06_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id_a} ${job_id_b}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen1 "${J1_FILE}"
	read_first_line seen2 "${J2_FILE}"
	rm -f "${J1_FILE}" "${J2_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${seen1}" = "only_${job_id_a}" ] &&
		[ "${seen2}" = "only_${job_id_b}" ]
	then
		PASS "${job_id_a}='${seen1}', ${job_id_b}='${seen2}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, ${job_id_a}='${seen1}', ${job_id_b}='${seen2}'"
		return 1
	fi
}

# Verify that registering the same param key twice for a job
#   keeps the last value (last write wins) without error
test_params_07() {
	test_params_07_do_job() {
		job_get_params "${1}" DUPKEY
		printf '%s\n' "${DUPKEY-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=7 \
		sched_rv \
		error_seen \
		seen

	local \
		OUT_FILE="/tmp/sched.params.dup.${TEST_NUM}.$$" \
		job_id=params_7_job

	rm -f "${OUT_FILE}"

	print_test_header 7 "Duplicate param key: last write wins" "${job_id}"

	job_set_params "${job_id}" "DUPKEY=first" "DUPKEY=second" || error_seen=1

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_07_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "second" ] && [ -z "${error_seen}" ]
	then
		PASS "DUPKEY='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, DUPKEY='${seen}', expected 'second', error_seen='${error_seen}'"
		return 1
	fi
}

# Verify pair parsing splits only on the first '=':
#   the value may contain further '=' characters unmodified.
test_params_08() {
	test_params_08_do_job() {
		job_get_params "${1}" URL
		printf '%s\n' "${URL-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=8 \
		sched_rv \
		seen \
		expected='http://x?a=1&b=2'

	local \
		OUT_FILE="/tmp/sched.params.eqsign.${TEST_NUM}.$$" \
		job_id=params_8_job

	rm -f "${OUT_FILE}"

	print_test_header 8 "Value containing embedded '=' preserved intact" "${job_id}"

	job_set_params "${job_id}" "URL=${expected}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_08_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "${expected}" ]
	then
		PASS "URL='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, URL='${seen}', expected '${expected}'"
		return 1
	fi
}

# Verify param values are stored/delivered as opaque data:
#   quotes, $(), backticks, globs, spaces, empty value
#   are preserved and never executed or glob-expanded.
test_params_09() {
	test_params_09_touch_inject() { touch "${INJECT_FILE:?}"; }

	test_params_09_do_job() {
		job_get_params "${1}" SPACEY QUOTY CMDSUB BACKTICK GLOBBY EMPTYV
		{
			printf 'SPACEY=%s\n' "${SPACEY-<unset>}"
			printf 'QUOTY=%s\n' "${QUOTY-<unset>}"
			printf 'CMDSUB=%s\n' "${CMDSUB-<unset>}"
			printf 'BACKTICK=%s\n' "${BACKTICK-<unset>}"
			printf 'GLOBBY=%s\n' "${GLOBBY-<unset>}"
			printf 'EMPTYV=[%s]\n' "${EMPTYV-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=9 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.valfidelity.${TEST_NUM}.$$" \
		INJECT_FILE="/tmp/sched.params.valfidelity.inject.${TEST_NUM}.$$" \
		job_id=params_9_job

	rm -f "${OUT_FILE}" "${INJECT_FILE}"

	print_test_header 9 "Param value fidelity / no injection via value content" "${job_id}"

	# shellcheck disable=SC2016
	job_set_params "${job_id}" \
		'SPACEY=hello world' \
		"QUOTY=a'b\"c" \
		'CMDSUB=$(test_params_09_touch_inject)' \
		'BACKTICK=`test_params_09_touch_inject`' \
		'GLOBBY=*.txt' \
		'EMPTYV='

	# shellcheck disable=SC2016
	expected="SPACEY=hello world"$'\n'"QUOTY=a'b\"c"$'\n'"CMDSUB="'$(test_params_09_touch_inject)'$'\n'"BACKTICK="'`test_params_09_touch_inject`'$'\n'"GLOBBY=*.txt"$'\n'"EMPTYV=[]"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_09_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual}" = "${expected}" ] &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${OUT_FILE}" "${INJECT_FILE}"
		PASS
		return 0
	else
		rm -f "${OUT_FILE}" "${INJECT_FILE}"
		FAIL "sched_rv=${sched_rv}, inject_marker_exists=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		printf '%s\n%s\n%s\n' \
			"expected:" "${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job params and forwarded positional args to DO_JOB_CB coexist without interference.
test_params_10() {
	test_params_10_do_job() {
		job_get_params "${1}" COMBOPARAM
		{
			printf 'PARAM=%s\n' "${COMBOPARAM-<unset>}"
			printf 'ARGS=%s\n' "$*"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=10 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.withargs.${TEST_NUM}.$$" \
		job_id=params_10_job

	rm -f "${OUT_FILE}"

	print_test_header 10 "Job params coexist with forwarded extra args" "${job_id}"

	job_set_params "${job_id}" "COMBOPARAM=paramval"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_10_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" extra1 extra2 &

	wait "$!"
	sched_rv=$?

	expected="$(printf 'PARAM=paramval\nARGS=%s extra1 extra2' "${job_id}")"
	actual="$([ -f "${OUT_FILE}" ] && cat "${OUT_FILE}")"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		printf '%s\n%s\n' "expected: ${expected}" "actual: ${actual}"
		return 1
	fi
}

# Verify job_get_params() runs its own reserved/malformed-name validation on the requested
#   param name, independent of job_set_params()'s validation at registration time.
test_params_11() {
	test_params_11_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=11 \
		name \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM \
		IFS="${IFS}"

	local \
		MSG_FILE="/tmp/sched.params.get_validate.${TEST_NUM}.$$" \
		job_id=params_11_job

	rm -f "${MSG_FILE}"

	print_test_header 11 "job_get_params() rejects reserved/malformed param names" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine" "AAA=1" "BBB=2"

	# "IFS" is deliberately included below: job_get_params() must reject it
	#   before reaching its eval-assignment line.
	# local IFS="${IFS}" guards from IFS corruption leak
	#
	# "AAA BBB" is deliberately built from two registered names
	for name in SCH_FOO sch_foo _sch_foo SCHED_MAX_JOBS DO_JOB_CB JOB_DONE_CB IFS 1bad "bad name" "AAA BBB"
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_params_11_fail_msg job_get_params "${job_id}" "${name}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: %s\n' "${name}" >&2
		fi
	done

	# Legitimate, already-registered param must still work afterward.
	job_get_params "${job_id}" REALPARAM

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${REALPARAM}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, REALPARAM='${REALPARAM}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, REALPARAM='${REALPARAM-<unset>}'"
		return 1
	fi
}

# Verify job_get_params() runs its own job-ID validation,
#   independent of job_set_params()'s job-ID validation at registration time.
test_params_12() {
	test_params_12_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=12 \
		jid \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM

	local \
		MSG_FILE="/tmp/sched.params.get_jobid.${TEST_NUM}.$$" \
		job_id=params_12_job

	rm -f "${MSG_FILE}"

	print_test_header 12 "job_get_params() rejects a bad/empty job ID" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	for jid in "" "bad id"; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=test_params_12_fail_msg job_get_params "${jid}" REALPARAM
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted job ID: %s\n' "${jid}" >&2
		fi
	done

	# Legitimate job ID must still work afterward
	job_get_params "${job_id}" REALPARAM

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${REALPARAM}" = "fine" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, REALPARAM='${REALPARAM}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, REALPARAM='${REALPARAM-<unset>}'"
		return 1
	fi
}

# Verify job_get_params() rejects a call with a valid job ID but zero requested param names,
#   and that this failure is reported with its own distinct message
#   (not conflated with the bad-job-ID message)
test_params_13() {
	test_params_13_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=13 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.get_empty.${TEST_NUM}.$$" \
		job_id=params_13_job

	rm -f "${MSG_FILE}"

	print_test_header 13 "job_get_params() rejects zero requested param names" "(direct call, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	SCHED_FAIL_MSG_CB=test_params_13_fail_msg job_get_params "${job_id}"
	rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"no params specified"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${rv}" != 0 ] && [ "${msg_cnt}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "rv=${rv}, msg='${msg}'"
		return 0
	else
		FAIL "rv=${rv}, msg_cnt=${msg_cnt}, msg='${msg}'"
		return 1
	fi
}

# Verify job_set_params() rejects a call with a valid job ID but zero key=value pairs -
#   symmetric with equivalent guard above (test_params_13).
test_params_14() {
	test_params_14_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_NUM=14 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.set_empty.${TEST_NUM}.$$" \
		job_id=params_14_job

	rm -f "${MSG_FILE}"

	print_test_header 14 "job_set_params() rejects zero key=value pairs" "(direct call, no scheduler run)"

	SCHED_FAIL_MSG_CB=test_params_14_fail_msg job_set_params "${job_id}"
	rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	msg="$([ -f "${MSG_FILE}" ] && cat "${MSG_FILE}")"
	rm -f "${MSG_FILE}"

	case "${msg}" in
		*"no params specified"*) msg_ok=1 ;;
		*) msg_ok= ;;
	esac

	if [ "${rv}" != 0 ] && [ "${msg_cnt}" = 1 ] && [ -n "${msg_ok}" ]
	then
		PASS "rv=${rv}, msg='${msg}'"
		return 0
	else
		FAIL "rv=${rv}, msg_cnt=${msg_cnt}, msg='${msg}'"
		return 1
	fi
}

# Verify job_get_params() always reflects the current registered value,
#   not something cached at an earlier point -
#   re-fetching after a later job_set_params() update picks up the new value.
test_params_15() {
	local \
		TEST_NUM=15 \
		first \
		second \
		REFETCH \
		job_id=params_15_job

	print_test_header 15 "job_get_params() reflects updates from a later job_set_params() call" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REFETCH=one"
	job_get_params "${job_id}" REFETCH
	first="${REFETCH}"

	job_set_params "${job_id}" "REFETCH=two"
	unset REFETCH
	job_get_params "${job_id}" REFETCH
	second="${REFETCH}"

	if [ "${first}" = "one" ] && [ "${second}" = "two" ]
	then
		PASS "first='${first}', second='${second}'"
		return 0
	else
		FAIL "first='${first}', expected 'one', second='${second}', expected 'two'"
		return 1
	fi
}

# Verify job_get_params() works when called from JOB_DONE_CB,
#   which runs in the main scheduler process (not the forked per-job subshell that runs
#   DO_JOB_CB) - confirming params are available in every callback, not just DO_JOB_CB.
test_params_16() {
	test_params_16_do_job() { return 0; }

	test_params_16_done() {
		job_get_params "${1}" FROMDONE
		printf '%s\n' "${FROMDONE-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_NUM=16 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.job_done_cb.${TEST_NUM}.$$" \
		job_id=params_16_job

	rm -f "${OUT_FILE}"

	print_test_header 16 "job_get_params() is usable from JOB_DONE_CB" "${job_id}"

	job_set_params "${job_id}" "FROMDONE=seen_in_job_done_cb"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=test_params_16_done \
	DO_JOB_CB=test_params_16_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "seen_in_job_done_cb" ]
	then
		PASS "FROMDONE='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FROMDONE='${seen}', expected 'seen_in_job_done_cb'"
		return 1
	fi
}

# Verify job_get_params() is usable directly in the caller's own top-level scope,
#   not only from within a scheduler callback -
#   confirming params are available in the user's application scope
test_params_17() {
	test_params_17_do_job() { return 0; }

	local \
		TEST_NUM=17 \
		sched_rv \
		seen \
		FROMSCOPE \
		job_id=params_17_job

	print_test_header 17 "job_get_params() is usable directly in the caller's own scope" "${job_id}"

	job_set_params "${job_id}" "FROMSCOPE=seen_in_caller_scope"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_17_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	# FROMSCOPE is declared local above so this direct (main-process) call
	# doesn't leak it into the global scope.
	unset FROMSCOPE
	job_get_params "${job_id}" FROMSCOPE
	seen="${FROMSCOPE-<unset>}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = "seen_in_caller_scope" ]
	then
		PASS "FROMSCOPE='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, FROMSCOPE='${seen}', expected 'seen_in_caller_scope'"
		return 1
	fi
}

# Verify that job_get_params() "sch_all" mode is a no-op success (rv=0, no params assigned)
#   when the job has never had any params registered
test_params_18() {
	local \
		TEST_NUM=18 \
		rv \
		job_id=params_18_job_noparams

	print_test_header 18 \
		"job_get_params() 'sch_all' on a job with zero registered params is a no-op success" \
		"(direct call, no scheduler run)"

	job_get_params "${job_id}" sch_all
	rv=$?

	if [ "${rv}" = 0 ]
	then
		PASS "rv=${rv}"
		return 0
	else
		FAIL "rv=${rv}, expected 0"
		return 1
	fi
}

# Verify job_get_params() "sch_all" mode returns the complete, correct set of registered params,
#   matching an explicit multi-param fetch of the same job.
# Also verifies "sch_all" mode's internal word-splitting of the registered-params list
#   does not leak or lose the caller's noglob state.
test_params_19() {
	local \
		TEST_NUM=19 \
		job_id=params_19_job \
		P1 P2 P3 \
		explicit_ok=0 \
		all_ok=0 \
		noglob_ok=1

	print_test_header 19 "job_get_params() 'all' mode returns the full registered set" \
		"(direct calls, no scheduler run)"

	job_set_params "${job_id}" "P1=one" "P2=two" "P3=three"

	job_get_params "${job_id}" P1 P2 P3
	[ "${P1}" = one ] && [ "${P2}" = two ] && [ "${P3}" = three ] &&
		explicit_ok=1

	unset P1 P2 P3
	job_get_params "${job_id}" sch_all
	[ "${P1}" = one ] && [ "${P2}" = two ] && [ "${P3}" = three ] &&
		all_ok=1

	# Noglob preservation around "sch_all" mode's internal set -f handling:
	# caller's set -f/+f state must survive the call unchanged either way.
	set +f
	job_get_params "${job_id}" sch_all >/dev/null
	case "${-}" in *f*) noglob_ok=0 ;; esac

	set -f
	job_get_params "${job_id}" sch_all >/dev/null
	case "${-}" in *f*) ;; *) noglob_ok=0 ;; esac
	set +f

	if [ "${explicit_ok}" = 1 ] && [ "${all_ok}" = 1 ] && [ "${noglob_ok}" = 1 ]
	then
		PASS "P1='${P1}', P2='${P2}', P3='${P3}'"
		return 0
	else
		FAIL "explicit_ok=${explicit_ok}, all_ok=${all_ok}, noglob_ok=${noglob_ok}, P1='${P1}', P2='${P2}', P3='${P3}'"
		return 1
	fi
}

# Verify that job_get_params() with the "-export" flag exports into the process environment,
#   while the default (no "-export") mode only assigns in the caller's own shell scope.
test_params_20() {
	local \
		TEST_NUM=20 \
		job_id=params_20_job \
		EXPORTPARAM \
		default_exported \
		flag_exported

	print_test_header 20 "job_get_params() '-export' flag exports to the real environment" \
		"(direct calls, no scheduler run)"

	job_set_params "${job_id}" "EXPORTPARAM=exported_val"

	unset EXPORTPARAM
	job_get_params "${job_id}" EXPORTPARAM
	default_exported="$(sh -c 'printf "%s" "${EXPORTPARAM-<unset>}"')"

	unset EXPORTPARAM
	job_get_params -export "${job_id}" EXPORTPARAM
	flag_exported="$(sh -c 'printf "%s" "${EXPORTPARAM-<unset>}"')"

	if [ "${default_exported}" = '<unset>' ] &&
		[ "${flag_exported}" = exported_val ]
	then
		PASS "default='${default_exported}', -export='${flag_exported}'"
		return 0
	else
		FAIL "default='${default_exported}', expected '<unset>'; -export='${flag_exported}', expected 'exported_val'"
		return 1
	fi
}

# Verify with SCHED_AUTO_PARAMS=1:
# - DO_JOB_CB sees its own job's registered params without job_get_params() call
# - jobs with different params stay isolated from each other
# - job_get_params() "all" doesn't 'exit 1' on empty params set
test_params_21() {
	test_params_21_do_job() {
		case "${1}" in
			withparam1)
				[ "${MYPARAM-}" = aaa ] && printf 'ok\n' > "${WP1_FILE:?}"
			;;
			withparam2)
				[ "${MYPARAM-}" = bbb ] && printf 'ok\n' > "${WP2_FILE:?}"
			;;
			noparam)
				printf 'started\n' > "${NOPARAM_STARTED_FILE:?}"
				[ -z "${MYPARAM-}" ] && printf 'ok\n' > "${NOPARAM_FILE:?}"
			;;
		esac

		return 0
	}

	local \
		TEST_NUM=21 \
		sched_rv \
		jobs='withparam1 withparam2 noparam'

	local \
		WP1_FILE="/tmp/sched.autoparams.wp1.${TEST_NUM}.$$" \
		WP2_FILE="/tmp/sched.autoparams.wp2.${TEST_NUM}.$$" \
		NOPARAM_FILE="/tmp/sched.autoparams.noparam.${TEST_NUM}.$$" \
		NOPARAM_STARTED_FILE="/tmp/sched.autoparams.noparam_started.${TEST_NUM}.$$"

	rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"

	print_test_header 21 "SCHED_AUTO_PARAMS=1: auto-export, per-job isolation, and jobs with no params" "${jobs}"

	# "noparam" deliberately has no job_set_params() call at all.
	job_set_params withparam1 "MYPARAM=aaa"
	job_set_params withparam2 "MYPARAM=bbb"

	SCHED_AUTO_PARAMS=1 \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=test_params_21_do_job \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	if [ "${sched_rv}" = 0 ] &&
		[ -f "${WP1_FILE}" ] &&
		[ -f "${WP2_FILE}" ] &&
		[ -f "${NOPARAM_STARTED_FILE}" ] &&
		[ -f "${NOPARAM_FILE}" ]
	then
		rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, wp1=$([ -f "${WP1_FILE}" ] && echo ok || echo missing), wp2=$([ -f "${WP2_FILE}" ] && echo ok || echo missing), noparam_started=$([ -f "${NOPARAM_STARTED_FILE}" ] && echo ok || echo missing), noparam=$([ -f "${NOPARAM_FILE}" ] && echo ok || echo missing)"
		rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"
		return 1
	fi
}

