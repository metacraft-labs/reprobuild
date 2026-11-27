#!/usr/bin/env bash
# The lint's `nim check` sweep (scripts/check_nim_sources.sh) runs no more
# checks at once than the memory available to it can hold, and a check that
# dies says which one died and why.
#
# The defect this guards (measured 2026-11-26): the default concurrency
# was `nproc` alone. On a 32-processor host under the fleet's
# `MemoryMax=16G` scope, 32 checks were OOM-killed 42 s into a commit's lint,
# and the hook printed only `Terminated`. Neither a RunQuota daemon (which
# admits against the whole host) nor the fixed unleased bound of 4 sees such a
# cap, so the sweep also admits a check only while the reservations of the
# running checks (2560 MiB, 7 GiB for the engine checks, or
# REPRO_LINT_CHECK_MEM) fit the memory available to it.
#
# tests/test_lint_nim_checks_are_admitted.sh covers the leasing itself; this
# test covers the memory bound, in both modes, and the failure reports.
#
# Each case runs the REAL scripts/check_nim_sources.sh, inside a REAL transient
# systemd scope whose `MemoryMax` is the cap under test, so the memory limit
# the script reads is the kernel's cgroup v2 `memory.max` and not a value this
# test injects.
#
# MOCK JUSTIFICATION: `nim` is replaced, on PATH, by a recorder that notes how
# many copies of itself run at once, then sleeps briefly and succeeds. The
# property under test is the sweep's scheduling (how many checks it starts at
# once) and its failure report, not what `nim check` says about the sources.
# A real sweep costs up to ~6 GiB per check and minutes of wall clock, and at the
# fan-out the defect produces it is exactly the OOM kill this test must not
# inflict on the host. The defect was reproduced against the real compiler
# (see the commit that added this test); this test keeps it from coming back.
# The OOM case below does use a real allocation and the real kernel OOM killer.
#
# Cases (no RunQuota daemon is found unless a case starts one):
#   1. Unleased, under a 3 GiB cap, with no REPRO_LINT_JOBS: one check at a
#      time (2560 MiB each), where the unleased bound alone allows 4 and the
#      processor count 32.
#   1b. With REPRO_LINT_CHECK_MEM=512MiB under the same cap, the reservation
#      is what bounds it: several run at once again.
#   1c. Leased from a real `runquotad` whose budget admits every check, under
#      the same cap: still one at a time, every check leased.
#   2. An explicit REPRO_LINT_JOBS wins over the memory bound.
#   3. A REPRO_LINT_JOBS that is not a positive integer, or a
#      REPRO_LINT_CHECK_MEM that is not a size, is refused with status 2.
#   4. A check that is killed by a signal is reported by its source path and
#      the signal's name.
#   5. A check the kernel OOM killer kills (a real allocation past a 384 MiB
#      cap, scope OOMPolicy=continue so only that process dies) is reported as
#      an OOM kill, naming the knobs that bound the fan-out.
#   6. A sweep that is itself terminated (as systemd does to a whole scope
#      under OOMPolicy=stop) names the checks that were still running, and
#      only those: not the next check, still waiting for admission.
#   7. A check whose subshell is killed before it records a status does not
#      leave the sweep waiting forever on a reservation nothing will free; the
#      sweep finishes and reports that check's status as missing.
#
# Every sweep runs under `timeout`, so a sweep that hangs fails its case.
#
# Needs a user systemd manager (`systemd-run --user --scope`) on cgroup v2,
# `runquota` and `runquotad` (RUNQUOTA_BIN / RUNQUOTAD_BIN, a sibling
# ../runquota/build/bin, or PATH; a missing one FAILS the test), and the dev
# shell (scripts/source_paths.sh resolves the sibling sources).
#
#   bash tests/test_check_nim_sources_fan_out_fits_memory.sh
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v systemd-run >/dev/null || fail "systemd-run is required (the memory cap is a real cgroup)"
command -v flock >/dev/null || fail "flock is required (the recorder's counter)"
command -v python3 >/dev/null || fail "python3 is required (the real allocation in the OOM case)"
# The host's systemd-run must match the running manager, so it is not the dev
# shell's; it is started without the dev shell's LD_LIBRARY_PATH, which would
# hand it a second glibc (flake.nix, LD_LIBRARY_PATH, names this remedy), and
# the sweep inside the scope gets that variable back.
host_systemd_run() { env -u LD_LIBRARY_PATH systemd-run "$@"; }
host_systemd_run --user --scope -q -- true 2>/dev/null ||
  fail "cannot create a transient user scope (systemd-run --user --scope); run from a login session"

