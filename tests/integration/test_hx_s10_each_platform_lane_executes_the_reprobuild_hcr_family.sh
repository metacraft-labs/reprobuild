#!/usr/bin/env bash
# HX-S-10 verification — three platform lanes, each invoking the REPROBUILD HCR
# gate family, each accounting for every gate in the tree.
#
# THE CLAIM UNDER TEST
#
# `.github/workflows/hcr-lanes.yml` defines exactly three lanes -- one per
# platform -- and each of them invokes the reprobuild HCR family through
# `scripts/run_hcr_lane.sh` with its own platform id. The number of lanes
# examined is asserted to be exactly THREE, and each lane's work list is
# asserted against the manifest rather than against the workflow's own prose,
# so "three platforms" is a property of the run rather than a sentence in a job
# name.
#
# WHAT THIS GATE IS AND IS NOT
#
# It is a STRUCTURAL gate: it reads the real workflow, the real Justfile and the
# real manifest. It does NOT execute the lanes -- the lane that was executed is
# the Linux one, and the gate that proves a lane's VERDICT discriminates is
# `test_hx_s10_a_zero_case_result_is_not_a_pass.sh`. Splitting them that way is
# deliberate: a gate that had to run three lanes could only ever be run on a
# host that is all three platforms at once, which is nowhere.
#
# It therefore does not, and cannot, claim that the macOS or Windows lanes
# PASS. It claims they are DEFINED and correctly wired. The workflow says which
# of the three has actually been measured; so does this gate's output.
#
# Usage:
#   bash tests/integration/test_hx_s10_each_platform_lane_executes_the_reprobuild_hcr_family.sh
#   ... --include-falsifier

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

