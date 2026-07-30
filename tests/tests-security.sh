#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-security.sh

# Category: Security (command-injection / forgery resistance)
# This file is sourced by tests.sh; it defines test_N functions only.
# The library builds/reads shell variable names via eval (scheduler.sh),
#   so these tests verify that names crossing public boundaries (job IDs, param names,
#   destination var names, callback var names) are validated before they reach eval,
#   and that values are never interpolated as code. Shared helpers used below come from tests.sh
#   (read_first_line, finalize_handler, done_handler, get_test_pid, write_id_sets).

#
# Tests
#

# Verify job-ID validation: IDs are restricted to [a-zA-Z0-9_].
# Each list containing an ID with any other character is rejected upfront: rv 1, one error message,
#   nothing dispatched (a valid ID in the same list must not run),
#   and injection-shaped IDs are never executed.
# A control run with valid IDs (including a leading digit) still succeeds.
# Also controls the injection marker itself, anchoring the marker-absence checks
#   used across the security tests.
test_security_01() {
	security_01_do_job() {
		printf '%s\n' "$1" >> "${ARGS_FILE:?}"
		return 0
	}

	security_01_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	security_01_fail_msg() {
		printf '%s\n' "$*" >> "${MSG_FILE:?}"
	}

	local \
		TEST_ID=security_01 \
		sched_rv bad_id bad_cnt=0 msg_cnt=0 \
		checks_ok=1 \
		inject_cmd=security_01_touch_inject

	local \
		INJECT_FILE="/tmp/sched.idchars.inject.${TEST_ID}.$$" \
		ARGS_FILE="/tmp/sched.idchars.args.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.idchars.msg.${TEST_ID}.$$"

	rm -f "${ARGS_FILE}" "${MSG_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Job ID validation: only [a-zA-Z0-9_] accepted" \
		"(30 invalid IDs rejected + 1 valid control run)"

	# Control for the whole injection-marker family (security_01/02/03/04/06/07/14/16):
	#   they all assert '[ ! -e INJECT_FILE ]' via an identical one-line touch helper.
	#   Without proof the helper can create the marker, every one of those checks
	#   would pass even if the payload never had a chance to fire.
	# ${inject_cmd} is the single source of truth: the payloads below are built from
	#   the same variable this control invokes, so a payload cannot name a command
	#   that was never proven to set the marker
	"${inject_cmd}"
	[ -e "${INJECT_FILE}" ] || {
		FAIL "'${inject_cmd}' did not create '${INJECT_FILE}' - marker-absence checks would be vacuous"
		return 1
	}
	rm -f "${INJECT_FILE}"

	# Glob/quote/injection-shaped chars: every one of these IDs must be rejected.
	# IDs contain no whitespace, so a plain for-list is safe here.
	for bad_id in \
		'star*id' \
		'quest?id' \
		'brk[et]s' \
		'brace{d}' \
		'paren(ed)' \
		'dollarsign$x' \
		'backtick`x`' \
		'semi;colon' \
		'pipe|line' \
		'amp&and' \
		'ltgt<>x' \
		'eqsign=x' \
		'hashtag#x' \
		'bangmark!x' \
		'tildeish~x' \
		'atsign@x' \
		'carethat^x' \
		'percentsign%x' \
		'colonsep:x' \
		'dotdot.x' \
		'commasep,x' \
		'dash-ed' \
		"apos'trophe" \
		'dquo"te' \
		'bslash\x' \
		"cmdsub\$(${inject_cmd})" \
		"subshelltick\`${inject_cmd}\`" \
		"semiexec;${inject_cmd}" \
		"andexec&&${inject_cmd}" \
		"pipeexec|${inject_cmd}"
	do
		bad_cnt=$((bad_cnt + 1))
		SCHED_FAIL_MSG_CB=security_01_fail_msg \
		DO_JOB_CB=security_01_do_job \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs "validok ${bad_id}" &
		wait "$!"
		sched_rv=$?
		[ "${sched_rv}" = 1 ] ||
			{ checks_ok=; echo "id '${bad_id}': sched_rv=${sched_rv}, expected 1" >&2; }
	done

	# Nothing may be dispatched from a rejected list - not even the valid ID
	[ ! -s "${ARGS_FILE}" ] ||
		{ checks_ok=; echo "jobs ran despite rejection: $(cat "${ARGS_FILE}")" >&2; }

	# Injection-shaped IDs must never be executed
	[ ! -e "${INJECT_FILE}" ] ||
		{ checks_ok=; echo "injection marker exists" >&2; }

	# One error message per rejected list
	[ -f "${MSG_FILE}" ] && msg_cnt="$(wc -l < "${MSG_FILE}")"
	[ "${msg_cnt}" -eq "${bad_cnt}" ] ||
		{ checks_ok=; echo "expected ${bad_cnt} error messages, got ${msg_cnt}" >&2; }

	# Control: valid IDs, including one with a leading digit, still run
	SCHED_FAIL_MSG_CB=security_01_fail_msg \
	DO_JOB_CB=security_01_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'plain_ok 0digit_ok' &
	wait "$!"
	sched_rv=$?
	[ "${sched_rv}" = 0 ] && [ "$(sed '/^$/d' "${ARGS_FILE}" 2>/dev/null | wc -l)" = 2 ] ||
		{ checks_ok=; echo "control run: sched_rv=${sched_rv}, jobs run: $(cat "${ARGS_FILE}" 2>/dev/null)" >&2; }

	rm -f "${ARGS_FILE}" "${MSG_FILE}" "${INJECT_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "${bad_cnt} invalid IDs rejected, control run ok"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify forged completion records (glob/injection-shaped IDs) are rejected, never executed.
test_security_02() {
	security_02_touch_inject() {
		touch "${INJECT_FILE:?}"
	}

	security_02_do_job() {
		printf '%s %s\n' 0 "${SPOOF_DONE_ID:?}" >&3
		sleep 1

		return 0
	}

	security_02_fail_msg_handler() {
		printf '%s\n' "$*" >> "${FAIL_MSG_FILE:?}"
	}

	security_02_check_forgery() {
		local job_id="${1:?}" spoof_id="${2:?}" sched_rv

		rm -f "${INJECT_FILE:?}"

		SCHED_FINALIZE_CB=finalize_handler \
		JOB_DONE_CB=done_handler \
		DO_JOB_CB=security_02_do_job \
		SCHED_FAIL_MSG_CB=security_02_fail_msg_handler \
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
		TEST_ID=security_02 \
		pass_cnt=0 \
		total_cnt=0 \
		msg_cnt=0

	local \
		INJECT_FILE="/tmp/sched.forge.inject.${TEST_ID}.$$" \
		FAIL_MSG_FILE="/tmp/sched.forge.msg.${TEST_ID}.$$"

	rm -f "${INJECT_FILE}" "${FAIL_MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Job-ID forgery / injection resistance" \
		"spoofed completion records with glob and shell-metacharacter IDs"

	security_02_check_forgery "realjob" "*"
	security_02_check_forgery "realjob" "\$(security_02_touch_inject)"
	security_02_check_forgery "realjob" "\`security_02_touch_inject\`"
	security_02_check_forgery "realjob" ";security_02_touch_inject"

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

# Verify a job-ID list containing glob/injection-shaped IDs is rejected upfront:
#   schedule_jobs() fails (rv=1), nothing is dispatched, the embedded command substitution is never evaluated,
#   and SCHED_FINALIZE_CB's ok/fail sets are never written.
# Job IDs are restricted to [a-zA-Z0-9_] (REFERENCE.md).
test_security_03() {
	security_03_touch_inject() { touch "${INJECT_FILE:?}"; }

	security_03_do_job() {
		touch "${DISPATCH_FILE:?}"
		case "${1}" in
			*ok_marker*) return 0 ;;
			*) return 1 ;;
		esac
	}

	local \
		TEST_ID=security_03 \
		sched_rv \
		ok_raw fail_raw \
		inject_exists dispatch_exists \
		bad_ok_id bad_fail_id \
		jobs

	bad_ok_id='ok_marker_$(security_03_touch_inject)'
	bad_fail_id='fail_marker_`security_03_touch_inject`'
	jobs="${bad_ok_id} ${bad_fail_id}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		INJECT_FILE="/tmp/sched.inject.${TEST_ID:?}.$$" \
		DISPATCH_FILE="/tmp/sched.dispatch.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${INJECT_FILE}" "${DISPATCH_FILE}"

	print_test_header "${TEST_ID:?}" "Injection-shaped job IDs are rejected upfront, never classified" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=security_03_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	# Capture marker existence before cleanup, for both the check and diagnostics
	[ -e "${INJECT_FILE}" ] && inject_exists=yes || inject_exists=no
	[ -e "${DISPATCH_FILE}" ] && dispatch_exists=yes || dispatch_exists=no

	read_first_line --rm ok_raw "${FINALIZE_SETS_PREFIX}.ok"
	read_first_line --rm fail_raw "${FINALIZE_SETS_PREFIX}.fail"
	rm -f "${INJECT_FILE}" "${DISPATCH_FILE}"

	# Rejected upfront: rv=1, no injection, no dispatch, finalize sets unwritten
	if [ "${sched_rv}" = 1 ] &&
		[ "${inject_exists}" = no ] &&
		[ "${dispatch_exists}" = no ] &&
		[ -z "${ok_raw}" ] &&
		[ -z "${fail_raw}" ]
	then
		PASS "list rejected (rv=1), no dispatch, no injection, sets unwritten"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 1), inject_exists=${inject_exists}, dispatch_exists=${dispatch_exists}, ok_raw='${ok_raw}', fail_raw='${fail_raw}'"
		return 1
	fi
}

