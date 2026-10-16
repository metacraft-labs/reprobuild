# shellcheck shell=bash
# HX-S-10 — the one place that decides whether an HCR gate's output is a PASS.
#
# This file exists so that the LANE and the GATE THAT PROVES THE LANE call the
# same function rather than two implementations of one rule
# (Verification-Harness-Traps.md Sec. 30: "one predicate, one function, rule and
# control both calling it").  `scripts/run_hcr_lane.sh` sources it to reach a
# verdict on a real run; `tests/integration/test_hx_s10_a_zero_case_result_is_not_a_pass.sh`
# sources nothing and drives the real `run_hcr_lane.sh` end to end, so the
# predicate under test is this one and not a paraphrase of it.
#
# THE RULE, AND WHY EACH CLAUSE IS HERE
#
# A gate result is a PASS only if ALL of the following hold:
#
#   rc == 0                 -- necessary and nowhere near sufficient.  This is
#                              the ONLY thing a runner keying on exit status
#                              checks, and it is why `t_hcr_agent_process_target`
#                              and `t_hcr_watch_inference` have read green on
#                              Linux for their whole lives.
#   [FAILED] count == 0     -- belt and braces; a binary that prints [FAILED] and
#                              still exits 0 is a shape std/unittest can produce
#                              (Verification-Harness-Traps.md Sec. 29).
#   [SKIPPED] count == the manifest's DECLARED skip count for this platform,
#                              which is 0 unless the cell says otherwise.  A gate
#                              that skips on a platform the manifest says it runs
#                              on is a disagreement between the declaration and
#                              the binary, and the honest report of a
#                              disagreement is red, not silence.  Where a cell
#                              DOES declare M skips (one file carrying a
#                              platform-neutral half and an off-platform half),
#                              the lane additionally requires M loud-unsupported
#                              diagnostics in the log, so a BARE `skip()` can
#                              never satisfy a `skip:` cell and the declaration
#                              cannot be used to launder one.
#   executed cases > 0      -- "the job passed" and "the suite ran" are different
#                              claims.  A binary that executes zero cases exits 0.
#                              So does a std/unittest binary given a name filter
#                              that matches nothing (Sec. 37).
#   executed cases >= floor -- the population floor.  Zero-case is the degenerate
#                              case of this clause and is reported separately
#                              because the two have different remedies: a zero is
#                              "it did not run", a shortfall is "it stopped
#                              running some of it".  The 54 -> 75 vacuous-case
#                              growth went unnoticed because nothing watched the
#                              count in either direction.
#
# ONE OUTCOME THAT IS NEITHER: "CONDITIONS NOT MET".
#
# A gate whose verdict is a statistical claim (HLX-M4's concurrency gate is the
# first) states the host conditions its thresholds were calibrated under. When
# a run cannot collect its evidence inside them, the gate asserts everything
# that would be a regression on ANY host, then skips the calibrated remainder
# and prints one line per such case:
#
#     HCR-CONDITIONS-NOT-MET: <gate>: <which arm, which readings>
#
# That is not a pass -- nothing calibrated was shown -- and it is not a
# failure -- nothing was shown wrong. Reporting it as either is the defect
# reprobuild-pm issues/2026-09-26-hcr-concurrent-patch-gate-verdict-depends-on-
# host-load.md records: a red that cannot be told apart from a regression
# without re-running it. So a [SKIPPED] matched by that line is excused from
# the SKIP-AS-GREEN clause and counts toward the case floor (its unconditional
# checks did run), and a result whose ONLY departure from a pass is such skips
# returns 2, NO VERDICT. A result with any other violated clause is still a
# refusal, and the conditions line is reported beside the reasons.
#
# EVERY violated clause is reported, not merely the first.  A gate that both
# skips and executes nothing must say BOTH, because a lane that reported only
# "zero cases" would be indistinguishable from a gate whose binary never
# started -- and the remedies differ.
#
# OUTPUT CONTRACT
#
# `hcr_lane_verdict` sets these globals and returns 0 for pass, 1 for refuse,
# 2 for no verdict (conditions not met, nothing else wrong):
#   HCR_VERDICT_OK, HCR_VERDICT_FAILED, HCR_VERDICT_SKIPPED, HCR_VERDICT_CASES
#   HCR_VERDICT_CONDITIONS -- [SKIPPED] cases excused as conditions not met
#   HCR_VERDICT_REASONS   -- newline-separated, one diagnostic per violated clause
#                            (for 2: one line per case that missed its conditions)
#
# Each diagnostic NAMES the gate, so a lane failure is attributable without
# reading the log (HX-S-8's rule, restated: a falsifier must go red naming the
# thing that broke).

# Count a std/unittest result marker.  Anchored at the start of the line modulo
# unittest's two-space indent: a gate that PRINTS the text "[OK]" inside its own
# diagnostics must not be counted as having passed a case.
hcr_count_marker() {
    local marker="$1" logfile="$2"
    grep -c "^[[:space:]]*\\[${marker}\\]" "$logfile" 2>/dev/null || true
}

# The loud-unsupported diagnostic HX-S-8 established and this milestone reuses
# unchanged.  A `skip:` cell is satisfied only by a log carrying this many of
# these; `[SKIPPED]` alone is not enough.
HCR_LOUD_UNSUPPORTED_RE='UNSUPPORTED:.*covered by '

