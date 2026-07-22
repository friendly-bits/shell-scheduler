#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# scheduler-job-term-children.sh - /proc children-walk job termination library for scheduler.sh
# Kills the process tree of each job by walking /proc/<pid>/task/<tid>/children
# Usage: source this file after scheduler.sh, select the mechanism: JOB_TERM_CB=sched_job_term_children


# Walks /proc/<pid>/task/<tid>/children breadth-first from the seeds and collects all live descendant PIDs
#   (space-separated, seeds excluded). Globs task/* so children forked by non-leader threads are found.
# 1: out-var
# 2: space-separated seed PIDs
sch_get_descendants_children() {
	local \
		stch_had_f stch_rv=0 \
		stch_frontier stch_next stch_seen stch_out stch_files \
		stch_p stch_f stch_kid \
		stch_out_var="${1}" stch_seeds="${2}"

	sch_had_f && stch_had_f=1

	stch_seen="${stch_seeds}"
	stch_frontier="${stch_seeds}"
	stch_out=

	while [ -n "${stch_frontier}" ]; do
		stch_files=
		set -f
		# shellcheck disable=SC2086
		for stch_p in ${stch_frontier}; do
			set +f
			for stch_f in /proc/"${stch_p}"/task/*/children; do
				sch_append stch_files "${stch_f}"
			done
		done
		set -f

		# getline < file: -1 on missing file (skipped), 0 at EOF
		stch_next="$(${SCHED_AWK_CMD:-awk} -v paths="${stch_files}" '
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
		}')" || stch_rv=${?}

		stch_frontier=
		# shellcheck disable=SC2086
		for stch_kid in ${stch_next}; do
			sch_is_included "${stch_kid}" "${stch_seen}" && continue
			sch_append stch_seen "${stch_kid}"
			sch_append stch_frontier "${stch_kid}"
			sch_append stch_out "${stch_kid}"
		done
	done

	[ -n "${stch_had_f}" ] || set +f
	export -n "${stch_out_var}=${stch_out}"
	return ${stch_rv}
}

# Job termination callback (see the protocol contract in REFERENCE.md):
#   sched_job_term_children init|setup|cleanup       (no-ops)
#   sched_job_term_children term <out_var> <pid>...
# Reports no verified PIDs (assigns an empty list to <out_var>): kill verification is not possible here.
sched_job_term_children() {
	local \
		stch_lib_name=sched_job_term_children \
		stch_had_f \
		stch_p stch_seeds stch_all stch_prev stch_found stch_try \
		stch_subcmd="${1}"

	shift 2>/dev/null

	case "${stch_subcmd}" in
		init|setup|cleanup) return 0 ;;
		term) : ;;
		*) sch_fail_msg "${stch_lib_name}: unknown subcommand '${stch_subcmd}'."; return 1
	esac

	sch_check_name "var" "${1}" "${stch_lib_name}: term" || return 1
	export -n "${1}="
	shift

	stch_seeds=
	for stch_p in "${@}"; do
		sch_is_uint "${stch_p}" ||
			{ sch_fail_msg "${stch_lib_name}: term: ignoring invalid PID '${stch_p}'."; continue; }
		sch_append stch_seeds "${stch_p}"
	done
	[ -n "${stch_seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill: each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	stch_all="${stch_seeds}"
	stch_prev=

	sch_had_f && stch_had_f=1
	set -f

	for stch_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${stch_all} 2>/dev/null
		sch_get_descendants_children stch_found "${stch_all}" || {
			sch_fail_msg "${stch_lib_name}: /proc scan failed."
			break
		}
		stch_all="${stch_seeds}${stch_found:+ }${stch_found}"
		sch_rm_trailing stch_all " "
		[ "${stch_all}" = "${stch_prev}" ] && break
		stch_prev="${stch_all}"
	done

	# SIGKILL is delivered to stopped processes; no CONT needed
	# shellcheck disable=SC2086
	kill -KILL ${stch_all} 2>/dev/null

	[ -n "${stch_had_f}" ] || set +f
	:

}

# Return 0 if the kernel exposes /proc/<pid>/task/<tid>/children (needs CONFIG_PROC_CHILDREN);
#   the children-walk discovery depends on it. Absent it,
#   this library discovers no descendants and leaves job subtrees alive. Emits no messages. Return codes: 0 -
#   supported; 1 - not supported
proc_children_supported() {
	local pcs_had_f

	sch_is_cmd "${SCHED_AWK_CMD:-awk}" || return 1

	# Resolve the glob with globbing on; an absent children file leaves the pattern literal,
	#   so a live glob is the presence test
	sch_had_f && pcs_had_f=1
	set +f
	set -- /proc/self/task/*/children
	[ -n "${pcs_had_f}" ] && set -f

	[ -e "${1}" ]
}