# Verify param values are stored/delivered as opaque data: quotes, $(), backticks, globs, spaces,
#   empty value are preserved and never executed or glob-expanded.
test_security_04() {
	security_04_touch_inject() { touch "${INJECT_FILE:?}"; }

	security_04_do_job() {
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
		TEST_ID=security_04 \
		sched_rv \
		actual \
		expected

	local \
		OUT_FILE="/tmp/sched.params.valfidelity.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.params.valfidelity.inject.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${OUT_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Param value fidelity / no injection via value content" "${job_id}"

	# GLOBBY uses a bare '*' (matches any file in the non-empty test CWD),
	#   so a regression that let the value reach an unquoted expansion would visibly expand to filenames -
	#   unlike a non-matching pattern (e.g. '*.txt'),
	#   which would stay literal whether or not it was glob-expanded.
	# shellcheck disable=SC2016
	job_set_params "${job_id}" \
		'SPACEY=hello world' \
		"QUOTY=a'b\"c" \
		'CMDSUB=$(security_04_touch_inject)' \
		'BACKTICK=`security_04_touch_inject`' \
		'GLOBBY=*' \
		'EMPTYV='

	# shellcheck disable=SC2016
	expected="SPACEY=hello world"$'\n'"QUOTY=a'b\"c"$'\n'"CMDSUB="'$(security_04_touch_inject)'$'\n'"BACKTICK="'`security_04_touch_inject`'$'\n'"GLOBBY=*"$'\n'"EMPTYV=[]"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=security_04_do_job \
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

# Verify job_get_params() char-validates the source param name in an alias (var=param):
#   a source containing shell metacharacters is rejected before the eval-assignment and is never executed.
test_security_05() {
	security_05_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=security_05 \
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
		SCHED_FAIL_MSG_CB=security_05_fail_msg job_get_params "${job_id}" "${spec}"
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

# Verify a callback env var whose value is injection-shaped is rejected and never executed.
# sch_check_cb() reads the value with eval "val=${CB}" (parameter expansion only, no command substitution)
#   and passes it to command -v as a single quoted word, so an embedded $(...)/`...` is never run.
# Distinct from test_sched_env_02, which uses a benign non-existent command with no marker.
test_security_06() {
	security_06_touch_inject() { touch "${INJECT_FILE:?}"; }
	security_06_do_job() { return 0; }

	# shellcheck disable=SC2034
	local \
		TEST_ID=security_06 \
		sched_rv \
		cb bad_cb \
		pass_cnt=0 total_cnt=0 \
		\
		DO_JOB_CB_def=security_06_do_job \
		JOB_DONE_CB_def=done_handler \
		SCHED_FINALIZE_CB_def=finalize_handler \
		SCHED_FAIL_MSG_CB_def=echo

	local INJECT_FILE="/tmp/sched.sec.cbinject.${TEST_ID}.$$"
	rm -f "${INJECT_FILE}"

	# shellcheck disable=SC2016
	local payload='x$(security_06_touch_inject)'

	local cb_list="DO_JOB_CB JOB_DONE_CB SCHED_FINALIZE_CB SCHED_FAIL_MSG_CB"

	print_test_header "${TEST_ID:?}" "Injection-shaped callback values are rejected, never executed" "${cb_list}"

	for bad_cb in ${cb_list}; do
		total_cnt=$((total_cnt + 1))

		# Every callback valid except the one under test, which gets the payload
		for cb in ${cb_list}; do
			if [ "${cb}" = "${bad_cb}" ]; then
				eval "local ${cb}=\"\${payload}\""
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

		if [ "${sched_rv}" = 1 ] && [ ! -e "${INJECT_FILE}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'cb=%s: sched_rv=%s, marker=%s\n' "${bad_cb}" "${sched_rv}" \
				"$([ -e "${INJECT_FILE}" ] && echo yes || echo no)" >&2
		fi

		rm -f "${INJECT_FILE}"
	done

	if [ "${pass_cnt}" = "${total_cnt}" ]; then
		PASS "${pass_cnt}/${total_cnt} callbacks rejected, no injection"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} callbacks rejected"
		return 1
	fi
}

# Verify the public setters reject injection-shaped job IDs and param names before those names reach eval,
#   and never execute the embedded command.
# Covers job_set_params (eval building SCH_JOB_PARAMS_<id>)
#   and job_set_timeout (eval reading SCH_TIMEOUT_JOB_<id>).
# Direct calls, no scheduler run.
# Mirrors test_security_05 on the set side; distinct from test_params_04,
#   which uses benign bad names (space/empty) with no injection payload or marker.
test_security_07() {
	security_07_touch_inject() { touch "${INJECT_FILE:?}"; }
	security_07_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	security_07_reject_set_params() {
		local rv
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=security_07_fail_msg job_set_params "${1}" "${2}"
		rv=$?
		if [ "${rv}" != 0 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'job_set_params accepted: id=%s pair=%s\n' "${1}" "${2}" >&2
		fi
	}

	security_07_reject_set_timeout() {
		local rv
		total_cnt=$((total_cnt + 1))
		SCHED_FAIL_MSG_CB=security_07_fail_msg job_set_timeout "${1}" "${2}"
		rv=$?
		if [ "${rv}" != 0 ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'job_set_timeout accepted: id=%s\n' "${1}" >&2
		fi
	}

	local \
		TEST_ID=security_07 \
		bad \
		pass_cnt=0 total_cnt=0 msg_cnt

	local \
		MSG_FILE="/tmp/sched.sec.setter.msg.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.sec.setter.inject.${TEST_ID}.$$" \
		job_id="${TEST_ID}_job"

	rm -f "${MSG_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Setters reject injection-shaped job IDs and param names, no execution" "(direct calls, no scheduler run)"

	# Injection-shaped job IDs: rejected by both setters at job-ID validation
	for bad in \
		'$(security_07_touch_inject)' \
		'`security_07_touch_inject`' \
		'a;security_07_touch_inject'
	do
		security_07_reject_set_params "${bad}" "GOOD=v"
		security_07_reject_set_timeout "${bad}" 5
	done

	# Injection-shaped param-name keys: rejected by job_set_params at name validation
	security_07_reject_set_params "${job_id}" '$(security_07_touch_inject)=v'
	security_07_reject_set_params "${job_id}" '`security_07_touch_inject`=v'

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${MSG_FILE}" "${INJECT_FILE}"
		PASS "${pass_cnt}/${total_cnt} rejected, no injection"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, injected=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		rm -f "${MSG_FILE}" "${INJECT_FILE}"
		return 1
	fi
}

# Verify the ${#job_id} length prefix in the internal param key keeps two (job_id, param) pairs
#   that would otherwise concatenate identically from colliding.
# job1="security_08_x"/param="y_z" and job2="security_08_x_y"/param="z" both form "security_08_x_y_z";
#   the length prefix disambiguates them (SCH_JOB_PARAM_13_... vs SCH_JOB_PARAM_15_...).
# Distinct values must be stored and retrieved with no cross-contamination.
# Direct calls, no scheduler run.
test_security_08() {
	local \
		TEST_ID=security_08 \
		g1 g2 \
		job1="security_08_x" param1="y_z" \
		job2="security_08_x_y" param2="z"

	print_test_header "${TEST_ID:?}" "Param key namespace: length prefix prevents (job,param) collision" "(direct calls, no scheduler run)"

	job_set_params "${job1}" "${param1}=VAL_ONE"
	job_set_params "${job2}" "${param2}=VAL_TWO"

	job_get_params "${job1}" "g1=${param1}"
	job_get_params "${job2}" "g2=${param2}"

	if [ "${g1}" = VAL_ONE ] && [ "${g2}" = VAL_TWO ]; then
		PASS "g1='${g1}', g2='${g2}'"
		return 0
	else
		FAIL "g1='${g1}' (want VAL_ONE), g2='${g2}' (want VAL_TWO)"
		return 1
	fi
}

# Verify the job-ID list split is glob-safe:
#   a glob-shaped ID reaches validation unexpanded even when it would match a file in the scheduler's CWD,
#   so it is rejected verbatim and never dispatched.
# Live sentinel: the scheduler runs in a dir holding a file whose name is a VALID id ('zzsentinelJOB'),
#   so a dropped `set -f` on the list split would expand 'zzsentinel*' to that id and dispatch it -
#   the discriminator here is rejection (rv=1, no dispatch, msg names '*').
test_security_09() {
	security_09_do_job() { touch "${DISPATCH_FILE:?}"; return 0; }
	security_09_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=security_09 \
		sched_rv \
		dispatch_exists msg_has_glob

	local \
		WORK_DIR="/tmp/sched.globsafe.${TEST_ID}.$$" \
		DISPATCH_FILE="/tmp/sched.globsafe.dispatch.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.globsafe.msg.${TEST_ID}.$$"

	rm -rf "${WORK_DIR}"
	rm -f "${DISPATCH_FILE}" "${MSG_FILE}"
	mkdir -p "${WORK_DIR}"
	: > "${WORK_DIR}/zzsentinelJOB"

	print_test_header "${TEST_ID:?}" "Job-ID list is not glob-expanded (live sentinel)" "zzsentinel*"

	# Run with CWD=WORK_DIR so 'zzsentinel*' is a live glob there.
	#   Marker/msg files are absolute, so the cd does not misplace them.
	( cd "${WORK_DIR}" &&
		SCHED_FAIL_MSG_CB=security_09_fail_msg \
		DO_JOB_CB=security_09_do_job \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs 'zzsentinel*' ) &
	wait "$!"
	sched_rv=$?

	[ -e "${DISPATCH_FILE}" ] && dispatch_exists=yes || dispatch_exists=no
	msg_has_glob=no
	[ -f "${MSG_FILE}" ] && grep -qF 'zzsentinel*' "${MSG_FILE}" && msg_has_glob=yes

	rm -rf "${WORK_DIR}"
	rm -f "${DISPATCH_FILE}" "${MSG_FILE}"

	# Correct (set -f held): rejected verbatim, never dispatched, msg names the literal glob
	if [ "${sched_rv}" = 1 ] &&
		[ "${dispatch_exists}" = no ] &&
		[ "${msg_has_glob}" = yes ]
	then
		PASS "rejected verbatim, not dispatched"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 1), dispatched=${dispatch_exists}, msg_names_glob=${msg_has_glob}"
		return 1
	fi
}

# Verify a glob-shaped ID in a mixed list is rejected verbatim without expanding or dispatching its valid sibling.
#   Live sentinel: a file 'zzsibling' (valid id) exists in the scheduler's CWD,
#   so a dropped `set -f` on the list split would turn 'zzsibling*' into 'zzsibling' and dispatch both jobs.
test_security_10() {
	security_10_do_job() { printf '%s\n' "${1}" >> "${DISPATCH_FILE:?}"; return 0; }
	security_10_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=security_10 \
		sched_rv \
		dispatched msg_has_glob

	local \
		WORK_DIR="/tmp/sched.globsafe2.${TEST_ID}.$$" \
		DISPATCH_FILE="/tmp/sched.globsafe2.dispatch.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.globsafe2.msg.${TEST_ID}.$$"

	rm -rf "${WORK_DIR}"
	rm -f "${DISPATCH_FILE}" "${MSG_FILE}"
	mkdir -p "${WORK_DIR}"
	: > "${WORK_DIR}/zzsibling"

	print_test_header "${TEST_ID:?}" "Glob ID in a mixed list rejected verbatim, valid sibling not dispatched" "realjob zzsibling*"

	( cd "${WORK_DIR}" &&
		SCHED_FAIL_MSG_CB=security_10_fail_msg \
		DO_JOB_CB=security_10_do_job \
		SCHED_MAX_JOBS=1 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs 'realjob zzsibling*' ) &
	wait "$!"
	sched_rv=$?

	dispatched=none
	[ -f "${DISPATCH_FILE}" ] && dispatched="$(tr '\n' ' ' < "${DISPATCH_FILE}")"
	msg_has_glob=no
	[ -f "${MSG_FILE}" ] && grep -qF 'zzsibling*' "${MSG_FILE}" && msg_has_glob=yes

	rm -rf "${WORK_DIR}"
	rm -f "${DISPATCH_FILE}" "${MSG_FILE}"

	# Correct: whole list rejected upfront (rv=1), nothing dispatched, msg names the literal glob
	if [ "${sched_rv}" = 1 ] &&
		[ "${dispatched}" = none ] &&
		[ "${msg_has_glob}" = yes ]
	then
		PASS "list rejected verbatim, no dispatch"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 1), dispatched='${dispatched}', msg_names_glob=${msg_has_glob}"
		return 1
	fi
}

# jobs_init()'s internal ID-list split does not glob-expand:
#   a glob-metacharacter ID is rejected verbatim even with a matching file present.
test_security_11() {
	security_11_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=security_11 \
		rv msg_has_glob

	local \
		WORK_DIR="/tmp/sched.jobsinit.globsafe.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.jobsinit.globsafe.msg.${TEST_ID}.$$"

	rm -rf "${WORK_DIR}"
	rm -f "${MSG_FILE}"
	mkdir -p "${WORK_DIR}"
	# Sentinel filename is a valid job ID: had the glob expanded, jobs_init would accept it and return 0.
	: > "${WORK_DIR}/zzsentinelJOB"

	print_test_header "${TEST_ID:?}" "jobs_init() rejects glob ID verbatim, no expansion" "zzsentinel*"

	( cd "${WORK_DIR}" &&
		SCHED_FAIL_MSG_CB=security_11_fail_msg jobs_init 'zzsentinel*' )
	rv=$?

	msg_has_glob=no
	[ -f "${MSG_FILE}" ] && grep -qF 'zzsentinel*' "${MSG_FILE}" && msg_has_glob=yes

	rm -rf "${WORK_DIR}"
	rm -f "${MSG_FILE}"

	# Correct: literal rejected (rv=1), error names the literal glob.
	if [ "${rv}" = 1 ] && [ "${msg_has_glob}" = yes ]
	then
		PASS "glob rejected verbatim (rv=1)"
		return 0
	else
		FAIL "rv=${rv} (want 1), msg_names_glob=${msg_has_glob}"
		return 1
	fi
}

# jobs_init() splits its ID list on whitespace regardless of the caller's IFS,
#   and leaves the caller's IFS unchanged on return.
test_security_12() {
	# Impose IFS, reset two IDs passed space-separated in one arg, check the outcome.
	sec12_run() {
		local imposed="${1}" j1="${2}" j2="${3}" rv ifs_after g1 g2 saved="${IFS}"

		job_set_params "${j1}" "P=v1"
		job_set_params "${j2}" "P=v2"

		IFS="${imposed}"
		jobs_init "${j1} ${j2}"
		rv=$?
		ifs_after="${IFS}"
		IFS="${saved}"

		unset g1 g2
		job_get_params "${j1}" g1=P
		job_get_params "${j2}" g2=P

		[ "${rv}" = 0 ] && [ -z "${g1}" ] && [ -z "${g2}" ] &&
			[ "${ifs_after}" = "${imposed}" ]
	}

	local \
		TEST_ID=security_12 \
		total=0 \
		passed=0

	print_test_header "${TEST_ID:?}" "jobs_init() whitespace-splits under any caller IFS, preserves IFS" "(direct calls, no scheduler run)"

	# IFS without a space, then empty IFS (both suppress splitting if jobs_init trusted them).
	total=$((total + 1)); sec12_run ':' sec12a1 sec12a2 && passed=$((passed + 1))
	total=$((total + 1)); sec12_run '' sec12b1 sec12b2 && passed=$((passed + 1))

	if [ "${passed}" = "${total}" ]
	then
		PASS "${passed}/${total} IFS variants"
		return 0
	else
		FAIL "${passed}/${total} IFS variants"
		return 1
	fi
}

# Verify the job-ID length cap: 2020 chars accepted, 2021 rejected.
# Accepted: schedule_jobs() rv 0, no fail messages, JOB_DONE_CB gets the ID verbatim with rv 0
#   (a torn completion record would surface as a fatal "Malformed completion record").
# Rejected: rv 1, one message, nothing dispatched.
# jobs_init() applies the same cap.
test_security_13() {
	security_13_do_job() {
		printf '%s\n' "${1}" >> "${ARGS_FILE:?}"
		do_job_default "${1}"
	}

	security_13_done() {
		printf '%s %s\n' "${1}" "${2}" >> "${DONE_FILE:?}"
		return 0
	}

	security_13_fail_msg() {
		printf '%s\n' "$*" >> "${MSG_FILE:?}"
	}

	local \
		TEST_ID=security_13 \
		sched_rv msg_cnt done_line ok_id long_id \
		checks_ok=1

	local \
		ARGS_FILE="/tmp/sched.idlen.args.${TEST_ID}.$$" \
		DONE_FILE="/tmp/sched.idlen.done.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.idlen.msg.${TEST_ID}.$$" \
		SCHED_FAIL_MSG_CB=security_13_fail_msg

	export -n SCHED_FAIL_MSG_CB

	rm -f "${ARGS_FILE}" "${DONE_FILE}" "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "Job ID length cap: 2020 accepted, 2021 rejected" \
		"(1 max-length job + 1 oversized ID rejected)"

	mk_name_of_len ok_id 2020 "instant_${TEST_ID}_" &&
	mk_name_of_len long_id 2021 "instant_${TEST_ID}_" || {
		echo "mk_name_of_len failed" >&2
		FAIL
		return 1
	}

	# Accepted: 2020-char ID runs and reports back verbatim
	DO_JOB_CB=security_13_do_job \
	JOB_DONE_CB=security_13_done \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=4 \
		schedule_jobs "${ok_id}" &
	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 0 ] ||
		{ checks_ok=; echo "2020-char ID: sched_rv=${sched_rv}, expected 0" >&2; }

	read_first_line --rm done_line "${DONE_FILE}" ||
		{ checks_ok=; echo "2020-char ID: no JOB_DONE_CB record" >&2; }
	[ "${done_line}" = "${ok_id} 0" ] ||
		{ checks_ok=; echo "2020-char ID: JOB_DONE_CB got a record of ${#done_line} chars, expected the ID verbatim with rv 0" >&2; }

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt="$(wc -l < "${MSG_FILE}")"
	[ "${msg_cnt}" -eq 0 ] ||
		{ checks_ok=; echo "2020-char ID: ${msg_cnt} error message(s), expected 0" >&2; }

	rm -f "${ARGS_FILE}" "${MSG_FILE}"

	# Rejected: 2021-char ID
	DO_JOB_CB=security_13_do_job \
	JOB_DONE_CB=security_13_done \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=4 \
		schedule_jobs "${long_id}" &
	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = 1 ] ||
		{ checks_ok=; echo "2021-char ID: sched_rv=${sched_rv}, expected 1" >&2; }

	[ ! -s "${ARGS_FILE}" ] ||
		{ checks_ok=; echo "2021-char ID: job dispatched despite rejection" >&2; }

	[ ! -s "${DONE_FILE}" ] ||
		{ checks_ok=; echo "2021-char ID: JOB_DONE_CB invoked despite rejection" >&2; }

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt="$(wc -l < "${MSG_FILE}")"
	[ "${msg_cnt}" -eq 1 ] ||
		{ checks_ok=; echo "2021-char ID: ${msg_cnt} error message(s), expected 1" >&2; }

	# jobs_init() applies the same cap
	jobs_init "${long_id}" &&
		{ checks_ok=; echo "jobs_init accepted the 2021-char ID" >&2; }
	jobs_init "${ok_id}" ||
		{ checks_ok=; echo "jobs_init rejected the 2020-char ID" >&2; }

	rm -f "${ARGS_FILE}" "${DONE_FILE}" "${MSG_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "2020-char ID ran and reported verbatim, 2021-char ID rejected"
		return 0
	else
		FAIL
		return 1
	fi
}

# Verify the public helpers reject an injection-shaped ${SCHED_ID}
#   before it reaches eval/export/unset, and never execute the embedded command.
# Covers the namespace infix built into SCH_JOB_PARAMS_/SCH_JOB_PARAM_/SCH_TIMEOUT_JOB_ names.
# Direct calls, no scheduler run.
test_security_14() {
	security_14_touch_inject() { touch "${INJECT_FILE:?}"; }
	security_14_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }

	# 1: SCHED_ID value
	security_14_reject_all() {
		local rv helper
		for helper in \
			"job_set_params ${JOB_ID} GOOD=v" \
			"job_get_params ${JOB_ID} GOOD" \
			"job_set_timeout ${JOB_ID} 5" \
			"jobs_init ${JOB_ID}"
		do
			total_cnt=$((total_cnt + 1))
			# shellcheck disable=SC2086
			SCHED_ID="${1}" SCHED_FAIL_MSG_CB=security_14_fail_msg ${helper}
			rv=$?
			if [ "${rv}" != 0 ]; then
				pass_cnt=$((pass_cnt + 1))
			else
				printf "accepted SCHED_ID='%s': %s\n" "${1}" "${helper}" >&2
			fi
		done
	}

	local \
		TEST_ID=security_14 \
		bad \
		pass_cnt=0 total_cnt=0 msg_cnt

	local \
		JOB_ID=security_14_job \
		MSG_FILE="/tmp/sched.sec.schedid.msg.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.sec.schedid.inject.${TEST_ID}.$$"

	rm -f "${MSG_FILE}" "${INJECT_FILE}"

	print_test_header "${TEST_ID:?}" "Helpers reject injection-shaped SCHED_ID, no execution" "(direct calls, no scheduler run)"

	for bad in \
		'$(security_14_touch_inject)' \
		'`security_14_touch_inject`' \
		'a;security_14_touch_inject'
	do
		security_14_reject_all "${bad}"
	done

	msg_cnt=0
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")

	if [ "${pass_cnt}" = "${total_cnt}" ] &&
		[ "${msg_cnt}" = "${total_cnt}" ] &&
		[ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${MSG_FILE}" "${INJECT_FILE}"
		PASS "${pass_cnt}/${total_cnt} rejected, no injection"
		return 0
	else
		FAIL "${pass_cnt}/${total_cnt} rejected, msg_cnt=${msg_cnt}, injected=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		rm -f "${MSG_FILE}" "${INJECT_FILE}"
		return 1
	fi
}

# Verify the ${#SCHED_ID} length prefix in the internal param key keeps two
#   (SCHED_ID, job_id, param) triplets that would otherwise concatenate identically apart.
# SCHED_ID='...a'/job='1'/param='2_x' and SCHED_ID='...a_1'/job='2'/param='x'
#   both form '..._a_1_1_2_x' without it.
# Direct calls, no scheduler run.
test_security_15() {
	local TEST_ID=security_15
	local \
		g1 g2 \
		ns1="${TEST_ID}_a" ns2="${TEST_ID}_a_1"

	print_test_header "${TEST_ID:?}" "Param key namespace: length prefix prevents (SCHED_ID,job) collision" "(direct calls, no scheduler run)"

	SCHED_ID="${ns1}" job_set_params 1 "2_x=VAL_ONE"
	SCHED_ID="${ns2}" job_set_params 2 "x=VAL_TWO"

	SCHED_ID="${ns1}" job_get_params 1 "g1=2_x"
	SCHED_ID="${ns2}" job_get_params 2 "g2=x"

	if [ "${g1}" = VAL_ONE ] && [ "${g2}" = VAL_TWO ]; then
		PASS "g1='${g1}', g2='${g2}'"
		return 0
	else
		FAIL "g1='${g1}' (want VAL_ONE), g2='${g2}' (want VAL_TWO)"
		return 1
	fi
}

# Verify a callback that overwrites ${SCHED_ID} mid-run with an injection payload
#   cannot get it executed: the scheduler re-validates the namespace and aborts.
test_security_16() {
	security_16_touch_inject() { touch "${INJECT_FILE:?}"; }
	security_16_fail_msg() { printf '%s\n' "$*" >> "${MSG_FILE:?}"; }
	security_16_do_job() { printf '%s\n' "${1}" >> "${RAN_FILE:?}"; return 0; }

	# Runs in the scheduler process: no 'local', so the assignment leaks into it
	security_16_tick() { SCHED_ID='$(security_16_touch_inject)'; return 0; }

	local \
		TEST_ID=security_16 \
		sched_rv ran

	local \
		MSG_FILE="/tmp/sched.sec.schedid_run.msg.${TEST_ID}.$$" \
		INJECT_FILE="/tmp/sched.sec.schedid_run.inject.${TEST_ID}.$$" \
		RAN_FILE="/tmp/sched.sec.schedid_run.ran.${TEST_ID}.$$" \
		jobs="security_16_j1 security_16_j2"

	rm -f "${MSG_FILE}" "${INJECT_FILE}" "${RAN_FILE}"

	print_test_header "${TEST_ID:?}" "SCHED_ID overwritten by a callback mid-run is re-validated" "${jobs}"

	SCHED_FAIL_MSG_CB=security_16_fail_msg \
	SCHED_FINALIZE_CB=finalize_handler \
	SCHED_DISPATCH_TICK_CB=security_16_tick \
	DO_JOB_CB=security_16_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=5 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	# Only the job dispatched before the callback ran may have started
	ran=
	[ -f "${RAN_FILE}" ] && ran="$(tr '\n' ' ' < "${RAN_FILE}")"
	ran="${ran% }"

	if [ "${sched_rv}" = 1 ] && [ "${ran}" = 'security_16_j1' ] && [ ! -e "${INJECT_FILE}" ]
	then
		rm -f "${MSG_FILE}" "${INJECT_FILE}" "${RAN_FILE}"
		PASS "sched_rv=${sched_rv}, ran='${ran}', no injection"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 1), ran='${ran}' (want 'security_16_j1'), injected=$([ -e "${INJECT_FILE}" ] && echo yes || echo no)"
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		rm -f "${MSG_FILE}" "${INJECT_FILE}" "${RAN_FILE}"
		return 1
	fi
}

