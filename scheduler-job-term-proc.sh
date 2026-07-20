#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# scheduler-job-term-proc.sh - /proc-based job termination library for scheduler.sh
#
# Kills the process tree of each job by walking /proc/<pid>/task/<tid>/children
#
# Usage: source this file after scheduler.sh, select the mechanism:
#   JOB_TERM_CB=sched_job_term_proc


# Walks /proc/<pid>/task/<tid>/children breadth-first from the seeds and
# collects all live descendant PIDs (space-separated, seeds excluded).
# Globs task/* so children forked by non-leader threads are found.
# 1: out-var
# 2: space-separated seed PIDs
sch_get_descendants_proc() {
	local \
		stp_had_f stp_rv=0 \
		stp_frontier stp_next stp_seen stp_out stp_files \
		stp_p stp_f stp_kid \
		stp_out_var="${1}" stp_seeds="${2}"

	sch_had_f && stp_had_f=1

	stp_seen="${stp_seeds}"
	stp_frontier="${stp_seeds}"
	stp_out=

	while [ -n "${stp_frontier}" ]; do
		stp_files=
		set -f
		# shellcheck disable=SC2086
		for stp_p in ${stp_frontier}; do
			set +f
			for stp_f in /proc/"${stp_p}"/task/*/children; do
				sch_append stp_files "${stp_f}"
			done
		done
		set -f

		# getline < file: -1 on missing file (skipped), 0 at EOF
		stp_next="$(${SCHED_AWK_CMD:-awk} -v paths="${stp_files}" '
		BEGIN {
			num_paths = split(paths, path_list, " ")
			for (i = 1; i <= num_paths; i++) {
				children_file = path_list[i]
				while ((getline line < children_file) > 0) {
					num_kids = split(line, child_pids, " ")
					for (j = 1; j <= num_kids; j++) printf "%s ", child_pids[j]
				}
				close(children_file)
			}
		}')" || stp_rv=${?}

		stp_frontier=
		# shellcheck disable=SC2086
		for stp_kid in ${stp_next}; do
			sch_is_included "${stp_kid}" "${stp_seen}" && continue
			sch_append stp_seen "${stp_kid}"
			sch_append stp_frontier "${stp_kid}"
			sch_append stp_out "${stp_kid}"
		done
	done

	[ -n "${stp_had_f}" ] || set +f
	export -n "${stp_out_var}=${stp_out}"
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
		sch_get_descendants_proc stp_found "${stp_all}" || {
			sch_fail_msg "${stp_lib_name}: /proc scan failed."
			break
		}
		stp_all="${stp_seeds}${stp_found:+ }${stp_found}"
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
