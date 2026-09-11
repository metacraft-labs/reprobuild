#!/usr/bin/env bash
# GDH-M4 gate driver — a session serves more than one reload.
#
# Design: `codetracer-specs/Planned-Features/`
#         `GDScript-Hot-Reload-Multi-Version-Sources.md` §4.2-§4.4.
# Milestone: the `GDH-M4` block of the campaign's `.milestones.org`.
#
# What runs here:
#
#   1. `gdh4_second_reload_is_distinct`, unmutated, plus its CONTROL ARM
#      (a single notification acknowledged with generation 2).
#   2. `gdh4_unnegotiated_capability_is_refused_not_ignored`, unmutated, plus
#      its CONTROL ARM (the identical message to a host that DID advertise).
#   3. Every named falsifier arm, each of which must turn ITS gate red while
#      leaving its control green.
#
# Rules it enforces (codetracer-specs/Testing/Verification-Harness-Traps.md):
#
#   * COMPILE and RUN are separate steps; a compile error is never a red gate.
#   * A hang is rc 124 and NOTHING ELSE — and no arm here is allowed to be one.
#     Arm 2 was measured as rc 124 during development, which made it a
#     CHECK-FAIL rather than a kill; the driver was fixed (every socket wait is
#     bounded) and the arm now fails by name in milliseconds. The rc-124 check
#     below is what keeps that from regressing.
#   * An arm must go red IN THE GATE IT IS AIMED AT — every failure carries a
#     `GDH4-FAIL[<gate>]` prefix and this driver requires the right one.
#   * A DRIVER-FAIL (rc 2) is never counted as a kill.
#   * The unmutated runs must be GREEN first.
#
# Usage:  tests/e2e/hcr-source-reload/run_gdh4_gates.sh
# Exit:   0 iff every gate is green and every arm is red in its own gate.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

CASE_DIR="$REPO/tests/e2e/hcr-source-reload"
WORK="${GDH4_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
TIMEOUT="${GDH4_TIMEOUT:-120}"
AGENT_C="$REPO/libs/repro_hcr_agent/c/repro_hcr_agent.c"
AGENT_INC="$REPO/libs/repro_hcr_agent/c"

# `sun_path` is 108 bytes. A work dir under a long scratch root cannot hold the
# socket, so the gate binary places it under a short directory; this is where
# that directory is chosen, loudly.
if [[ -z "${GDH4_SOCKET_DIR:-}" ]]; then
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
    GDH4_SOCKET_DIR="$XDG_RUNTIME_DIR"
  else
    GDH4_SOCKET_DIR="/tmp"
  fi
fi
export GDH4_SOCKET_DIR

fail_script() { echo "DRIVER-FAIL: $*" >&2; exit 1; }

failures=0
green=0
redarms=0

# ---------------------------------------------------------------------------
# 0. Prerequisites, stated loudly. A missing one must fail the run, never be
#    skipped past.
# ---------------------------------------------------------------------------
command -v gcc >/dev/null || fail_script "gcc is not on PATH"
command -v nim >/dev/null || fail_script "nim is not on PATH"
[[ -f "$AGENT_C" ]] || fail_script "the production C agent is missing: $AGENT_C"
[[ -f "$CASE_DIR/gdh4_source_reload_host.c" ]] ||
  fail_script "the host source is missing"
[[ -f "$CASE_DIR/gdh4_gate.nim" ]] || fail_script "the gate source is missing"

# ---------------------------------------------------------------------------
# 1. Build the coordinator-side gate binary and every host arm.
# ---------------------------------------------------------------------------
echo "== build =="

if ! nim c --hints:off --warnings:off -d:release \
     -p:libs/repro_hcr_agent/src -p:libs/repro_hcr_linkgraph/src \
     -p:libs/repro_hcr_linker/src -p:libs/repro_hash/src \
     -p:libs/repro_core/src -p:. \
     --nimcache:"$WORK/nc-gate" -o:"$WORK/gdh4_gate" \
     "$CASE_DIR/gdh4_gate.nim" >"$WORK/gate.build.log" 2>&1; then
  tail -30 "$WORK/gate.build.log" >&2
  fail_script "the gate driver does not compile"
