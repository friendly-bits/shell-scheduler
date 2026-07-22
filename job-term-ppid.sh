#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# job-term-ppid.sh - /proc PPID-walk job termination library for scheduler.sh
#
# Kills the process tree of each job by walking PPID links from /proc/*/stat.
# Unlike job-term-children.sh (which reads /proc/<pid>/task/<tid>/children and so needs a
#   kernel built with CONFIG_PROC_CHILDREN), this mechanism needs only /proc/<pid>/stat and awk -
#   available on essentially any Linux.
#
# Usage: source this file after scheduler.sh, select the mechanism:
#   JOB_TERM_CB=sched_job_term_ppid


# Prints to stdout all live descendant PIDs (space-separated, seeds excluded).
# Returns 1 if /proc yielded no parseable records at all.
# 1: space-separated seed PIDs
sch_get_descendants_ppid() {
	local spp_had_f spp_rv spp_seeds="${1}"

	sch_had_f && spp_had_f=1
	set +f

	cat /proc/[0-9]*/stat 2>/dev/null | {
		set -f
		# shellcheck disable=SC2016
		${SCHED_AWK_CMD:-awk} -v seeds="${spp_seeds}" '
		/^[0-9]+ \(/ {
			pid = $1
			s = $0
			# Strip "pid (comm) X " (X = single state char).
			# comm may contain spaces and parens - the greedy match handles those;
			#   a line that does not match is a fragment of a newline-containing comm - skip
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
	spp_rv=${?}
	[ -n "${spp_had_f}" ] && set -f
	return ${spp_rv}
}

# Job termination callback (see the protocol contract in REFERENCE.md):
#   sched_job_term_ppid init|setup|cleanup       (no-ops)
#   sched_job_term_ppid term <out_var> <pid>...
# Reports no verified PIDs (assigns an empty list to <out_var>):
#   kill verification is not possible here.
sched_job_term_ppid() {
	local \
		spp_lib_name=sched_job_term_ppid \
		spp_had_f \
		spp_p spp_seeds spp_all spp_prev spp_found spp_try \
		spp_subcmd="${1}"

	shift 2>/dev/null

	case "${spp_subcmd}" in
		init|setup|cleanup) return 0 ;;
		term) : ;;
		*) sch_fail_msg "${spp_lib_name}: unknown subcommand '${spp_subcmd}'."; return 1
	esac

	sch_check_name "var" "${1}" "${spp_lib_name}: term" || return 1
	export -n "${1}="
	shift

	spp_seeds=
	for spp_p in "${@}"; do
		sch_is_uint "${spp_p}" ||
			{ sch_fail_msg "${spp_lib_name}: term: ignoring invalid PID '${spp_p}'."; continue; }
		sch_append spp_seeds "${spp_p}"
	done
	[ -n "${spp_seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill:
	#   each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	spp_all="${spp_seeds}"
	spp_prev=

	sch_had_f && spp_had_f=1
	set -f

	for spp_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${spp_all} 2>/dev/null
		spp_found="$(sch_get_descendants_ppid "${spp_all}")" || {
			sch_fail_msg "${spp_lib_name}: /proc scan failed."
			break
		}
		spp_all="${spp_seeds} ${spp_found}"
		sch_rm_trailing spp_all " "
		[ "${spp_all}" = "${spp_prev}" ] && break
		spp_prev="${spp_all}"
	done

	# SIGKILL is delivered to stopped processes; no CONT needed
	# shellcheck disable=SC2086
	kill -KILL ${spp_all} 2>/dev/null

	[ -n "${spp_had_f}" ] || set +f
	:
}

# Return 0 if the PPID-walk mechanism can work here: awk is available and /proc
#   exposes per-process stat records. Emits no messages.
# Return codes: 0 - supported; 1 - not supported
proc_ppid_supported() {
	sch_is_cmd "${SCHED_AWK_CMD:-awk}" && [ -r /proc/self/stat ]
}