# Verify jobs_abort() from DO_JOB_CB is rejected: the job wrapper is a forked process,
#   so the process-identity guard fails on the pid comparison.
# Asserts rv 1, the guard message, and that the abort target still completes and classifies OK.
test_security_17() {
	security_17_do_job() {
		[ "${1}" = "${ABORT_FROM_ID}" ] && {
			jobs_abort "${ABORT_TARGET_ID:?}"
			printf '%s\n' "${?}" >> "${RV_FILE:?}"
		}

		do_job_default "${@}"
	}

	local \
		TEST_ID=security_17 \
		sched_rv abort_rv msg_cnt exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	local \
		ABORT_TARGET_ID=ok2_security17 \
		ABORT_FROM_ID=ok1_security17

	# Target is listed first, so it is already running when the second job calls jobs_abort
	local jobs="${ABORT_TARGET_ID} ${ABORT_FROM_ID}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${RV_FILE}"

	print_test_header "${TEST_ID:?}" "jobs_abort() from DO_JOB_CB is rejected" "${jobs}"

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=security_17_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm abort_rv "${RV_FILE}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${abort_rv}" = 1 ] &&
		[ "${msg_cnt}" = 1 ] &&
		msgs_have "${MSG_FILE}" 'SCHED_UID is not set or scheduler is not running in this process' &&
		verify_id_set exp act "${jobs}" "${ok_raw}" &&
		[ -z "${aborted_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		PASS "jobs_abort rv=${abort_rv}, guard message recorded, both jobs OK"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 0), abort_rv='${abort_rv}' (want 1), msg_cnt=${msg_cnt} (want 1)"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		return 1
	fi
}

