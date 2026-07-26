#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# job-term.sh - job termination library for scheduler.sh

# Kills each job's whole process tree (background children, orphaned grandchildren)
#   via one of three mechanisms:
#   - cgroup: the kernel's cgroup.kill, with kernel-verified kill reporting;
#       needs cgroup v2 and a writable cgroup subtree (root or a delegated subtree)
#   - children: walks /proc/<pid>/task/<tid>/children;
#       needs a kernel built with CONFIG_PROC_CHILDREN, plus awk
#   - ppid: walks PPID links from /proc/*/stat;
#       needs only /proc/<pid>/stat and awk - available on essentially any Linux
#   The /proc mechanisms cannot verify kills and report no verified PIDs.
# See REFERENCE.md ("Job termination").

# Usage: source this file after scheduler.sh, then select the mechanism:
#   sched_use_job_term <cgroup|children|ppid|auto>
# which sets JOB_TERM_CB=sched_job_term_<mechanism> on success, or JOB_TERM_CB= and
#   returns 1 when the requested mechanism is unusable here.

# Alternatively, select the callback manually: JOB_TERM_CB=sched_job_term_ppid

# Reads env vars:
# SCHED_CGROUP_BASE (optional): writable cgroup2 directory under which the per-run cgroup is created,
#  skipping base autodetection
# SCHED_AWK_CMD (optional): awk command to use for the /proc mechanisms

# This library owns variables prefixed SCH_JT_.


### Shared helper

# Collect the valid PIDs from <pid>..., warning about and skipping the invalid ones.
# 1: out var for the space-separated valid PIDs
# 2: caller name
# 3..: candidate PIDs
sch_jt_get_valid_pids() {
	local sjts_out_var="${1:?}" sjts_caller="${2:?}" sjts_p
	shift 2

	export -n "${sjts_out_var}="
	for sjts_p in "${@}"; do
		sch_is_uint "${sjts_p}" ||
			{ sch_fail_msg "${sjts_caller}: term: ignoring invalid PID '${sjts_p}'."; continue; }
		sch_append "${sjts_out_var}" "${sjts_p}"
	done
	:
}


### /proc mechanisms

# Collect all live descendant PIDs (space-separated, seeds excluded)
#   by walking /proc/*/stat PPID links
# Returns 1 if /proc yielded no parseable records
# 1: out var
# 2: space-separated seed PIDs
sch_jt_desc_ppid() {
	local sjtd_rv sjtd_out \
		sjtd_out_var="${1:?}" sjtd_seeds="${2?}"

	# The awk pipeline runs in a subshell either way, so capture it here rather than
	#   printing to stdout
	sjtd_out="$(
		set +f
		cat /proc/[0-9]*/stat 2>/dev/null | {
			set -f
			# shellcheck disable=SC2016
			${SCHED_AWK_CMD:-awk} -v seeds="${sjtd_seeds}" '
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
	)"
	sjtd_rv=${?}

	export -n "${sjtd_out_var}=${sjtd_out}"
	return ${sjtd_rv}
}

