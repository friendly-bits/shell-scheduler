#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

# scheduler-job-term-cgroup.sh - cgroup v2 job termination library for scheduler.sh
#
# Kills each job's whole process tree (background children, orphaned
# grandchildren) via the kernel's cgroup.kill, with kernel-verified kill
# reporting. See REFERENCE.md ("Job termination").
#
# Usage: source this file after scheduler.sh, then select the mechanism:
#   JOB_TERM_CB=sched_job_term_cgroup
# Call cgroup_cleanup_supported() beforehand to check availability.
#
# Requirements: cgroup v2 with cgroup.kill (kernel >= 5.14), and either root
# or a scheduler process already inside a delegated cgroup subtree (e.g. a
# systemd user service, or any command launched via
# 'systemd-run --user --scope <cmd>').
#
# Environment:
# SCHED_CGROUP_BASE  Optional, advanced (mainly for testing): writable cgroup2
#                    directory under which the per-run cgroup is created,
#                    skipping base autodetection
#
# This library owns variables prefixed SCH_TC_.

# Create the per-run base cgroup as a child of <parent dir>
# Sets ${SCH_TC_BASE}
# 1: parent dir
sch_tc_mk_base() {
	local stc_d="${1}/sched_${SCH_TC_PID:?}"

	# Remove a stale (empty) leftover from a previous run with a reused PID
	rmdir "${stc_d}" 2>/dev/null
	mkdir "${stc_d}" 2>/dev/null || return 1
	SCH_TC_BASE="${stc_d}"
}

# Set up the per-run base cgroup which will hold per-job child cgroups.
# Base autodetection tries, in order:
#   - this process's own cgroup: writable when running as root,
#       or unprivileged inside a delegated subtree (e.g. a systemd user session
#       or user service, or any command launched via 'systemd-run --user --scope')
#   - cgroup2 mount root: writable when running as root
# Validates the whole mechanism by moving a probe subshell into a child cgroup
sch_tc_init() {
	local \
		stc_lib_name=sched_job_term_cgroup \
		stc_mnt stc_own stc_line stc_fstype stc_cand SCH_TC_PID \
		stc_hint="need root or a delegated cgroup subtree, e.g. run via 'systemd-run --user --scope <cmd>'"

	SCH_TC_BASE=
	SCH_TC_PENDING=

	sch_get_cur_pid SCH_TC_PID || return 1

	# Locate the cgroup2 mountpoint
	stc_mnt=
	while read -r _ stc_line stc_fstype _; do
		[ "${stc_fstype}" = cgroup2 ] && { stc_mnt="${stc_line}"; break; }
	done 2>/dev/null < /proc/mounts

	[ -n "${stc_mnt}" ] ||
		{ sch_fail_msg "${stc_lib_name}: no cgroup2 mount found."; return 1; }

	if [ -n "${SCHED_CGROUP_BASE}" ]; then
		# Specified by the user
		stc_cand="${SCHED_CGROUP_BASE}"
		sch_rm_trailing stc_cand "/"
		sch_tc_mk_base "${stc_cand}" || {
			sch_fail_msg "${stc_lib_name}: cannot create a cgroup under '${SCHED_CGROUP_BASE}'."
			return 1
		}
	else
		# Own cgroup path: the '0::<path>' (cgroup v2) entry
		stc_own=
		while IFS= read -r stc_line; do
			case "${stc_line}" in
				0::*) stc_own="${stc_line#0::}"; break
			esac
		done 2>/dev/null < /proc/self/cgroup

		stc_cand="${stc_mnt}${stc_own}"
		sch_rm_trailing stc_cand "/"

		sch_tc_mk_base "${stc_cand}" ||
		sch_tc_mk_base "${stc_mnt}" || {
			sch_fail_msg "${stc_lib_name}: cannot create a cgroup under '${stc_cand}' or '${stc_mnt}' (${stc_hint})."
			return 1
		}
	fi

	[ -f "${SCH_TC_BASE}/cgroup.kill" ] || {
		sch_fail_msg "${stc_lib_name}: no cgroup.kill in '${SCH_TC_BASE}' (kernel >= 5.14 required)."
		rmdir "${SCH_TC_BASE}" 2>/dev/null
		SCH_TC_BASE=
		return 1
	}

	mkdir "${SCH_TC_BASE}/probe" 2>/dev/null &&
	{
		{ printf '0\n' 2>/dev/null > "${SCH_TC_BASE}/probe/cgroup.procs"; } &
		wait "${!}"
	} &&
	rmdir "${SCH_TC_BASE}/probe" 2>/dev/null || {
		sch_fail_msg "${stc_lib_name}: job processes cannot join cgroups under '${SCH_TC_BASE}' (${stc_hint})."
		rmdir "${SCH_TC_BASE}/probe" "${SCH_TC_BASE}" 2>/dev/null
		SCH_TC_BASE=
		return 1
	}
}

# Try to remove the per-job cgroup of the job with wrapper PID <pid>.
# rmdir succeeds only once the kernel has confirmed the cgroup empty and fully
#   reaped, i.e. the kill of the job's whole process tree is verified: append
#   the PID to ${stc_reaped} (a local of the calling dispatcher, resolved via
#   dynamic scoping). Otherwise park the PID in ${SCH_TC_PENDING} for later
#   retries.
# 1: job wrapper PID
sch_tc_try_rm() {
	rmdir "${SCH_TC_BASE:?}/job_${1:?}" 2>/dev/null &&
		{ sch_append stc_reaped "${1}"; return 0; }
	sch_is_included "${1}" "${SCH_TC_PENDING}" ||
		sch_append SCH_TC_PENDING "${1}"
	return 1
}

