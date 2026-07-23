#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-job_termination.sh

# Category: job termination - variant-shared tests and shared infrastructure.
#   Tests here run against whichever variant is selected: they drive the
#   variant's default termination callback via ${SCHED_TERM_CB_DEFAULT}
#   (full: sched_job_term_ppid; mini: sched_job_term_mini) and gate on
#   term_default_capable. Full-only library tests live in
#   tests-job_termination_full.sh; mini-only tests in tests-job_termination_mini.sh.
#   The job-termination libraries are sourced by tests.sh (full variant only).

# This file is sourced by tests.sh; it defines test_job_termination_NN functions
#   plus the shared infrastructure used by all three job-termination files.

# All tests exercise the public interface only:
#   JOB_TERM_CB, schedule_jobs(), environment variables and callbacks.
#
# Category infrastructure
#

# Wait (up to ${2:-3} x 1 s) until every PID recorded in file ${1} is gone.
# On failure sets ${ALIVE_PIDS} to the list of surviving PIDs.
jt_assert_dead() {
	local caf_f="${1}" caf_tries="${2:-3}" caf_t=0 caf_pid

	ALIVE_PIDS=
	[ -f "${caf_f}" ] || return 0
	while :; do
		ALIVE_PIDS=
		while read -r caf_pid; do
			[ -n "${caf_pid}" ] || continue
			kill -0 "${caf_pid}" 2>/dev/null && ALIVE_PIDS="${ALIVE_PIDS}${ALIVE_PIDS:+ }${caf_pid}"
		done < "${caf_f}"
		[ -z "${ALIVE_PIDS}" ] && return 0
		caf_t=$((caf_t + 1))
		[ "${caf_t}" -gt "${caf_tries}" ] && return 1
		sleep 1
	done
}

# Return 0 if every whitespace-separated ID in ${2} is included in list ${1}
#   and both lists have the same element count
jt_same_set() {
	local css_e css_cnt_a=0 css_cnt_b=0

	for css_e in ${1}; do css_cnt_a=$((css_cnt_a + 1)); done
	for css_e in ${2}; do
		css_cnt_b=$((css_cnt_b + 1))
		sch_is_included "${css_e}" "${1}" || return 1
	done
	[ "${css_cnt_a}" = "${css_cnt_b}" ]
}

# Best-effort teardown so one failing test cannot cascade:
#   kill recorded PIDs, remove record files, remove leftover cgroups
# 1: pids file (optional)
# 2: test base cgroup dir (optional)
# Extra args: additional files to remove
jt_teardown() {
	local ctd_p ctd_d ctd_pids_f="${1}" ctd_base="${2}"

	[ -f "${ctd_pids_f}" ] && {
		while read -r ctd_p; do
			[ -n "${ctd_p}" ] && kill -9 "${ctd_p}" 2>/dev/null
		done < "${ctd_pids_f}"
	}
	[ "${#}" -gt 2 ] && { shift 2; rm -f "${@}"; }
	rm -f "${ctd_pids_f}"

	[ -n "${ctd_base}" ] && [ -d "${ctd_base}" ] && {
		for ctd_d in "${ctd_base}"/sched_*/job_* "${ctd_base}"/sched_*/probe "${ctd_base}"/sched_* "${ctd_base}"; do
			rmdir "${ctd_d}" 2>/dev/null
		done
	}
	:
}

# Job execution callback for this category.
# Record file paths are inherited from the calling test's locals at fork time.
do_job_term() {
	local job_name="${1%%_*}"

	case "${job_name}" in
		instant) : ;;

		# Proof-of-execution marker
		mark) : > "${MARK_F:?}" ;;

		# Return instantly, leaving a background child and an orphaned grandchild behind (both recorded)
		strag)
			sleep 300 &
			printf '%s\n' "${!}" >> "${PIDS_F:?}"
			(
				sleep 300 &
				printf '%s\n' "${!}" >> "${PIDS_F:?}"
			) &
		;;

		# Block on a recorded child until killed
		block)
			sleep 300 &
			printf '%s\n' "${!}" >> "${PIDS_F:?}"
			wait "${!}"
		;;

		# Live two-level subtree: a child that itself keeps a grandchild alive. Both the child (mid)
		#   and the grandchild are recorded, then the wrapper blocks.
		# Exercises multi-level descendant discovery (the fixpoint walk).
		deep)
			(
				sleep 300 &
				printf '%s\n' "${!}" >> "${PIDS_F:?}"
				wait "${!}"
			) &
			printf '%s\n' "${!}" >> "${PIDS_F:?}"
			wait "${!}"
		;;

		*)
			printf '%s\n' "Unexpected job name '${job_name}'." >&2
			return 1
		;;
	esac

	return 0
}