# Verify a stale SCHED_UID / SCH_STARTED_* pair left lying around cannot make the
#   jobs_abort() guard accept a call. Both reach the scheduler as ordinary shell
#   variables, so leftovers from an earlier or outer run are indistinguishable from
#   values the caller set on purpose.
# Cases: the identity of a process that has since exited, standalone; a leftover
#   identity whose PID this shell now has, standalone (only the start-time half
#   rejects it); both still set across a live run, with DO_JOB_CB calling jobs_abort.
test_security_18() {
	# '<pid>_<starttime>' of the calling process. In a subshell it reports that
	#   subshell's identity, so a command substitution cannot be used to read the
	#   caller's own.
	# 1: out var
	security_18_self_uid() {
		local su_out="${1:?}" su_line su_pid su_start su_had_f

		export -n "${su_out}="
		IFS= read -r su_line < /proc/self/stat || return 1

		su_pid="${su_line%% *}"
		# comm can contain ') ' and spaces - strip greedily
		su_line="${su_line##*") "}"

		case "${-}" in *f*) su_had_f=1 ;; esac
		set -f
		set -- ${su_line}
		[ -n "${su_had_f}" ] || set +f

		# Start time is stat field 22; the strip leaves state (field 3) first
		[ "${#}" -ge 20 ] || return 1
		shift 19
		su_start="${1}"

		is_uint "${su_pid}" "${su_start}" || return 1
		export -n "${su_out}=${su_pid}_${su_start}"
	}

	security_18_do_job() {
		[ "${1}" = "${ABORT_FROM_ID}" ] || { do_job_default "${@}"; return "${?}"; }

		jobs_abort "${ABORT_TARGET_ID:?}"
		printf '%s\n' "${?}" >> "${RV_FILE:?}"

		do_job_default "${@}"
	}

	local \
		TEST_ID=security_18 \
		sched_rv self_uid stale_uid reused_uid rv_exited rv_reused rv_in_job \
		msg_cnt_pre msg_cnt exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	local \
		ABORT_TARGET_ID=ok2_security18 \
		ABORT_FROM_ID=ok1_security18

	local jobs="${ABORT_TARGET_ID} ${ABORT_FROM_ID}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$" \
		UID_FILE="/tmp/sched.uid.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${RV_FILE}" "${UID_FILE}"

	print_test_header "${TEST_ID:?}" "Stale SCHED_UID / SCH_STARTED_* cannot pass the jobs_abort() guard" "${jobs}"

	# Identity of a process that has since exited, as an earlier run would leave behind
	( security_18_self_uid stale_uid && printf '%s\n' "${stale_uid}" ) > "${UID_FILE}"
	read_first_line --rm stale_uid "${UID_FILE}"

	security_18_self_uid self_uid &&
	[ -n "${stale_uid}" ] &&
	[ "${stale_uid%%_*}" != "${self_uid%%_*}" ] ||
	{
		FAIL "could not capture identities: own='${self_uid}', exited='${stale_uid}'"
		return 1
	}

	# Leftover identity whose PID this shell now has: same PID, start time 1
	#   (one tick after boot, which no live process of ours can have)
	reused_uid="${self_uid%%_*}_1"

	# Set as plain variables: an inherited environment variable reaches the scheduler
	#   as one of these, and forks carry them into the run either way
	export -n "SCH_STARTED_${stale_uid}=1" "SCH_STARTED_${reused_uid}=1"

	SCHED_UID="${stale_uid}" SCHED_FAIL_MSG_CB=record_fail_msg jobs_abort "${ABORT_TARGET_ID}"
	rv_exited=$?

	SCHED_UID="${reused_uid}" SCHED_FAIL_MSG_CB=record_fail_msg jobs_abort "${ABORT_TARGET_ID}"
	rv_reused=$?

	count_msgs msg_cnt_pre "${MSG_FILE}"

	# Both leftovers still set, and a stale SCHED_UID handed to the run itself
	SCHED_UID="${stale_uid}" \
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=security_18_do_job \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	unset "SCH_STARTED_${stale_uid}" "SCH_STARTED_${reused_uid}"

	read_first_line --rm rv_in_job "${RV_FILE}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${rv_exited}" = 1 ] &&
		[ "${rv_reused}" = 1 ] &&
		[ "${rv_in_job}" = 1 ] &&
		[ "${msg_cnt_pre}" = 2 ] &&
		[ "${msg_cnt}" = 3 ] &&
		msgs_have "${MSG_FILE}" 'SCHED_UID is not set or scheduler is not running in this process' &&
		verify_id_set exp act "${jobs}" "${ok_raw}" &&
		[ -z "${aborted_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		PASS "stale identities rejected (rv 1,1,1), ${msg_cnt} guard messages, run unaffected"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 0), rvs: exited='${rv_exited}' reused='${rv_reused}' in_job='${rv_in_job}' (want 1,1,1), msgs=${msg_cnt_pre}/${msg_cnt} (want 2/3)"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		return 1
	fi
}