find_bin() { # find_bin <name> <override>
  local name="$1" override="$2"
  if [[ -n "${override}" && -x "${override}" ]]; then
    echo "${override}"
  elif [[ -x "${repo}/../runquota/build/bin/${name}" ]]; then
    echo "${repo}/../runquota/build/bin/${name}"
  else
    command -v "${name}" || true
  fi
}
rq_cli="$(find_bin runquota "${RUNQUOTA_BIN:-}")"
rq_daemon="$(find_bin runquotad "${RUNQUOTAD_BIN:-}")"
[[ -n "${rq_cli}" && -n "${rq_daemon}" ]] ||
  fail "runquota and runquotad are required (RUNQUOTA_BIN, RUNQUOTAD_BIN, ../runquota/build/bin or PATH)"
daemon_pid=""
trap '[[ -z "${daemon_pid}" ]] || kill "${daemon_pid}" 2>/dev/null || true; rm -rf "${scratch}"' EXIT

# No daemon the caller's environment names may leak in, and the developer's
# own per-user daemon and the host service are never found: every lookup the
# sweep makes points into this test's scratch directory.
unset RUNQUOTA_SOCKET RUNQUOTA_ENDPOINT_SCOPE RUNQUOTA_PARENT_LEASE \
  REPRO_LINT_JOBS REPRO_LINT_CHECK_MEM
export RUNQUOTA_USER_ENDPOINT_DIR="${scratch}/no-user-daemon"
export REPRO_HOST_RUNQUOTA_SOCKETS="${scratch}/no-host.sock"
export RUNQUOTA_BIN="${rq_cli}"

# The recorder that stands in for `nim` (see MOCK JUSTIFICATION above).
mkdir -p "${scratch}/bin"
cat >"${scratch}/bin/nim" <<'EOF'
#!/usr/bin/env bash
d="${FAKE_NIM_DIR:?}"
src="${*: -1}"
bump() {
  (
    flock 9
    local n=$(( $(cat "${d}/cur") + $1 ))
    echo "${n}" >"${d}/cur"
    if (( n > $(cat "${d}/max") )); then echo "${n}" >"${d}/max"; fi
  ) 9>"${d}/lock"
}
bump 1
case "${src}" in
  "${FAKE_NIM_KILL:-//none}") kill -KILL $$ ;;
  "${FAKE_NIM_HOG:-//none}")
    # Allocate (and touch) far past the scope's cap; the kernel OOM killer,
    # not this script, ends it.
    exec python3 -c 'b = []
while True: b.append(bytearray(b"x") * (64 << 20))' ;;
  "${FAKE_NIM_HANG:-//none}")
    # Becomes the sleep, so the PID it records is the process a terminated
    # sweep must stop.
    echo $$ >"${d}/hang-started.tmp"
    mv "${d}/hang-started.tmp" "${d}/hang-started"
    exec sleep 600 ;;
  "${FAKE_NIM_ORPHAN:-//none}")
    # Kill the sweep's per-check subshell, this process's parent (the check
    # is exec'd in place of its own subshell), before it can write a status.
    kill -KILL "${PPID}" ;;
esac
sleep "${FAKE_NIM_SLEEP:-0.05}"
bump -1
EOF
chmod +x "${scratch}/bin/nim"

