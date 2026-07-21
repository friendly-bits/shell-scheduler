#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3001,SC3060,SC3003,SC2329,SC2086
# shellcheck source=/dev/null

# tests-job_termination.sh

# Category: Modular job termination (JOB_TERM_CB)
#   and the supplementary job termination libraries (scheduler-job-term-cgroup.sh,
#   scheduler-job-term-children.sh)

# This file is sourced by tests.sh; it defines test_N functions only.

# All tests exercise the public interface only:
#   JOB_TERM_CB, schedule_jobs(), cgroup_cleanup_supported(),
#   environment variables and callbacks.

# Tests of the cgroup library require a capable environment
#   (root or a delegated cgroup subtree - e.g. run the suite via 'systemd-run --user --scope')
#   and SKIP otherwise.
# Tests of the children library require a kernel with CONFIG_PROC_CHILDREN
#   (the /proc/<pid>/task/<tid>/children files) and SKIP otherwise.
# Core-contract and ppid-walk tests run everywhere (ppid needs only /proc and awk).

. "${script_dir:?}/../scheduler-job-term-cgroup.sh"
. "${script_dir:?}/../scheduler-job-term-children.sh"
. "${script_dir:?}/../scheduler-job-term-ppid.sh"

#
# Category infrastructure
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

# Capability gate for the ppid-walk library, evaluated once per suite run. ppid needs only /proc and awk,
#   so this is effectively always true; the gate exists for symmetry and to SKIP (rather than fail)
#   if awk is truly absent.
ppid_capable() {
	[ -n "${PPID_CAPABLE_CACHED}" ] || {
		if proc_ppid_supported; then
			PPID_CAPABLE_CACHED=yes
		else
			PPID_CAPABLE_CACHED=no
		fi
	}
	[ "${PPID_CAPABLE_CACHED}" = yes ]
}
PPID_CAPABLE_CACHED=
PPID_SKIP_REASON="ppid-walk termination unsupported here - /proc or awk unavailable"

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

# Wait (up to ${2:-3} x 1 s) until every PID recorded in file ${1} is gone.
# On failure sets ${CG_ALIVE} to the list of surviving PIDs.
cg_assert_dead() {
	local caf_f="${1}" caf_tries="${2:-3}" caf_t=0 caf_pid

	CG_ALIVE=
	[ -f "${caf_f}" ] || return 0
	while :; do
		CG_ALIVE=
		while read -r caf_pid; do
			[ -n "${caf_pid}" ] || continue
			kill -0 "${caf_pid}" 2>/dev/null && CG_ALIVE="${CG_ALIVE}${CG_ALIVE:+ }${caf_pid}"
		done < "${caf_f}"
		[ -z "${CG_ALIVE}" ] && return 0
		caf_t=$((caf_t + 1))
		[ "${caf_t}" -gt "${caf_tries}" ] && return 1
		sleep 1
	done
}

# Return 0 if every whitespace-separated ID in ${2} is included in list ${1}
#   and both lists have the same element count
cg_same_set() {
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
cg_teardown() {
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
do_job_cg() {
	local job_name="${1%%_*}"

	case "${job_name}" in
		cginstant) : ;;

		# Proof-of-execution marker
		cgtouch) : > "${CG_MARK_F:?}" ;;

		# Return instantly, leaving a background child and an orphaned grandchild behind (both recorded)
		cgstrag)
			sleep 300 &
			printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
			(
				sleep 300 &
				printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
			) &
		;;

		# Block on a recorded child until killed
		cgblock)
			sleep 300 &
			printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
			wait "${!}"
		;;

		# Live two-level subtree: a child that itself keeps a grandchild alive. Both the child (mid)
		#   and the grandchild are recorded, then the wrapper blocks.
		# Exercises multi-level descendant discovery (the fixpoint walk).
		cgdeep)
			(
				sleep 300 &
				printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
				wait "${!}"
			) &
			printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
			wait "${!}"
		;;

		*)
			printf '%s\n' "Unexpected job name '${job_name}'." >&2
			return 1
		;;
	esac

	return 0
}