fi

build_host() {  # build_host <tag> [-Ddefine ...]
  local tag="$1"; shift
  gcc -O2 -g -I "$AGENT_INC" -o "$WORK/host-$tag" \
    "$CASE_DIR/gdh4_source_reload_host.c" "$AGENT_C" -lpthread "$@" \
    >"$WORK/host-$tag.build.log" 2>&1
}

if ! build_host plain; then
  tail -30 "$WORK/host-plain.build.log" >&2
  fail_script "the unmutated host does not build"
fi
echo "built: gate driver + unmutated host"
echo

run_gate() {  # run_gate <mode> <hostbin> <tag>; echoes rc
  local mode="$1" host="$2" tag="$3"
  rm -rf "$WORK/$tag"
  timeout "$TIMEOUT" "$WORK/gdh4_gate" "$mode" "$WORK/$tag" "$host" \
    >"$WORK/$tag.out" 2>&1
  echo $?
}

check_green() {  # check_green <mode> <tag> <label>
  local mode="$1" tag="$2" label="$3"
  local rc
  rc=$(run_gate "$mode" "$WORK/host-plain" "$tag")
  if [[ "$rc" == "124" ]]; then
    echo "GATE-FAIL: $label HUNG (rc 124)" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$rc" != "0" ]]; then
    cat "$WORK/$tag.out" >&2
    echo "GATE-FAIL: $label is RED (rc $rc)" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -q "^PASS: " "$WORK/$tag.out"; then
    echo "GATE-FAIL: $label exited 0 without printing a PASS line" >&2
    failures=$((failures + 1))
    return
  fi
  cat "$WORK/$tag.out"
  green=$((green + 1))
}

# ---------------------------------------------------------------------------
# 2. The unmutated gates and their control arms.
# ---------------------------------------------------------------------------
echo "== gdh4_second_reload_is_distinct — CONTROL ARM (one notification) =="
check_green one-reload ctrl-one "the single-notification control"
echo

echo "== gdh4_second_reload_is_distinct =="
check_green two-reloads two "gdh4_second_reload_is_distinct"
echo

echo "== gdh4_unnegotiated_capability_is_refused_not_ignored — CONTROL ARM =="
check_green negotiated-control ctrl-neg "the advertising-host control"
echo

echo "== gdh4_unnegotiated_capability_is_refused_not_ignored =="
check_green unnegotiated unneg \
  "gdh4_unnegotiated_capability_is_refused_not_ignored"
echo

# ---------------------------------------------------------------------------
# 3. Falsifier arms.
# ---------------------------------------------------------------------------

