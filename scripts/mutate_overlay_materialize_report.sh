#!/usr/bin/env bash
# scripts/mutate_overlay_materialize_report.sh
#
# NEGATIVE CONTROLS for
# libs/repro_local_store/tests/t_overlay_materialize_report_names_the_cause.nim.
#
# That suite says [OK] four times against the real `materializeDirectory` and
# the real filesystem. On its own that is indistinguishable from a suite that
# cannot fail, and the report it covers is exactly the kind of thing that
# passes a weak test: every rendering is a string, and a renderer that dropped
# a field would still produce a well-formed report.
#
# The shapes most at risk, each of which would leave the suite green and the
# report useless:
#
#   * The per-CAUSE breakdown is dropped from one rendering. The mechanism and
#     the counts still render, so "the overlay is fat" survives with no cause.
#   * A zero-valued cause is omitted from the MACHINE rendering. A consumer
#     summing causes across entries then has to distinguish "absent" from
#     "zero", which is how that distinction gets made accidentally.
#   * The mechanism is reported optimistically. A copy that reports "hardlink"
#     is the silent degradation this whole class of report exists to catch.
#   * The escaper is a no-op. Every Windows path contains backslashes, so a
#     report that a backslash corrupts is a report that Windows corrupts.
#
# Every mutation is applied to a COPY of the tree under test in a scratch
# directory. Nothing here edits the checkout: the sources are restored by
# construction, because they were never modified.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEST_REL="libs/repro_local_store/tests/t_overlay_materialize_report_names_the_cause.nim"
STORE_REL="libs/repro_local_store/src/repro_local_store/store.nim"