# Shared finalize handler: records the outcome arguments to ${CG_FIN_F}
cg_finalize_rec() {
	printf '%s\n' \
		"rv=${1}" \
		"pids=${2}" \
		"ok=${3}" \
		"fail=${4}" \
		"unfin=${5}" \
		"undisp=${6}" \
		"expired=${7}" > "${CG_FIN_F:?}"
}

# Read field ${2} recorded by cg_finalize_rec from file ${3} into var ${1}
cg_fin_get() {
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

#
# Tests
#

# Verify cgroup_cleanup_supported(): consistent return code across calls,
#   no output on success or failure paths, forced-failure via bad
#   SCHED_CGROUP_BASE returns 1, and no stray messages through a user-set
#   SCHED_FAIL_MSG_CB. Runs in any environment.
test_job_termination_01() {
	job_termination_01_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_01 \
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
	SCHED_FAIL_MSG_CB=job_termination_01_fail_msg \
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
test_job_termination_02() {
	job_termination_02_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_02 \
		rv_badcmd rv_badinit msg_cnt=0 marker=no fin=no

	local \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$" \
		CG_MARK_F="/tmp/sched.job_termination.mark.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${MSG_FILE}" "${CG_MARK_F}" "${CG_FIN_F}"

	print_test_header "${TEST_ID}" "Unusable termination command: clean abort before dispatch" "cgtouch_c02 cgtouch_c02b"

	SCHED_FAIL_MSG_CB=job_termination_02_fail_msg \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB=sch_no_such_cmd_t02 \
		schedule_jobs 'cgtouch_c02b' &
	wait "${!}"
	rv_badcmd=${?}

	SCHED_FAIL_MSG_CB=job_termination_02_fail_msg \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE=/nonexistent/schtest \
		schedule_jobs 'cgtouch_c02' &
	wait "${!}"
	rv_badinit=${?}

	[ -f "${MSG_FILE}" ] && msg_cnt=$(wc -l < "${MSG_FILE}")
	[ -f "${CG_MARK_F}" ] && marker=yes
	[ -f "${CG_FIN_F}" ] && fin=yes
	rm -f "${MSG_FILE}" "${CG_MARK_F}" "${CG_FIN_F}"

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
test_job_termination_03() {
	local \
		TEST_ID=job_termination_03 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 fin_pids fin_ok base_state=empty \
		jobs='cgstrag_c03 cginstant_c03'

	print_test_header "${TEST_ID}" "cgroup: completed job's stragglers reaped by scheduler exit; base left empty" "${jobs}"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=3 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs "${jobs}" &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	[ "$(sed '/^$/d' "${CG_PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${CG_PIDS_F}" | wc -l) (want 2)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "stragglers still alive: ${CG_ALIVE}"; }

	cg_fin_get fin_ok ok "${CG_FIN_F}" && cg_same_set "${fin_ok}" "${jobs}" ||
		{ checks_ok=; echo "ok bucket '${fin_ok}' (want '${jobs}')"; }
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty)"; }

	cg_base_empty "${CG_TEST_BASE}" || { base_state=dirty; checks_ok=; echo "base cgroup not empty"; }

	cg_teardown "${CG_PIDS_F}" "${CG_TEST_BASE}" "${CG_FIN_F}"

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
test_job_termination_04() {
	job_termination_04_done() {
		local i pid alive=unknown

		[ "${2}" = 124 ] && [ -n "${3}" ] ||
			{ printf 'unexpected|%s|%s|%s\n' "${1}" "${2}" "${3:-}" >> "${DONE_F:?}"; return 0; }
		for i in 1 2 3; do
			alive=no
			while read -r pid; do
				[ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && alive=yes
			done < "${CG_PIDS_F:?}"
			[ "${alive}" = no ] && break
			sleep 1
		done
		printf 'expired|%s|dead_at_cb=%s\n' "${1}" "$([ "${alive}" = no ] && printf yes || printf no)" >> "${DONE_F:?}"
	}

	local \
		TEST_ID=job_termination_04 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 done_rec fin_pids fin_expired

	print_test_header "${TEST_ID}" "cgroup: per-job timeout kills the job's process tree at expiry" "cgblock_c04"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		DONE_F="/tmp/sched.job_termination.done.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}" "${DONE_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	job_set_timeout cgblock_c04 1 || { FAIL "job_set_timeout failed"; cg_teardown "${CG_PIDS_F}" "${CG_TEST_BASE}"; return 1; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=job_termination_04_done \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=6 \
	SCHED_IDLE_TIMEOUT_S=4 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs 'cgblock_c04' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	read_first_line done_rec "${DONE_F}" &&
	[ "${done_rec}" = "expired|cgblock_c04|dead_at_cb=yes" ] ||
		{ checks_ok=; echo "done record '${done_rec}' (want 'expired|cgblock_c04|dead_at_cb=yes')"; }

	cg_fin_get fin_expired expired "${CG_FIN_F}" && [ "${fin_expired}" = cgblock_c04 ] ||
		{ checks_ok=; echo "expired bucket '${fin_expired}' (want 'cgblock_c04')"; }
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kill verified)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${CG_ALIVE}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	cg_teardown "${CG_PIDS_F}" "${CG_TEST_BASE}" "${CG_FIN_F}" "${DONE_F}"

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
test_job_termination_05() {
	local \
		TEST_ID=job_termination_05 \
		CG_TEST_BASE \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin \
		jobs='cgblock_c05a cgblock_c05b'

	print_test_header "${TEST_ID}" "cgroup: USR1 abort kills all running job trees (verified)" "${jobs}"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
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

	cg_fin_get fin_unfin unfin "${CG_FIN_F}" && cg_same_set "${fin_unfin}" "${jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"; }
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kills verified)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "job children still alive: ${CG_ALIVE}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	cg_teardown "${CG_PIDS_F}" "${CG_TEST_BASE}" "${CG_FIN_F}"

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
test_job_termination_06() {
	local \
		TEST_ID=job_termination_06 \
		CG_TEST_BASE \
		sched_rv checks_ok=1 fin_pids fin_unfin

	print_test_header "${TEST_ID}" "cgroup: scheduler global timeout kills the running job tree (verified)" "cgblock_c06"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}"

	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=1 \
	SCHED_IDLE_TIMEOUT_S=5 \
	JOB_TERM_CB=sched_job_term_cgroup \
	SCHED_CGROUP_BASE="${CG_TEST_BASE}" \
		schedule_jobs 'cgblock_c06' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 82 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 82)"; }

	cg_fin_get fin_unfin unfin "${CG_FIN_F}" && [ "${fin_unfin}" = cgblock_c06 ] ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want 'cgblock_c06')"; }
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - kill verified)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${CG_ALIVE}"; }

	cg_base_empty "${CG_TEST_BASE}" || { checks_ok=; echo "base cgroup not empty"; }

	cg_teardown "${CG_PIDS_F}" "${CG_TEST_BASE}" "${CG_FIN_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=82, unfinished='${fin_unfin}', running_pids empty, tree dead"
		return 0
	else
		FAIL
		return 1
	fi
}

# Contrast/regression with no termination command: the same straggler job
#   leaves its background child and orphaned grandchild running after the
#   scheduler exits (the test then kills them). Guards against termination
#   becoming unconditionally active, and validates the methodology of the
#   other tests. Runs in any environment.
test_job_termination_07() {
	local \
		TEST_ID=job_termination_07 \
		sched_rv checks_ok=1 alive_cnt=0 pid

	local CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}"
	: > "${CG_PIDS_F}"

	print_test_header "${TEST_ID}" "Without JOB_TERM_CB stragglers survive the run" "cgstrag_c07"

	SCHED_FAIL_MSG_CB=echo \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=3 \
	SCHED_IDLE_TIMEOUT_S=2 \
		schedule_jobs 'cgstrag_c07' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	[ "$(sed '/^$/d' "${CG_PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${CG_PIDS_F}" | wc -l) (want 2)"; }

	while read -r pid; do
		[ -n "${pid}" ] || continue
		kill -0 "${pid}" 2>/dev/null && alive_cnt=$((alive_cnt + 1))
	done < "${CG_PIDS_F}"

	[ "${alive_cnt}" = 2 ] ||
		{ checks_ok=; echo "alive straggler count ${alive_cnt} (want 2)"; }

	cg_teardown "${CG_PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=0, both stragglers survived (then killed by the test)"
		return 0
	else
		FAIL
		return 1
	fi
}

# cgroup library, autodetected base (no SCHED_CGROUP_BASE): termination
#   works with the base derived from the scheduler's own cgroup - stragglers
#   of a completed job are reaped.
test_job_termination_08() {
	local \
		TEST_ID=job_termination_08 \
		sched_rv checks_ok=1 fin_pids fin_ok

	print_test_header "${TEST_ID}" "cgroup: autodetected base (no SCHED_CGROUP_BASE): stragglers reaped" "cgstrag_c08"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}"
	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=5 \
	SCHED_IDLE_TIMEOUT_S=3 \
	JOB_TERM_CB=sched_job_term_cgroup \
		schedule_jobs 'cgstrag_c08' &

	wait "${!}"
	sched_rv=${?}

	[ "${sched_rv}" = 0 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 0)"; }

	cg_fin_get fin_ok ok "${CG_FIN_F}" && [ "${fin_ok}" = cgstrag_c08 ] ||
		{ checks_ok=; echo "ok bucket '${fin_ok}' (want 'cgstrag_c08')"; }
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "stragglers still alive: ${CG_ALIVE}"; }

	cg_teardown "${CG_PIDS_F}" "" "${CG_FIN_F}"

	if [ -n "${checks_ok}" ]; then
		PASS "autodetected base, stragglers reaped, running_pids empty"
		return 0
	else
		FAIL
		return 1
	fi
}

