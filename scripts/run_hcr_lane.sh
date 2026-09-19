#!/usr/bin/env bash
# HX-S-10 — one platform lane over the reprobuild HCR gate family.
#
# WHAT IT IS FOR
#
# Before this script, "the HCR gates pass" was a sentence about one developer's
# host on one date.  Worse, two of the gates -- `t_hcr_agent_process_target` and
# `t_hcr_watch_inference` -- print `[SKIPPED]`, report 0 OK / 0 FAILED and exit
# 0 off-platform, so a runner keying on exit status reads them as green.  The
# whole point of this script is that it does NOT key on exit status.
#
# THE CONTRACT
#
#   * The work list comes from `scripts/hcr-lane-manifest.tsv`, which declares
#     for every HCR gate source in the tree what EACH of the three platforms
#     does with it.  The manifest is held to the tree by
#     `scripts/check_hcr_lane_manifest.py`, which this script runs FIRST: a lane
#     whose work list disagrees with the tree is refused before any gate runs.
#   * Every declared-`run` gate must reach a PASS under
#     `scripts/lib/hcr_lane_verdict.sh` -- rc 0, no [FAILED], NO [SKIPPED],
#     a non-zero case count, and a case count at or above its declared floor.
#   * Every declared-`unsupported` gate is NAMED in the census with the lane
#     that does cover it, so executed + unsupported == the whole census and a
#     gate cannot fall out of the accounting.
#   * `--verify-unsupported` additionally RUNS the declared-unsupported gates
#     and requires each to execute zero cases here.  This is the drift check in
#     the other direction: a gate that quietly became portable, or was declared
#     unsupported to dodge a red, is caught.  It is opt-in because it doubles
#     the lane's build cost; the Linux lane runs it.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It does not lower a floor, narrow a `targetOs`, or add a skip to make a lane
# green.  A gate that fails is reported failing.  The `rb_hcr_*` application ABI
# contract gate is expected RED on Windows (HWX-M0's known gap) and the Windows
# lane must report that red rather than hide it.
#
# USAGE
#
#   scripts/run_hcr_lane.sh --platform linux-x86_64 [--verify-unsupported]
#
# Environment overrides, both used only by the gate that proves this script:
#   REPRO_HCR_LANE_MANIFEST  -- read the work list from another TSV
#   REPRO_HCR_LANE_ALLOW_HOST_MISMATCH -- run a lane whose platform is not this
#                               host (never set in CI; see the host check below)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/lib/hcr_lane_verdict.sh
source "$REPO_ROOT/scripts/lib/hcr_lane_verdict.sh"

PLATFORM=""
VERIFY_UNSUPPORTED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="${2:-}"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --verify-unsupported) VERIFY_UNSUPPORTED=1; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run_hcr_lane: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$PLATFORM" ]]; then
    echo "run_hcr_lane: --platform is required (linux-x86_64 | macos-arm64 | windows-x86_64)." >&2
    echo "run_hcr_lane: it is required rather than derived from the host on purpose: a lane that" >&2
    echo "              names its own platform can be checked against the host, and a lane that" >&2
    echo "              guesses cannot be caught running the wrong work list." >&2
    exit 2
fi

# The host check.  A lane that names a platform it is not running on would
# publish a census attributed to the wrong platform, which is worse than no
# census: the milestone files would cite it.
host_os="$(uname -s)"
host_arch="$(uname -m)"
case "$PLATFORM" in
    linux-x86_64)   want_os="Linux";  want_arch_re='^(x86_64|amd64)$' ;;
    macos-arm64)    want_os="Darwin"; want_arch_re='^(arm64|aarch64)$' ;;
    windows-x86_64) want_os="*NT*|MINGW*|MSYS*"; want_arch_re='^(x86_64|amd64)$' ;;
    *) echo "run_hcr_lane: unknown platform '$PLATFORM'." >&2; exit 2 ;;
esac

host_matches=0
if [[ "$PLATFORM" == "windows-x86_64" ]]; then
    case "$host_os" in *NT*|MINGW*|MSYS*|CYGWIN*) host_matches=1 ;; esac