checks=0
failures=0
pass() {
    checks=$((checks + 1))
    printf '  ok:   %s\n' "$1"
}
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf '  FAIL: %s\n' "$1"
    [[ $# -gt 1 ]] && printf '        %s\n' "$2"
    return 0
}

[[ -f "$REPO_ROOT/$TEST_REL" ]] || {
    echo "FAIL: suite under test not found at $REPO_ROOT/$TEST_REL" >&2
    exit 1
}

if ! command -v nim > /dev/null 2>&1; then
    echo "  ! SKIPPED: no nim on PATH, so a mutation could not be distinguished" >&2
    echo "    from a compile failure. NOTHING here is controlled on this host." >&2
    exit 0
fi

echo "mutate_overlay_materialize_report — negative controls"
echo

# A sandbox is a COPY of `config.nims` + `libs/`, never a symlink farm and
# never an edit to the checkout that an interrupted run could leave behind.
#
# It is created as a SIBLING OF THE REPO rather than under /tmp, and that is
# load-bearing rather than tidy: `config.nims` resolves the workspace's Nim
# siblings (io-mon, nim-shm-queue, ...) as `../<name>/src` relative to the
# project root, so a sandbox anywhere else fails to COMPILE — and a control
# whose red is a compile failure asserts nothing.
WORK="$(mktemp -d "$(dirname "$REPO_ROOT")/.repro-mutation-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The sandbox path is returned in a GLOBAL, not on stdout. A
# `sb="$(new_sandbox)"` would run the function in a subshell, and the
# bookkeeping the cleanup trap reads would be discarded with it — which is
# exactly what happened the first time this was written, and it leaked one
# sandbox per control into the workspace root.
SANDBOX_SEQ=0
SANDBOX=""
SANDBOXES=()
new_sandbox() {
    SANDBOX_SEQ=$((SANDBOX_SEQ + 1))
    SANDBOX="$(mktemp -d "$(dirname "$REPO_ROOT")/.repro-mutation-sb-XXXXXX")"
    SANDBOXES+=("$SANDBOX")
    cp "$REPO_ROOT/config.nims" "$SANDBOX/"
    cp -r "$REPO_ROOT/libs" "$SANDBOX/libs"
}
cleanup() {
    rm -rf "$WORK"
    if [[ ${#SANDBOXES[@]} -gt 0 ]]; then
        rm -rf "${SANDBOXES[@]}"
    fi
}
trap cleanup EXIT

run_suite() {
    local sb="$1"
    SUITE_OUT="$(cd "$sb" && timeout 900 nim c -r --hints:off --warnings:off \
        --nimcache:"$sb/nimcache" --out:"$sb/suite" \
        "$TEST_REL" 2>&1)"
    return $?
}

# assert_mutation_detected <label> <mutation-fn>
assert_mutation_detected() {
    local label="$1" mutate="$2"
    new_sandbox
    local sb="$SANDBOX"
    if ! "$mutate" "$sb"; then
        fail "$label" "the mutation itself could not be applied — the control would be vacuous"
        return 0
    fi
    if run_suite "$sb"; then
        fail "$label" "the suite stayed GREEN under this mutation — it does not detect it"
        return 0
    fi
    # A compile error is not a detection: it proves the mutation was
    # syntactically wrong, not that the suite asserts anything.
    if grep -qE 'Error: (type mismatch|undeclared|expression)' <<< "$SUITE_OUT"; then
        fail "$label" "the mutation did not COMPILE, so the red is not an assertion"
        return 0
    fi
    pass "$label (suite goes red)"
}

# ── 1. The text rendering drops the per-CAUSE breakdown. Mechanism and counts
#      still render, so the report still looks complete.
mut_text_drops_causes() {
    local f="$1/$STORE_REL"
    grep -qF 'lines.add "fallback " & $reason' "$f" || return 1
    perl -0pi -e 's/^(\s*)lines\.add "fallback " & \$reason & ": " & \$report\.reasons\[reason\]$/$1discard reason/m' "$f"
    grep -qF 'discard reason' "$f" || return 1
}

# ── 2. The JSON rendering emits only NON-ZERO causes, so a consumer summing
#      causes across entries cannot tell an absent cause from a zero one.
mut_json_omits_zero_causes() {
    local f="$1/$STORE_REL"
    grep -qF 'reasons.add "\"" & $reason' "$f" || return 1
    perl -0pi -e 's/^(\s*)(reasons\.add "\\"" & \$reason.*)$/$1if report.reasons[reason] > 0:\n$1  $2/m' "$f"
    # The same guard already exists in the TEXT renderer, so "does the file
    # contain it" would be true before the mutation. What is true only after
    # it is that one of those guards is followed by the JSON accumulator.
    grep -A1 -F 'if report.reasons[reason] > 0:' "$f" | grep -qF 'reasons.add "\""' || return 1
}

# ── 3. The machine rendering's SCHEMA drifts without the consumers changing.
#      A consumer keyed on the schema then silently stops recognising it.
mut_json_schema_drifts() {
    local f="$1/$STORE_REL"
    grep -qF 'reprobuild.store-materialize.v1' "$f" || return 1
    sed -i 's/reprobuild\.store-materialize\.v1/reprobuild.store-materialize.v2/' "$f"
    grep -qF 'reprobuild.store-materialize.v2' "$f" || return 1
}

# ── 4. THE SILENT DEGRADATION ITSELF: report the link tier optimistically.
#      The tree is correct and the size is N times larger, which is the whole
#      hazard this report class exists for.
mut_mechanism_always_hardlink() {
    local f="$1/$STORE_REL"
    grep -qF 'if report.hardlinked > 0 and report.copied == 0: "hardlink"' "$f" || return 1
    perl -0pi -e 's/if report\.hardlinked > 0 and report\.copied == 0: "hardlink"/if true: "hardlink"/' "$f"
    grep -qF 'if true: "hardlink"' "$f" || return 1
}

# ── 5. The link CAPABILITY is reported as absent whatever was probed. "The
#      overlay is fat because this filesystem cannot link" and "because this
#      caller declined the arm" are different bug reports.
mut_capability_always_false() {
    local f="$1/$STORE_REL"
    grep -qF '", \"hardlink_available\": " & (if report.hardlinkAvailable' "$f" || return 1
    perl -0pi -e 's/\(if report\.hardlinkAvailable: "true" else: "false"\)/"false"/' "$f"
    grep -qF '", \"hardlink_available\": " & "false"' "$f" || return 1
}

# ── 6. The escaper is a no-op. Every Windows path carries backslashes, so
#      this corrupts the machine rendering on the platform the report is for.
mut_json_escape_is_identity() {
    local f="$1/$STORE_REL"
    grep -qF 'proc jsonEscape(s: string): string =' "$f" || return 1
    perl -0pi -e 's/(proc jsonEscape\(s: string\): string =\n)/$1  return s\n/' "$f"
    grep -A1 -F 'proc jsonEscape(s: string): string =' "$f" | grep -qF 'return s' || return 1
}

# ── 7. The caller's declined arm is counted as a PER-FILE fallback. A
#      deliberate policy then looks like N files hitting their link cap, which
#      sends the reader to the wrong diagnosis.
mut_arm_disabled_counted_per_file() {
    local f="$1/$STORE_REL"
    grep -qF 'else: mfrUnsupported].inc' "$f" || return 1
    perl -0pi -e 's/^(        else: mfrUnsupported\]\.inc)$/$1\n      report.perFileFallbacks.inc/m' "$f"
    grep -A1 -F 'else: mfrUnsupported].inc' "$f" | grep -qF 'report.perFileFallbacks.inc' || return 1
}

assert_mutation_detected "the TEXT rendering drops the per-cause breakdown" \
    mut_text_drops_causes
assert_mutation_detected "the JSON rendering omits zero-valued causes" \
    mut_json_omits_zero_causes
assert_mutation_detected "the machine rendering's schema drifts" \
    mut_json_schema_drifts
assert_mutation_detected "a copy is reported as the link tier (the silent degradation)" \
    mut_mechanism_always_hardlink
assert_mutation_detected "the link capability is reported as absent whatever was probed" \
    mut_capability_always_false
assert_mutation_detected "the JSON escaper is a no-op (every Windows path breaks it)" \
    mut_json_escape_is_identity
assert_mutation_detected "the caller's declined arm is counted as a per-file fallback" \
    mut_arm_disabled_counted_per_file

echo
echo "$((checks - failures))/$checks negative controls passed"
if [[ "$failures" -gt 0 ]]; then
    echo "FAILED: $failures control(s) — the suite has a hole." >&2
    exit 1
fi
exit 0