# The line a gate prints for each case that did not meet its stated conditions.
# Anchored at the start of the line, like the result markers.
HCR_CONDITIONS_NOT_MET_RE='^HCR-CONDITIONS-NOT-MET: '

# hcr_lane_verdict <gate-name> <rc> <logfile> <floor-or-empty> [declared-skips]
hcr_lane_verdict() {
    local gate="$1" rc="$2" logfile="$3" floor="${4:-}" declared_skips="${5:-0}"

    HCR_VERDICT_REASONS=""

    if [[ ! -f "$logfile" ]]; then
        HCR_VERDICT_OK=0
        HCR_VERDICT_FAILED=0
        HCR_VERDICT_SKIPPED=0
        HCR_VERDICT_CASES=0
        HCR_VERDICT_CONDITIONS=0
        HCR_VERDICT_REASONS="${gate}: no log was produced at ${logfile}; the lane cannot report on a run it did not observe"
        return 1
    fi

    HCR_VERDICT_OK=$(hcr_count_marker OK "$logfile")
    HCR_VERDICT_FAILED=$(hcr_count_marker FAILED "$logfile")
    HCR_VERDICT_SKIPPED=$(hcr_count_marker SKIPPED "$logfile")
    HCR_VERDICT_CONDITIONS=0

    # Undeclared skips each matched by a conditions line are "conditions not
    # met", never more of them than there are undeclared skips.
    local undeclared=$(( HCR_VERDICT_SKIPPED - declared_skips ))
    if [[ "$undeclared" -gt 0 ]]; then
        local conditions
        conditions=$(grep -c "$HCR_CONDITIONS_NOT_MET_RE" "$logfile" 2>/dev/null || true)
        if [[ "$conditions" -gt "$undeclared" ]]; then
            conditions=$undeclared
        fi
        HCR_VERDICT_CONDITIONS=$conditions
    fi
    # A case that missed its conditions still ran its unconditional checks, so
    # it counts as executed for the floor; it is simply not a pass.
    HCR_VERDICT_CASES=$(( HCR_VERDICT_OK + HCR_VERDICT_FAILED + HCR_VERDICT_CONDITIONS ))

    local reasons=()

    if [[ "$rc" -ne 0 ]]; then
        reasons+=("${gate}: exited ${rc}")
    fi
    if [[ "$HCR_VERDICT_FAILED" -gt 0 ]]; then
        reasons+=("${gate}: ${HCR_VERDICT_FAILED} case(s) reported [FAILED]")
    fi
    if [[ $(( HCR_VERDICT_SKIPPED - HCR_VERDICT_CONDITIONS )) -ne "$declared_skips" ]]; then
        reasons+=("${gate}: SKIP-AS-GREEN — ${HCR_VERDICT_SKIPPED} case(s) reported [SKIPPED], but scripts/hcr-lane-manifest.tsv declares ${declared_skips} for this platform. Remedy: either the gate's platform guard is wrong, or the manifest should declare it 'unsupported' here (or 'run:N+skip:M') and name the lane that does cover it.")
    fi
    if [[ "$declared_skips" -gt 0 ]]; then
        # A declared skip must be a LOUD one.  This is the clause that stops
        # `+skip:M` from becoming the escape hatch the milestone warns about:
        # the count alone would let a bare `skip()` sit inside the allowance.
        local loud
        loud=$(grep -c "$HCR_LOUD_UNSUPPORTED_RE" "$logfile" 2>/dev/null || true)
        if [[ "$loud" -lt "$declared_skips" ]]; then
            reasons+=("${gate}: BARE SKIP — the manifest declares ${declared_skips} skipped case(s) here, but the log carries only ${loud} loud-unsupported diagnostic(s) matching /${HCR_LOUD_UNSUPPORTED_RE}/. A declared skip must NAME the host that does cover it; a bare skip() does not satisfy a 'skip:' cell.")
        fi
    fi
    if [[ "$HCR_VERDICT_CASES" -eq 0 ]]; then
        reasons+=("${gate}: ZERO-CASE RESULT — the binary reported 0 OK and 0 FAILED and exited ${rc}. A lane keying on exit status alone reads this as a pass; this lane does not.")
    elif [[ -n "$floor" && "$HCR_VERDICT_CASES" -lt "$floor" ]]; then
        reasons+=("${gate}: CASE FLOOR — executed ${HCR_VERDICT_CASES} case(s), below the declared floor of ${floor}. Either cases stopped running, or the floor in scripts/hcr-lane-manifest.tsv is stale; the floor is measured, so lowering it requires saying what was removed and why.")
    fi

    local notes=()
    if [[ "$HCR_VERDICT_CONDITIONS" -gt 0 ]]; then
        local line
        while IFS= read -r line; do
            notes+=("${gate}: CONDITIONS NOT MET — ${line#HCR-CONDITIONS-NOT-MET: }")
        done < <(grep "$HCR_CONDITIONS_NOT_MET_RE" "$logfile" | head -n "$HCR_VERDICT_CONDITIONS")
    fi

    if [[ ${#reasons[@]} -gt 0 ]]; then
        HCR_VERDICT_REASONS=$(printf '%s\n' "${reasons[@]}" "${notes[@]}")
        return 1
    fi
    if [[ ${#notes[@]} -gt 0 ]]; then
        HCR_VERDICT_REASONS=$(printf '%s\n' "${notes[@]}")
        return 2
    fi
    return 0
}