# `run_arm` requires FOUR things of an arm, not two:
#   * it must COMPILE (a compile error is not a red gate);
#   * its CONTROL mode must stay green where the milestone says it should, so
#     the arm is shown to DISCRIMINATE rather than to fail everywhere;
#   * the targeted mode must exit non-zero, and not with 124;
#   * the failure must carry `GDH4-FAIL[<the gate it is aimed at>]`.
run_arm() {  # run_arm <tag> <define> <control-mode|-> <target-mode> <gate>
  local tag="$1" define="$2" control="$3" target="$4" gate="$5"
  echo "-- arm $tag (C: -D$define)"
  if ! build_host "$tag" "-D$define"; then
    tail -20 "$WORK/host-$tag.build.log" >&2
    echo "ARM-FAIL: $tag did not COMPILE; a compile error is not a red gate" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$control" != "-" ]]; then
    local crc
    crc=$(run_gate "$control" "$WORK/host-$tag" "arm-$tag-ctrl")
    if [[ "$crc" != "0" ]]; then
      cat "$WORK/arm-$tag-ctrl.out" >&2
      echo "ARM-FAIL: $tag went red on its CONTROL ($control, rc $crc). It" \
           "must pass there — an arm that fails everywhere has not been" \
           "shown to discriminate." >&2
      failures=$((failures + 1))
      return
    fi
    echo "   control ($control): PASSES under the mutation, as it must"
  fi
  local rc
  rc=$(run_gate "$target" "$WORK/host-$tag" "arm-$tag")
  if [[ "$rc" == "124" ]]; then
    echo "ARM-FAIL: $tag HUNG (rc 124). Trap 1: a hang is not a diagnosis," \
         "and an arm that 'detects' a defect by hanging has not been" \
         "distinguished from a driver bug. CHECK-FAIL, not a kill." >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$rc" == "0" ]]; then
    echo "ARM-FAIL: $tag PASSED $target; the mutation did not turn it red" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$rc" == "2" ]]; then
    cat "$WORK/arm-$tag.out" >&2
    echo "ARM-FAIL: $tag exited 2 (DRIVER-FAIL). A harness failure is not a" \
         "kill." >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -q "GDH4-FAIL\[$gate\]" "$WORK/arm-$tag.out"; then
    echo "ARM-FAIL: $tag exited $rc but not with GDH4-FAIL[$gate]:" >&2
    cat "$WORK/arm-$tag.out" >&2
    failures=$((failures + 1))
    return
  fi
  echo "   RED (rc $rc): $(grep -o 'GDH4-FAIL\[.*' "$WORK/arm-$tag.out" | head -1 | cut -c1-190)"
  redarms=$((redarms + 1))
}

# ARM 1 — the milestone's own mutation: the acknowledged generation is the
#   literal 1, i.e. `repro_hcr_agent.c`'s shipping `symbolGeneration: 1`
#   reproduced deliberately. It has NO control mode, and that is recorded
#   rather than papered over: design §4.3 numbered generations so that 1 is
#   never a valid value, so this mutation is caught on the FIRST notification
#   as well and cannot be shown to discriminate one reload from two. ARM 1b is
#   the half that can.
run_arm gen REPRO_HCR_GDH4_FALSIFY_HARDCODE_GENERATION - two-reloads \
  gdh4_second_reload_is_distinct

# ARM 1b — added because ARM 1 fires everywhere. Every reload is acknowledged
#   with the generation of the FIRST one, so a single-notification session is
#   perfectly correct and only a SECOND reload reveals it. This is GDH-G8's
#   property and the shape the campaign keeps shipping: a value that is
#   coincidentally right for the one case anybody exercised.
run_arm latch REPRO_HCR_GDH4_FALSIFY_LATCH_FIRST_GENERATION one-reload \
  two-reloads gdh4_second_reload_is_distinct

# ARM 2 — the pre-GDH-M4 agent restored: `repro_hcr_poll_done = 1` after the
#   first message. The control (one notification) must still pass, because one
#   patch per process is exactly the case the old agent handled.
run_arm oneshot REPRO_HCR_GDH4_FALSIFY_ONE_SHOT_POLL one-reload two-reloads \
  gdh4_second_reload_is_distinct

# ARM 3 — the host IGNORES a message it cannot serve instead of refusing it.
#   The control (a host that CAN serve it) must still pass, so the arm is shown
#   to act only on the unnegotiated path.
run_arm ignore REPRO_HCR_GDH4_FALSIFY_IGNORE_UNKNOWN_KIND negotiated-control \
  unnegotiated gdh4_unnegotiated_capability_is_refused_not_ignored

echo
echo "======================================================"
echo "gates green:   $green of 4"
echo "arms gone red: $redarms of 4"
echo "failures:      $failures"
echo "work dir:      $WORK"
if [[ $failures -ne 0 || $green -ne 4 || $redarms -ne 4 ]]; then
  exit 1
fi
echo "GDH-M4: one process served two reloads with distinct generations and"
echo "        distinct host-recomputed digests; an unnegotiated notification"
echo "        was REFUSED by name rather than ignored; all four falsifier arms"
echo "        went red in their own gates, none of them by hanging"
