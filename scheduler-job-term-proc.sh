#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# scheduler-job-term-proc.sh - /proc-based job termination library for scheduler.sh
#
# Kills the process tree of each job by walking PPID links from /proc/*/stat
# (one pass, transitive closure in awk). Works wherever /proc and awk are
# available - no cgroups, no root requirement beyond permission to signal the
# job processes. See REFERENCE.md ("Job termination").
#
# Usage: source this file after scheduler.sh, then select the mechanism:
#   JOB_TERM_CB=sched_job_term_proc
#
# Limitations (vs scheduler-job-term-cgroup.sh):
#   - Only trees rooted at a LIVE job process can be found: processes whose
#     parent already exited are reparented to init and escape the walk. In
#     particular, stragglers of a job that already completed are not reaped.
#   - Kills are not verified: no PIDs are reported to the scheduler core, so
#     <running_pids> keeps its default semantics.
#   - The freeze phase briefly sends SIGSTOP to the tree before SIGKILL.

# All live descendants of the space-separated seed PIDs (seeds excluded),
#   reported as a space-separated list on stdout.
# Returns 1 if /proc yielded no parseable records at all.
# 1: seed PIDs
sch_tp_descendants() {
	local stp_had_f stp_seeds="${1}"

	# The /proc glob must expand regardless of the caller's noglob state
	# (the application may run under set -f)
	sch_had_f && stp_had_f=1
	set +f
	set -- /proc/[0-9]*/stat
	[ -n "${stp_had_f}" ] && set -f

	cat "${@}" 2>/dev/null |
	awk -v seeds="${stp_seeds}" '
	/^[0-9]+ \(/ {
		pid = $1
		s = $0
		# Strip "pid (comm) X " (X = single state char). comm may contain
		# spaces and parens - the greedy match handles those; a line that
		# does not match is a fragment of a newline-containing comm - skip
		if (!sub(/^[0-9]+ \(.*\) . /, "", s)) next
		split(s, f, " ")
		if (f[1] !~ /^[0-9]+$/) next
		ppid[pid] = f[1]
		valid++
	}
	END {
		if (!valid) exit 1
		n = split(seeds, a, " ")
		for (i = 1; i <= n; i++)
			if (a[i] ~ /^[0-9]+$/) {
				seed[a[i]] = 1
				want[a[i]] = 1
			}
		do {
			changed = 0
			for (p in ppid)
				if (!(p in want) && (ppid[p] in want)) { want[p] = 1; changed = 1 }
		} while (changed)
		for (p in want) if (!(p in seed)) printf "%s ", p
	}'
}

# Job termination command (see the protocol contract in REFERENCE.md):
#   sched_job_term_proc init|setup|cleanup       (no-ops)
#   sched_job_term_proc term <out_var> <pid>...
# Reports no verified PIDs (assigns an empty list to <out_var>): kill
# verification is not possible here.
sched_job_term_proc() {
	local \
		stp_lib_name=sched_job_term_proc \
		stp_p stp_seeds stp_all stp_prev stp_found stp_try \
		stp_subcmd="${1}"

	shift 2>/dev/null

	case "${stp_subcmd}" in
		init|setup|cleanup) return 0 ;;
		term) : ;;
		*) sch_fail_msg "${stp_lib_name}: unknown subcommand '${stp_subcmd}'."; return 1
	esac

	sch_check_name "var" "${1}" "${stp_lib_name}: term" || return 1
	export -n "${1}="
	shift

	stp_seeds=
	for stp_p in "${@}"; do
		sch_is_uint "${stp_p}" ||
			{ sch_fail_msg "${stp_lib_name}: term: ignoring invalid PID '${stp_p}'."; continue; }
		sch_append stp_seeds "${stp_p}"
	done
	[ -n "${stp_seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill: a stopped process
	# cannot fork, so each STOP pass pins down what the previous
	# scan saw while the next scan catches anything forked in between
	stp_all="${stp_seeds}"
	stp_prev=
	for stp_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${stp_all} 2>/dev/null
		stp_found="$(sch_tp_descendants "${stp_all}")" || {
			sch_fail_msg "${stp_lib_name}: /proc scan failed."
			break
		}
		stp_all="${stp_seeds} ${stp_found}"
		sch_rm_trailing stp_all " "
		[ "${stp_all}" = "${stp_prev}" ] && break
		stp_prev="${stp_all}"
	done
	# SIGKILL is delivered to stopped processes; no CONT needed
	# shellcheck disable=SC2086
	kill -KILL ${stp_all} 2>/dev/null
	:

}
