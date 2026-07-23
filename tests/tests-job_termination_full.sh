#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-job_termination_full.sh

# Category: job termination, full-variant only.
#   Tests of the standalone termination libraries (cgroup, children, ppid) and
#   the full JOB_TERM_CB protocol (init/setup/term <out_var>/cleanup, verified
#   kills). The mini variant drops these; its own tests live in
#   tests-job_termination_mini.sh. Shared infrastructure (gates, do_job_term,
#   cg_* helpers, _jt_*_scenario) is defined in tests-job_termination.sh.

# This file is sourced by tests.sh; it defines test_job_termination_full_NN functions only.

#
# Full-only infrastructure: capability gates and cgroup-base helpers for the
#   standalone termination libraries (cgroup, children).
#

# Capability gate for the cgroup library, evaluated once per suite run
cg_capable() {
	[ -n "${CG_CAPABLE_CACHED}" ] || {
		if cgroup_cleanup_supported; then
			CG_CAPABLE_CACHED=yes
		else
			CG_CAPABLE_CACHED=no
		fi
	}
	[ "${CG_CAPABLE_CACHED}" = yes ]
}
CG_CAPABLE_CACHED=
CG_SKIP_REASON="cgroup termination unsupported here - run as root or via 'systemd-run --user --scope'"

# Capability gate for the children library, evaluated once per suite run
children_capable() {
	[ -n "${CHILDREN_CAPABLE_CACHED}" ] || {
		if proc_children_supported; then
			CHILDREN_CAPABLE_CACHED=yes
		else
			CHILDREN_CAPABLE_CACHED=no
		fi
	}
	[ "${CHILDREN_CAPABLE_CACHED}" = yes ]
}
CHILDREN_CAPABLE_CACHED=
CHILDREN_SKIP_REASON="children-walk termination unsupported here - kernel lacks CONFIG_PROC_CHILDREN (/proc/<pid>/task/<tid>/children)"

# Create a private parent cgroup for one test under this process's own cgroup
#   and assign its path to ${CG_TEST_BASE}; the test passes it to the cgroup
#   library via SCHED_CGROUP_BASE, and can then assert the run left it empty
# 1: test id (used in the dir name)
cg_mk_test_base() {
	local mnt line fstype own

	mnt=
	while read -r _ line fstype _; do
		[ "${fstype}" = cgroup2 ] && { mnt="${line}"; break; }
	done 2>/dev/null < /proc/mounts

	own=
	while IFS= read -r line; do
		case "${line}" in
			0::*) own="${line#0::}"; break
		esac
	done 2>/dev/null < /proc/self/cgroup

	[ -n "${mnt}" ] || return 1
	CG_TEST_BASE="${mnt}${own}"
	sch_rm_trailing CG_TEST_BASE "/"
	CG_TEST_BASE="${CG_TEST_BASE}/schtest_${1:?}_$$"
	rmdir "${CG_TEST_BASE}" 2>/dev/null
	mkdir "${CG_TEST_BASE}" 2>/dev/null
}