elif [[ "$host_os" == "$want_os" ]]; then
    host_matches=1
fi
if [[ $host_matches -eq 1 ]] && ! [[ "$host_arch" =~ $want_arch_re ]]; then
    host_matches=0
fi
if [[ $host_matches -eq 0 ]]; then
    if [[ "${REPRO_HCR_LANE_ALLOW_HOST_MISMATCH:-}" == "1" ]]; then
        echo "run_hcr_lane: WARNING — running the $PLATFORM lane on $host_os $host_arch because" >&2
        echo "              REPRO_HCR_LANE_ALLOW_HOST_MISMATCH=1. The census this produces is NOT" >&2
        echo "              evidence for $PLATFORM. Never set this in CI." >&2
    else
        echo "run_hcr_lane: REFUSING — the $PLATFORM lane was asked to run on $host_os $host_arch." >&2
        echo "              This is a host/lane mismatch, not a missing prerequisite, and it exits" >&2
        echo "              non-zero rather than skipping: a lane that quietly ran the wrong work" >&2
        echo "              list would publish a census the milestone files then cite." >&2
        exit 1
    fi
fi

MANIFEST_ARG=()
if [[ -n "${REPRO_HCR_LANE_MANIFEST:-}" ]]; then
    MANIFEST_ARG=(--manifest "$REPRO_HCR_LANE_MANIFEST")
fi

echo "== HCR lane: $PLATFORM =="
echo "-- host: $host_os $host_arch"
echo

# STEP 1 — the work list must agree with the tree before any gate runs.
echo "[1/3] manifest vs tree"
if ! python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --check "${MANIFEST_ARG[@]}"; then
    echo "run_hcr_lane: REFUSING — the lane manifest disagrees with the tree (above)." >&2
    echo "              The lane does not run a work list it cannot vouch for." >&2
    exit 1
fi
echo

WORKLIST="$(python3 "$REPO_ROOT/scripts/check_hcr_lane_manifest.py" --platform "$PLATFORM" "${MANIFEST_ARG[@]}")"
if [[ -z "$WORKLIST" ]]; then
    echo "run_hcr_lane: REFUSING — empty work list for $PLATFORM." >&2
    exit 1
fi

# Prerequisite: four gates in the family (`t_b4_hcr_flags_in_repro_tests` and the
# three `tests/e2e/hcr-watch/` gates) carry `requiresReproBinary: true` and
# assert `build/bin/repro` exists rather than recompiling it. A missing one is
# announced HERE with its remedy rather than left to surface as four confusing
# gate failures -- and it FAILS, it does not skip, because a lane that ran
# without them would publish a census that quietly omits four gates.
REPRO_BIN="$REPO_ROOT/build/bin/repro"
[[ "$PLATFORM" == "windows-x86_64" ]] && REPRO_BIN="$REPO_ROOT/build/bin/repro.exe"
if [[ ! -x "$REPRO_BIN" ]]; then
    echo "run_hcr_lane: REFUSING — $REPRO_BIN is missing." >&2
    echo "              Four gates in this family assert it exists (repro_tests.nim:" >&2
    echo "              requiresReproBinary). Remedy: run 'just build' in this checkout" >&2
    echo "              before the lane." >&2
    exit 1
fi

LOG_DIR="$REPO_ROOT/test-logs"
CENSUS_DIR="$REPO_ROOT/build/reports"
mkdir -p "$LOG_DIR" "$CENSUS_DIR" "$REPO_ROOT/build/test-bin" "$REPO_ROOT/build/nimcache"
CENSUS="$CENSUS_DIR/hcr-lane-$PLATFORM.tsv"
{
    echo "# HX-S-10 per-platform HCR gate census — generated by scripts/run_hcr_lane.sh"
    echo "# platform	$PLATFORM"
    echo "# host	$host_os $host_arch"
    echo "# generated	$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'disposition\tgate\tsource\trc\tok\tfailed\tskipped\texecuted_cases\tdeclared_floor\n'
} > "$CENSUS"

