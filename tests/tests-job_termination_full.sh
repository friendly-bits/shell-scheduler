#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-job_termination_full.sh

# Category: job termination, full-variant only.
#   Tests of the standalone termination library's mechanisms (cgroup, children,
#   ppid) and the full JOB_TERM_CB protocol (init/setup/term <out_var>/cleanup,
#   verified kills). The mini variant drops these; its own tests live in
#   tests-job_termination_mini.sh. Shared infrastructure (gates, do_job_term,
#   cg_* helpers, _jt_*_scenario) is defined in tests-job_termination.sh.

# This file is sourced by tests.sh; it defines test_job_termination_full_NN functions only.

#
# Full-only infrastructure: capability gates and cgroup-base helpers for the
#   standalone library's cgroup and children mechanisms.
#

# Capability gate for the cgroup mechanism, evaluated once per suite run
cg_capable() {
	[ -n "${CG_CAPABLE_CACHED}" ] || {
		if jt_mech_capable cgroup; then
			CG_CAPABLE_CACHED=yes
		else
			CG_CAPABLE_CACHED=no
		fi
	}
	[ "${CG_CAPABLE_CACHED}" = yes ]
}
CG_CAPABLE_CACHED=
CG_SKIP_REASON="cgroup termination unsupported here - run as root or via 'systemd-run --user --scope'"

