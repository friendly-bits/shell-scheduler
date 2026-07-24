#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003,SC2329
# shellcheck source=/dev/null

# test-matrix.sh
# run the scheduler test suite across the {bash, busybox ash} x {full,mini} matrix in parallel,
#   using scheduler.sh itself as the parallel runner.

# Each combo writes its suite output to its own FIFO.
# A per-combo background drainer buffers each test's output - delimited by ${TEST_BLOCK_END},
#   which tests.sh emits after every test - and flushes the whole block to stdout under a shared mutex,
#   so each test's block prints contiguously even though combos run concurrently.
# The read-write FIFO opens mean a combo's open-for-write never blocks and a drainer never sees a
#   premature EOF; drainers stop on a ${MATRIX_STOP} sentinel.

# The scheduler gives per-combo timeout + tree-kill for free,
#   so a combo that wedges (e.g. a shell-specific hang) is reaped instead of stalling the matrix.

# Usage: bash test-matrix.sh [<tests.sh args>]   (default: run)
# Exit:  0 if every combo passed, non-zero otherwise.


matrix_cleanup() {
	trap - INT TERM EXIT
	[ -n "${MATRIX_SCHED_PID}" ] && {
		kill -TERM "${MATRIX_SCHED_PID}" 2>/dev/null
		wait "${MATRIX_SCHED_PID}"
	}
	[ -n "${DRAIN_PIDS}" ] && kill -KILL ${DRAIN_PIDS} 2>/dev/null
	exec 8>&- 9>&-
	rm -rf "${MATRIX_WORK_DIR}"
}

lock()   { IFS= read -r _ <&9; }
unlock() { printf 'x\n' >&9; }

get_combo_fifo() { printf '%s/out.%s' "${MATRIX_WORK_DIR}" "${1}"; }

# Per-combo drainer: buffer each test's block, flush it contiguously under the mutex.
# Combo identity is the FIFO it reads, so no per-line tagging is needed.
drain_combo() {
	local blk='' line
	exec 7<>"${1}"
	while IFS= read -r line <&7; do
		case "${line}" in
			"${MATRIX_STOP}") break ;;
			"${TEST_BLOCK_END}") lock; printf '%s' "${blk}"; unlock; blk= ;;
			*) blk="${blk}${line}${NL}" ;;
		esac
	done
	# Flush a trailing partial block (combo killed mid-test).
	[ -z "${blk}" ] || { lock; printf '%s' "${blk}"; unlock; }
	exec 7>&-
}


# --- callbacks ---

# DO_JOB_CB: run one combo. Params: shell (command word(s)), variant (full|mini).
# Streams the suite's output to the combo's FIFO and returns non-zero unless the suite reports zero
#   failures.
run_combo() {
	local id="${1}" shell variant
	job_get_params "${id}" shell variant || return 1

	# Run the suite in a clean environment (env -i):
	#   the outer scheduler's callback/SCHED_* vars are exported into this job by the '&' fork,
	#   and would otherwise leak into the inner run (e.g. an inherited JOB_TERM_CB the inner
	#   variant cannot resolve).
	# Close the mutex/summary fds (8, 9) so they do not leak into the suite or its job workers.
	# shellcheck disable=SC2086
	env -i MATRIX_ID="${id}" PATH="${PATH}" HOME="${HOME:-/}" TERM="${TERM:-dumb}" \
		SCHEDULER_VARIANT="${variant}" \
		TEST_BLOCK_END="${TEST_BLOCK_END}" \
		${shell} "${SUITE}" ${SUITE_ARGS} > "$(get_combo_fifo "${id}")" 2>&1 8>&- 9>&-
}

# SCHED_FAIL_MSG_CB: route scheduler errors to stdout, serialized via the mutex.
matrix_fail_msg() { lock; printf '[scheduler] %s\n' "${*}"; unlock; }

# SCHED_FINALIZE_CB: stash the matrix summary (printed in teardown, after all test blocks);
#   fail unless all combos are ok.
matrix_finalize() {
	local ok="${3}" fail="${4}" unfinished="${5}" undispatched="${6}" expired="${7}"
	{
		printf '\n===== matrix summary =====\n'
		printf 'passed:       %s\n' "${ok:-<none>}"
		printf 'failed:       %s\n' "${fail:-<none>}"
		printf 'timed out:    %s\n' "${expired:-<none>}"
		printf 'unfinished:   %s\n' "${unfinished:-<none>}"
		printf 'undispatched: %s\n' "${undispatched:-<none>}"
		printf '%s\n' "${TEST_BLOCK_END}"
	} >&8
	[ -z "${fail}${unfinished}${undispatched}${expired}" ]
}