total_run=0
total_unsupported=0
total_cases=0
total_skipped=0
total_declared_skips=0
failed_gates=()
REASONS_ALL=""

run_one() {
    # run_one <gate> <source> <floor-or-empty> <expectation: run|unsupported> <declared-skips>
    local gate="$1" source="$2" floor="$3" expectation="$4" declared_skips="${5:-0}"
    local logfile="$LOG_DIR/hcr-lane-$PLATFORM.$gate.log"
    local start end rc
    start=$(date +%s)
    just "$gate" > "$logfile" 2>&1
    rc=$?
    end=$(date +%s)

    if [[ "$expectation" == "run" ]]; then
        if hcr_lane_verdict "$gate" "$rc" "$logfile" "$floor" "$declared_skips"; then
            printf 'run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$gate" "$source" "$rc" "$HCR_VERDICT_OK" "$HCR_VERDICT_FAILED" \
                "$HCR_VERDICT_SKIPPED" "$HCR_VERDICT_CASES" "${floor:-unmeasured}" >> "$CENSUS"
            if [[ -z "$floor" ]]; then
                printf '  PASS  %-72s %3d case(s) in %3ds   FLOOR UNMEASURED on %s — record run:%d\n' \
                    "$gate" "$HCR_VERDICT_CASES" "$((end-start))" "$PLATFORM" "$HCR_VERDICT_CASES"
            else
                printf '  PASS  %-72s %3d case(s) in %3ds   (floor %s)\n' \
                    "$gate" "$HCR_VERDICT_CASES" "$((end-start))" "$floor"
            fi
            total_cases=$(( total_cases + HCR_VERDICT_CASES ))
            total_skipped=$(( total_skipped + HCR_VERDICT_SKIPPED ))
            return 0
        fi
        printf 'run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$gate" "$source" "$rc" "$HCR_VERDICT_OK" "$HCR_VERDICT_FAILED" \
            "$HCR_VERDICT_SKIPPED" "$HCR_VERDICT_CASES" "${floor:-unmeasured}" >> "$CENSUS"
        printf '  REFUSE %-72s %3d case(s) in %3ds\n' "$gate" "$HCR_VERDICT_CASES" "$((end-start))"
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf '         %s\n' "$line"
        done <<< "$HCR_VERDICT_REASONS"
        printf '         log: %s\n' "${logfile#"$REPO_ROOT"/}"
        total_cases=$(( total_cases + HCR_VERDICT_CASES ))
        total_skipped=$(( total_skipped + HCR_VERDICT_SKIPPED ))
        failed_gates+=("$gate")
        REASONS_ALL+="$HCR_VERDICT_REASONS"$'\n'
        return 1
    fi

    # expectation == unsupported: the claim is that this gate executes NOTHING
    # here.  A gate that executes cases on a platform it was declared
    # unsupported on is a manifest lie, and it reddens the lane exactly as a
    # failing gate does.
    local ok cases
    ok=$(hcr_count_marker OK "$logfile")
    local failed
    failed=$(hcr_count_marker FAILED "$logfile")
    cases=$(( ok + failed ))
    printf 'unsupported-verified\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' \
        "$gate" "$source" "$rc" "$ok" "$failed" "$(hcr_count_marker SKIPPED "$logfile")" "$cases" >> "$CENSUS"
    if [[ "$cases" -gt 0 ]]; then
        printf '  REFUSE %-72s executed %d case(s) on a platform where it is declared UNSUPPORTED\n' "$gate" "$cases"
        printf '         Remedy: promote it to run:%d for %s in scripts/hcr-lane-manifest.tsv.\n' "$cases" "$PLATFORM"
        failed_gates+=("$gate")
        REASONS_ALL+="${gate}: declared unsupported on ${PLATFORM} but executed ${cases} case(s)"$'\n'
        return 1
    fi
    printf '  UNSUP %-72s 0 case(s) in %3ds   (as declared)\n' "$gate" "$((end-start))"
    return 0
}