# Shared finalize handler: records the outcome arguments to ${FINALIZE_F}
jt_finalize_rec() {
	printf '%s\n' \
		"rv=${1}" \
		"pids=${2}" \
		"ok=${3}" \
		"fail=${4}" \
		"unfin=${5}" \
		"undisp=${6}" \
		"expired=${7}" > "${FINALIZE_F:?}"
}

# Read field ${2} recorded by jt_finalize_rec from file ${3} into var ${1}
jt_finalize_get() {
	local cfg_line

	export -n "${1:?}="
	[ -f "${3:?}" ] || return 1
	while IFS= read -r cfg_line; do
		case "${cfg_line}" in
			"${2:?}="*)
				export -n "${1}=${cfg_line#"${2}"=}"
				return 0
		esac
	done < "${3}"
	return 1
}

# "per-job timeout kills the job's process tree at expiry (unverified)".
# 1: test id
# 2: JOB_TERM_CB
# 3: capability gate fn
# 4: skip reason
# 5: job id (a block_* id, so do_job_term blocks on a recorded child)
_jt_timeout_scenario() {
	# On the expiry notification (rv 124), wait for the job's recorded child to die,
	#   then record whether it was already dead when the callback ran
	_jt_timeout_done() {
		local i pid alive=unknown
		[ "${2}" = 124 ] && [ -n "${3}" ] ||
			{ printf 'unexpected|%s|%s|%s\n' "${1}" "${2}" "${3:-}" >> "${DONE_F:?}"; return 0; }
		for i in 1 2 3; do
			alive=no
			while read -r pid; do
				[ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && alive=yes
			done < "${PIDS_F:?}"
			[ "${alive}" = no ] && break
			sleep 1
		done
		printf 'expired|%s|%s|dead_at_cb=%s\n' "${1}" "${3}" "$([ "${alive}" = no ] && printf yes || printf no)" >> "${DONE_F:?}"
	}

	local \
		TEST_ID="${1}" jt_cb="${2}" jt_gate="${3}" jt_skip="${4}" jt_job="${5}" \
		sched_rv checks_ok=1 done_rec done_pid fin_pids fin_expired

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		DONE_F="/tmp/sched.job_termination.done.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}" "${DONE_F}"

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: per-job timeout kills the job's process tree at expiry (unverified)" "${jt_job}"

	"${jt_gate}" || { SKIP "${jt_skip}"; return 2; }

	job_set_timeout "${jt_job}" 1 || { FAIL "job_set_timeout failed"; return 1; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=_jt_timeout_done \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
	JOB_TERM_CB="${jt_cb}" \
		schedule_jobs "${jt_job}" &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	read_first_line done_rec "${DONE_F}"
	done_pid="${done_rec#expired|${jt_job}|}"
	done_pid="${done_pid%%|*}"
	case "${done_rec}" in
		"expired|${jt_job}|${done_pid}|dead_at_cb=yes") ;;
		*) checks_ok=; echo "done record '${done_rec}' (want 'expired|${jt_job}|<pid>|dead_at_cb=yes')" ;;
	esac

	jt_finalize_get fin_expired expired "${FINALIZE_F}" && [ "${fin_expired}" = "${jt_job}" ] ||
		{ checks_ok=; echo "expired bucket '${fin_expired}' (want '${jt_job}')"; }

	# No verification in a /proc-based library:
	#   the expired job's wrapper PID must still be reported in running_pids
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ "${fin_pids}" = "${done_pid}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want '${done_pid}' - unverified kill)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${ALIVE_PIDS}"; }

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}" "${DONE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "killed at expiry, expired='${fin_expired}', running_pids='${fin_pids}' (unverified)"
		return 0
	else
		FAIL
		return 1
	fi
}