# Shared scenario runners for the /proc-based mechanisms (children, ppid).
# Both libraries implement the same unverified-kill contract,
#   so each scenario is written once and run against a given callback + capability gate.

# "per-job timeout kills the job's process tree at expiry (unverified)".
# 1: test id
# 2: JOB_TERM_CB
# 3: capability gate fn
# 4: skip reason
# 5: job id (a cgblock_* id, so do_job_cg blocks on a recorded child)
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
			done < "${CG_PIDS_F:?}"
			[ "${alive}" = no ] && break
			sleep 1
		done
		printf 'expired|%s|%s|dead_at_cb=%s\n' "${1}" "${3}" "$([ "${alive}" = no ] && printf yes || printf no)" >> "${DONE_F:?}"
	}

	local \
		TEST_ID="${1}" jt_cb="${2}" jt_gate="${3}" jt_skip="${4}" jt_job="${5}" \
		sched_rv checks_ok=1 done_rec done_pid fin_pids fin_expired

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		DONE_F="/tmp/sched.job_termination.done.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}" "${DONE_F}"

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: per-job timeout kills the job's process tree at expiry (unverified)" "${jt_job}"

	"${jt_gate}" || { SKIP "${jt_skip}"; return 0; }

	job_set_timeout "${jt_job}" 1 || { FAIL "job_set_timeout failed"; return 1; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=_jt_timeout_done \
	DO_JOB_CB=do_job_cg \
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

	cg_fin_get fin_expired expired "${CG_FIN_F}" && [ "${fin_expired}" = "${jt_job}" ] ||
		{ checks_ok=; echo "expired bucket '${fin_expired}' (want '${jt_job}')"; }

	# No verification in a /proc-based library:
	#   the expired job's wrapper PID must still be reported in running_pids
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ "${fin_pids}" = "${done_pid}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want '${done_pid}' - unverified kill)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "job child still alive: ${CG_ALIVE}"; }

	cg_teardown "${CG_PIDS_F}" "" "${CG_FIN_F}" "${DONE_F}"

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
# 5: space-separated cgblock_* ids
_jt_abort_scenario() {
	local \
		TEST_ID="${1}" jt_cb="${2}" jt_gate="${3}" jt_skip="${4}" jt_jobs="${5}" \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin pid_cnt=0 job_cnt=0 p

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}"

	for p in ${jt_jobs}; do job_cnt=$((job_cnt + 1)); done

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: USR1 abort kills all running job trees (unverified)" "${jt_jobs}"

	"${jt_gate}" || { SKIP "${jt_skip}"; return 0; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
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

	cg_fin_get fin_unfin unfin "${CG_FIN_F}" && cg_same_set "${fin_unfin}" "${jt_jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jt_jobs}')"; }

	# Kills are unverified: every wrapper PID must still be reported
	cg_fin_get fin_pids pids "${CG_FIN_F}"
	for p in ${fin_pids}; do pid_cnt=$((pid_cnt + 1)); done
	[ "${pid_cnt}" = "${job_cnt}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want ${job_cnt} PIDs - unverified kills)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "job children still alive: ${CG_ALIVE}"; }

	cg_teardown "${CG_PIDS_F}" "" "${CG_FIN_F}"

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
# 3: job id (a cgstrag_* id)
_jt_strag_scenario() {
	local \
		TEST_ID="${1}" jt_cb="${2}" jt_job="${3}" \
		sched_rv checks_ok=1 alive_cnt=0 pid

	local CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}"
	: > "${CG_PIDS_F}"

	print_test_header "${TEST_ID}" "${jt_cb#sched_job_term_}: completed-job stragglers are NOT reaped (documented limitation)" "${jt_job}"

	SCHED_FAIL_MSG_CB=echo \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
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
	done < "${CG_PIDS_F}"

	[ "${alive_cnt}" = 2 ] ||
		{ checks_ok=; echo "alive straggler count ${alive_cnt} (want 2 - the documented gap)"; }

	cg_teardown "${CG_PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "sched_rv=0, stragglers survived as documented (then killed by the test)"
		return 0
	else
		FAIL
		return 1
	fi
}

# children library: per-job timeout kills the job's process tree at expiry; kills unverified,
#   so the expired PID stays in running_pids. SKIP where the children mechanism is unavailable.
test_job_termination_09() {
	_jt_timeout_scenario job_termination_09 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" cgblock_c09
}

# children library: USR1 abort kills all running job trees; jobs classified unfinished;
#   both wrapper PIDs reported (kills unverified). SKIP where the children mechanism is unavailable.
test_job_termination_10() {
	_jt_abort_scenario job_termination_10 sched_job_term_children children_capable "${CHILDREN_SKIP_REASON}" 'cgblock_c10a cgblock_c10b'
}

# children library, documented limitation:
#   stragglers of a COMPLETED job are not reaped (the wrapper already exited,
#   so its children are reparented to init and escape the descendant walk).
# The recorded stragglers must survive the run; the test then kills them. Runs in any environment.
test_job_termination_11() {
	_jt_strag_scenario job_termination_11 sched_job_term_children cgstrag_c11
}

# Custom (user-defined) termination command exercising the out-var report
#   contract: the command kills the wrapper PIDs, reports them as verified via
#   'export -n "${out_var}=..."', and deliberately prints noise to stdout -
#   which must not corrupt the report: running_pids must come out empty and
#   no "invalid verified PID" complaints must be raised. Runs in any
#   environment.
test_job_termination_12() {
	job_termination_12_cb() {
		local t12_sub="${1}" t12_out_var="${2}"

		case "${t12_sub}" in
			init|setup) : ;;
			term)
				shift 2
				# stdout noise must not reach the verified-PID report
				echo "job_termination_12 stdout noise: not pids"
				kill -9 "${@}" 2>/dev/null
				export -n "${t12_out_var}=${*}"
			;;
			cleanup)
				echo "job_termination_12 more stdout noise"
			;;
		esac
	}
	job_termination_12_fail_msg() { printf '%s\n' "${*}" >> "${MSG_FILE:?}"; }

	local \
		TEST_ID=job_termination_12 \
		sched_pid sched_rv checks_ok=1 fin_pids fin_unfin bad_msg_cnt=0 \
		jobs='cgblock_c12a cgblock_c12b'

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		CG_FIN_F="/tmp/sched.job_termination.fin.${TEST_ID}.$$" \
		MSG_FILE="/tmp/sched.job_termination.msg.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}" "${CG_FIN_F}" "${MSG_FILE}"
	: > "${CG_PIDS_F}"

	print_test_header "${TEST_ID}" "Custom termination command: out-var report immune to stdout noise" "${jobs}"

	SCHED_FAIL_MSG_CB=job_termination_12_fail_msg \
	SCHED_FINALIZE_CB=cg_finalize_rec \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=2 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB=job_termination_12_cb \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	cg_fin_get fin_unfin unfin "${CG_FIN_F}" && cg_same_set "${fin_unfin}" "${jobs}" ||
		{ checks_ok=; echo "unfinished bucket '${fin_unfin}' (want '${jobs}')"; }

	# The custom command reported both wrapper PIDs as verified: despite the
	# stdout noise, running_pids must be empty
	cg_fin_get fin_pids pids "${CG_FIN_F}" && [ -z "${fin_pids}" ] ||
		{ checks_ok=; echo "running_pids '${fin_pids}' (want empty - report honored)"; }

	# No 'invalid verified PID' complaints: the noise never reached the report
	[ -f "${MSG_FILE}" ] && bad_msg_cnt=$(grep -c "invalid verified PID" "${MSG_FILE}")
	[ "${bad_msg_cnt}" = 0 ] ||
		{ checks_ok=; echo "core saw ${bad_msg_cnt} invalid-PID token(s): $(cat "${MSG_FILE}")"; }

	cg_teardown "${CG_PIDS_F}" "" "${CG_FIN_F}" "${MSG_FILE}"

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
test_job_termination_13() {
	local \
		TEST_ID=job_termination_13 \
		CG_TEST_BASE \
		SCH_TC_BASE SCH_TC_PENDING \
		checks_ok=1 p init_rv cleanup_rv reaped squat newbase

	print_test_header "${TEST_ID}" "cgroup: base collision with a same-PID sibling is avoided; sibling untouched" "(no jobs)"

	cg_capable || { SKIP "${CG_SKIP_REASON}"; return 0; }

	get_test_pid p || { FAIL "cannot get test PID"; return 1; }
	cg_mk_test_base "${TEST_ID}" || { FAIL "cannot create test base cgroup"; return 1; }

	squat="${CG_TEST_BASE}/sched_${p}.0"
	newbase="${CG_TEST_BASE}/sched_${p}.1"

	# Plant the sibling's base, non-empty (its own job cgroup),
	#   so a regression to steal-then-recreate would be caught
	mkdir "${squat}" 2>/dev/null && mkdir "${squat}/job_squat" 2>/dev/null ||
		{ FAIL "cannot create squat cgroup"; cg_teardown "" "${CG_TEST_BASE}"; return 1; }

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

	cg_teardown "" "${CG_TEST_BASE}"

	if [ -n "${checks_ok}" ]; then
		PASS "routed .0 -> .1, sibling untouched, cleanup removed only own base"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid library: per-job timeout kills the job's process tree at expiry; unverified,
#   so the expired PID stays in running_pids.
test_job_termination_14() {
	_jt_timeout_scenario job_termination_14 sched_job_term_ppid ppid_capable "${PPID_SKIP_REASON}" cgblock_p14
}

# ppid library: USR1 abort kills all running job trees; unverified.
test_job_termination_15() {
	_jt_abort_scenario job_termination_15 sched_job_term_ppid ppid_capable "${PPID_SKIP_REASON}" 'cgblock_p15a cgblock_p15b'
}

# ppid library: completed-job stragglers are NOT reaped (documented orphan limitation).
test_job_termination_16() {
	_jt_strag_scenario job_termination_16 sched_job_term_ppid cgstrag_p16
}

# ppid library: the PPID-map fixpoint walk reaches a multi-level subtree.
# The job keeps a live wrapper -> child -> grandchild chain (child and grandchild both recorded);
#   a USR1 abort must kill the whole chain,
#   proving discovery iterates past direct children rather than stopping at depth 1.
test_job_termination_17() {
	local \
		TEST_ID=job_termination_17 \
		sched_pid sched_rv checks_ok=1 \
		jobs='cgdeep_p17'

	local CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$"
	rm -f "${CG_PIDS_F}"

	print_test_header "${TEST_ID}" "ppid: abort kills a multi-level subtree (fixpoint walk depth)" "${jobs}"

	ppid_capable || { SKIP "${PPID_SKIP_REASON}"; return 0; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=do_job_cg \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB=sched_job_term_ppid \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	# Both the mid child and the grandchild (2 recorded PIDs) must be dead
	[ "$(sed '/^$/d' "${CG_PIDS_F}" | wc -l)" = 2 ] ||
		{ checks_ok=; echo "recorded pid count $(sed '/^$/d' "${CG_PIDS_F}" | wc -l) (want 2)"; }
	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "multi-level subtree survivor(s): ${CG_ALIVE}"; }

	cg_teardown "${CG_PIDS_F}" ""

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, whole wrapper->child->grandchild chain killed"
		return 0
	else
		FAIL
		return 1
	fi
}

# ppid library: the proc_ppid_supported probe. Reports supported on a normal system,
#   and reports unsupported when awk cannot be found.
test_job_termination_18() {
	local TEST_ID=job_termination_18 checks_ok=1

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

# ppid library: the /proc/<pid>/stat parser tolerates a comm containing ')'
#   plus a fake ' <state> <ppid> ' sequence.
# A job child exec's a shebang script whose basename is 'x) R 99999'
#   (<=15 bytes, so it survives comm truncation);
#   its stat line reads '<pid> (x) R 99999) S <wrapper> ...'.
# A naive first-')' parse mis-reads the ppid and drops the process;
#   the library's greedy match recovers it, so an abort must still kill the crafted-comm child.
test_job_termination_19() {
	job_termination_19_do_job() {
		local scr="${P6_DIR:?}/x) R 99999"
		printf '#!/bin/sh\nsleep 300\n' > "${scr}"
		chmod +x "${scr}"
		"${scr}" &
		printf '%s\n' "${!}" >> "${CG_PIDS_F:?}"
		wait "${!}"
	}

	local \
		TEST_ID=job_termination_19 \
		sched_pid sched_rv checks_ok=1 \
		jobs='cparse_p19'

	local \
		CG_PIDS_F="/tmp/sched.job_termination.pids.${TEST_ID}.$$" \
		P6_DIR="/tmp/sched.job_termination.p6.${TEST_ID}.$$"
	rm -rf "${P6_DIR}"
	mkdir -p "${P6_DIR}"
	rm -f "${CG_PIDS_F}"

	print_test_header "${TEST_ID}" "ppid: /proc/<pid>/stat parser handles ')' in comm" "${jobs}"

	ppid_capable || { SKIP "${PPID_SKIP_REASON}"; rm -rf "${P6_DIR}"; return 0; }

	: > "${CG_PIDS_F}"

	SCHED_FAIL_MSG_CB=echo \
	SCHED_FINALIZE_CB=finalize_handler \
	JOB_DONE_CB=done_handler \
	DO_JOB_CB=job_termination_19_do_job \
	SCHED_MAX_JOBS=1 \
	SCHED_TIMEOUT_S=8 \
	SCHED_IDLE_TIMEOUT_S=6 \
	JOB_TERM_CB=sched_job_term_ppid \
		schedule_jobs "${jobs}" &

	sched_pid=${!}
	sleep 1
	kill -USR1 "${sched_pid}" 2>/dev/null
	wait "${sched_pid}"
	sched_rv=${?}

	[ "${sched_rv}" = 83 ] || { checks_ok=; echo "sched_rv=${sched_rv} (want 83)"; }

	cg_assert_dead "${CG_PIDS_F}" ||
		{ checks_ok=; echo "crafted-comm child survived (parser mis-read its stat line): ${CG_ALIVE}"; }

	cg_teardown "${CG_PIDS_F}" ""
	rm -rf "${P6_DIR}"

	if [ -n "${checks_ok}" ]; then
		PASS "rv=83, crafted-comm child discovered and killed"
		return 0
	else
		FAIL
		return 1
	fi
}