# Walk /proc/<pid>/task/<tid>/children breadth-first from the seeds and collect all live descendant PIDs
#   (space-separated, seeds excluded).
# Globs task/* so children forked by non-leader threads are found.
# 1: out var
# 2: space-separated seed PIDs
sch_jt_desc_children() {
	local \
		sjtd_had_f sjtd_rv=0 \
		sjtd_frontier sjtd_next sjtd_seen sjtd_files \
		sjtd_p sjtd_f sjtd_kid \
		sjtd_out_var="${1}" sjtd_seeds="${2}"

	sch_has_f && sjtd_had_f=1

	sjtd_seen="${sjtd_seeds}"
	sjtd_frontier="${sjtd_seeds}"
	export -n "${sjtd_out_var}="

	while [ -n "${sjtd_frontier}" ]; do
		sjtd_files=
		set -f
		# shellcheck disable=SC2086
		for sjtd_p in ${sjtd_frontier}; do
			set +f
			for sjtd_f in /proc/"${sjtd_p}"/task/*/children; do
				sch_append sjtd_files "${sjtd_f}"
			done
		done
		set -f

		# getline < file: -1 on missing file (skipped), 0 at EOF
		sjtd_next="$(${SCHED_AWK_CMD:-awk} -v paths="${sjtd_files}" '
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
		}')" || sjtd_rv=${?}

		sjtd_frontier=
		# shellcheck disable=SC2086
		for sjtd_kid in ${sjtd_next}; do
			sch_is_included "${sjtd_kid}" "${sjtd_seen}" && continue
			sch_append sjtd_seen "${sjtd_kid}"
			sch_append sjtd_frontier "${sjtd_kid}"
			sch_append "${sjtd_out_var}" "${sjtd_kid}"
		done
	done

	[ -n "${sjtd_had_f}" ] || set +f

	return ${sjtd_rv}
}

# Shared implementation of the /proc job termination callbacks.
#   init, setup and cleanup are no-ops: no per-run or per-job state is held.
#   term freezes, re-scans to a fixpoint and kills.
# Reports no verified killed PIDs (assigns empty list to <out var>):
#   kill verification is not possible here.
# 1: mechanism (ppid|children)
# 2: subcommand
# 3..: subcommand args
sch_jt_proc() {
	local \
		sjtp_mech="${1:?}" \
		sjtp_caller="sched_job_term_${1}" \
		sjtp_had_f \
		sjtp_seeds sjtp_all sjtp_prev sjtp_found sjtp_try \
		sjtp_subcmd="${2}"

	shift
	[ -n "${1}" ] && shift

	case "${sjtp_subcmd}" in
		init|setup|cleanup) return 0 ;;
		term) : ;;
		*) sch_fail_msg "${sjtp_caller}: unknown subcommand '${sjtp_subcmd}'."; return 1
	esac

	sch_check_name "var" "${1}" "${sjtp_caller}: term" || return 1
	export -n "${1}="
	shift

	sch_jt_get_valid_pids sjtp_seeds "${sjtp_caller}" "${@}"
	[ -n "${sjtp_seeds}" ] || return 0

	# Freeze, re-scan to fixpoint, then kill:
	#   each STOP pass pins down what the previous scan saw,
	#   while the next scan catches anything forked in between
	sjtp_all="${sjtp_seeds}"
	sjtp_prev=

	sch_has_f && sjtp_had_f=1
	set -f

	for sjtp_try in 1 2 3; do
		# shellcheck disable=SC2086
		kill -STOP ${sjtp_all} 2>/dev/null
		case "${sjtp_mech}" in
			ppid) sch_jt_desc_ppid sjtp_found "${sjtp_all}" ;;
			children) sch_jt_desc_children sjtp_found "${sjtp_all}" ;;
			*) false
		esac ||
		{
			sch_fail_msg "${sjtp_caller}: /proc scan failed."
			break
		}
		sch_append sjtp_all "${sjtp_found}"
		sch_tr_trailing sjtp_all " "
		[ "${sjtp_all}" = "${sjtp_prev}" ] && break
		sjtp_prev="${sjtp_all}"
	done

	# SIGKILL is delivered to stopped processes; no CONT needed
	# shellcheck disable=SC2086
	[ -n "${sjtp_all}" ] && kill -KILL ${sjtp_all} 2>/dev/null

	[ -n "${sjtp_had_f}" ] || set +f
	:
}

# Job termination callbacks (see the protocol contract in REFERENCE.md):
#   sched_job_term_<mech> init|setup             (no-ops)
#   sched_job_term_<mech> term <out var> <pid>...
#   sched_job_term_<mech> cleanup <out var>
sched_job_term_ppid() { sch_jt_proc ppid "${@}"; }

sched_job_term_children() { sch_jt_proc children "${@}"; }


### cgroup mechanism

# Create the per-run base cgroup as a child of <parent dir>, assigning it to <base out var>
#   on success only.
#
# mkdir is atomic (fails if the name exists), so concurrent instances - even ones sharing
#   <pid> across PID namespaces under a shared SCHED_CGROUP_BASE - claim distinct bases;
#   the loser advances the suffix.
# 1: out var for the created base cgroup path
# 2: parent dir
# 3: PID to name the base after
sch_jt_cg_mk_base() {
	local sjtc_n=0 sjtc_d

	export -n "${1}="
	while :; do
		sjtc_d="${2}/sched_${3:?}.${sjtc_n}"
		mkdir "${sjtc_d}" 2>/dev/null && { export -n "${1}=${sjtc_d}"; return 0; }
		sjtc_n=$((sjtc_n + 1))
		[ "${sjtc_n}" -lt 16 ] || return 1
	done
}

# Set up the per-run base cgroup which will hold per-job child cgroups. Base autodetection tries,
#   in order:
#   - this process's own cgroup: writable when running as root,
#       or unprivileged inside a delegated subtree (e.g. a systemd user session
#       or user service, or any command launched via 'systemd-run --user --scope')
#   - cgroup2 mount root: writable when running as root
# Validates the whole mechanism by moving a probe subshell into a child cgroup
sch_jt_cg_init() {
	local \
		sjtc_lib_name=sched_job_term_cgroup \
		sjtc_mnt sjtc_own sjtc_line sjtc_fstype sjtc_cand sjtc_pid \
		sjtc_hint="need root or a delegated cgroup subtree, e.g. run via 'systemd-run --user --scope <cmd>'"

	SCH_JT_BASE=
	SCH_JT_PENDING=

	sch_get_cur_pid sjtc_pid || return 1

	# Locate the cgroup2 mountpoint
	sjtc_mnt=
	while read -r _ sjtc_line sjtc_fstype _; do
		[ "${sjtc_fstype}" = cgroup2 ] && { sjtc_mnt="${sjtc_line}"; break; }
	done 2>/dev/null < /proc/mounts

	[ -n "${sjtc_mnt}" ] ||
		{ sch_fail_msg "${sjtc_lib_name}: no cgroup2 mount found."; return 1; }

	if [ -n "${SCHED_CGROUP_BASE}" ]; then
		# Specified by the user
		sjtc_cand="${SCHED_CGROUP_BASE}"
		sch_tr_trailing sjtc_cand "/"
		sch_jt_cg_mk_base SCH_JT_BASE "${sjtc_cand}" "${sjtc_pid}" || {
			sch_fail_msg "${sjtc_lib_name}: cannot create a cgroup under '${SCHED_CGROUP_BASE}'."
			return 1
		}
	else
		# Own cgroup path: the '0::<path>' (cgroup v2) entry
		sjtc_own=
		while IFS= read -r sjtc_line; do
			case "${sjtc_line}" in
				0::*) sjtc_own="${sjtc_line#0::}"; break
			esac
		done 2>/dev/null < /proc/self/cgroup

		sjtc_cand="${sjtc_mnt}${sjtc_own}"
		sch_tr_trailing sjtc_cand "/"

		sch_jt_cg_mk_base SCH_JT_BASE "${sjtc_cand}" "${sjtc_pid}" ||
		sch_jt_cg_mk_base SCH_JT_BASE "${sjtc_mnt}" "${sjtc_pid}" || {
			sch_fail_msg "${sjtc_lib_name}: cannot create a cgroup under '${sjtc_cand}' or '${sjtc_mnt}' (${sjtc_hint})."
			return 1
		}
	fi

	[ -f "${SCH_JT_BASE}/cgroup.kill" ] || {
		sch_fail_msg "${sjtc_lib_name}: no cgroup.kill in '${SCH_JT_BASE}' (kernel >= 5.14 required)."
		rmdir "${SCH_JT_BASE}" 2>/dev/null
		SCH_JT_BASE=
		return 1
	}

	mkdir "${SCH_JT_BASE}/probe" 2>/dev/null &&
	{
		{ printf '0\n' 2>/dev/null > "${SCH_JT_BASE}/probe/cgroup.procs"; } &
		wait "${!}"
	} &&
	rmdir "${SCH_JT_BASE}/probe" 2>/dev/null || {
		sch_fail_msg "${sjtc_lib_name}: job processes cannot join cgroups under '${SCH_JT_BASE}' (${sjtc_hint})."
		rmdir "${SCH_JT_BASE}/probe" "${SCH_JT_BASE}" 2>/dev/null
		SCH_JT_BASE=
		return 1
	}
}

# Try to remove the per-job cgroup of the job with wrapper PID <pid>.
# rmdir succeeds only once the kernel confirmed cgroup empty and fully reaped,
#   i.e. kill of the job's process tree is verified:
#   append the PID to <out var>
# Otherwise park the PID in ${SCH_JT_PENDING} for later retries.
# 1: out var for reaped PID
# 2: job wrapper PID
sch_jt_cg_try_rm() {
	export -n "${1:?}="
	rmdir "${SCH_JT_BASE:?}/job_${2:?}" 2>/dev/null &&
		{ export -n "${1:?}=${2}"; return 0; }
	sch_is_included "${2}" "${SCH_JT_PENDING}" ||
		sch_append SCH_JT_PENDING "${2}"
	return 1
}

# Kill all processes remaining in the per-job cgroup of the job with wrapper
#   PID <pid> and try to remove the cgroup (verifying the kill)
# 1: out var for reaped PID
# 2: job wrapper PID
sch_jt_cg_kill_job() {
	local sjtc_d="${SCH_JT_BASE:?}/job_${2:?}"

	export -n "${1:?}="
	[ -d "${sjtc_d}" ] || return 0
	printf '1\n' 2>/dev/null > "${sjtc_d}/cgroup.kill"
	sch_jt_cg_try_rm "${1:?}" "${2}"
	:
}

# 'term' body: retry previously unverified removals, then kill the listed jobs.
#   Always runs the retry pass and always assigns <out var> - no empty-seeds shortcut.
# 1: out var for kernel-verified killed PIDs (already validated and cleared by the caller)
# 2..: job wrapper PIDs
sch_jt_cg_term() {
	local \
		sjtc_lib_name=sched_job_term_cgroup \
		sjtc_out_var="${1}" sjtc_reaped sjtc_seeds sjtc_p sjtc_prev

	shift 2>/dev/null

	# Retry previously unverified removals first, then kill
	sjtc_prev="${SCH_JT_PENDING}"
	SCH_JT_PENDING=
	export -n "${sjtc_out_var}="

	# shellcheck disable=SC2086
	for sjtc_p in ${sjtc_prev}; do
		sch_jt_cg_try_rm sjtc_reaped "${sjtc_p}"
		sch_append "${sjtc_out_var}" "${sjtc_reaped}"
	done

	sch_jt_get_valid_pids sjtc_seeds "${sjtc_lib_name}" "${@}"
	# shellcheck disable=SC2086
	for sjtc_p in ${sjtc_seeds}; do
		sch_jt_cg_kill_job sjtc_reaped "${sjtc_p}"
		sch_append "${sjtc_out_var}" "${sjtc_reaped}"
	done

	:
}

# 'cleanup' body: sweep all remaining job cgroups, retry unverified removals and
#   remove the base cgroup.
# 1: out var for kernel-verified killed PIDs (already validated and cleared by the caller)
sch_jt_cg_cleanup() {
	local \
		sjtc_lib_name=sched_job_term_cgroup \
		sjtc_out_var="${1}" sjtc_reaped sjtc_p sjtc_prev sjtc_try sjtc_had_f

	export -n "${sjtc_out_var}="

	# Sweep all remaining job cgroups - including those of completed jobs that left processes behind:
	#   nothing a job spawned survives the run.
	# The glob must expand regardless of the caller's noglob state (the application may run under set -f)
	[ -n "${SCH_JT_BASE}" ] && {
		sch_has_f && sjtc_had_f=1
		set +f
		set -- "${SCH_JT_BASE}"/job_*
		[ -z "${sjtc_had_f}" ] || set -f
		for sjtc_p in "${@}"; do
			[ -d "${sjtc_p}" ] || continue
			sjtc_p="${sjtc_p##*/job_}"
			sch_is_uint "${sjtc_p}" && {
				sch_jt_cg_kill_job sjtc_reaped "${sjtc_p}"
				sch_append "${sjtc_out_var}" "${sjtc_reaped}"
			}
		done
	}

	# Bounded retry for unverified removals:
	#   rmdir succeeds only once the kernel has fully reaped a cgroup's processes
	for sjtc_try in 1 2 3; do
		[ -n "${SCH_JT_PENDING}" ] || break
		sjtc_prev="${SCH_JT_PENDING}"
		SCH_JT_PENDING=
		# shellcheck disable=SC2086
		for sjtc_p in ${sjtc_prev}; do
			sch_jt_cg_try_rm sjtc_reaped "${sjtc_p}"
			sch_append "${sjtc_out_var}" "${sjtc_reaped}"
		done
		[ -n "${SCH_JT_PENDING}" ] || break
		[ "${sjtc_try}" = 3 ] || sleep 1
	done
	[ -z "${SCH_JT_BASE}" ] || {
		rmdir "${SCH_JT_BASE}" 2>/dev/null ||
			sch_fail_msg "${sjtc_lib_name}: failed to remove cgroup(s) under '${SCH_JT_BASE}'."
	}
	SCH_JT_BASE=

	:
}