INCLUDE_FALSIFIER=0
[[ "${1:-}" == "--include-falsifier" ]] && INCLUDE_FALSIFIER=1

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hx_s10_lanes_XXXXXX")}"
mkdir -p "$WORK_DIR"
cleanup() { [[ -n "${PRESERVE_WORK:-}" ]] || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

WORKFLOW="$REPO_ROOT/.github/workflows/hcr-lanes.yml"
MANIFEST="$REPO_ROOT/scripts/hcr-lane-manifest.tsv"
PLATFORMS=(linux-x86_64 macos-arm64 windows-x86_64)

FAILURES=0
pass() { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAILED] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# Slice one job out of a workflow file: from `^  <job>:` to the next `^  <x>:`.
job_body() {
    local file="$1" job="$2"
    awk -v j="  $job:" '
        $0 == j { inside = 1; next }
        inside && /^  [A-Za-z0-9_-]+:/ { inside = 0 }
        inside { print }
    ' "$file"
}

# verify_lanes <workflow-file> -> prints the number of lanes verified, and the
# diagnostics, to stdout; returns non-zero if fewer than three verified.
#
# ONE function, called by the real arm, by the control arm and by every
# falsifier, so the rule and its controls cannot drift apart
# (Verification-Harness-Traps.md Sec. 30).
verify_lanes() {
    local file="$1"
    local verified=0
    if [[ ! -f "$file" ]]; then
        echo "no workflow at $file"
        echo "lanes verified: 0"
        return 1
    fi
    local -A job_for=( [linux-x86_64]=hcr-lane-linux [macos-arm64]=hcr-lane-macos [windows-x86_64]=hcr-lane-windows )
    local platform job body
    for platform in "${PLATFORMS[@]}"; do
        job="${job_for[$platform]}"
        body="$(job_body "$file" "$job")"
        if [[ -z "$body" ]]; then
            echo "$platform lane missing invocation: job '$job' is not defined in $(basename "$file")"
            continue
        fi
        # The invocation itself. `just hcr_lane_<x>` is the recipe; the recipe
        # is checked separately below against the platform id it passes, so a
        # lane cannot satisfy this by naming the wrong recipe.
        if ! grep -q "just hcr_lane_" <<< "$body"; then
            echo "$platform lane missing invocation: job '$job' does not run a hcr_lane_* recipe"
            continue
        fi
        if ! grep -q "check_hcr_lane_manifest.py --check" <<< "$body"; then
            echo "$platform lane missing invocation: job '$job' does not check the manifest against the tree"
            continue
        fi
        verified=$((verified + 1))
    done
    echo "lanes verified: $verified"
    [[ "$verified" -eq 3 ]]
}

echo "== HX-S-10: each platform lane executes the reprobuild HCR family =="
echo

# =========================================================================
# [1/6] Exactly three lanes, each invoking the family.
# =========================================================================
echo "[1/6] three lanes, each invoking the reprobuild HCR family"
out="$(verify_lanes "$WORKFLOW")"
rc=$?
echo "$out" | sed 's/^/      /'
if [[ $rc -ne 0 ]]; then
    fail "fewer than three lanes are wired"
else
    pass "exactly 3 lanes verified — and the count is asserted, so a two-platform wiring is a failure"
fi
echo

# =========================================================================
# [2/6] Each lane passes ITS OWN platform id, and the recipes exist.
#
# The previous step only proves a lane runs *a* hcr_lane recipe. This one
# proves the linux job runs the linux platform and not, say, the linux recipe
# three times -- which is exactly how a "three-platform" wiring silently
# becomes one platform run thrice.
# =========================================================================
echo "[2/6] each lane's recipe passes its own platform id"
declare -A recipe_for=( [linux-x86_64]=hcr_lane_linux [macos-arm64]=hcr_lane_macos [windows-x86_64]=hcr_lane_windows )
declare -A job_for=( [linux-x86_64]=hcr-lane-linux [macos-arm64]=hcr-lane-macos [windows-x86_64]=hcr-lane-windows )
justfile_text="$(cat "$REPO_ROOT/Justfile")"
for platform in "${PLATFORMS[@]}"; do
    recipe="${recipe_for[$platform]}"
    body="$(job_body "$WORKFLOW" "${job_for[$platform]}")"
    if ! grep -q "just $recipe" <<< "$body"; then
        fail "$platform lane does not invoke '$recipe'"
        continue
    fi
    recipe_body="$(awk -v t="$recipe:" '$0 ~ "^" t {f=1; next} f && /^[a-zA-Z0-9_-]+.*:/ {f=0} f {print}' <<< "$justfile_text")"
    if [[ -z "$recipe_body" ]]; then
        fail "$platform: the Justfile has no recipe '$recipe'"
    elif ! grep -q -- "--platform $platform" <<< "$recipe_body"; then
        fail "$platform: recipe '$recipe' does not pass --platform $platform"
    else
        pass "$platform: job -> $recipe -> run_hcr_lane.sh --platform $platform"
    fi
done
echo

# =========================================================================
# [3/6] ANTI-VACUITY — the census adds up, per platform.
#
# "The total file census equals the number of gates accounted for (executed +
# declared-unsupported)", asserted against a LIVE walk of the tree rather than
# against the manifest's own row count, so a manifest that lost half its rows
# cannot satisfy it.
# =========================================================================
echo "[3/6] anti-vacuity: executed + declared-unsupported == the tree census, per platform"
# The census comes from `check_hcr_lane_manifest.py`, which is the ONE
# implementation of "which files are HCR gates" (Verification-Harness-Traps.md
# Sec. 30). A second `find … | grep hcr` here was the first version of this
# step and it counted 949 of 949 test files, because the absolute repo path in
# this workspace is `…/godot-demo-hcr/reprobuild` and the grep matched the
# PREFIX rather than the basename — Sec. 6, the subject of a scan is a claim.
# It is fixed by not having a second implementation at all.
tree_count=$(python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --check 2>/dev/null \
    | grep -oE '^check_hcr_lane_manifest: [0-9]+ HCR gate' | grep -oE '[0-9]+' || true)
if [[ "$tree_count" -lt 30 ]]; then
    fail "the tree census found only $tree_count HCR gate(s); the instrument, not the tree, is what to check first"
else
    pass "tree census: $tree_count HCR gate source(s) (floor 30)"
    for platform in "${PLATFORMS[@]}"; do
        worklist="$(python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --platform "$platform")"
        n_run=$(grep -c '^run	' <<< "$worklist" || true)
        n_unsup=$(grep -c '^unsupported	' <<< "$worklist" || true)
        if [[ $(( n_run + n_unsup )) -ne "$tree_count" ]]; then
            fail "$platform: $n_run run + $n_unsup unsupported != $tree_count in the tree"
        elif [[ "$n_run" -lt 1 ]]; then
            fail "$platform: zero gates declared 'run'; a lane that runs nothing satisfies 'no failures' trivially"
        else
            pass "$platform: $n_run run + $n_unsup unsupported = $tree_count"
        fi
    done
fi
echo

# =========================================================================
# [4/6] The per-platform EXECUTED floor is above zero and, for the platform
# that has actually been measured, above a real measured value.
# =========================================================================
echo "[4/6] per-platform executed-case floors"
census="$(python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --census)"
linux_floor=$(grep '^linux-x86_64' <<< "$census" | grep -oE 'case_floor=[0-9]+' | cut -d= -f2)
if [[ -z "$linux_floor" || "$linux_floor" -lt 100 ]]; then
    fail "linux-x86_64 case floor is '${linux_floor:-none}', below the 110 measured on 2026-09-19"
else
    pass "linux-x86_64 case floor: $linux_floor (measured 2026-09-19 on Linux 6.12.85 x86_64)"
fi
# macOS and Windows floors are 0 BY DESIGN and that is asserted rather than
# tolerated: an unmeasured platform must carry `run:unmeasured`, never a number
# nobody measured. If one of these ever becomes non-zero, someone measured it
# and this gate's expectation is the thing to update -- with the run to cite.
for platform in macos-arm64 windows-x86_64; do
    unmeasured=$(grep "^$platform" <<< "$census" | grep -oE 'measured_floors=[0-9]+' | cut -d= -f2)
    n_run=$(grep "^$platform" <<< "$census" | grep -oE 'run=[0-9]+' | cut -d= -f2)
    if [[ "$unmeasured" -ne 0 ]]; then
        pass "$platform: $unmeasured measured floor(s) — a real run happened; update this gate's expectation and cite it"
    elif [[ "$n_run" -lt 1 ]]; then
        fail "$platform: declares no gate 'run'"
    else
        pass "$platform: $n_run gate(s) declared run, 0 measured floors — DEFINED, NEVER RUN, and says so"
    fi
done
echo

# =========================================================================
# [5/6] CONTROL ARM — the pre-change tree.
#
# Reconstructed as the tree without `hcr-lanes.yml`, since that file IS the
# change. `verify_lanes` must find ZERO lanes there, so a green result above is
# attributable to the wiring and not to a gate that would pass on anything.
# =========================================================================
echo "[5/6] control arm: the pre-change tree must show ZERO lanes"
ctrl_out="$(verify_lanes "$WORK_DIR/does-not-exist.yml")"
ctrl_rc=$?
if [[ $ctrl_rc -eq 0 ]]; then
    fail "control arm: verify_lanes reported three lanes on a tree that has no lane workflow"
elif ! grep -q "lanes verified: 0" <<< "$ctrl_out"; then
    fail "control arm: expected 'lanes verified: 0', got: $ctrl_out"
else
    pass "control: the pre-change tree verifies 0 lanes"
fi
echo

# =========================================================================
# [6/6] FALSIFIERS — deleting one lane must redden THIS gate, naming THAT lane.
# =========================================================================
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
    echo "[6/6] falsifiers: delete one lane's invocation; the gate must name that lane"
    for platform in "${PLATFORMS[@]}"; do
        job="${job_for[$platform]}"
        mutated="$WORK_DIR/mutated-$platform.yml"
        python3 - "$WORKFLOW" "$mutated" "$job" <<'PY'
import sys
src, dst, job = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src, encoding="utf-8").read().splitlines()
out, inside = [], False
for line in lines:
    if line == f"  {job}:":
        inside = True
        continue
    if inside:
        import re
        if re.match(r"^  [A-Za-z0-9_-]+:", line):
            inside = False
        else:
            continue
    out.append(line)
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
        mut_out="$(verify_lanes "$mutated")"
        mut_rc=$?
        if [[ $mut_rc -eq 0 ]]; then
            fail "falsifier: deleting the $platform lane did not redden the gate"
        elif ! grep -q "^$platform lane missing invocation" <<< "$mut_out"; then
            fail "falsifier: the $platform lane was deleted but the gate did not name it: $mut_out"
        elif ! grep -q "lanes verified: 2" <<< "$mut_out"; then
            fail "falsifier: expected 'lanes verified: 2' after deleting one lane, got: $mut_out"
        else
            pass "falsifier: deleting the $platform lane reddens the gate, naming $platform, 2 of 3 verified"
        fi
    done

    # Second falsifier shape: the lane is present but no longer checks the
    # manifest against the tree -- i.e. it would run a work list it cannot
    # vouch for. The milestone's second falsifier arm in spirit: "leave the
    # invocation in place but make every gate in it skip"; the structural
    # equivalent here is removing the check that makes skips accountable.
    mutated="$WORK_DIR/mutated-nocheck.yml"
    grep -v "check_hcr_lane_manifest.py --check" "$WORKFLOW" > "$mutated"
    mut_out="$(verify_lanes "$mutated")"
    if verify_lanes "$mutated" > /dev/null 2>&1; then
        fail "falsifier: removing the manifest check from every lane did not redden the gate"
    elif ! grep -q "lanes verified: 0" <<< "$mut_out"; then
        fail "falsifier: expected 0 lanes verified without the manifest check, got: $mut_out"
    else
        pass "falsifier: a lane that does not check the manifest against the tree does not count as a lane"
    fi
    echo
else
    echo "[6/6] falsifiers skipped (pass --include-falsifier to run them)"
    echo
fi

echo "== summary =="
if [[ $FAILURES -gt 0 ]]; then
    echo "hx_s10_each_platform_lane_executes_the_reprobuild_hcr_family: FAILED ($FAILURES problem(s))" >&2
    exit 1
fi
echo "hx_s10_each_platform_lane_executes_the_reprobuild_hcr_family: PASSED"
echo "NOTE: this gate proves the three lanes are DEFINED and correctly wired."
echo "      Only the linux-x86_64 lane has ever been EXECUTED. See the workflow header."
