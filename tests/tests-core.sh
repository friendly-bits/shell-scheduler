#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329
# shellcheck source=/dev/null

# tests-core.sh

# Category: Core Job Execution & Completion
# This file is sourced by tests.sh; it defines test_N functions only.

#
# Tests
#

# Verify the scheduler succeeds and calls JOB_DONE_CB for every job, even when one fails.
test_core_01() {
	TEST_ID=core_01 \
	TEST_NAME='Normal completion with failure status propagation' \
	TEST_JOBS='instant_1 instant_2 fail' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify the scheduler succeeds and all JOB_DONE_CB callbacks run when every job succeeds.
test_core_02() {
	TEST_ID=core_02 \
	TEST_NAME='All jobs succeed' \
	TEST_JOBS='instant_1 instant_2 instant_3 instant_4 instant_5' \
	TEST_EXPECT_RV=0 \
	TEST_SCHED_MAX_JOBS=3 \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
		run_generic_test
}

# Verify a failing JOB_DONE_CB terminates the scheduler with the callback's
#   return code; the completed job stays in the ok set, the still-running job
#   stays unfinished. The timeout-notification counterpart of this contract
#   is covered by timeout_12.
test_core_03() {
	core_03_done_handler() {
		echo "done idx='$1' rv='$2'"
		return "${CORE_03_DONE_HANDLER_RV:?}"
	}
	core_03_finalize() {
		finalize_handler "$1" "$2"
		printf '%s\n' "ok=$3" "unfin=$5" > "${FIN_FILE:?}"
	}

	local sched_rv checks_ok=1 \
		TEST_ID=core_03 \
		CORE_03_DONE_HANDLER_RV=99 \
		jobs="instant_c03 hang_c03"

	local FIN_FILE="/tmp/sched.cbfail.${TEST_ID:?}.$$"
	rm -f "${FIN_FILE}"

	print_test_header "${TEST_ID:?}" "Failing JOB_DONE_CB terminates the scheduler with its return code" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=core_03_finalize \
	JOB_DONE_CB=core_03_done_handler \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?

	[ "${sched_rv}" = "${CORE_03_DONE_HANDLER_RV}" ] ||
		{ checks_ok=; echo "sched_rv=${sched_rv}, expected ${CORE_03_DONE_HANDLER_RV}" >&2; }
	grep -q '^ok=instant_c03$' "${FIN_FILE}" 2>/dev/null &&
	grep -q '^unfin=hang_c03$' "${FIN_FILE}" 2>/dev/null ||
		{ checks_ok=; echo "outcome sets mismatch: $(tr '\n' ' ' < "${FIN_FILE}" 2>/dev/null)" >&2; }

	rm -f "${FIN_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=${sched_rv}"
		return 0
	else
		FAIL "sched_rv=${sched_rv}"
		return 1
	fi
}

# Verify arbitrary DO_JOB_CB return codes reach JOB_DONE_CB unchanged without failing the scheduler.
test_core_04() {
	core_04_do_job() {
		return "$1"
	}

	core_04_done_handler() {
		printf '%s %s\n' "$1" "$2" >> "${STATUS_FILE:?}"

		return 0
	}

	local \
		TEST_ID=core_04 \
		sched_rv \
		actual \
		expected \
		jobs='0 1 17 42 99 255'

	local STATUS_FILE="/tmp/sched.status.${TEST_ID:?}.$$"
	rm -f "${STATUS_FILE}"

	print_test_header "${TEST_ID:?}" "DO_JOB_CB return statuses" "${jobs}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=core_04_done_handler \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=20 \
	SCHED_IDLE_TIMEOUT_S=10 \
	DO_JOB_CB=core_04_do_job \
		schedule_jobs "${jobs}" &

	wait "$!"
	sched_rv=$?
	expected=$(cat <<EOF | sort
0 0
1 1
17 17
42 42
99 99
255 255
EOF
)

	actual=
	actual_cnt=0

	if [ -f "${STATUS_FILE}" ]
	then
		actual="$(sort "${STATUS_FILE}")"
		actual_cnt="$(wc -l < "${STATUS_FILE}")"
	fi

	rm -f "${STATUS_FILE}"

	if [ "${sched_rv}" = 0 ] &&
		[ "${actual_cnt}" = 6 ] &&
		[ "${actual}" = "${expected}" ]
	then
		PASS
		return 0
	else
		FAIL "sched_rv=${sched_rv}, count=${actual_cnt}, actual=${actual//$'\n'/; }"
		return 1
	fi
}

# Verify DO_JOB_CB, JOB_DONE_CB, and SCHED_FINALIZE_CB observe the caller's noglob state.
test_core_05() {
	core_05_do_job() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${do_job_glob_file}"
		return 0
	}

	core_05_done_handler() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac >> "${done_glob_file}"
		return 0
	}

	core_05_finalize_handler() {
		case "${-}" in
			*f*) printf 'noglob\n' ;;
			*) printf 'glob\n' ;;
		esac > "${finalize_glob_file}"
		return 0
	}

	local \
		TEST_ID=core_05 \
		mode \
		expect \
		sched_rv \
		pass_cnt=0 \
		parent_pre \
		parent_post \
		do_job_glob_file \
		done_glob_file \
		finalize_glob_file \
		do_job_result \
		done_result \
		finalize_result

	print_test_header "${TEST_ID:?}" "noglob state preserved in callbacks" \
		"glob-enabled and glob-disabled callers"

	for mode in glob noglob; do
		do_job_glob_file="/tmp/sched.globtest.job.${TEST_ID:?}.$$"
		done_glob_file="/tmp/sched.globtest.done.${TEST_ID:?}.$$"
		finalize_glob_file="/tmp/sched.globtest.finalize.${TEST_ID:?}.$$"
		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"

		case "${mode}" in
			glob) set +f; expect=glob ;;
			noglob) set -f; expect=noglob ;;
		esac

		parent_pre="${mode}"

		SCHED_FAIL_MSG_CB=echo \
		SCHED_FINALIZE_CB=core_05_finalize_handler \
		JOB_DONE_CB=core_05_done_handler \
		DO_JOB_CB=core_05_do_job \
		SCHED_MAX_JOBS=2 \
		SCHED_TIMEOUT_S=3 \
		SCHED_IDLE_TIMEOUT_S=2 \
			schedule_jobs 'instant_1 instant_2 instant_3' &

		wait "$!"
		sched_rv=$?

		parent_post=glob
		case "${-}" in
			*f*) parent_post=noglob ;;
		esac
		set +f

		do_job_result="$(sort -u "${do_job_glob_file}" 2>/dev/null | tr '\n' ' ')"
		done_result="$(sort -u "${done_glob_file}" 2>/dev/null | tr '\n' ' ')"
		finalize_result="$(cat "${finalize_glob_file}" 2>/dev/null)"

		if [ "${sched_rv}" = 0 ] &&
			[ "${parent_post}" = "${parent_pre}" ] &&
			[ "${do_job_result}" = "${expect} " ] &&
			[ "${done_result}" = "${expect} " ] &&
			[ "${finalize_result}" = "${expect}" ]
		then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'sub-check failed for mode=%s (sched_rv=%s, do_job=%s, done=%s, finalize=%s)\n' \
				"${mode}" "${sched_rv}" "${do_job_result}" "${done_result}" "${finalize_result}" >&2
		fi

		rm -f "${do_job_glob_file}" "${done_glob_file}" "${finalize_glob_file}"
	done

	set +f

	if [ "${pass_cnt}" = 2 ]
	then
		PASS
		return 0
	else
		FAIL "passed=${pass_cnt}/2"
		return 1
	fi
}