# "USR1 abort kills all running job trees (unverified)".
# 1: test id
# 2: callback
# 3: gate fn
# 4: skip reason
# 5: space-separated block_* ids
_jt_abort_scenario() {
	local \
		TEST_ID="${1}" jt_cb="${2}" jt_gate="${3}" jt_skip="${4}" jt_jobs="${5}" \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin pid_cnt=0 job_cnt=0 p

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}"

	for p in ${jt_jobs}; do job_cnt=$((job_cnt + 1)); done

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: USR1 abort kills all running job trees (unverified)" "${jt_jobs}"

	"${jt_gate}" || { SKIP "${jt_skip}"; return 2; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS="${job_cnt}" \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB="${jt_cb}" \
		schedule_jobs "${jt_jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && jt_same_set "${fin_unfin}" "${jt_jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jt_jobs}')"; }

	# Kills are unverified: every wrapper PID must still be reported
	jt_finalize_get fin_pids pids "${FINALIZE_F}"
	for p in ${fin_pids}; do pid_cnt=$((pid_cnt + 1)); done
	[ "${pid_cnt}" = "${job_cnt}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want ${job_cnt} PIDs - unverified kills)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "job children still alive: ${ALIVE_PIDS}"; }

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, unfinished='${fin_unfin}', children dead, running_pids has ${job_cnt} (unverified)"
		return 0
	else
		FAIL
		return 1
	fi
}

# "completed-job stragglers are NOT reaped (documented limitation)".
# Orphans escape any /proc-based mechanism regardless of its own availability,
#   so this holds everywhere - no capability gate.
# 1: test id
# 2: callback
# 3: job id (a strag_* id)
_jt_strag_scenario() {
	local \
		TEST_ID="${1}" jt_cb="${2}" jt_job="${3}" \
		sched_rv checks_ok=1 alive_cnt=0 pid

	local PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${PIDS_F}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: completed-job stragglers are NOT reaped (documented limitation)" "${jt_job}"

	SCHED_FAIL_MSG_CB=echo \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB="${jt_cb}" \
		schedule_jobs "${jt_job}" &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	while read -r pid; do
		[ -n "${pid}" ] || continue
		kill -0 "${pid}" 2>/dev/null && alive_cnt=$((alive_cnt + 1))
	done < "${PIDS_F}"

	[ "${alive_cnt}" = 2 ] ||
		{ checks_ok=; echo "alive straggler count ${alive_cnt} (want 2 - the documented gap)"; }

	jt_teardown "${PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=0, stragglers survived as documented (then killed by the test)"
		return 0
	else
		FAIL
		return 1
	fi
}

#
# Tests
#

# An invalid JOB_TERM_CB (a name that is not a command) must fail callback
#   validation: rv 1, the job callback never runs, an error is delivered via
#   SCHED_FAIL_MSG_CB, and the finalize callback is not invoked.
#   Runs against either variant.
test_job_termination_01() {
	job_termination_01_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_01 \
		rv_badcmd msg_cnt=0 marker=no fin=no

	local \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$" \
		MARK_F="/tmp/sched.job_termination.mark.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${MSG_FILE}" "${MARK_F}" "${FINALIZE_F}"

	print_test_header "${TEST_ID}" "Invalid JOB_TERM_CB: clean abort before dispatch" "mark_01"

	SCHED_FAIL_MSG_CB=job_termination_01_fail_msg \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB=sch_no_such_cmd_t01 \
		schedule_jobs 'mark_01' &
	wait "${!}"
	rv_badcmd=${?}

	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	[ -f "${MARK_F}" ] && marker=yes
	[ -f "${FINALIZE_F}" ] && fin=yes
	rm -f "${MSG_FILE}" "${MARK_F}" "${FINALIZE_F}"

	if [ "${rv_badcmd}" = 1 ] && [ "${msg_cnt}" -ge 1 ] &&
		[ "${marker}" = no ] && [ "${fin}" = no ]
	then
		PASS "rv=1, error reported, no job ran, no finalize"
		return 0
	else
		FAIL "rv_badcmd=${rv_badcmd} (want 1), msg_cnt=${msg_cnt} (want >=1), job_ran=${marker} (want no), finalize=${fin} (want no)"
		return 1
	fi
}

# Contrast/regression with no termination command: the same straggler job
#   leaves its background child and orphaned grandchild running after the
#   scheduler exits (the test then kills them). Guards against termination
#   becoming unconditionally active, and validates the methodology of the
#   other tests. Runs in any environment.
test_job_termination_02() {
	local \
		TEST_ID=job_termination_02 \
		sched_rv checks_ok=1 alive_cnt=0 pid

	local PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${PIDS_F}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Without JOB_TERM_CB stragglers survive the run" "strag_02"

	SCHED_FAIL_MSG_CB=echo \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'strag_02' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	[ "$(sed '/^$/d' "${PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${PIDS_F}" | wc -l) (want 2)"; }

	while read -r pid; do
		[ -n "${pid}" ] || continue
		kill -0 "${pid}" 2>/dev/null && alive_cnt=$((alive_cnt + 1))
	done < "${PIDS_F}"

	[ "${alive_cnt}" = 2 ] ||
		{ checks_ok=; echo "alive straggler count ${alive_cnt} (want 2)"; }

	jt_teardown "${PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=0, both stragglers survived (then killed by the test)"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid library: per-job timeout kills the job's process tree at expiry; unverified,
#   so the expired PID stays in running_pids.
test_job_termination_03() {
	_jt_timeout_scenario job_termination_03 "${SCHED_TERM_CB_DEFAULT}" term_default_capable "${TERM_DEFAULT_SKIP_REASON}" block_03
}

# ppid library: USR1 abort kills all running job trees; unverified.
test_job_termination_04() {
	_jt_abort_scenario job_termination_04 "${SCHED_TERM_CB_DEFAULT}" term_default_capable "${TERM_DEFAULT_SKIP_REASON}" 'block_04a block_04b'
}

# ppid library: completed-job stragglers are NOT reaped (documented orphan limitation).
test_job_termination_05() {
	_jt_strag_scenario job_termination_05 "${SCHED_TERM_CB_DEFAULT}" strag_05
}

# ppid library: the PPID-map fixpoint walk reaches a multi-level subtree.
# The job keeps a live wrapper -> child -> grandchild chain (child and grandchild both recorded);
#   a USR1 abort must kill the whole chain,
#   proving discovery iterates past direct children rather than stopping at depth 1.
test_job_termination_06() {
	local \
		TEST_ID=job_termination_06 \
		sched_pid sched_rv checks_ok=1 \
		jobs='deep_06'

	local PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${PIDS_F}"

	print_test_header "${TEST_ID}" "term: abort kills a multi-level subtree (fixpoint walk depth)" "${jobs}"

	term_default_capable || { SKIP "${TERM_DEFAULT_SKIP_REASON}"; return 2; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB="${SCHED_TERM_CB_DEFAULT}" \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	# Both the mid child and the grandchild (2 recorded PIDs) must be dead
	[ "$(sed '/^$/d' "${PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${PIDS_F}" | wc -l) (want 2)"; }
	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "multi-level subtree survivor(s): ${ALIVE_PIDS}"; }

	jt_teardown "${PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, whole wrapper->child->grandchild chain killed"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid library: the /proc/<pid>/stat parser tolerates a comm containing ')'
#   plus a fake ' <state> <ppid> ' sequence.
# A job child exec's a shebang script whose basename is 'x) R 99999'
#   (<=15 bytes, so it survives comm truncation);
#   its stat line reads '<pid> (x) R 99999) S <wrapper> ...'.
# A naive first-')' parse mis-reads the ppid and drops the process;
#   the library's greedy match recovers it, so an abort must still kill the crafted-comm child.
test_job_termination_07() {
	job_termination_07_do_job() {
		local scr="${P6_DIR:?}/x) R 99999"
		printf '#!/bin/sh\nsleep 300\n' > "${scr}"
		chmod +x "${scr}"
		"${scr}" &
		printf '%s\n' "${!}" >> "${PIDS_F:?}"
		wait "${!}"
	}

	local \
		TEST_ID=job_termination_07 \
		sched_pid sched_rv checks_ok=1 \
		jobs='parse_07'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		P6_DIR="/tmp/sched.job_termination.p6.${TEST_ID}.$$"
	rm -rf "${P6_DIR}"
	mkdir -p "${P6_DIR}"
	rm -f "${PIDS_F}"

	print_test_header "${TEST_ID}" "term: /proc/<pid>/stat parser handles ')' in comm" "${jobs}"

	term_default_capable || { SKIP "${TERM_DEFAULT_SKIP_REASON}"; rm -rf "${P6_DIR}"; return 2; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=job_termination_07_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB="${SCHED_TERM_CB_DEFAULT}" \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "crafted-comm child survived (parser mis-read its stat line): ${ALIVE_PIDS}"; }

	jt_teardown "${PIDS_F}" ""
	rm -rf "${P6_DIR}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, crafted-comm child discovered and killed"
		return 0
	else
		FAIL
		return 1
	fi
}