# Return 0 if cgroup directory ${1} contains no child cgroups.
# cgroupfs directories always contain control files (cgroup.procs etc.) -
#   only subdirectories indicate leftover cgroups
cg_base_empty() {
	local e
	for e in "${1}"/*; do
		[ -d "${e}" ] && return 1
	done
	:
}

# Verify cgroup_cleanup_supported(): consistent return code across calls,
#   no output on success or failure paths, forced-failure via bad
#   SCHED_CGROUP_BASE returns 1, and no stray messages through a user-set
#   SCHED_FAIL_MSG_CB. Runs in any environment.
test_job_termination_full_01() {
	require_variant full || return 2

	job_termination_full_01_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_01 \
		rv1 rv2 rv_forced out1 out_forced msg_cnt=0

	local MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID}" "cgroup_cleanup_supported(): consistency, silence, forced failure" "(no jobs)"

	out1=$(cgroup_cleanup_supported 2>&1)
	rv1=${?}
	cgroup_cleanup_supported >/dev/null 2>&1
	rv2=${?}

	out_forced=$(SCHED_CGROUP_BASE=/nonexistent/schtest cgroup_cleanup_supported 2>&1)
	rv_forced=${?}

	# A user-set fail-msg callback must stay silent during the check
	SCHED_FAIL_MSG_CB=job_termination_full_01_fail_msg \
		cgroup_cleanup_supported >/dev/null 2>&1
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${rv1}" = "${rv2}" ] && { [ "${rv1}" = 0 ] || [ "${rv1}" = 1 ]; } &&
		[ -z "${out1}" ] && [ -z "${out_forced}" ] &&
		[ "${rv_forced}" = 1 ] && [ "${msg_cnt}" = 0 ]
	then
		PASS "rv=${rv1} (consistent), forced rv=${rv_forced}, silent"
		return 0
	else
		FAIL "rv1=${rv1} rv2=${rv2} rv_forced=${rv_forced} (want 1), out1='${out1}', out_forced='${out_forced}', msg_cnt=${msg_cnt}"
		return 1
	fi
}

# Verify clean early abort of a run whose termination command cannot work:
#   (a) an invalid JOB_TERM_CB fails callback validation;
#   (b) a valid command whose 'init' fails (cgroup library with an invalid
#       SCHED_CGROUP_BASE) aborts before dispatch.
#   In both cases: rv 1, the job callback never runs, an error is delivered
#   via SCHED_FAIL_MSG_CB, the finalize callback is not invoked.
#   Runs in any environment.
test_job_termination_full_02() {
	require_variant full || return 2

	job_termination_full_02_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_02 \
		rv_badcmd rv_badinit msg_cnt=0 marker=no fin=no

	local \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$" \
		MARK_F="/tmp/sched.job_termination.mark.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${MSG_FILE}" "${MARK_F}" "${FINALIZE_F}"

	print_test_header "${TEST_ID}" "Unusable termination command: clean abort before dispatch" "mark_02 mark_02b"

	SCHED_FAIL_MSG_CB=job_termination_full_02_fail_msg \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB=sch_no_such_cmd_t02 \
		schedule_jobs 'mark_02b' &
	wait "${!}"
	rv_badcmd=${?}

	SCHED_FAIL_MSG_CB=job_termination_full_02_fail_msg \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE=/nonexistent/schtest \
		schedule_jobs 'mark_02' &
	wait "${!}"
	rv_badinit=${?}

	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	[ -f "${MARK_F}" ] && marker=yes
	[ -f "${FINALIZE_F}" ] && fin=yes
	rm -f "${MSG_FILE}" "${MARK_F}" "${FINALIZE_F}"

	if [ "${rv_badcmd}" = 1 ] && [ "${rv_badinit}" = 1 ] &&
		[ "${msg_cnt}" -ge 2 ] && [ "${marker}" = no ] && [ "${fin}" = no ]
	then
		PASS "rv=1/1, errors reported, no job ran, no finalize"
		return 0
	else
		FAIL "rv_badcmd=${rv_badcmd} rv_badinit=${rv_badinit} (want 1/1), msg_cnt=${msg_cnt} (want >=2), job_ran=${marker} (want no), finalize=${fin} (want no)"
		return 1
	fi
}

# cgroup library: stragglers of a completed job are reaped by scheduler
#   exit (the cleanup sweep - completion itself no longer kills) - a job that
#   exits 0 leaving a background child and an orphaned grandchild behind:
#   both must be dead after the run, both jobs classified ok, running_pids
#   empty, and the run must leave the base cgroup empty.
test_job_termination_full_03() {
	require_variant full || return 2

	local \
		TEST_ID=job_termination_full_03 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 fin_pids fin_ok base_state=empty \
		jobs='strag_03 instant_03'

	print_test_header "${TEST_ID}" "cgroup: completed job's stragglers reaped by scheduler exit; base left empty" "${jobs}"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs "${jobs}" &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	[ "$(sed '/^$/d' "${PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${PIDS_F}" | wc -l) (want 2)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "stragglers still alive: ${ALIVE_PIDS}"; }

	jt_finalize_get fin_ok ok "${FINALIZE_F}" && jt_same_set "${fin_ok}" "${jobs}" ||
		{ checks_ok=; echo "ok bucket '${fin_ok}' (want '${jobs}')"; }
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty)"; }

	cg_base_empty "${CG_TEST_BASE}" || { base_state=dirty; checks_ok=; echo "base cgroup not empty"; }

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "stragglers reaped, ok='${fin_ok}', base ${base_state}"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup library: the job tree is killed at per-job timeout expiry (not
#   merely at scheduler exit): the completion callback - invoked right after
#   the expiry sweep - must observe the job's recorded child already dead;
#   the job is classified expired and its PID is scrubbed from running_pids
#   (kill verified).
test_job_termination_full_04() {
	require_variant full || return 2

	job_termination_full_04_done() {
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
		printf 'expired|%s|dead_at_cb=%s\n' "${1}" "$([ "${alive}" = no ] && printf yes || printf no)" >> "${DONE_F:?}"
	}

	local \
		TEST_ID=job_termination_full_04 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 done_rec fin_pids fin_expired

	print_test_header "${TEST_ID}" "cgroup: per-job timeout kills the job's process tree at expiry" "block_04"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		DONE_F="/tmp/sched.job_termination.done.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}" "${DONE_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	job_set_timeout block_04 1 || { FAIL "job_set_timeout failed"; jt_teardown "${PIDS_F}" "${CG_TEST_BASE}"; return 1; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=job_termination_full_04_done \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs 'block_04' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	read_first_line done_rec "${DONE_F}" &&
	[ "${done_rec}" = "expired|block_04|dead_at_cb=yes" ] ||
		{ checks_ok=; echo "done record '${done_rec}' (want 'expired|block_04|dead_at_cb=yes')"; }

	jt_finalize_get fin_expired expired "${FINALIZE_F}" && [ "${fin_expired}" = block_04 ] ||
		{ checks_ok=; echo "expired bucket '${fin_expired}' (want 'block_04')"; }
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kill verified)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${ALIVE_PIDS}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}" "${DONE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "killed at expiry, expired='${fin_expired}', running_pids empty"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup library: USR1 abort kills all running job trees, kills are
#   verified (running_pids empty), the jobs are classified unfinished, and
#   the base cgroup is left empty.
test_job_termination_full_05() {
	require_variant full || return 2

	local \
		TEST_ID=job_termination_full_05 \
		CG_TEST_BASE \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin \
		jobs='block_05a block_05b'

	print_test_header "${TEST_ID}" "cgroup: USR1 abort kills all running job trees (verified)" "${jobs}"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && jt_same_set "${fin_unfin}" "${jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"; }
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kills verified)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "job children still alive: ${ALIVE_PIDS}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, unfinished='${fin_unfin}', running_pids empty, trees dead"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup library: scheduler global timeout kills the running job tree, with
#   the same guarantees as on USR1 and return code 82.
test_job_termination_full_06() {
	require_variant full || return 2

	local \
		TEST_ID=job_termination_full_06 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 fin_pids fin_unfin

	print_test_header "${TEST_ID}" "cgroup: scheduler global timeout kills the running job tree (verified)" "block_06"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=5 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs 'block_06' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 82 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 82)"; }

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && [ "${fin_unfin}" = block_06 ] ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want 'block_06')"; }
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kill verified)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${ALIVE_PIDS}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=82, unfinished='${fin_unfin}', running_pids empty, tree dead"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup library, autodetected base (no SCHED_CGROUP_BASE): termination
#   works with the base derived from the scheduler's own cgroup - stragglers
#   of a completed job are reaped.
test_job_termination_full_07() {
	require_variant full || return 2

	local \
		TEST_ID=job_termination_full_07 \
		sched_rv checks_ok=1 fin_pids fin_ok

	print_test_header "${TEST_ID}" "cgroup: autodetected base (no SCHED_CGROUP_BASE): stragglers reaped" "strag_07"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}"
	: > "${PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	JOB_TERM_CB=sched_job_term_cgroup \
		schedule_jobs 'strag_07' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	jt_finalize_get fin_ok ok "${FINALIZE_F}" && [ "${fin_ok}" = strag_07 ] ||
		{ checks_ok=; echo "ok bucket '${fin_ok}' (want 'strag_07')"; }
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty)"; }

	jt_assert_dead "${PIDS_F}" ||
		{ checks_ok=; echo "stragglers still alive: ${ALIVE_PIDS}"; }

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "autodetected base, stragglers reaped, running_pids empty"
		return 0
	else
		FAIL
		return 1
	fi
}

# children library: per-job timeout kills the job's process tree at expiry;
#   kills unverified, so the expired PID stays in running_pids.
# SKIP where the children mechanism is unavailable.
test_job_termination_full_08() {
	require_variant full || return 2

	_jt_timeout_scenario job_termination_full_08 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" block_08
}

# children library: USR1 abort kills all running job trees; jobs classified unfinished;
#   both wrapper PIDs reported (kills unverified).
# SKIP where the children mechanism is unavailable.
test_job_termination_full_09() {
	require_variant full || return 2

	_jt_abort_scenario job_termination_full_09 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" 'block_09a block_09b'
}

# children library, documented limitation:
#   stragglers of a COMPLETED job are not reaped (the wrapper already exited,
#   so its children are reparented to init and escape the descendant walk).
# The recorded stragglers must survive the run; the test then kills them.
# Runs in any environment.
test_job_termination_full_10() {
	require_variant full || return 2

	_jt_strag_scenario job_termination_full_10 sched_job_term_children strag_10
}

# Custom (user-defined) termination command exercising the out-var report
# Contract: the command kills the wrapper PIDs, reports them as verified via 'export -n "${out_var}=..."',
#   and deliberately prints noise to stdout - which must not corrupt the report:
#   running_pids must come out empty and no "invalid verified PID" complaints must be raised.
# Runs in any environment.
test_job_termination_full_11() {
	require_variant full || return 2

	job_termination_full_11_cb() {
		local t12_sub="${1}" t12_out_var="${2}"

		case "${t12_sub}" in
			init|setup) : ;;
			term)
				shift 2
				# stdout noise must not reach the verified-PID report
				echo "job_termination_full_11 stdout noise: not pids"
				kill -9 "${@}" 2>/dev/null
				export -n "${t12_out_var}=${*}"
			;;
			cleanup)
				echo "job_termination_full_11 more stdout noise"
			;;
		esac
	}
	job_termination_full_11_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_11 \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin bad_msg_cnt=0 \
		jobs='block_11a block_11b'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}" "${MSG_FILE}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command: out-var report immune to stdout noise" "${jobs}"

	SCHED_FAIL_MSG_CB=job_termination_full_11_fail_msg \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_term \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB=job_termination_full_11_cb \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && jt_same_set "${fin_unfin}" "${jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"; }

	# The custom command reported both wrapper PIDs as verified: despite the
	# stdout noise, running_pids must be empty
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - report honored)"; }

	# No 'invalid verified PID' complaints: the noise never reached the report
	[ -f "${MSG_FILE}" ] && bad_msg_cnt=$(grep -c "invalid verified PID" "${MSG_FILE}")
	[ "${bad_msg_cnt}" = 0 ] ||
		{ checks_ok=; echo "core saw ${bad_msg_cnt} invalid-PID token(s): $(cat "${MSG_FILE}")"; }

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}" "${MSG_FILE}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, running_pids empty via out-var report, stdout noise ignored"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup base collision under a colliding PID:
#   a directory named exactly like the base this process would claim (sched_<pid>.0)
#   is pre-created to stand in for a same-PID sibling instance sharing SCHED_CGROUP_BASE.
# 'init' must route around it to sched_<pid>.1 without disturbing the squat,
#   and 'cleanup' must remove only this instance's own base.
# Deterministically emulates the shared-base collision without containers or a real second process.
# SCH_TC_BASE/SCH_TC_PENDING are shadowed locally so the in-process init/cleanup calls resolve them by dynamic
#   scope and don't touch suite-global state.
test_job_termination_full_12() {
	require_variant full || return 2

	local \
		TEST_ID=job_termination_full_12 \
		CG_TEST_BASE \
		SCH_TC_BASE SCH_TC_PENDING \
		checks_ok=1 p init_rv cleanup_rv reaped squat newbase

	print_test_header "${TEST_ID}" "cgroup: base collision with a same-PID sibling is avoided; sibling untouched" "(no jobs)"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	get_test_pid p || { FAIL "cannot get test PID"; return 1; }
	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	squat="${CG_TEST_BASE}/sched_${p}.0"
	newbase="${CG_TEST_BASE}/sched_${p}.1"

	# Plant the sibling's base, non-empty (its own job cgroup),
	#   so a regression to steal-then-recreate would be caught
	mkdir "${squat}" 2>/dev/null && mkdir "${squat}/job_squat" 2>/dev/null ||
		{ FAIL "cannot create squat cgroup"; jt_teardown "" "${CG_TEST_BASE}"; return 1; }

	# init runs in THIS process, so SCH_TC_PID == our PID;
	#   SCHED_CGROUP_BASE forces the per-run base under CG_TEST_BASE, where .0 is already taken
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" sched_job_term_cgroup init
	init_rv=$?

	[ "${init_rv}" = 0 ] || { checks_ok=; echo "init rv=${init_rv} (want 0)"; }
	[ -d "${newbase}" ] || { checks_ok=; echo "new base 'sched_${p}.1' not created (did not route around .0)"; }
	[ -d "${squat}" ] || { checks_ok=; echo "squat 'sched_${p}.0' vanished"; }
	[ -d "${squat}/job_squat" ] || { checks_ok=; echo "squat's job cgroup vanished (stolen)"; }

	# cleanup removes only this instance's own base; the sibling stays intact
	sched_job_term_cgroup cleanup reaped
	cleanup_rv=$?

	[ "${cleanup_rv}" = 0 ] || { checks_ok=; echo "cleanup rv=${cleanup_rv} (want 0)"; }
	[ -z "${reaped}" ] || { checks_ok=; echo "cleanup reaped '${reaped}' (want empty)"; }
	[ -d "${newbase}" ] && { checks_ok=; echo "own base 'sched_${p}.1' not removed by cleanup"; }
	[ -d "${squat}/job_squat" ] || { checks_ok=; echo "cleanup removed the sibling's cgroup"; }

	jt_teardown "" "${CG_TEST_BASE}"

	if [ -n "${checks_ok}" ]; then
		PASS "routed .0 -> .1, sibling untouched, cleanup removed only own base"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid library: the proc_ppid_supported probe. Reports supported on a normal system,
#   and reports unsupported when awk cannot be found.
test_job_termination_full_13() {
	require_variant full || return 2

	local TEST_ID=job_termination_full_13 checks_ok=1

	print_test_header "${TEST_ID}" "ppid: proc_ppid_supported probe (supported here; fails without awk)" "(no jobs)"

	proc_ppid_supported ||
		{ checks_ok=; echo "proc_ppid_supported returned non-zero on a normal system"; }
	SCHED_AWK_CMD=/nonexistent/nope proc_ppid_supported &&
		{ checks_ok=; echo "proc_ppid_supported reported supported with awk missing"; }

	if [ -n "${checks_ok}" ]; then
		PASS "supported here, unsupported without awk"
		return 0
	else
		FAIL
		return 1
	fi
}

