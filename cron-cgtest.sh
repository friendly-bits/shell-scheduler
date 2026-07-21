#!/bin/sh
# cron-cgtest.sh - exercise cgroup job termination (JOB_TERM_CB) from a cron job
#
# Runs a 3-job batch where jobs deliberately leave processes behind, then
# verifies the scheduler's cgroup cleanup actually killed them:
#   straggler - succeeds instantly, leaves a background child and an orphaned
#               grandchild (both would outlive the batch without cleanup)
#   timeout   - blocks on a child until its 3 s per-job timeout kills the tree
#   ok        - plain success, spawns nothing
# Every spawned PID is recorded; after the batch each must be dead.
#
# Appends a timestamped report to the log; the last line of each run is
# 'RESULT: PASS' or 'RESULT: FAIL ...'.
#
# Example cron entries:
#   root (OpenWrt or any distro):
#     * * * * * /path/to/cron-cgtest.sh
#   unprivileged user on a systemd distro (user manager must be running -
#   'loginctl enable-linger <user>' if not always logged in):
#     * * * * * XDG_RUNTIME_DIR=/run/user/<uid> systemd-run --user --scope --quiet /path/to/cron-cgtest.sh
#
# Env overrides:
#   CGTEST_LOG    log file (default: /tmp/sched-cgtest.log)
#   SCHEDULER_SH  path to scheduler.sh (default: next to this script); must
#                 contain a '/', and scheduler-job-term-cgroup.sh must sit next to it

LOG="${CGTEST_LOG:-/tmp/sched-cgtest.log}"
exec >> "${LOG}" 2>&1

log() {
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${$}" "${*}"
}

fail_cnt=0
fail() {
	fail_cnt=$((fail_cnt + 1))
	log "FAIL: ${*}"
}

SCHED_LIB="${SCHEDULER_SH:-${0%/*}/scheduler.sh}"
. "${SCHED_LIB}" &&
. "${SCHED_LIB%/*}/scheduler-job-term-cgroup.sh" || {
	log "RESULT: FAIL - cannot source scheduler.sh / scheduler-job-term-cgroup.sh"
	exit 1
}

PIDS_F="${TMPDIR:-/tmp}/sched_cgtest_pids_${$}"
: > "${PIDS_F}"

do_job() {
	case "${1}" in
		straggler)
			sleep 300 &
			printf '%s\n' "${!}" >> "${PIDS_F}"
			(
				sleep 300 &
				printf '%s\n' "${!}" >> "${PIDS_F}"
			) &
			# returns immediately: both sleeps become the job's leftovers
			;;
		timeout)
			sleep 300 &
			printf '%s\n' "${!}" >> "${PIDS_F}"
			wait "${!}"
			;;
		ok)
			: ;;
	esac
}

job_done() {
	local extra=
	[ -n "${3}" ] && extra=" (timed out, wrapper pid ${3})"
	log "job done: id='${1}' rv=${2}${extra}"
}

finalize() {
	log "finalize: rv=${1} running_pids='${2}' ok='${3}' fail='${4}' unfinished='${5}' undispatched='${6}' expired='${7}'"
}

log "=== run start: uid=$(id -u), cgroup=$(cat /proc/self/cgroup 2>/dev/null) ==="

job_set_timeout timeout 3 || fail "job_set_timeout"

DO_JOB_CB=do_job \
JOB_DONE_CB=job_done \
SCHED_FINALIZE_CB=finalize \
SCHED_MAX_JOBS=3 \
SCHED_TIMEOUT_S=60 \
JOB_TERM_CB=sched_job_term_cgroup \
	schedule_jobs "straggler timeout ok" &
wait "${!}"
sched_rv=${?}

log "scheduler rv=${sched_rv}"
[ "${sched_rv}" = 0 ] || fail "scheduler rv=${sched_rv} (want 0)"

# Give the kernel a moment to finish reaping, then verify every recorded
# process is gone
sleep 1

pid_cnt=0
while read -r pid; do
	pid_cnt=$((pid_cnt + 1))
	kill -0 "${pid}" 2>/dev/null && {
		fail "pid ${pid} still alive"
		kill -9 "${pid}" 2>/dev/null
	}
done < "${PIDS_F}"
rm -f "${PIDS_F}"

[ "${pid_cnt}" = 3 ] || fail "recorded ${pid_cnt} spawned pids (want 3)"

if [ "${fail_cnt}" = 0 ]; then
	log "RESULT: PASS"
else
	log "RESULT: FAIL (${fail_cnt} problem(s))"
	exit 1
fi
