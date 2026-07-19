#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# scheduler-job-term-proc.sh - /proc-based job termination library for scheduler.sh
#
# Kills the process tree of each job by walking PPID links from /proc/*/stat
#
# Usage: source this file after scheduler.sh, select the mechanism:
#   JOB_TERM_CB=sched_job_term_proc


# Prints to stdout all live descendants PIDs (space-separated, seeds excluded)
# Returns 1 if /proc yielded no parseable records at all.
# 1: space-separated seed PIDs
sch_get_descendants_proc() {
	local stp_had_f stp_rv stp_seeds="${1}"

	sch_had_f && stp_had_f=1
	set +f

	cat /proc/[0-9]*/stat 2>/dev/null | {
		set -f
		# shellcheck disable=SC2016
		${SCHED_AWK_CMD:-awk} -v seeds="${stp_seeds}" '
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
	stp_rv=${?}
	[ -n "${stp_had_f}" ] && set -f
	return ${stp_rv}
}

# Job termination callback (see the protocol contract in REFERENCE.md):
#   sched_job_term_proc init|setup|cleanup       (no-ops)
#   sched_job_term_proc term <out_var> <pid>...
# Reports no verified PIDs (assigns an empty list to <out_var>):
#   kill verification is not possible here.
sched_job_term_proc() {
	local \
		stp_lib_name=sched_job_term_proc \
		stp_had_f \
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

	# Freeze, re-scan to fixpoint, then kill:
	#   each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	stp_all="${stp_seeds}"
	stp_prev=

	sch_had_f && stp_had_f=1
	set -f

	for stp_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${stp_all} 2>/dev/null
		stp_found="$(sch_get_descendants_proc "${stp_all}")" || {
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

	[ -n "${stp_had_f}" ] || set +f
	:

}