# Kill all processes remaining in the per-job cgroup of the job with wrapper
#   PID <pid> and try to remove the cgroup (verifying the kill)
# 1: job wrapper PID
sch_tc_kill_job() {
	local stc_d="${SCH_TC_BASE:?}/job_${1:?}"

	[ -d "${stc_d}" ] || return 0
	printf '1\n' 2>/dev/null > "${stc_d}/cgroup.kill"
	sch_tc_try_rm "${1}"
	:
}

# Job termination command (see the protocol contract in REFERENCE.md):
#   sched_job_term_cgroup init
#   sched_job_term_cgroup setup <job_id> <pid>   (runs in the job process)
#   sched_job_term_cgroup term <out_var> <pid>...
#   sched_job_term_cgroup cleanup <out_var>
# 'term' and 'cleanup' report kernel-verified killed PIDs by assigning a
# whitespace-separated list to the variable named <out_var>.
sched_job_term_cgroup() {
	local \
		stc_lib_name=sched_job_term_cgroup \
		stc_out_var stc_reaped='' stc_p stc_prev stc_try stc_had_f \
		stc_sub="${1}"

	shift 2>/dev/null

	case "${stc_sub}" in
		init)
			sch_tc_init
		;;

		setup)
			# Join a fresh per-job cgroup: writing '0' to cgroup.procs moves
			# the writing process, which is the job process since the core
			# invokes 'setup' there; all the job's descendants inherit the
			# membership
			sch_is_uint "${2}" ||
				{ sch_fail_msg "${stc_lib_name}: setup: invalid PID '${2}'."; return 1; }
			mkdir "${SCH_TC_BASE:?}/job_${2}" 2>/dev/null &&
			printf '0\n' 2>/dev/null > "${SCH_TC_BASE}/job_${2}/cgroup.procs" ||
			{
				sch_fail_msg "${stc_lib_name}: job '${1}' (PID ${2}): failed to join cgroup '${SCH_TC_BASE}/job_${2}'."
				return 1
			}
		;;

		term)
			stc_out_var="${1}"
			shift
			sch_check_name "var" "${stc_out_var}" "${stc_lib_name}: term" || return 1
			export -n "${stc_out_var}="

			# Retry previously unverified removals first, then kill
			stc_prev="${SCH_TC_PENDING}"
			SCH_TC_PENDING=
			for stc_p in ${stc_prev}; do
				sch_tc_try_rm "${stc_p}"
			done
			for stc_p in "${@}"; do
				sch_is_uint "${stc_p}" ||
					{ sch_fail_msg "${stc_lib_name}: term: ignoring invalid PID '${stc_p}'."; continue; }
				sch_tc_kill_job "${stc_p}"
			done

			export -n "${stc_out_var}=${stc_reaped}"
		;;

		cleanup)
			stc_out_var="${1}"
			sch_check_name "var" "${stc_out_var}" "${stc_lib_name}: cleanup" || return 1
			export -n "${stc_out_var}="

			# Sweep all remaining job cgroups - including those of completed
			# jobs that left processes behind: nothing a job spawned survives
			# the run. The glob must expand regardless of the caller's noglob
			# state (the application may run under set -f)
			[ -n "${SCH_TC_BASE}" ] && {
				sch_had_f && stc_had_f=1
				set +f
				set -- "${SCH_TC_BASE}"/job_*
				[ -z "${stc_had_f}" ] || set -f
				for stc_p in "${@}"; do
					[ -d "${stc_p}" ] || continue
					stc_p="${stc_p##*/job_}"
					sch_is_uint "${stc_p}" && sch_tc_kill_job "${stc_p}"
				done
			}

			# Bounded retry for unverified removals: rmdir succeeds only once
			# the kernel has fully reaped a cgroup's processes
			for stc_try in 1 2 3; do
				[ -n "${SCH_TC_PENDING}" ] || break
				stc_prev="${SCH_TC_PENDING}"
				SCH_TC_PENDING=
				for stc_p in ${stc_prev}; do
					sch_tc_try_rm "${stc_p}"
				done
				[ -n "${SCH_TC_PENDING}" ] || break
				[ "${stc_try}" = 3 ] || sleep 1
			done
			[ -z "${SCH_TC_BASE}" ] || {
				rmdir "${SCH_TC_BASE}" 2>/dev/null ||
					sch_fail_msg "${stc_lib_name}: failed to remove cgroup(s) under '${SCH_TC_BASE}'."
			}
			SCH_TC_BASE=

			export -n "${stc_out_var}=${stc_reaped}"
		;;

		*)
			sch_fail_msg "${stc_lib_name}: unknown subcommand '${stc_sub}'."
			return 1
	esac
}

# Check whether cgroup v2 job termination is supported in the current
#   environment: runs the same validation 'sched_job_term_cgroup init' performs
#   (cgroup v2 mount, cgroup.kill support, base cgroup creation, process
#   self-migration), then cleans up after itself.
# Honors ${SCHED_CGROUP_BASE} if set. Emits no messages.
# Return codes: 0 - supported; 1 - not supported
cgroup_cleanup_supported() {
	# Locals shadow the library state for the probe run; the ':' callback
	# override silences all reporting
	local SCH_TC_BASE SCH_TC_PENDING SCHED_FAIL_MSG_CB=: ccs_rv=0

	sch_tc_init || ccs_rv=1

	[ -z "${SCH_TC_BASE}" ] || rmdir "${SCH_TC_BASE}" 2>/dev/null
	return "${ccs_rv}"
}