# Verify jobs_abort() called outside any scheduler run is rejected: rv 1 and one guard
#   message per call, with no args and with a stale SCHED_UID / SCH_STARTED_* alike.
# A control run afterwards shows the rejected calls left no state behind.
test_security_19() {
	local \
		TEST_ID=security_19 \
		rv_plain rv_noargs rv_stale msg_cnt sched_rv exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	local jobs="instant_security19a instant_security19b"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"

	print_test_header "${TEST_ID:?}" "jobs_abort() outside a scheduler run is rejected" "${jobs} (after 3 standalone jobs_abort calls)"

	SCHED_FAIL_MSG_CB=record_fail_msg jobs_abort instant_security19a
	rv_plain=$?

	SCHED_FAIL_MSG_CB=record_fail_msg jobs_abort
	rv_noargs=$?

	SCHED_UID=1_1 SCH_STARTED_1_1=1 SCHED_FAIL_MSG_CB=record_fail_msg jobs_abort instant_security19a
	rv_stale=$?

	count_msgs msg_cnt "${MSG_FILE}"

	# Control run: the rejected calls must not have disturbed anything
	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${rv_plain}" = 1 ] &&
		[ "${rv_noargs}" = 1 ] &&
		[ "${rv_stale}" = 1 ] &&
		[ "${msg_cnt}" = 3 ] &&
		msgs_have "${MSG_FILE}" 'SCHED_UID is not set or scheduler is not running in this process' &&
		[ "${sched_rv}" = 0 ] &&
		verify_id_set exp act "${jobs}" "${ok_raw}" &&
		[ -z "${aborted_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		PASS "3 standalone calls rejected (rv 1), ${msg_cnt} guard messages, control run clean"
		return 0
	else
		FAIL "rvs: plain='${rv_plain}' noargs='${rv_noargs}' stale='${rv_stale}' (want 1,1,1), msg_cnt=${msg_cnt} (want 3), sched_rv=${sched_rv} (want 0)"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		return 1
	fi
}

# Verify a stray completion record naming a concurrently RUNNING sibling misclassifies
#   that sibling as OK, and that the sibling's genuine record is then fatal: rv 1 with
#   'Unexpected completion record'.
# Records carry no pid, so the scheduler cannot tell which job wrote one; a job that
#   writes fd 3 a second time lands here without meaning to.
test_security_20() {
	# DO_JOB_CB writing an extra record for ${SPOOF_DONE_ID} (rv ${SPOOF_DONE_RV:-0}) only
	#   from the job whose ID is ${SPOOF_FROM_ID}; every job then runs do_job_default.
	security_20_done() {
		printf '%s %s\n' "${1}" "${2}" >> "${DONE_FILE:?}"
		return 0
	}

	local \
		TEST_ID=security_20 \
		sched_rv exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	local \
		SPOOF_DONE_ID=ok2_security20 \
		SPOOF_FROM_ID=ok1_security20 \
		keepalive_id=ok5_security20

	# Target first so it is running when the writer starts; keepalive outlives the
	#   target, so its genuine record is still read
	local jobs="${SPOOF_DONE_ID} ${SPOOF_FROM_ID} ${keepalive_id}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$" \
		DONE_FILE="/tmp/sched.done.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${DONE_FILE}"

	print_test_header "${TEST_ID:?}" "Stray completion record for a running sibling misclassifies it" "${jobs}"

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=security_20_done \
	DO_JOB_CB=spoof_done_job_from \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=15 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${sched_rv}" = 1 ] &&
		msgs_have "${MSG_FILE}" "Unexpected completion record for job ID '${SPOOF_DONE_ID}'" &&
		msgs_have "${DONE_FILE}" "${SPOOF_DONE_ID} 0" &&
		verify_id_set exp act "${SPOOF_DONE_ID} ${SPOOF_FROM_ID}" "${ok_raw}" &&
		verify_id_set exp act "${keepalive_id}" "${unfinished_raw}" &&
		[ -z "${fail_raw}${expired_raw}${aborted_raw}${undispatched_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${DONE_FILE}"
		PASS "'${SPOOF_DONE_ID}' misclassified OK, its genuine record fatal (rv=${sched_rv})"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 1), expected='${exp}', actual='${act}'"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		[ -f "${DONE_FILE}" ] && cat "${DONE_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${DONE_FILE}"
		return 1
	fi
}

# Verify jobs_abort() from SCHED_FINALIZE_CB is rejected: the callback runs in the
#   scheduler's own process, but the started flag is unset before it is invoked.
# Asserts rv 1, one guard message, the callback entered exactly once (no finalize
#   recursion), and the rv the callback was handed reaching the caller unchanged.
test_security_21() {
	security_21_finalize() {
		# One line per invocation, holding the rv the callback was handed
		printf '%s\n' "${1}" >> "${FIN_FILE:?}"

		jobs_abort "${ABORT_TARGET_ID:?}"
		printf '%s\n' "${?}" >> "${RV_FILE:?}"

		sets_finalize_handler "${@}"
	}

	local \
		TEST_ID=security_21 \
		sched_rv abort_rv fin_cnt fin_rv msg_cnt exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	# Both jobs have completed by the time finalize runs
	local ABORT_TARGET_ID=instant_security21a

	local jobs="${ABORT_TARGET_ID} instant_security21b"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$" \
		FIN_FILE="/tmp/sched.fin.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${FIN_FILE}" "${RV_FILE}"

	print_test_header "${TEST_ID:?}" "jobs_abort() from SCHED_FINALIZE_CB is rejected" "${jobs}"

	SCHED_FAIL_MSG_CB=record_fail_msg \
	SCHED_FINALIZE_CB=security_21_finalize \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	count_msgs fin_cnt "${FIN_FILE}"
	count_msgs msg_cnt "${MSG_FILE}"
	read_first_line --rm abort_rv "${RV_FILE}"
	read_first_line --rm fin_rv "${FIN_FILE}"
	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${fin_cnt}" = 1 ] &&
		[ "${fin_rv}" = "${sched_rv}" ] &&
		[ "${abort_rv}" = 1 ] &&
		[ "${msg_cnt}" = 1 ] &&
		msgs_have "${MSG_FILE}" 'SCHED_UID is not set or scheduler is not running in this process' &&
		verify_id_set exp act "${jobs}" "${ok_raw}" &&
		[ -z "${aborted_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		PASS "jobs_abort rv=${abort_rv}, finalize entered ${fin_cnt}x, sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 0), fin_cnt=${fin_cnt} (want 1), fin_rv='${fin_rv}' (want '${sched_rv}'), abort_rv='${abort_rv}' (want 1), msg_cnt=${msg_cnt} (want 1)"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}"
		return 1
	fi
}

# Verify jobs_abort() from SCHED_FAIL_MSG_CB is rejected: the callback runs in a
#   subshell, so the pid comparison fails there.
# The guard message cannot re-enter the callback - it reaches stderr together with
#   the recursion warning. The callback is entered once, by an unknown-ID abort
#   from JOB_DONE_CB; the target job is unaffected.
test_security_22() {
	security_22_done() {
		[ "${1}" = "${TRIGGER_ID:?}" ] &&
			jobs_abort "${UNKNOWN_ID:?}"

		done_handler "${@}"
	}

	security_22_fail_msg() {
		record_fail_msg "${@}"

		jobs_abort "${ABORT_TARGET_ID:?}"
		printf '%s\n' "${?}" >> "${RV_FILE:?}"

		return 0
	}

	local \
		TEST_ID=security_22 \
		sched_rv abort_rv msg_cnt err_cnt exp act \
		ok_raw fail_raw unfinished_raw undispatched_raw expired_raw aborted_raw

	local \
		ABORT_TARGET_ID=ok2_security22 \
		TRIGGER_ID=ok1_security22 \
		UNKNOWN_ID=nosuch_security22

	# Target is listed first and outlives the trigger, so it is still running when
	#   the callback tries to abort it
	local jobs="${ABORT_TARGET_ID} ${TRIGGER_ID}"

	local \
		FINALIZE_SETS_PREFIX="/tmp/sched.finsets.${TEST_ID:?}.$$" \
		MSG_FILE="/tmp/sched.msg.${TEST_ID:?}.$$" \
		ERR_FILE="/tmp/sched.err.${TEST_ID:?}.$$" \
		RV_FILE="/tmp/sched.abortrv.${TEST_ID:?}.$$"

	rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${ERR_FILE}" "${RV_FILE}"

	print_test_header "${TEST_ID:?}" "jobs_abort() from SCHED_FAIL_MSG_CB is rejected" "${jobs}"

	SCHED_FAIL_MSG_CB=security_22_fail_msg \
	SCHED_FINALIZE_CB=sets_finalize_handler \
	JOB_DONE_CB=security_22_done \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=15 \
	SCHED_IDLE_TIMEOUT_S=10 \
		schedule_jobs "${jobs}" 2>"${ERR_FILE}" &

	wait "$!"
	sched_rv=$?

	read_first_line --rm abort_rv "${RV_FILE}"
	count_msgs msg_cnt "${MSG_FILE}"
	count_msgs err_cnt "${ERR_FILE}"
	read_id_sets "${FINALIZE_SETS_PREFIX}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${abort_rv}" = 1 ] &&
		[ "${msg_cnt}" = 1 ] &&
		msgs_have "${MSG_FILE}" "jobs_abort: unknown job ID '${UNKNOWN_ID}'." &&
		! msgs_have "${MSG_FILE}" 'SCHED_UID is not set or scheduler is not running in this process' &&
		[ "${err_cnt}" = 2 ] &&
		msgs_have "${ERR_FILE}" 'jobs_abort: SCHED_UID is not set or scheduler is not running in this process.' &&
		msgs_have "${ERR_FILE}" 'Warning: stopping infinite SCHED_FAIL_MSG_CB recursion.' &&
		verify_id_set exp act "${jobs}" "${ok_raw}" &&
		[ -z "${aborted_raw}" ] &&
		verify_id_partition "${jobs}"
	then
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${ERR_FILE}"
		PASS "jobs_abort rv=${abort_rv}, guard message on stderr with the recursion warning, callback entered ${msg_cnt}x"
		return 0
	else
		FAIL "sched_rv=${sched_rv} (want 0), abort_rv='${abort_rv}' (want 1), msg_cnt=${msg_cnt} (want 1), err_cnt=${err_cnt} (want 2)"
		print_id_sets >&2
		[ -f "${MSG_FILE}" ] && cat "${MSG_FILE}" >&2
		[ -f "${ERR_FILE}" ] && cat "${ERR_FILE}" >&2
		rm -f "${FINALIZE_SETS_PREFIX:?}".* "${MSG_FILE}" "${ERR_FILE}" "${RV_FILE}"
		return 1
	fi
}
