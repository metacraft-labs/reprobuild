#!/usr/bin/env bash
# HX-S-10 verification — a gate that reports 0 OK / 0 FAILED is not a pass.
#
# THE CLAIM UNDER TEST
#
# `scripts/run_hcr_lane.sh` reports a zero-case result, an undeclared
# `[SKIPPED]`, a below-floor case count and a bare skip inside a declared
# allowance as LANE RED — and reports a real run of real gates as LANE GREEN.
# Both halves are needed: a lane that reddened on everything would satisfy the
# first four arms and prove nothing.
#
# WHY IT DRIVES THE REAL LANE AND REAL GATES
#
# Every arm below runs `scripts/run_hcr_lane.sh` itself, over real `just`
# targets whose real output is parsed by the real verdict function. Nothing is
# simulated. The three refusal conditions are produced the way they occur in
# the wild:
#
#   ZERO-CASE    `e2e_hcr_in_target_link_and_trampoline` on Linux. Its body is
#                `when defined(macosx) and defined(arm64)`, so on this host it
#                compiles, runs, prints its suite header, executes NOTHING and
#                exits 0. That is the exact shape the milestone exists to end.
#   SKIP         `unit_hcr_watch_inference` on Linux — one of the two gates
#                HX-S-10 names by file. It prints `[SKIPPED]`, reports 0 OK / 0
#                FAILED and exits 0.
#   FLOOR        A gate that really does execute its cases, with its declared
#                floor raised above the count it really produces.
#
# HOW THE MUTATIONS ARE APPLIED — AND WHY NO TRACKED FILE IS EVER TOUCHED
#
# Through `REPRO_HCR_LANE_MANIFEST`, which points the lane at a COPY of
# `scripts/hcr-lane-manifest.tsv` under this run's work dir. The tracked
# manifest is never written, so there is no restore to get wrong and no way for
# a kill between mutation and restore to leave the tree modified
# (Verification-Harness-Traps.md Sec. 32h). The copy keeps ALL 46 rows -- the
# lane's own manifest-vs-tree check would refuse a subset -- and varies only
# the `linux-x86_64` cells, which is also what keeps each arm to a handful of
# compiles instead of the full 46-gate lane.
#
# The ONE arm that does mutate the tree plants a file and removes it in the
# same shell invocation under a trap, and then ASSERTS the tree is clean again.
#
# Usage:
#   bash tests/integration/test_hx_s10_a_zero_case_result_is_not_a_pass.sh
#   ... --include-falsifier     (adds the arms that must NOT discriminate)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