# Verify the standalone param/timeout helpers do not leak the caller's noglob (set -f) state:
#   they save and restore it around internal set -f sections (e.g. job_get_params 'sch_all').
#   Checked in both glob-enabled and glob-disabled callers via ${-}.
#   Direct calls, no scheduler run.
test_core_06() {
	local \
		TEST_ID=core_06 \
		mode now \
		pass_cnt=0 \
		P \
		job_id=core_06_job

	print_test_header "${TEST_ID:?}" "Standalone helpers preserve caller noglob state" \
		"(direct calls, no scheduler run)"

	job_set_params "${job_id}" "P=v"

	for mode in glob noglob; do
		case "${mode}" in
			glob) set +f ;;
			noglob) set -f ;;
		esac

		# Exercise each helper, including the set -f 'sch_all' path in job_get_params
		job_set_params  "${job_id}" "Q=w"
		job_get_params  "${job_id}" P
		job_get_params  "${job_id}" sch_all
		job_set_timeout "${job_id}" 5

		now=glob
		case "${-}" in *f*) now=noglob ;; esac

		# Restore glob for the harness before evaluating/looping
		set +f

		if [ "${now}" = "${mode}" ]; then
			pass_cnt=$((pass_cnt + 1))
		else
			printf 'helper leaked -f: caller was %s, became %s\n' "${mode}" "${now}" >&2
		fi
	done

	if [ "${pass_cnt}" = 2 ]; then
		PASS
		return 0
	else
		FAIL "passed=${pass_cnt}/2"
		return 1
	fi
}