# Job termination callback (see the protocol contract in REFERENCE.md):
#   sched_job_term_cgroup init
#   sched_job_term_cgroup setup <job_id> <pid>   (runs in the job process)
#   sched_job_term_cgroup term <out var> <pid>...
#   sched_job_term_cgroup cleanup <out var>
# 'term' and 'cleanup' report kernel-verified killed PIDs by assigning
#   space-separated list to <out var>.
sched_job_term_cgroup() {
	local \
		sjtc_lib_name=sched_job_term_cgroup \
		sjtc_sub="${1}"

	shift 2>/dev/null

	case "${sjtc_sub}" in
		init)
			sch_jt_cg_init
		;;

		setup)
			# Join a fresh per-job cgroup: writing '0' to cgroup.procs moves the writing process,
			#   which is the job process since the core invokes 'setup' there;
			#   all the job's descendants inherit the membership
			sch_is_uint "${2}" ||
				{ sch_fail_msg "${sjtc_lib_name}: setup: invalid PID '${2}'."; return 1; }
			mkdir "${SCH_JT_BASE:?}/job_${2}" 2>/dev/null &&
			printf '0\n' 2>/dev/null > "${SCH_JT_BASE}/job_${2}/cgroup.procs" ||
			{
				sch_fail_msg "${sjtc_lib_name}: job '${1}' (PID ${2}): failed to join cgroup '${SCH_JT_BASE}/job_${2}'."
				return 1
			}
		;;

		term)
			sch_check_name "var" "${1}" "${sjtc_lib_name}: term" || return 1
			export -n "${1}="
			sch_jt_cg_term "${@}"
		;;

		cleanup)
			sch_check_name "var" "${1}" "${sjtc_lib_name}: cleanup" || return 1
			export -n "${1}="
			sch_jt_cg_cleanup "${1}"
		;;

		*)
			sch_fail_msg "${sjtc_lib_name}: unknown subcommand '${sjtc_sub}'."
			return 1
	esac
}