# Capability gate for the children mechanism, evaluated once per suite run
children_capable() {
	[ -n "${CHILDREN_CAPABLE_CACHED}" ] || {
		if jt_mech_capable children; then
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
	tr_trailing CG_TEST_BASE "${mnt}${own}" "/"
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

# Verify sched_use_job_term cgroup: consistent return code across calls,
#   ${JOB_TERM_CB} armed on success and cleared on failure, forced-failure via
#   bad SCHED_CGROUP_BASE returns 1, '-q' silent on stderr and through a
#   user-set SCHED_FAIL_MSG_CB, and one message without '-q'. Runs in any environment.
test_job_termination_full_01() {
	job_termination_full_01_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_01 \
		JOB_TERM_CB \
		rv1 rv2 rv_forced out1 out_forced out_loud cb1 cb_forced msg_cnt=0 want_cb=

	local MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${MSG_FILE}"

	print_test_header "${TEST_ID}" "sched_use_job_term cgroup: consistency, JOB_TERM_CB, -q silence, forced failure" "(no jobs)"

	require_variant full || return 2

	out1=$(sched_use_job_term -q cgroup 2>&1)
	rv1=${?}
	sched_use_job_term -q cgroup >/dev/null 2>&1
	rv2=${?}
	cb1="${JOB_TERM_CB}"
	[ "${rv2}" = 0 ] && want_cb=sched_job_term_cgroup

	out_forced=$(SCHED_CGROUP_BASE=/nonexistent/schtest sched_use_job_term -q cgroup 2>&1)
	rv_forced=${?}
	SCHED_CGROUP_BASE=/nonexistent/schtest sched_use_job_term -q cgroup >/dev/null 2>&1
	cb_forced="${JOB_TERM_CB}"

	# Without -q the unavailable mechanism is reported, on one line
	out_loud=$(SCHED_CGROUP_BASE=/nonexistent/schtest sched_use_job_term cgroup 2>&1)

	# A user-set fail-msg callback must stay silent under -q, including on the failure path
	SCHED_FAIL_MSG_CB=job_termination_full_01_fail_msg \
		SCHED_CGROUP_BASE=/nonexistent/schtest sched_use_job_term -q cgroup >/dev/null 2>&1
	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	rm -f "${MSG_FILE}"

	if [ "${rv1}" = "${rv2}" ] && { [ "${rv1}" = 0 ] || [ "${rv1}" = 1 ]; } &&
		[ -z "${out1}" ] && [ -z "${out_forced}" ] &&
		[ "${cb1}" = "${want_cb}" ] && [ -z "${cb_forced}" ] &&
		[ "${rv_forced}" = 1 ] && [ "$(printf '%s' "${out_loud}" | wc -l)" = 0 ] &&
		[ -n "${out_loud}" ] && [ "${msg_cnt}" = 0 ]
	then
		PASS "rv=${rv1} (consistent), JOB_TERM_CB='${cb1}', forced rv=${rv_forced}, -q silent, reports without -q"
		return 0
	else
		FAIL "rv1=${rv1} rv2=${rv2} rv_forced=${rv_forced} (want 1), out1='${out1}', out_forced='${out_forced}', out_loud='${out_loud}', cb1='${cb1}' (want '${want_cb}'), cb_forced='${cb_forced}', msg_cnt=${msg_cnt}"
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

	require_variant full || return 2

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
	local \
		TEST_ID=job_termination_full_03 \
		CG_TEST_BASE \
		sched_rv checks_pass=0 checks_exp=6 fin_pids fin_ok base_state=empty \
		jobs='strag_03 instant_03'

	print_test_header "${TEST_ID}" "cgroup: completed job's stragglers reaped by scheduler exit; base left empty" "${jobs}"

	require_variant full || return 2

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

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 0)"

	[ "$(sed '/^$/d' "${PIDS_F}" | wc -l)" = 2 ] && checks_pass=$((checks_pass + 1)) ||
		echo "recorded pid count $(sed '/^$/d' "${PIDS_F}" | wc -l) (want 2)"

	jt_assert_dead "${PIDS_F}" && checks_pass=$((checks_pass + 1)) ||
		echo "stragglers still alive: ${ALIVE_PIDS}"

	jt_finalize_get fin_ok ok "${FINALIZE_F}" && jt_same_set "${fin_ok}" "${jobs}" && checks_pass=$((checks_pass + 1)) ||
		echo "ok bucket '${fin_ok}' (want '${jobs}')"
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty)"

	cg_base_empty "${CG_TEST_BASE}" && checks_pass=$((checks_pass + 1)) ||
		{ base_state=dirty; echo "base cgroup not empty"; }

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
		sched_rv checks_pass=0 checks_exp=6 done_rec fin_pids fin_expired

	print_test_header "${TEST_ID}" "cgroup: per-job timeout kills the job's process tree at expiry" "block_04"

	require_variant full || return 2

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

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 0)"

	read_first_line --rm done_rec "${DONE_F}" &&
	[ "${done_rec}" = "expired|block_04|dead_at_cb=yes" ] && checks_pass=$((checks_pass + 1)) ||
		echo "done record '${done_rec}' (want 'expired|block_04|dead_at_cb=yes')"

	jt_finalize_get fin_expired expired "${FINALIZE_F}" && [ "${fin_expired}" = block_04 ] && checks_pass=$((checks_pass + 1)) ||
		echo "expired bucket '${fin_expired}' (want 'block_04')"
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty - kill verified)"

	jt_assert_dead "${PIDS_F}" && checks_pass=$((checks_pass + 1)) ||
		echo "job child still alive: ${ALIVE_PIDS}"

	cg_base_empty "${CG_TEST_BASE}" && checks_pass=$((checks_pass + 1)) || echo "base cgroup not empty"

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
	local \
		TEST_ID=job_termination_full_05 \
		CG_TEST_BASE \
		sched_pid sched_rv checks_pass=0 checks_exp=5 fin_pids fin_unfin \
		jobs='block_05a block_05b'

	print_test_header "${TEST_ID}" "cgroup: USR1 abort kills all running job trees (verified)" "${jobs}"

	require_variant full || return 2

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

	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && jt_same_set "${fin_unfin}" "${jobs}" && checks_pass=$((checks_pass + 1)) ||
		echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty - kills verified)"

	jt_assert_dead "${PIDS_F}" && checks_pass=$((checks_pass + 1)) ||
		echo "job children still alive: ${ALIVE_PIDS}"

	cg_base_empty "${CG_TEST_BASE}" && checks_pass=$((checks_pass + 1)) || echo "base cgroup not empty"

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
	local \
		TEST_ID=job_termination_full_06 \
		CG_TEST_BASE \
		sched_rv checks_pass=0 checks_exp=5 fin_pids fin_unfin

	print_test_header "${TEST_ID}" "cgroup: scheduler global timeout kills the running job tree (verified)" "block_06"

	require_variant full || return 2

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

	[ "${sched_rv}" = 82 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 82)"

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && [ "${fin_unfin}" = block_06 ] && checks_pass=$((checks_pass + 1)) ||
		echo "unfinished bucket '${fin_unfin}' (want 'block_06')"
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty - kill verified)"

	jt_assert_dead "${PIDS_F}" && checks_pass=$((checks_pass + 1)) ||
		echo "job child still alive: ${ALIVE_PIDS}"

	cg_base_empty "${CG_TEST_BASE}" && checks_pass=$((checks_pass + 1)) || echo "base cgroup not empty"

	jt_teardown "${PIDS_F}" "${CG_TEST_BASE}" "${FINALIZE_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
	local \
		TEST_ID=job_termination_full_07 \
		sched_rv checks_pass=0 checks_exp=4 fin_pids fin_ok

	print_test_header "${TEST_ID}" "cgroup: autodetected base (no SCHED_CGROUP_BASE): stragglers reaped" "strag_07"

	require_variant full || return 2

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

	[ "${sched_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 0)"

	jt_finalize_get fin_ok ok "${FINALIZE_F}" && [ "${fin_ok}" = strag_07 ] && checks_pass=$((checks_pass + 1)) ||
		echo "ok bucket '${fin_ok}' (want 'strag_07')"
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty)"

	jt_assert_dead "${PIDS_F}" && checks_pass=$((checks_pass + 1)) ||
		echo "stragglers still alive: ${ALIVE_PIDS}"

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
	_jt_timeout_scenario job_termination_full_08 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" block_08 full
}