script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

DEFAULT_IFS=" "$'\t'$'\n'
IFS="${DEFAULT_IFS}"

. "${script_dir}/../scheduler.sh"
. "${script_dir}/../job-term-ppid.sh"

SUITE="${script_dir}/tests.sh"
[ "${#}" -gt 0 ] || set -- run
SUITE_ARGS="${*}"


SHELLS="bash"$'\n'"busybox ash"

# --- matrix definition ---
IFS=$'\n'
for shell in ${SHELLS}; do
	command -v "${shell%% *}" 1>/dev/null || { printf '\n%s\n' "Warning: ${shell} not found; its combos will not run." >&2; continue; }
	for variant in full mini; do
		combo=${shell##* }_${variant}
		JOBS="${JOBS}${JOBS:+ }${combo}"
		jobs_init "${combo}" &&
		job_set_params "${combo}" "shell=${shell}" variant=${variant} || exit 1
	done
done
IFS="${DEFAULT_IFS}"

# --- work dir, markers, mutex, per-combo FIFOs + drainers ---
NL=$'\n'
# Distinctive one-line markers (SOH-prefixed so they cannot occur in test text).
TEST_BLOCK_END=$'\001__test_block_end__'
MATRIX_STOP=$'\001__matrix_stop__'

# shellcheck disable=SC2154
trap '
	rv=${?}
	matrix_cleanup
	exit ${rv}
' EXIT

trap '
	printf "\nAborting matrix run on receipt of a signal.\n" >&2
	matrix_cleanup
	printf "\n"
	exit 1
' INT TERM

MATRIX_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sched-matrix.XXXXXX") || exit 1

# Mutex as a 1-token FIFO semaphore on fd 9: serializes block flushes to stdout.
mkfifo "${MATRIX_WORK_DIR}/mutex" || { rm -rf "${MATRIX_WORK_DIR}"; exit 1; }
exec 9<>"${MATRIX_WORK_DIR}/mutex"
printf 'x\n' >&9

# Summary/control FIFO on fd 8: matrix_finalize writes the summary here;
#   the main shell prints it in teardown, after all test blocks have drained.
mkfifo "${MATRIX_WORK_DIR}/summary" || { rm -rf "${MATRIX_WORK_DIR}"; exit 1; }
exec 8<>"${MATRIX_WORK_DIR}/summary"


# Create drainer FIFO's
for id in ${JOBS}; do
	mkfifo "$(get_combo_fifo "${id}")" || { rm -rf "${MATRIX_WORK_DIR}"; exit 1; }
done

# Start drainers
DRAIN_PIDS=
for id in ${JOBS}; do
	drain_combo "$(get_combo_fifo "${id}")" &
	DRAIN_PIDS="${DRAIN_PIDS}${DRAIN_PIDS:+ }${!}"
done

# --- run the matrix (backgrounded: schedule_jobs exits its shell on finalize) ---
DO_JOB_CB=run_combo \
SCHED_FAIL_MSG_CB=matrix_fail_msg \
SCHED_FINALIZE_CB=matrix_finalize \
JOB_TERM_CB=sched_job_term_ppid \
SCHED_MAX_JOBS=4 \
SCHED_TIMEOUT_S="${MATRIX_TIMEOUT_S:-3600}" \
SCHED_IDLE_TIMEOUT_S="${MATRIX_IDLE_TIMEOUT_S:-3600}" \
SCHED_JOB_TIMEOUT_S="${MATRIX_JOB_TIMEOUT_S:-1800}" \
	schedule_jobs "${JOBS}" &

MATRIX_SCHED_PID=${!}
wait "${MATRIX_SCHED_PID}"
MATRIX_RV=${?}
MATRIX_SCHED_PID=

# Stop the drainers (each flushes any buffered block)
for id in ${JOBS}; do
	printf '%s\n' "${MATRIX_STOP}" > "$(get_combo_fifo "${id}")"
done
# shellcheck disable=SC2086
wait ${DRAIN_PIDS} 2>/dev/null
DRAIN_PIDS=

# Print the summary after all test blocks
while IFS= read -r line <&8; do
	[ "${line}" = "${TEST_BLOCK_END}" ] && break
	printf '%s\n' "${line}"
done

# Cleanup
matrix_cleanup

exit "${MATRIX_RV}"