### Probes and mechanism selection

# Return 0 if the PPID-walk mechanism can work here: awk is available and /proc
#   exposes per-process stat records. Emits no messages.
sch_jt_probe_ppid() {
	sch_is_cmd "${SCHED_AWK_CMD:-awk}" && [ -r /proc/self/stat ]
}

# Return 0 if awk is available and the kernel exposes /proc/<pid>/task/<tid>/children
#   (needs CONFIG_PROC_CHILDREN); the children-walk discovery depends on it. Absent it,
#   this mechanism discovers no descendants and leaves job subtrees alive. Emits no messages.
sch_jt_probe_children() {
	local sjt_had_f

	sch_is_cmd "${SCHED_AWK_CMD:-awk}" || return 1

	# Resolve the glob with globbing on; an absent children file leaves the pattern literal,
	#   so a live glob is the presence test
	sch_has_f && sjt_had_f=1
	set +f
	set -- /proc/self/task/*/children
	[ -n "${sjt_had_f}" ] && set -f

	[ -e "${1}" ]
}

# Return 0 if cgroup v2 job termination is supported in the current environment:
#   runs the same validation 'sched_job_term_cgroup init' performs, then cleans up after itself.
# Honors ${SCHED_CGROUP_BASE} if set. Emits no messages.
sch_jt_probe_cgroup() {
	local SCH_JT_BASE SCH_JT_PENDING sjt_rv=0

	SCHED_FAIL_MSG_CB=: sch_jt_cg_init || sjt_rv=1

	[ -n "${SCH_JT_BASE}" ] && rmdir "${SCH_JT_BASE}" 2>/dev/null
	return "${sjt_rv}"
}

# Select a job termination mechanism: probe it and, on success, arm the matching callback
#   by assigning JOB_TERM_CB=sched_job_term_<mech>.
# 'auto' tries cgroup -> children -> ppid.
# On failure - the mechanism is unusable here, or the argument is outside the closed set -
#   JOB_TERM_CB is assigned an empty value, so a failed selection never leaves a stale callback armed.
#   Prints errors unless run with '-q'.
# 0 (optional): '-q' for quiet mode (no errors)
# 1: cgroup|children|ppid|auto
# Return codes: 0 - selected; 1 - not selected
sched_use_job_term() {
	local sjt_q
	[ "${1}" = '-q' ] && { sjt_q=1; shift; }
	local sjt_mech="${1}" sjt_arg="${1}"

	export -n JOB_TERM_CB=

	case "${sjt_mech}" in
		auto)
			if sch_jt_probe_cgroup; then sjt_mech=cgroup
			elif sch_jt_probe_children; then sjt_mech=children
			elif sch_jt_probe_ppid; then sjt_mech=ppid
			else false
			fi
		;;
		cgroup) sch_jt_probe_cgroup ;;
		children) sch_jt_probe_children ;;
		ppid) sch_jt_probe_ppid ;;
		*) false
	esac 2>/dev/null ||
	{
		[ -n "${sjt_q}" ] && return 1
		if [ "${sjt_arg}" = auto ]; then
			sch_fail_msg "Failed to find a functional job termination mechanism for this system."
		else
			sch_fail_msg "Job termination mechanism '${sjt_arg}' is unavailable."
		fi
		return 1
	}

	JOB_TERM_CB="sched_job_term_${sjt_mech}"
}