# children library: USR1 abort kills all running job trees; jobs classified unfinished;
#   both wrapper PIDs reported (kills unverified).
# SKIP where the children mechanism is unavailable.
test_job_termination_full_09() {
	_jt_abort_scenario job_termination_full_09 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" 'block_09a block_09b' full
}

# children library, documented limitation:
#   stragglers of a COMPLETED job are not reaped (the wrapper already exited,
#   so its children are reparented to init and escape the descendant walk).
# The recorded stragglers must survive the run; the test then kills them.
# Runs in any environment.
test_job_termination_full_10() {
	_jt_strag_scenario job_termination_full_10 sched_job_term_children strag_10 full
}

# Custom (user-defined) termination command exercising the out-var report
# Contract: the command kills the wrapper PIDs, reports them as verified via 'export -n "${out_var}=..."',
#   and deliberately prints noise to stdout - which must not corrupt the report:
#   running_pids must come out empty and no "invalid verified PID" complaints must be raised.
# Runs in any environment.
test_job_termination_full_11() {
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
		sched_pid sched_rv checks_pass=0 checks_exp=4 fin_pids fin_unfin bad_msg_cnt=0 \
		jobs='block_11a block_11b'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}" "${MSG_FILE}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command: out-var report immune to stdout noise" "${jobs}"

	require_variant full || return 2

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

	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	jt_finalize_get fin_unfin unfin "${FINALIZE_F}" && jt_same_set "${fin_unfin}" "${jobs}" && checks_pass=$((checks_pass + 1)) ||
		echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"

	# The custom command reported both wrapper PIDs as verified: despite the
	# stdout noise, running_pids must be empty
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty - report honored)"

	# No 'invalid verified PID' complaints: the noise never reached the report
	[ -f "${MSG_FILE}" ] && bad_msg_cnt=$(grep -c "invalid verified PID" "${MSG_FILE}")
	[ "${bad_msg_cnt}" = 0 ] && checks_pass=$((checks_pass + 1)) ||
		echo "core saw ${bad_msg_cnt} invalid-PID token(s): $(cat "${MSG_FILE}")"

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}" "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
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
# SCH_JT_BASE/SCH_JT_PENDING are shadowed locally so the in-process init/cleanup calls resolve them by dynamic
#   scope and don't touch suite-global state.
test_job_termination_full_12() {
	local \
		TEST_ID=job_termination_full_12 \
		CG_TEST_BASE \
		SCH_JT_BASE SCH_JT_PENDING \
		checks_pass=0 checks_exp=8 p init_rv cleanup_rv reaped squat newbase

	print_test_header "${TEST_ID}" "cgroup: base collision with a same-PID sibling is avoided; sibling untouched" "(no jobs)"

	require_variant full || return 2

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 2; }

	get_test_pid p || { FAIL "cannot get test PID"; return 1; }
	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	squat="${CG_TEST_BASE}/sched_${p}.0"
	newbase="${CG_TEST_BASE}/sched_${p}.1"

	# Plant the sibling's base, non-empty (its own job cgroup),
	#   so a regression to steal-then-recreate would be caught
	mkdir "${squat}" 2>/dev/null && mkdir "${squat}/job_squat" 2>/dev/null ||
		{ FAIL "cannot create squat cgroup"; jt_teardown "" "${CG_TEST_BASE}"; return 1; }

	# init runs in THIS process, so the base is named after our PID;
	#   SCHED_CGROUP_BASE forces the per-run base under CG_TEST_BASE, where .0 is already taken
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" sched_job_term_cgroup init
	init_rv=$?

	[ "${init_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "init rv=${init_rv} (want 0)"
	[ -d "${newbase}" ] && checks_pass=$((checks_pass + 1)) || echo "new base 'sched_${p}.1' not created (did not route around .0)"
	[ -d "${squat}" ] && checks_pass=$((checks_pass + 1)) || echo "squat 'sched_${p}.0' vanished"
	[ -d "${squat}/job_squat" ] && checks_pass=$((checks_pass + 1)) || echo "squat's job cgroup vanished (stolen)"

	# cleanup removes only this instance's own base; the sibling stays intact
	sched_job_term_cgroup cleanup reaped
	cleanup_rv=$?

	[ "${cleanup_rv}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "cleanup rv=${cleanup_rv} (want 0)"
	[ -z "${reaped}" ] && checks_pass=$((checks_pass + 1)) || echo "cleanup reaped '${reaped}' (want empty)"
	[ ! -d "${newbase}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "own base 'sched_${p}.1' not removed by cleanup"
	[ -d "${squat}/job_squat" ] && checks_pass=$((checks_pass + 1)) || echo "cleanup removed the sibling's cgroup"

	jt_teardown "" "${CG_TEST_BASE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "routed .0 -> .1, sibling untouched, cleanup removed only own base"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid mechanism: the sched_use_job_term probe. Selects it on a normal system,
#   and reports it unavailable when awk cannot be found.
test_job_termination_full_13() {
	local TEST_ID=job_termination_full_13 JOB_TERM_CB checks_pass=0 checks_exp=4

	print_test_header "${TEST_ID}" "ppid: sched_use_job_term probe (selected here; fails without awk)" "(no jobs)"

	require_variant full || return 2

	sched_use_job_term -q ppid && checks_pass=$((checks_pass + 1)) ||
		echo "sched_use_job_term ppid returned non-zero on a normal system"
	[ "${JOB_TERM_CB}" = sched_job_term_ppid ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_TERM_CB='${JOB_TERM_CB}' (want sched_job_term_ppid)"

	if SCHED_AWK_CMD=/nonexistent/nope sched_use_job_term -q ppid; then
		echo "sched_use_job_term ppid selected the mechanism with awk missing"
	else
		checks_pass=$((checks_pass + 1))
	fi
	[ -z "${JOB_TERM_CB}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "JOB_TERM_CB='${JOB_TERM_CB}' after a failed selection (want empty)"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "supported here, unsupported without awk"
		return 0
	else
		FAIL
		return 1
	fi
}

# children library: abort kills processes forked between discovery scans.
# The job's helper child starts forking recorded children only once the first
#   SIGSTOP pass has frozen the wrapper, so they are absent from the first scan.
# SKIP where the children mechanism is unavailable.
test_job_termination_full_14() {
	_jt_forkrace_scenario job_termination_full_14 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" forkrace_14 full
}

# Custom (user-defined) termination command:
#   the core drives the whole documented subcommand sequence.
# The out-var report itself is not checked here.
# Asserts:
#   'init' once, first, no args;
#   'setup <job_id> <pid>' once per job, before any 'term';
#   'term <out var> <pid>...' once, seeded with exactly the PIDs 'setup' was given;
#   'cleanup <out var>' once, last.
# Runs in any environment.
test_job_termination_full_15() {
	# Records '<subcmd>|<args>'. 'setup' runs in the job process and the rest in the
	#   scheduler process, so every invocation appends to the same file
	job_termination_full_15_cb() {
		local t15_sub="${1}"

		shift 2>/dev/null
		printf '%s|%s\n' "${t15_sub}" "${*}" >> "${REC_F:?}"

		[ "${t15_sub}" = term ] || return 0
		shift 2>/dev/null
		kill -9 "${@}" 2>/dev/null
		:
	}

	# Return 0 if ${1} is a usable shell variable name
	job_termination_full_15_is_var() {
		case "${1}" in
			''|[0-9]*|*[!A-Za-z0-9_]*) return 1
		esac
	}

	local \
		TEST_ID=job_termination_full_15 \
		sched_pid sched_rv checks_pass=0 checks_exp=13 \
		rec sub args idx=0 \
		init_cnt=0 setup_cnt=0 term_cnt=0 cleanup_cnt=0 bad_subs=0 \
		init_noargs=0 setup_wellformed=0 term_wellformed=0 \
		init_idx=0 setup_idx=0 term_idx=0 cleanup_idx=0 \
		setup_ids setup_pids term_out term_pids cleanup_args \
		jobs='block_15a block_15b'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		REC_F="/tmp/sched.job_termination.rec.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${REC_F}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command: core drives the documented subcommand sequence" "${jobs}"

	require_variant full || return 2

	SCHED_FAIL_MSG_CB=echo \
	DO_JOB_CB=do_job_term \
	JOB_TERM_CB=job_termination_full_15_cb \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	[ -f "${REC_F}" ] ||
		{ FAIL "callback was never invoked"; jt_teardown "${PIDS_F}" "" "${REC_F}"; return 1; }

	while IFS= read -r rec; do
		idx=$((idx + 1))
		sub="${rec%%|*}"
		args="${rec#*|}"

		case "${sub}" in
			init)
				init_cnt=$((init_cnt + 1))
				init_idx="${idx}"
				[ -z "${args}" ] && init_noargs=$((init_noargs + 1)) || echo "init got args '${args}' (want none)"
			;;

			setup)
				setup_cnt=$((setup_cnt + 1))
				setup_idx="${idx}"
				# Exactly '<job_id> <pid>'
				case "${args}" in
					*' '*' '*|*' ') echo "setup args '${args}' (want '<job_id> <pid>')" ;;
					*' '*)
						append setup_ids "${setup_ids}" "${args%% *}"
						append setup_pids "${setup_pids}" "${args##* }"
						is_uint "${args##* }" && setup_wellformed=$((setup_wellformed + 1)) ||
							echo "setup PID '${args##* }' is not a PID"
					;;
					*) echo "setup args '${args}' (want '<job_id> <pid>')"
				esac
			;;

			term)
				term_cnt=$((term_cnt + 1))
				[ "${term_idx}" = 0 ] && term_idx="${idx}"
				case "${args}" in
					*' '*)
						term_out="${args%% *}"
						append term_pids "${term_pids}" "${args#* }"
						term_wellformed=$((term_wellformed + 1))
					;;
					*) echo "term args '${args}' (want '<out var> <pid>...')"
				esac
			;;

			cleanup)
				cleanup_cnt=$((cleanup_cnt + 1))
				cleanup_idx="${idx}"
				cleanup_args="${args}"
			;;

			*) bad_subs=$((bad_subs + 1)); echo "unexpected subcommand '${sub}'"
		esac
	done < "${REC_F}"

	[ "${bad_subs}" = 0 ] && checks_pass=$((checks_pass + 1)) || echo "${bad_subs} unexpected subcommand(s)"

	[ "${init_cnt}" = 1 ] && [ "${init_noargs}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "init invoked ${init_cnt} time(s), ${init_noargs} without args (want 1 and 1)"
	[ "${init_idx}" = 1 ] && checks_pass=$((checks_pass + 1)) || echo "init was invocation #${init_idx} (want the first)"

	[ "${setup_cnt}" = 2 ] && [ "${setup_wellformed}" = 2 ] && checks_pass=$((checks_pass + 1)) ||
		echo "setup invoked ${setup_cnt} time(s), ${setup_wellformed} well-formed (want 2 and 2)"
	jt_same_set "${jobs}" "${setup_ids}" && checks_pass=$((checks_pass + 1)) ||
		echo "setup job IDs '${setup_ids}' (want '${jobs}')"

	# term_idx stays 0 and term_out/term_pids stay empty if term never ran,
	#   so the checks below fail on their own in that case
	[ "${term_cnt}" = 1 ] && [ "${term_wellformed}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "term invoked ${term_cnt} time(s), ${term_wellformed} well-formed (want 1 and 1)"
	[ "${setup_idx}" -lt "${term_idx}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "a setup (#${setup_idx}) came after term (#${term_idx})"
	job_termination_full_15_is_var "${term_out}" && checks_pass=$((checks_pass + 1)) ||
		echo "term out var '${term_out}' is not a usable variable name"
	jt_same_set "${setup_pids}" "${term_pids}" && checks_pass=$((checks_pass + 1)) ||
		echo "term seeds '${term_pids}' (want the setup PIDs '${setup_pids}')"

	[ "${cleanup_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) || echo "cleanup invoked ${cleanup_cnt} time(s) (want 1)"
	[ "${cleanup_idx}" = "${idx}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "cleanup was invocation #${cleanup_idx} of ${idx} (want the last)"
	job_termination_full_15_is_var "${cleanup_args}" && checks_pass=$((checks_pass + 1)) ||
		echo "cleanup args '${cleanup_args}' (want a single out var name)"

	jt_teardown "${PIDS_F}" "" "${REC_F}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "init -> setup x2 -> term (seeded with the setup PIDs) -> cleanup"
		return 0
	else
		FAIL
		return 1
	fi
}

# A custom termination command that fails: a non-zero return from 'term' or from
#   'cleanup' is reported via SCHED_FAIL_MSG_CB - naming the subcommand and the code -
#   but is not fatal: the run still ends with its own return code.
# Runs in any environment.
test_job_termination_full_16() {
	job_termination_full_16_cb() {
		case "${1}" in
			term)
				shift 2 2>/dev/null
				kill -9 "${@}" 2>/dev/null
				return 42
			;;
			cleanup) return 43
		esac
	}
	job_termination_full_16_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_16 \
		sched_pid sched_rv checks_pass=0 checks_exp=3 term_msg_cnt=0 cleanup_msg_cnt=0 \
		jobs='block_16a block_16b'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${MSG_FILE}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command failing: reported per subcommand, not fatal" "${jobs}"

	require_variant full || return 2

	SCHED_FAIL_MSG_CB=job_termination_full_16_fail_msg \
	DO_JOB_CB=do_job_term \
	JOB_TERM_CB=job_termination_full_16_cb \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	# A failing term/cleanup must not change the scheduler's own return code
	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	[ -f "${MSG_FILE}" ] && {
		term_msg_cnt=$(grep -c "job_termination_full_16_cb term' returned code 42." "${MSG_FILE}")
		cleanup_msg_cnt=$(grep -c "job_termination_full_16_cb cleanup' returned code 43." "${MSG_FILE}")
	}

	[ "${term_msg_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "term failure reported ${term_msg_cnt} time(s) (want 1)"
	[ "${cleanup_msg_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "cleanup failure reported ${cleanup_msg_cnt} time(s) (want 1)"
	[ "${checks_pass}" = "${checks_exp}" ] || { [ -f "${MSG_FILE}" ] && cat "${MSG_FILE}"; }

	jt_teardown "${PIDS_F}" "" "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "rv=83, both failing subcommands reported with their codes"
		return 0
	else
		FAIL
		return 1
	fi
}

# A custom termination command reporting a mixed verified-kill list: the invalid
#   tokens are reported via SCHED_FAIL_MSG_CB and skipped, while the valid PIDs in
#   the same report are still honored - scrubbed from <running_pids>.
# Runs in any environment.
test_job_termination_full_17() {
	job_termination_full_17_cb() {
		local t17_out="${2}"

		[ "${1}" = term ] || return 0
		shift 2 2>/dev/null
		kill -9 "${@}" 2>/dev/null
		# Valid wrapper PIDs bracketed by junk the core must reject
		export -n "${t17_out}=notapid ${*} 12x"
	}
	job_termination_full_17_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_full_17 \
		sched_pid sched_rv checks_pass=0 checks_exp=4 fin_pids \
		bad_msg_cnt=0 notapid_cnt=0 num_cnt=0 \
		jobs='block_17a block_17b'

	local \
		PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		FINALIZE_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${PIDS_F}" "${FINALIZE_F}" "${MSG_FILE}"
	: > "${PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command: invalid verified PIDs skipped, valid ones honored" "${jobs}"

	require_variant full || return 2

	SCHED_FAIL_MSG_CB=job_termination_full_17_fail_msg \
	SCHED_FINALIZE_CB=jt_finalize_rec \
	DO_JOB_CB=do_job_term \
	JOB_TERM_CB=job_termination_full_17_cb \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] && checks_pass=$((checks_pass + 1)) || echo "sched_rv=${sched_rv} (want 83)"

	[ -f "${MSG_FILE}" ] && {
		bad_msg_cnt=$(grep -c "invalid verified PID" "${MSG_FILE}")
		notapid_cnt=$(grep -c "invalid verified PID 'notapid'" "${MSG_FILE}")
		num_cnt=$(grep -c "invalid verified PID '12x'" "${MSG_FILE}")
	}

	# One complaint per junk token, naming it - and no others
	[ "${bad_msg_cnt}" = 2 ] && checks_pass=$((checks_pass + 1)) ||
		echo "invalid-PID complaints: ${bad_msg_cnt} (want 2)"
	[ "${notapid_cnt}" = 1 ] && [ "${num_cnt}" = 1 ] && checks_pass=$((checks_pass + 1)) ||
		echo "complaints naming 'notapid'/'12x': ${notapid_cnt}/${num_cnt} (want 1/1)"
	[ "${checks_pass}" = "${checks_exp}" ] || { [ -f "${MSG_FILE}" ] && cat "${MSG_FILE}"; }

	# The valid PIDs in the same report were still honored
	jt_finalize_get fin_pids pids "${FINALIZE_F}" && [ -z "${fin_pids}" ] && checks_pass=$((checks_pass + 1)) ||
		echo "running_pids '${fin_pids}' (want empty - valid PIDs honored)"

	jt_teardown "${PIDS_F}" "" "${FINALIZE_F}" "${MSG_FILE}"

	if [ "${checks_pass}" = "${checks_exp}" ]; then
		PASS "rv=83, both junk tokens named and skipped, valid PIDs still scrubbed"
		return 0
	else
		FAIL
		return 1
	fi
}