# Two scheduler instances run concurrently under a SHARED SCHED_DIR with disjoint job sets.
# Each must finish with rv 0 and report exactly its own jobs in the ok bucket -
#   no cross-instance leakage through the shared FIFO directory -
#   and both per-run dirs must be cleaned up, leaving no residue.
# Guards non-interference between simultaneous instances on a shared volume.
# Runs in any environment.
test_core_07() {
	# Per-instance finalize record, routed by ${CORE07_REC} (set per instance)
	core_07_finalize() {
		# $3 = ok ids, $4 = fail ids, $5 = unfinished ids
		printf 'ok=[%s] fail=[%s] unfin=[%s]\n' "$3" "$4" "$5" > "${CORE07_REC:?}"
	}
	# Extract the ok-bucket ids from a record file into <out var>
	core_07_ok() {
		local line val
		read_first_line line "${2}" || { export -n "${1}="; return 1; }
		val="${line#*ok=[}"
		val="${val%%]*}"
		export -n "${1}=${val}"
	}
	# Return 0 if <actual> and <expected> are equal as sets (order-insensitive)
	core_07_same_set() {
		local e cnt_a=0 cnt_b=0
		for e in ${1}; do cnt_a=$((cnt_a + 1)); done
		for e in ${2}; do
			cnt_b=$((cnt_b + 1))
			sch_is_included "${e}" "${1}" || return 1
		done
		[ "${cnt_a}" = "${cnt_b}" ]
	}

	local \
		TEST_ID=core_07 \
		checks_ok=1 rv_a rv_b pid_a pid_b ok_a ok_b \
		jobs_a='ok_a1 ok_a2' \
		jobs_b='ok_b1 ok_b2'

	local \
		SHARED_DIR="/tmp/sched.concurrency.${TEST_ID}.$$" \
		REC_A="/tmp/sched.concurrency.reca.${TEST_ID}.$$" \
		REC_B="/tmp/sched.concurrency.recb.${TEST_ID}.$$"
	rm -rf "${SHARED_DIR}"; rm -f "${REC_A}" "${REC_B}"

	print_test_header "${TEST_ID}" "Two instances share SCHED_DIR without interfering" "${jobs_a} | ${jobs_b}"

	CORE07_REC="${REC_A}" \
	SCHED_DIR="${SHARED_DIR}" \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=core_07_finalize \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=8 \
		schedule_jobs "${jobs_a}" &
	pid_a=$!

	CORE07_REC="${REC_B}" \
	SCHED_DIR="${SHARED_DIR}" \
	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=core_07_finalize \
	DO_JOB_CB=do_job_default \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=10 \
	SCHED_IDLE_TIMEOUT_S=8 \
		schedule_jobs "${jobs_b}" &
	pid_b=$!

	wait "${pid_a}"; rv_a=$?
	wait "${pid_b}"; rv_b=$?

	[ "${rv_a}" = 0 ] || { checks_ok=; echo "instance A rv=${rv_a} (want 0)"; }
	[ "${rv_b}" = 0 ] || { checks_ok=; echo "instance B rv=${rv_b} (want 0)"; }

	# Each instance reports exactly its own jobs
	core_07_ok ok_a "${REC_A}"
	core_07_ok ok_b "${REC_B}"
	core_07_same_set "${ok_a}" "${jobs_a}" ||
		{ checks_ok=; echo "A ok bucket '${ok_a}' (want '${jobs_a}')"; }
	core_07_same_set "${ok_b}" "${jobs_b}" ||
		{ checks_ok=; echo "B ok bucket '${ok_b}' (want '${jobs_b}')"; }

	# No cross-instance leakage through the shared FIFO directory
	case " ${ok_a} " in *" ok_b"*) checks_ok=; echo "A leaked B's ids: '${ok_a}'" ;; esac
	case " ${ok_b} " in *" ok_a"*) checks_ok=; echo "B leaked A's ids: '${ok_b}'" ;; esac

	# Both per-run dirs cleaned up: no leftover under the shared dir
	set -- "${SHARED_DIR}"/sched_*
	[ -e "${1}" ] && { checks_ok=; echo "leftover run dir(s): $*"; }

	rm -rf "${SHARED_DIR}"; rm -f "${REC_A}" "${REC_B}"

	if [ -n "${checks_ok}" ]; then
		PASS "both rv 0, ok sets correct and disjoint, run dirs cleaned"
		return 0
	else
		FAIL
		return 1
	fi
}

