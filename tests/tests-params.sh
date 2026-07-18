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
	params_01_do_job() {
		job_get_params "${1}" FOO
		printf '%s\n' "${FOO-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_01 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.basic.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Single job param delivered as env var" "${job_id}"

	job_set_params "${job_id}" "FOO=bar123"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_01_do_job \
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
	params_02_do_job() {
		job_get_params "${1}" PARAM_A PARAM_B PARAM_C
		{
			printf 'A=%s\n' "${PARAM_A-<unset>}"
			printf 'B=%s\n' "${PARAM_B-<unset>}"
			printf 'C=%s\n' "${PARAM_C-<unset>}"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_02 \
		sched_rv \
		expected \
		actual

	local \
		OUT_FILE="/tmp/sched.params.multi.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Multiple job params delivered" "${job_id}"

	job_set_params "${job_id}" "PARAM_A=1" "PARAM_B=two" "PARAM_C=3three3"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_02_do_job \
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
	params_03_do_job() {
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
		TEST_ID=params_03 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.unregistered.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() returns empty for an unregistered param, no error" "${job_id}"

	job_set_params "${job_id}" "GOOD1=alpha" "GOOD2=beta"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_03_do_job \
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
#   bad job ID, pair missing '=', bad/empty param names, and accepts a
#   leading-digit job ID and a leading-digit param name (neither need be a
#   valid shell identifier).
test_params_04() {
	params_04_check_rejected() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_04_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	params_04_check_accepted() {
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_04_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" = 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly rejected: job_id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	params_04_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_04 \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt

	local MSG_FILE="/tmp/sched.params.validate.${TEST_ID}.$$"
	local job_id="${TEST_ID}_job"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_set_params() input validation" "(direct calls, no scheduler run)"

	params_04_check_rejected ""          "FOO=bar"       # empty job ID
	params_04_check_rejected "bad id"    "FOO=bar"       # job ID with space
	params_04_check_rejected "${job_id}" "novalue"       # pair missing '='
	params_04_check_rejected "${job_id}" "=novalue"      # empty param name
	params_04_check_rejected "${job_id}" "bad param=x"   # param name with space
	params_04_check_accepted "${job_id}" "1bad=x"        # leading-digit param name is fine
	params_04_check_accepted "1job"      "FOO=x"         # leading-digit JOB ID is fine
	params_04_check_accepted "${job_id}" "GOOD=x"        # sanity: valid case still accepted

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	# The 5 rejected cases above should each produce exactly one message;
	# the 3 accepted cases produce none.
	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = 5 ]
	then
		PASS "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt}, messages=${msg_cnt}"
		return 1
	fi
}

# Verify job_set_params() accepts reserved-looking param names:
#   they are namespaced (SCH_JOB_PARAM_<idlen>_<id>_<name>) data keys which may or may not become var names
# Verify real internal state (IFS, SCHED_* env) is untouched.
# Verify each value is retrievable via a safe alias, while a direct fetch into the reserved name is rejected.
test_params_05() {
	params_05_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_05 \
		name \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt \
		direct_rv \
		saved_ifs \
		saved_max \
		GOT \
		IFS="${IFS}"

	local \
		MSG_FILE="/tmp/sched.params.reserved.msg.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Reserved-looking param names accepted at job_set_params() time" "(direct calls, no scheduler run)"

	saved_ifs="${IFS}"
	saved_max="${SCHED_MAX_JOBS-<unset>}"

	for name in \
		sch_foo sch_job_id sch_me \
		_sch_foo _sch_job_id _sch_me \
		SCH_JOB_PARAMS_foo SCH_JOB_PARAMS \
		SCHED_ SCHED_MAX_JOBS SCHED_TIMEOUT_S SCHED_IDLE_TIMEOUT_S SCHED_DIR \
		SCHED_FAIL_MSG_CB SCHED_FINALIZE_CB SCHED_DISPATCH_TICK_CB \
		DO_JOB_CB JOB_DONE_CB IFS
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_05_fail_msg job_set_params "${job_id}" "${name}=val_${name}"
		rv=$?
		if [ "${rv}" = 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly rejected reserved name: %s\n' "${name}" >&2
		fi
	done

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	# One reserved key is retrievable via a safe alias; a direct fetch into the
	#   reserved name is rejected before assignment.
	unset GOT
	job_get_params "${job_id}" GOT=IFS
	SCHED_FAIL_MSG_CB=: job_get_params "${job_id}" IFS 2>/dev/null
	direct_rv=$?

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = 0 ] &&
		[ "${GOT-<unset>}" = val_IFS ] &&
		[ "${direct_rv}" != 0 ] &&
		[ "${IFS}" = "${saved_ifs}" ] &&
		[ "${SCHED_MAX_JOBS-<unset>}" = "${saved_max}" ]
	then
		PASS "${pass_cnt}/${total_cnt} accepted, GOT='${GOT}'"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} accepted, msg_cnt=${msg_cnt}, GOT='${GOT-<unset>}', direct_rv=${direct_rv}, ifs_intact=$([ "${IFS}" = "${saved_ifs}" ] && echo yes || echo no)"
		return 1
	fi
}

# Verify a job's params don't leak into another job's environment: two jobs registering
#   the same param name with different values must each see only their own value.
test_params_06() {
	params_06_do_job() {
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
		TEST_ID=params_06 \
		sched_rv \
		seen1 \
		seen2

	local \
		J1_FILE="/tmp/sched.params.isolation.j1.${TEST_ID}.$$" \
		J2_FILE="/tmp/sched.params.isolation.j2.${TEST_ID}.$$" \
		job_id_a="${TEST_ID}_job_a" \
		job_id_b="${TEST_ID}_job_b"

	rm -f "${J1_FILE}" "${J2_FILE}"

	print_test_header "${TEST_ID:?}" "Params are scoped per job ID" "${job_id_a} ${job_id_b}"

	job_set_params "${job_id_a}" "SHARED_NAME=only_${job_id_a}"
	job_set_params "${job_id_b}" "SHARED_NAME=only_${job_id_b}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_06_do_job \
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
	params_07_do_job() {
		job_get_params "${1}" DUPKEY
		printf '%s\n' "${DUPKEY-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_07 \
		sched_rv \
		error_seen \
		seen

	local \
		OUT_FILE="/tmp/sched.params.dup.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Duplicate param key: last write wins" "${job_id}"

	job_set_params "${job_id}" "DUPKEY=first" "DUPKEY=second" || error_seen=1

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_07_do_job \
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
	params_08_do_job() {
		job_get_params "${1}" URL
		printf '%s\n' "${URL-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_08 \
		sched_rv \
		seen \
		expected='http://x?a=1&b=2'

	local \
		OUT_FILE="/tmp/sched.params.eqsign.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Value containing embedded '=' preserved intact" "${job_id}"

	job_set_params "${job_id}" "URL=${expected}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_08_do_job \
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
	params_09_touch_inject() { touch "${INJECT_FILE:?}"; }

	params_09_do_job() {
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
		TEST_ID=params_09 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.valfidelity.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.params.valfidelity.inject.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Param value fidelity / no injection via value content" "${job_id}"

	# shellcheck disable=SC2016
	job_set_params "${job_id}" \
		'SPACEY=hello world' \
		"QUOTY=a'b\"c" \
		'CMDSUB=$(params_09_touch_inject)' \
		'BACKTICK=`params_09_touch_inject`' \
		'GLOBBY=*.txt' \
		'EMPTYV='

	# shellcheck disable=SC2016
	expected="SPACEY=hello world"$'\n'"QUOTY=a'b\"c"$'\n'"CMDSUB="'$(params_09_touch_inject)'$'\n'"BACKTICK="'`params_09_touch_inject`'$'\n'"GLOBBY=*.txt"$'\n'"EMPTYV=[]"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_09_do_job \
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
		FAIL "sched_rv=${sched_rv}, inject_marker_exists=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		printf '%s\n%s\n%s\n' \
			"expected:" "${expected}" "actual: ${actual}"
		rm -f "${OUT_FILE}" "${INJECT_FILE}"
		return 1
	fi
}

# Verify job params and forwarded positional args to DO_JOB_CB coexist without interference.
test_params_10() {
	params_10_do_job() {
		job_get_params "${1}" COMBOPARAM
		{
			printf 'PARAM=%s\n' "${COMBOPARAM-<unset>}"
			printf 'ARGS=%s\n' "$*"
		} > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_10 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.withargs.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "Job params coexist with forwarded extra args" "${job_id}"

	job_set_params "${job_id}" "COMBOPARAM=paramval"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_10_do_job \
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

# Verify job_get_params() validates the destination variable name.
# Independent of job_set_params()'s registration-time validation.
test_params_11() {
	params_11_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_11 \
		name \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM \
		SCH_FOO sch_foo _sch_foo SCHED_MAX_JOBS DO_JOB_CB JOB_DONE_CB \
		IFS="${IFS}"

	local \
		MSG_FILE="/tmp/sched.params.get_validate.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() rejects reserved/malformed param names" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine" "AAA=1" "BBB=2"

	# "IFS" is deliberately included.
	# "AAA BBB" is deliberately built from two registered names.
	for name in SCH_FOO sch_foo _sch_foo SCHED_MAX_JOBS DO_JOB_CB JOB_DONE_CB IFS 1bad "bad name" "AAA BBB"
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_11_fail_msg job_get_params "${job_id}" "${name}"
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
	params_12_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_12 \
		jid \
		pass_cnt=0 \
		total_cnt=0 \
		rv \
		msg_cnt \
		REALPARAM

	local \
		MSG_FILE="/tmp/sched.params.get_jobid.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() rejects a bad/empty job ID" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	for jid in "" "bad id"; do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_12_fail_msg job_get_params "${jid}" REALPARAM
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
	params_13_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_13 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.get_empty.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() rejects zero requested param names" "(direct call, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	SCHED_FAIL_MSG_CB=params_13_fail_msg job_get_params "${job_id}"
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
	params_14_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_14 \
		rv \
		msg \
		msg_cnt \
		msg_ok

	local \
		MSG_FILE="/tmp/sched.params.set_empty.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_set_params() rejects zero key=value pairs" "(direct call, no scheduler run)"

	SCHED_FAIL_MSG_CB=params_14_fail_msg job_set_params "${job_id}"
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
		TEST_ID=params_15 \
		first \
		second \
		REFETCH
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() reflects updates from a later job_set_params() call" "(direct calls, no scheduler run)"

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
	params_16_do_job() { return 0; }

	params_16_done() {
		job_get_params "${1}" FROMDONE
		printf '%s\n' "${FROMDONE-<unset>}" > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_16 \
		sched_rv \
		seen

	local \
		OUT_FILE="/tmp/sched.params.job_done_cb.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() is usable from JOB_DONE_CB" "${job_id}"

	job_set_params "${job_id}" "FROMDONE=seen_in_job_done_cb"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=params_16_done \
	DO_JOB_CB=params_16_do_job \
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
	params_17_do_job() { return 0; }

	local \
		TEST_ID=params_17 \
		sched_rv \
		seen \
		FROMSCOPE
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() is usable directly in the caller's own scope" "${job_id}"

	job_set_params "${job_id}" "FROMSCOPE=seen_in_caller_scope"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_17_do_job \
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
		TEST_ID=params_18 \
		rv
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" \
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
		TEST_ID=params_19 \
		P1 P2 P3 \
		explicit_ok=0 \
		all_ok=0 \
		noglob_ok=1
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() 'all' mode returns the full registered set" \
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
		TEST_ID=params_20 \
		EXPORTPARAM \
		default_exported \
		flag_exported
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() '-export' flag exports to the real environment" \
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
# - job_get_params() "sch_all" doesn't 'exit 1' on empty params set
test_params_21() {
	params_21_do_job() {
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
		TEST_ID=params_21 \
		sched_rv \
		jobs='withparam1 withparam2 noparam'

	local \
		WP1_FILE="/tmp/sched.autoparams.wp1.${TEST_ID}.$$" \
		WP2_FILE="/tmp/sched.autoparams.wp2.${TEST_ID}.$$" \
		NOPARAM_FILE="/tmp/sched.autoparams.noparam.${TEST_ID}.$$" \
		NOPARAM_STARTED_FILE="/tmp/sched.autoparams.noparam_started.${TEST_ID}.$$"

	rm -f "${WP1_FILE}" "${WP2_FILE}" "${NOPARAM_FILE}" "${NOPARAM_STARTED_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_AUTO_PARAMS=1: auto-export, per-job isolation, and jobs with no params" "${jobs}"

	# "noparam" deliberately has no job_set_params() call at all.
	job_set_params withparam1 "MYPARAM=aaa"
	job_set_params withparam2 "MYPARAM=bbb"

	SCHED_AUTO_PARAMS=1 \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_21_do_job \
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

# Verify job_get_params() char-validates the source param name in an alias
#   (var=param): a source containing shell metacharacters is rejected before the
#   eval-assignment and is never executed.
test_params_22() {
	params_22_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_22 \
		dest \
		spec \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt

	local \
		MSG_FILE="/tmp/sched.params.alias_inject.msg.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.params.alias_inject.marker.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() rejects a malformed aliased source param name, no injection" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	for spec in \
		'dest=x:-$(touch '"${INJECT_FILE}"')' \
		'dest=`touch '"${INJECT_FILE}"'`' \
		'dest=a b' \
		'dest=a;b'
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_22_fail_msg job_get_params "${job_id}" "${spec}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: %s\n' "${spec}" >&2
		fi
	done

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${INJECT_FILE}"
		PASS "${pass_cnt}/${total_cnt} rejected, no injection"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, injected=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		rm -f "${INJECT_FILE}"
		return 1
	fi
}

# Verify job_get_params() alias form var=param assigns the param value to the named
#   variable, and does not also assign a variable named after the param.
test_params_23() {
	local \
		TEST_ID=params_23 \
		MYVAR \
		SRCPARAM
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() 'var=param' assigns to the aliased var only" "(direct call, no scheduler run)"

	job_set_params "${job_id}" "SRCPARAM=aliased_val"

	unset MYVAR SRCPARAM
	job_get_params "${job_id}" MYVAR=SRCPARAM

	if [ "${MYVAR-<unset>}" = aliased_val ] && [ "${SRCPARAM-<unset>}" = '<unset>' ]
	then
		PASS "MYVAR='${MYVAR}', SRCPARAM='${SRCPARAM-<unset>}'"
		return 0
	else
		FAIL "MYVAR='${MYVAR-<unset>}' (expected aliased_val), SRCPARAM='${SRCPARAM-<unset>}' (expected <unset>)"
		return 1
	fi
}

# Verify a leading-digit param name (a valid param key, not a valid shell variable
#   name) is retrievable through an alias var=param, while the plain form is rejected
#   because the name is an invalid destination variable.
test_params_24() {
	params_24_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_24 \
		rv \
		plain_rv \
		msg_cnt \
		DEST

	local \
		MSG_FILE="/tmp/sched.params.leadingdigit.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Leading-digit param retrievable via alias, rejected in plain form" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "1digit=viadigit"

	unset DEST
	job_get_params "${job_id}" DEST=1digit
	rv=$?

	SCHED_FAIL_MSG_CB=params_24_fail_msg job_get_params "${job_id}" 1digit
	plain_rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${rv}" = 0 ] && [ "${DEST-<unset>}" = viadigit ] &&
		[ "${plain_rv}" != 0 ] && [ "${msg_cnt}" = 1 ]
	then
		PASS "DEST='${DEST}', plain_rv=${plain_rv}"
		return 0
	else
		FAIL "rv=${rv}, DEST='${DEST-<unset>}', plain_rv=${plain_rv}, msg_cnt=${msg_cnt}"
		return 1
	fi
}

# Verify job_get_params() applies destination-variable rules to the alias target (the
#   var in var=param): reserved and leading-digit/malformed target names are rejected,
#   nothing is assigned, and IFS is not corrupted; the source param stays valid.
test_params_25() {
	params_25_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_25 \
		spec \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt \
		saved_ifs \
		SCH_x sch_x SCHED_x DO_JOB_CB JOB_DONE_CB \
		IFS="${IFS}"

	local \
		MSG_FILE="/tmp/sched.params.alias_dest.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() validates the aliased destination var (reserved/malformed)" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "SRC=v"

	saved_ifs="${IFS}"

	for spec in IFS=SRC SCH_x=SRC sch_x=SRC SCHED_x=SRC DO_JOB_CB=SRC JOB_DONE_CB=SRC 1dest=SRC
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_25_fail_msg job_get_params "${job_id}" "${spec}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: %s\n' "${spec}" >&2
		fi
	done

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ "${IFS}" = "${saved_ifs}" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected, IFS intact"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, ifs_intact=$([ "${IFS}" = "${saved_ifs}" ] && echo yes || echo no)"
		return 1
	fi
}

# Verify job_get_params() 'sch_all' fails when a job has a param whose name is not a
#   valid shell variable (e.g. leading digit):
#   it cannot be auto-delivered (the mechanism behind SCHED_AUTO_PARAMS),
#   while a valid-name job's 'sch_all' succeeds and the offending param stays reachable via an explicit alias.
test_params_26() {
	params_26_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_26 \
		all_rv \
		ok_all_rv \
		alias_rv \
		msg_cnt \
		goodname \
		DEST

	local \
		MSG_FILE="/tmp/sched.params.sch_all_baddigit.${TEST_ID}.$$" \
		bad_job="${TEST_ID}_bad_job" \
		ok_job="${TEST_ID}_ok_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "sch_all fails on a non-identifier param name; alias still works" "(direct calls, no scheduler run)"

	job_set_params "${bad_job}" "goodname=g" "1baddigit=b"
	job_set_params "${ok_job}" "goodname=g"

	SCHED_FAIL_MSG_CB=params_26_fail_msg job_get_params "${bad_job}" sch_all
	all_rv=$?

	job_get_params "${ok_job}" sch_all
	ok_all_rv=$?

	unset DEST
	job_get_params "${bad_job}" DEST=1baddigit
	alias_rv=$?

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${all_rv}" != 0 ] && [ "${msg_cnt}" -ge 1 ] &&
		[ "${ok_all_rv}" = 0 ] &&
		[ "${alias_rv}" = 0 ] && [ "${DEST-<unset>}" = b ]
	then
		PASS "all_rv=${all_rv}, ok_all_rv=${ok_all_rv}, DEST='${DEST}'"
		return 0
	else
		FAIL "all_rv=${all_rv}, ok_all_rv=${ok_all_rv}, alias_rv=${alias_rv}, DEST='${DEST-<unset>}', msg_cnt=${msg_cnt}"
		return 1
	fi
}

# Verify job_get_params() rejects an alias with an empty source param (var=) or an
#   empty destination var (=param); both fail before any assignment.
test_params_27() {
	params_27_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=params_27 \
		spec \
		rv \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt

	local \
		MSG_FILE="/tmp/sched.params.alias_empty.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "job_get_params() rejects empty alias source or destination" "(direct calls, no scheduler run)"

	job_set_params "${job_id}" "REALPARAM=fine"

	for spec in "DEST=" "=REALPARAM"
	do
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=params_27_fail_msg job_get_params "${job_id}" "${spec}"
		rv=$?
		if [ "${rv}" != 0 ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'Unexpectedly accepted: %s\n' "${spec}" >&2
		fi
	done

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${pass_cnt}" = "${total_cnt}" ] && [ "${msg_cnt}" = "${total_cnt}" ]
	then
		PASS "${pass_cnt}/${total_cnt} rejected"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}"
		return 1
	fi
}

# Verify job_get_params() handles a single call mixing plain names and var=param
#   aliases, assigning each target independently.
test_params_28() {
	local \
		TEST_ID=params_28 \
		PLAINA \
		ALIASB \
		PLAINC \
		SRCB
	local job_id="${TEST_ID}_job"

	print_test_header "${TEST_ID:?}" "job_get_params() mixes plain and aliased requests in one call" "(direct call, no scheduler run)"

	job_set_params "${job_id}" "PLAINA=va" "SRCB=vb" "PLAINC=vc"

	unset PLAINA ALIASB PLAINC SRCB
	job_get_params "${job_id}" PLAINA ALIASB=SRCB PLAINC

	if [ "${PLAINA-<unset>}" = va ] &&
		[ "${ALIASB-<unset>}" = vb ] &&
		[ "${PLAINC-<unset>}" = vc ] &&
		[ "${SRCB-<unset>}" = '<unset>' ]
	then
		PASS "PLAINA='${PLAINA}', ALIASB='${ALIASB}', PLAINC='${PLAINC}'"
		return 0
	else
		FAIL "PLAINA='${PLAINA-<unset>}', ALIASB='${ALIASB-<unset>}', PLAINC='${PLAINC-<unset>}', SRCB='${SRCB-<unset>}'"
		return 1
	fi
}

# Verify SCHED_AUTO_PARAMS=1 truly *exports* each param, with a scheduler run
test_params_29() {
	params_29_do_job() {
		# A child process must inherit the param through the environment.
		sh -c 'printf "%s\n" "${EXTPARAM-<unset>}"' > "${OUT_FILE:?}"
		return 0
	}

	local \
		TEST_ID=params_29 \
		sched_rv \
		seen \
		job_id=params_29_job

	local OUT_FILE="/tmp/sched.autoexport.${TEST_ID}.$$"
	rm -f "${OUT_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_AUTO_PARAMS exports params into an external command's environment" "${job_id}"

	job_set_params "${job_id}" "EXTPARAM=from_env"

	SCHED_AUTO_PARAMS=1 \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=params_29_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${job_id}" &

	wait "$!"
	sched_rv=$?

	read_first_line seen "${OUT_FILE}"
	rm -f "${OUT_FILE}"

	if [ "${sched_rv}" = 0 ] && [ "${seen}" = from_env ]
	then
		PASS "EXTPARAM='${seen}'"
		return 0
	else
		FAIL "sched_rv=${sched_rv}, EXTPARAM='${seen}', expected 'from_env'"
		return 1
	fi
}