echo "[2/3] declared-run gates"
while IFS=$'\t' read -r disposition gate source floor declared_skips; do
    [[ "$disposition" == "run" ]] || continue
    total_run=$(( total_run + 1 ))
    run_one "$gate" "$source" "$floor" run "${declared_skips:-0}"
    total_declared_skips=$(( total_declared_skips + ${declared_skips:-0} ))
done <<< "$WORKLIST"
echo

echo "[3/3] declared-unsupported gates"
while IFS=$'\t' read -r disposition gate source floor declared_skips; do
    [[ "$disposition" == "unsupported" ]] || continue
    total_unsupported=$(( total_unsupported + 1 ))
    if [[ $VERIFY_UNSUPPORTED -eq 1 ]]; then
        run_one "$gate" "$source" "" unsupported
    else
        printf 'unsupported-declared\t%s\t%s\t-\t-\t-\t-\t-\t-\n' "$gate" "$source" >> "$CENSUS"
        printf '  UNSUP %-72s declared unsupported on %s (not run)\n' "$gate" "$PLATFORM"
    fi
done <<< "$WORKLIST"
echo

# The population floor for the PLATFORM, derived as the sum of the per-gate
# floors rather than written down separately: a second number would rot against
# the first.  This is the clause that catches "the suite silently stopped
# running things" when no single gate dropped below its own floor.
#
# Gates whose floor is still `run:unmeasured` contribute nothing, so on a
# platform that has never been measured the platform floor is 0 and this clause
# is inert.  That is stated rather than hidden: the lane prints the count it
# measured for every unmeasured cell, and the summary below reports how many
# cells are still unmeasured, so a lane running with an inert floor says so.
PLATFORM_FLOOR=0
UNMEASURED_CELLS=0
while IFS=$'\t' read -r disposition gate source floor declared_skips; do
    [[ "$disposition" == "run" ]] || continue
    if [[ -n "$floor" ]]; then
        PLATFORM_FLOOR=$(( PLATFORM_FLOOR + floor ))
    else
        UNMEASURED_CELLS=$(( UNMEASURED_CELLS + 1 ))
    fi
done <<< "$WORKLIST"

echo "== census: $PLATFORM =="
echo "   gates declared run          : $total_run"
echo "   gates declared unsupported  : $total_unsupported"
echo "   total census                : $(( total_run + total_unsupported ))"
echo "   executed assertion cases    : $total_cases"
echo "   platform case floor         : $PLATFORM_FLOOR (sum of the per-gate floors in the manifest)"
echo "   gates with UNMEASURED floor : $UNMEASURED_CELLS (they contribute 0 to the floor above)"
echo "   [SKIPPED] markers seen      : $total_skipped (declared: $total_declared_skips; every declared one also carries a loud UNSUPPORTED naming its covering lane)"
echo "   census artifact             : ${CENSUS#"$REPO_ROOT"/}"
echo

verdict_rc=0
if [[ ${#failed_gates[@]} -gt 0 ]]; then
    echo "run_hcr_lane: LANE RED — ${#failed_gates[@]} gate(s) refused: ${failed_gates[*]}" >&2
    verdict_rc=1
fi
if [[ -n "$PLATFORM_FLOOR" && "$PLATFORM_FLOOR" -gt 0 && "$total_cases" -lt "$PLATFORM_FLOOR" ]]; then
    echo "run_hcr_lane: LANE RED — PLATFORM CASE FLOOR: the $PLATFORM lane executed $total_cases" >&2
    echo "              assertion case(s), below the declared floor of $PLATFORM_FLOOR. This clause is" >&2
    echo "              separate from the per-gate floors above: it catches the suite as a whole" >&2
    echo "              quietly running less than it used to, which is how a case population drifts" >&2
    echo "              without any single gate looking wrong." >&2
    verdict_rc=1
fi

if [[ $verdict_rc -eq 0 ]]; then
    echo "run_hcr_lane: LANE GREEN — $PLATFORM: $total_run gate(s) executed $total_cases case(s) (floor $PLATFORM_FLOOR), $total_unsupported declared unsupported, 0 [SKIPPED]."
fi
exit $verdict_rc