# run_sweep <case> <MemoryMax> [systemd-run -p ...] -- [env ...]
# Runs the real sweep with the recorder first on PATH, inside a scope capped
# at <MemoryMax>. Leaves its output in ${scratch}/<case>.log, its status in
# ${scratch}/<case>.rc and the peak concurrency in ${scratch}/<case>/max.
run_sweep() {
  local name="$1" mem="$2"
  shift 2
  local props=()
  while [[ $# -gt 0 && "$1" != -- ]]; do props+=(-p "$1"); shift; done
  [[ $# -gt 0 ]] && shift
  local d="${scratch}/${name}"
  mkdir -p "${d}"
  echo 0 >"${d}/cur"
  echo 0 >"${d}/max"
  local rc=0
  (
    cd "${repo}"
    host_systemd_run --user --scope -q -p "MemoryMax=${mem}" -p MemorySwapMax=0 \
      ${props[@]+"${props[@]}"} -- \
      env "$@" ${LD_LIBRARY_PATH+LD_LIBRARY_PATH="${LD_LIBRARY_PATH}"} \
      PATH="${scratch}/bin:${PATH}" FAKE_NIM_DIR="${d}" \
      timeout 300 bash scripts/check_nim_sources.sh
  ) >"${scratch}/${name}.log" 2>&1 || rc=$?
  echo "${rc}" >"${scratch}/${name}.rc"
}
show() { sed 's/^/    /' "${scratch}/$1.log" | tail -n 20 >&2; }

# Case 1: unleased, the default reservations fit one check in a 3 GiB cap.
run_sweep capped 3G -- FAKE_NIM_SLEEP=0.1
[[ "$(cat "${scratch}/capped.rc")" == 0 ]] || { show capped; fail "capped sweep failed"; }
grep -q 'unleased, at most 4 nim checks at a time' "${scratch}/capped.log" ||
  { show capped; fail "fixture: the sweep did not run unleased"; }
peak="$(cat "${scratch}/capped/max")"
(( peak >= 1 )) || { show capped; fail "the recorder never ran"; }
[[ "${peak}" == 1 ]] || {
  show capped
  fail "under a 3 GiB cap the unleased sweep ran ${peak} checks at once; at 2560 MiB each, one fits"
}
grep -q 'MiB available' "${scratch}/capped.log" ||
  { show capped; fail "the sweep does not say what memory bound its concurrency"; }

# Case 1b: a smaller reservation lets several fit in the same cap.
run_sweep small 3G -- REPRO_LINT_CHECK_MEM=512MiB FAKE_NIM_SLEEP=0.3
[[ "$(cat "${scratch}/small.rc")" == 0 ]] || { show small; fail "small-reservation sweep failed"; }
peak="$(cat "${scratch}/small/max")"
(( peak >= 2 && peak <= 4 )) ||
  { show small; fail "at 512 MiB a check, a 3 GiB cap ran ${peak} at once (expected 2..4, the unleased bound)"; }

# Case 1c: leased from a daemon that would admit every check, the cap still
# bounds the sweep: the daemon cannot see this scope's memory.max.
sock="${scratch}/rq/runquotad.sock"
mkdir -p "${scratch}/rq"
chmod 700 "${scratch}/rq"
# The private endpoint scope, as a user's own daemon runs: a socket directory
# the test's user owns is refused under any other scope.
RUNQUOTA_ENDPOINT_SCOPE=private "${rq_daemon}" --socket "${sock}" \
  --host-config "${scratch}/rq/host.toml" --host-identity-file "${scratch}/rq/host-id" \
  --estimate-db "${scratch}/rq/estimates.sqlite" --no-write-stats \
  --ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
  --cpu-milli 64000 --memory-bytes $((512 * 1024 * 1024 * 1024)) \
  >"${scratch}/rq/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 200); do
  grep -q "runquotad listening" "${scratch}/rq/daemon.log" 2>/dev/null && break
  kill -0 "${daemon_pid}" 2>/dev/null || { cat "${scratch}/rq/daemon.log" >&2; fail "runquotad exited before it listened"; }
  sleep 0.05
done
grep -q "runquotad listening" "${scratch}/rq/daemon.log" || fail "runquotad never listened"
run_sweep leased 3G -- RUNQUOTA_SOCKET="${sock}" RUNQUOTA_ENDPOINT_SCOPE=private FAKE_NIM_SLEEP=0.1
[[ "$(cat "${scratch}/leased.rc")" == 0 ]] || { show leased; fail "leased sweep failed"; }
grep -q "leasing each nim check" "${scratch}/leased.log" ||
  { show leased; fail "fixture: the sweep did not lease from the test's daemon"; }
peak="$(cat "${scratch}/leased/max")"
[[ "${peak}" == 1 ]] || {
  show leased
  fail "leased from a daemon with 64 CPUs and 512 GiB, a 3 GiB cap ran ${peak} checks at once; one fits"
}
kill "${daemon_pid}" 2>/dev/null || true
wait "${daemon_pid}" 2>/dev/null || true
daemon_pid=""

# Case 2: an explicit REPRO_LINT_JOBS wins.
run_sweep explicit 3G -- REPRO_LINT_JOBS=4 FAKE_NIM_SLEEP=0.3
[[ "$(cat "${scratch}/explicit.rc")" == 0 ]] || { show explicit; fail "explicit sweep failed"; }
peak="$(cat "${scratch}/explicit/max")"
[[ "${peak}" == 4 ]] || { show explicit; fail "REPRO_LINT_JOBS=4 ran ${peak} checks at once"; }

# Case 3: malformed settings are refused, not guessed at.
for setting in REPRO_LINT_JOBS=lots REPRO_LINT_JOBS=0 REPRO_LINT_CHECK_MEM=big; do
  run_sweep malformed 3G -- "${setting}"
  rc="$(cat "${scratch}/malformed.rc")"
  [[ "${rc}" == 2 ]] || { show malformed; fail "${setting} must be refused with status 2, got ${rc}"; }
  grep -q "${setting%%=*}" "${scratch}/malformed.log" ||
    { show malformed; fail "the refusal of ${setting} does not name the variable"; }
done

# Case 4: a killed check is named, with its signal.
victim="libs/repro_core/src/repro_core.nim"
grep -q '^repro_core\b' "${repo}/libs/libraries.txt" || fail "fixture: repro_core is no longer in libs/libraries.txt"
run_sweep killed 3G -- REPRO_LINT_JOBS=2 FAKE_NIM_KILL="${victim}"
[[ "$(cat "${scratch}/killed.rc")" == 1 ]] || { show killed; fail "a killed check must fail the sweep with status 1"; }
grep -F "${victim}" "${scratch}/killed.log" | grep -q 'SIGKILL' ||
  { show killed; fail "the failure report does not name ${victim} as killed by SIGKILL"; }

# Case 5: a check the kernel OOM killer kills is reported as such.
run_sweep oom 384M OOMPolicy=continue -- REPRO_LINT_JOBS=1 FAKE_NIM_HOG="${victim}"
[[ "$(cat "${scratch}/oom.rc")" == 1 ]] || { show oom; fail "an OOM-killed check must fail the sweep with status 1"; }
grep -F "${victim}" "${scratch}/oom.log" | grep -q 'SIGKILL' ||
  { show oom; fail "the failure report does not name ${victim} as killed"; }
grep -qi 'out of memory\|OOM' "${scratch}/oom.log" ||
  { show oom; fail "an OOM kill is not reported as one"; }
grep -q 'REPRO_LINT_JOBS' "${scratch}/oom.log" ||
  { show oom; fail "the OOM report does not name REPRO_LINT_JOBS"; }
grep -q 'REPRO_LINT_CHECK_MEM' "${scratch}/oom.log" ||
  { show oom; fail "the OOM report does not name REPRO_LINT_CHECK_MEM"; }

# Case 6: a terminated sweep names the checks that were running.
d="${scratch}/term"
mkdir -p "${d}"
echo 0 >"${d}/cur"
echo 0 >"${d}/max"
(
  cd "${repo}"
  exec env PATH="${scratch}/bin:${PATH}" FAKE_NIM_DIR="${d}" REPRO_LINT_JOBS=1 \
    FAKE_NIM_HANG="${victim}" bash scripts/check_nim_sources.sh
) >"${scratch}/term.log" 2>&1 &
sweep=$!
for _ in $(seq 1 600); do
  [[ -e "${d}/hang-started" ]] && break
  sleep 0.1
done
[[ -e "${d}/hang-started" ]] || { kill -KILL "${sweep}" 2>/dev/null; show term; fail "the hanging check never started"; }
kill -TERM "${sweep}"
rc=0
wait "${sweep}" || rc=$?
(( rc != 0 )) || { show term; fail "a terminated sweep exited 0"; }
# The running check itself was stopped, not left behind: TERM reached the
# recorder through the per-check subshell.
hung="$(cat "${d}/hang-started")"
for _ in $(seq 1 50); do
  kill -0 "${hung}" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "${hung}" 2>/dev/null; then
  kill -KILL "${hung}" 2>/dev/null || true
  show term
  fail "a terminated sweep left its running check (pid ${hung}) behind"
fi
grep -F "${victim}" "${scratch}/term.log" | grep -qi 'running' ||
  { show term; fail "a terminated sweep does not name the check that was running (${victim})"; }
listed="$(grep -c '(running)$' "${scratch}/term.log" || true)"
[[ "${listed}" == 1 ]] ||
  { show term; fail "with REPRO_LINT_JOBS=1 a terminated sweep listed ${listed} checks as running, not 1"; }

# Case 7: a check whose subshell dies without a status does not hang the sweep.
run_sweep orphan 3G -- REPRO_LINT_JOBS=1 FAKE_NIM_ORPHAN="${victim}"
rc="$(cat "${scratch}/orphan.rc")"
[[ "${rc}" == 1 ]] || { show orphan; fail "a check that died without a status must fail the sweep with status 1, got ${rc} (124: the sweep hung)"; }
grep -F "${victim}" "${scratch}/orphan.log" | grep -q 'missing' ||
  { show orphan; fail "the failure report does not show ${victim}'s status as missing"; }

echo "PASS"