INCLUDE_FALSIFIER=0
[[ "${1:-}" == "--include-falsifier" ]] && INCLUDE_FALSIFIER=1

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hx_s10_zero_case_XXXXXX")}"
mkdir -p "$WORK_DIR"
cleanup() { [[ -n "${PRESERVE_WORK:-}" ]] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TRACKED_MANIFEST="$REPO_ROOT/scripts/hcr-lane-manifest.tsv"
FAILURES=0
ARMS=0

pass() { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAILED] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# --- the manifest mutator -------------------------------------------------
#
# Writes a copy of the tracked manifest in which EVERY `linux-x86_64` cell is
# `unsupported` except for the targets named on the command line, each of which
# takes the cell text given. All 46 rows survive, so the lane's own
# manifest-vs-tree check still passes and the arm is testing the VERDICT rather
# than the census.
#
# Every row it forces to `unsupported` on Linux also gets `run:unmeasured` on
# macOS, because the manifest checker refuses a row that is `unsupported` on all
# three platforms -- "a gate no lane ever runs is not covered by this campaign".
# That refusal is correct and the mutator must produce a PLAUSIBLE manifest, not
# an invalid one, or every arm below would redden at the census step and prove
# nothing about the verdict. (It was written the naive way first, and the gate's
# own census check is what said so -- on all 28 Linux-only rows at once.)
# The macOS cells are inert here: this is the linux-x86_64 lane.
#
#   write_manifest <out> <target>=<cell> [<target>=<cell> ...]
write_manifest() {
    local out="$1"; shift
    python3 - "$TRACKED_MANIFEST" "$out" "$@" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
overrides = dict(a.split("=", 1) for a in sys.argv[3:])
lines = open(src, encoding="utf-8").read().splitlines()
res = []
for line in lines:
    if not line.strip() or line.startswith("#"):
        res.append(line); continue
    f = line.split("\t")
    if f[0] == "source":
        res.append(line); continue
    if f[1] in overrides:
        f[2] = overrides[f[1]]
    else:
        f[2] = "unsupported"
        # Two rules of the checker have to be respected for the copy to be a
        # PLAUSIBLE manifest rather than an invalid one, or every arm below
        # would redden at the census step and prove nothing about the verdict:
        #   - no row may be `unsupported` on all three platforms;
        #   - a gate with no platform guard in its code may not be dropped from
        #     a lane without the greppable override token.
        if f[3] == "unsupported" and f[4] == "unsupported":
            f[3] = "run:unmeasured"
        f[5] = "unsupported-despite-portable: narrowed by the HX-S-10 lane gate's own " \
               "work-list mutator, so each arm compiles two gates instead of forty-one. " + f[5]
    res.append("\t".join(f))
open(out, "w", encoding="utf-8").write("\n".join(res) + "\n")
PY
}

run_lane() {
    # run_lane <manifest> <logfile> -> echoes the rc
    local manifest="$1" logfile="$2"
    REPRO_HCR_LANE_MANIFEST="$manifest" \
        bash "$REPO_ROOT/scripts/run_hcr_lane.sh" --platform linux-x86_64 \
        > "$logfile" 2>&1
    echo $?
}

echo "== HX-S-10: a zero-case result is not a pass =="
echo "-- work dir: $WORK_DIR"
echo

# =========================================================================
# ARM 0 — CONTROL. Real gates that really execute cases must be LANE GREEN.
#
# Without this arm the four refusals below prove nothing: an instrument that
# reddened unconditionally would satisfy all of them. It also supplies the
# milestone's anti-vacuity requirement directly -- "assert the runner observed
# a nonzero number of cases for at least one gate in the same run", so that
# "zero cases" is shown to be a DISTINGUISHABLE observation rather than the
# only thing the instrument can report.
#
# NOT RUN, and recorded rather than implied: the milestone's control arm also
# asks for the two named gates on the host that DOES support them (macOS
# arm64). This host cannot run that half. What is proved here is that the
# refusal is caused by the zero-case/skip RESULT and not by the gate's name,
# because the gates in this arm are refused by nothing and pass.
# =========================================================================
echo "[arm 0/5] CONTROL — real gates executing real cases are GREEN"
ARMS=$((ARMS + 1))
write_manifest "$WORK_DIR/m-control.tsv" \
    "unit_hcr_agent_protocol=run:28" "unit_hcr_agent_ipc=run:4"
rc=$(run_lane "$WORK_DIR/m-control.tsv" "$WORK_DIR/control.log")
if [[ "$rc" -ne 0 ]]; then
    fail "control arm: expected LANE GREEN, got rc=$rc"
    sed -n '1,60p' "$WORK_DIR/control.log" >&2
else
    observed=$(grep -oE 'executed assertion cases +: [0-9]+' "$WORK_DIR/control.log" | grep -oE '[0-9]+$')
    if [[ -z "$observed" || "$observed" -lt 32 ]]; then
        fail "control arm: expected >= 32 executed cases, observed '${observed:-none}'"
    else
        pass "control: LANE GREEN with $observed executed case(s) — a non-zero case count IS observable"
    fi
fi
echo

# =========================================================================
# ARM 1 — ZERO-CASE. rc 0, no [OK], no [FAILED], no [SKIPPED]: nothing ran.
# =========================================================================
echo "[arm 1/5] a gate that executes ZERO cases and exits 0 must REDDEN the lane"
ARMS=$((ARMS + 1))
write_manifest "$WORK_DIR/m-zero.tsv" \
    "unit_hcr_agent_protocol=run:28" "e2e_hcr_in_target_link_and_trampoline=run:unmeasured"
rc=$(run_lane "$WORK_DIR/m-zero.tsv" "$WORK_DIR/zero.log")
if [[ "$rc" -eq 0 ]]; then
    fail "zero-case arm: lane went GREEN on a gate that executed nothing"
elif ! grep -q "ZERO-CASE RESULT" "$WORK_DIR/zero.log"; then
    fail "zero-case arm: lane went red (rc=$rc) but did not name the ZERO-CASE condition"
    grep -i "refuse\|red" "$WORK_DIR/zero.log" >&2
elif ! grep -q "e2e_hcr_in_target_link_and_trampoline: ZERO-CASE RESULT" "$WORK_DIR/zero.log"; then
    fail "zero-case arm: the diagnostic does not NAME the gate"
else
    pass "zero-case: LANE RED (rc=$rc), naming e2e_hcr_in_target_link_and_trampoline"
    # …and the same run still saw the control gate's cases, so the refusal is
    # about the zero, not about the lane being unable to count at all.
    if grep -q "PASS  unit_hcr_agent_protocol" "$WORK_DIR/zero.log"; then
        pass "zero-case: the SAME run counted 28 cases from another gate"
    else
        fail "zero-case: the control gate in the same run did not report its cases"
    fi
fi
echo

# =========================================================================
# ARM 2 — [SKIPPED] on a gate the manifest says runs here.
# =========================================================================
echo "[arm 2/5] a [SKIPPED] the manifest did not declare must REDDEN the lane"
ARMS=$((ARMS + 1))
write_manifest "$WORK_DIR/m-skip.tsv" \
    "unit_hcr_agent_protocol=run:28" "unit_hcr_watch_inference=run:unmeasured"
rc=$(run_lane "$WORK_DIR/m-skip.tsv" "$WORK_DIR/skip.log")
if [[ "$rc" -eq 0 ]]; then
    fail "skip arm: lane went GREEN on a gate that printed [SKIPPED]"
elif ! grep -q "unit_hcr_watch_inference: SKIP-AS-GREEN" "$WORK_DIR/skip.log"; then
    fail "skip arm: lane went red (rc=$rc) but did not name the SKIP-AS-GREEN condition for that gate"
else
    pass "skip: LANE RED (rc=$rc), naming unit_hcr_watch_inference — the gate HX-S-10 names by file"
fi
echo

# =========================================================================
# ARM 3 — below the declared per-gate floor.
#
# This is the clause that catches "the suite quietly stopped running some of
# it" while every gate still exits 0 and skips nothing.
# =========================================================================
echo "[arm 3/5] a case count below the declared floor must REDDEN the lane"
ARMS=$((ARMS + 1))
write_manifest "$WORK_DIR/m-floor.tsv" "unit_hcr_agent_ipc=run:99"
rc=$(run_lane "$WORK_DIR/m-floor.tsv" "$WORK_DIR/floor.log")
if [[ "$rc" -eq 0 ]]; then
    fail "floor arm: lane went GREEN with a gate below its declared floor"
elif ! grep -q "unit_hcr_agent_ipc: CASE FLOOR" "$WORK_DIR/floor.log"; then
    fail "floor arm: lane went red (rc=$rc) but did not name the CASE FLOOR condition"
elif ! grep -q "below the declared floor of 99" "$WORK_DIR/floor.log"; then
    fail "floor arm: the diagnostic does not report the floor it measured against"
else
    pass "floor: LANE RED (rc=$rc), naming unit_hcr_agent_ipc and the floor it fell below"
fi
echo

# =========================================================================
# ARM 4 — a DECLARED skip must be a LOUD one.
#
# `run:N+skip:M` is the only cell form that admits a skip at all, and it would
# be the escape hatch the milestone warns about if the count were the whole
# rule. This arm drives the SAME `hcr_lane_verdict` function the lane drives
# (Verification-Harness-Traps.md Sec. 30 — one predicate, one function, rule
# and control both calling it) over the REAL log of a real gate, and over the
# same log with the loud line removed.
# =========================================================================
echo "[arm 4/5] a declared skip is accepted only when it NAMES its covering lane"
ARMS=$((ARMS + 1))
# shellcheck source=scripts/lib/hcr_lane_verdict.sh
source "$REPO_ROOT/scripts/lib/hcr_lane_verdict.sh"
REAL_LOG="$WORK_DIR/b4.log"
( cd "$REPO_ROOT" && just integration_b4_hcr_flags_in_repro_tests ) > "$REAL_LOG" 2>&1
b4_rc=$?
if ! grep -q "UNSUPPORTED:.*covered by " "$REAL_LOG"; then
    fail "declared-skip arm: the real gate did not print a loud UNSUPPORTED line; nothing to test"
else
    if hcr_lane_verdict "b4-real" "$b4_rc" "$REAL_LOG" 1 1; then
        pass "declared-skip: the REAL log (1 case, 1 loud skip) is accepted against run:1+skip:1"
    else
        fail "declared-skip: the real log was refused: $HCR_VERDICT_REASONS"
    fi
    # The same log, with only the loud line removed. Everything else -- the
    # [OK], the [SKIPPED], the exit status -- is byte-identical, so the arm
    # isolates the diagnostic and nothing else.
    grep -v "UNSUPPORTED:.*covered by " "$REAL_LOG" > "$WORK_DIR/b4-bare.log"
    if hcr_lane_verdict "b4-bare" "$b4_rc" "$WORK_DIR/b4-bare.log" 1 1; then
        fail "declared-skip: a BARE skip was accepted inside a skip:1 allowance"
    elif [[ "$HCR_VERDICT_REASONS" != *"BARE SKIP"* ]]; then
        fail "declared-skip: refused, but not for the BARE SKIP reason: $HCR_VERDICT_REASONS"
    else
        pass "declared-skip: the same log WITHOUT the loud line is refused as BARE SKIP"
    fi
fi
echo

# =========================================================================
# ARM 5 — the census. A gate in the tree with no row must stop the lane BEFORE
# any gate runs, and must name the undeclared file.
#
# This is the "added to one platform, forgot the other two" catch, and it is
# the one arm that mutates the tree. The plant is removed under a trap in the
# same shell invocation and the tree is ASSERTED clean afterwards
# (Verification-Harness-Traps.md Sec. 32h: `finally` is not a signal handler,
# so the recovery is checked rather than trusted).
# =========================================================================
echo "[arm 5/5] a gate in the tree with no manifest row must refuse the lane by name"
ARMS=$((ARMS + 1))
PLANT="$REPO_ROOT/tests/unit/t_hcr_hx_s10_planted_census_probe.nim"
plant_cleanup() { rm -f "$PLANT"; }
trap 'plant_cleanup; cleanup' EXIT
cat > "$PLANT" <<'NIM'
# Planted by tests/integration/test_hx_s10_a_zero_case_result_is_not_a_pass.sh
# and removed in the same shell invocation. If you are reading this in a
# checkout, that arm was killed between the plant and the removal: delete it.
import std/unittest
suite "planted": test "planted": check true
NIM
census_out="$WORK_DIR/census.log"
if python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --check > "$census_out" 2>&1; then
    fail "census arm: the checker accepted a tree containing an undeclared HCR gate"
elif ! grep -q "UNDECLARED HCR gate: tests/unit/t_hcr_hx_s10_planted_census_probe.nim" "$census_out"; then
    fail "census arm: refused, but did not name the planted file"
    cat "$census_out" >&2
elif ! grep -q "Declaring it for one platform is not" "$census_out"; then
    fail "census arm: the diagnostic does not state the all-three-platforms rule"
else
    pass "census: the checker refuses by name and states the all-three-platforms remedy"
fi
plant_cleanup
trap cleanup EXIT
if [[ -e "$PLANT" ]]; then
    fail "census arm: the planted probe survived removal at $PLANT"
elif ! python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --check > /dev/null 2>&1; then
    fail "census arm: the tree did not return to a clean state after the plant was removed"
else
    pass "census: the plant is gone and the tracked manifest agrees with the tree again"
fi
echo

# =========================================================================
# FALSIFIER ARMS — things that must NOT redden the lane, so the four refusals
# above are shown to be caused by what they name rather than by the mutation
# machinery.
# =========================================================================
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
    echo "[falsifier] a floor set exactly AT the measured count must stay GREEN"
    ARMS=$((ARMS + 1))
    write_manifest "$WORK_DIR/m-exact.tsv" "unit_hcr_agent_ipc=run:4"
    rc=$(run_lane "$WORK_DIR/m-exact.tsv" "$WORK_DIR/exact.log")
    if [[ "$rc" -ne 0 ]]; then
        fail "falsifier: a floor equal to the measured count reddened the lane (rc=$rc)"
        sed -n '1,40p' "$WORK_DIR/exact.log" >&2
    else
        pass "falsifier: floor == measured count is GREEN — the floor clause is >=, not >"
    fi
    echo

    echo "[falsifier] the tracked manifest itself must agree with the tree"
    ARMS=$((ARMS + 1))
    if python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --check > "$WORK_DIR/tracked.log" 2>&1; then
        pass "falsifier: the committed manifest passes its own census check"
    else
        fail "falsifier: the committed manifest does not agree with the tree"
        cat "$WORK_DIR/tracked.log" >&2
    fi
    echo
fi

echo "== summary =="
echo "   arms run: $ARMS"
if [[ $FAILURES -gt 0 ]]; then
    echo "hx_s10_a_zero_case_result_is_not_a_pass: FAILED ($FAILURES problem(s))" >&2
    exit 1
fi
echo "hx_s10_a_zero_case_result_is_not_a_pass: PASSED"
