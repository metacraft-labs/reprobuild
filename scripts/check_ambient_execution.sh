#!/usr/bin/env bash
# check_ambient_execution.sh — fail on NEW ambient binary resolution/execution.
#
# WHY
# ---
# reprobuild-specs/Package-Model.md §"Executables, Libraries, And Package
# Collections" (lines 254-273) requires every executable to be "a strongly typed
# CLI interface bound to an execution profile", in one of three classes:
#
#   1. External executable   — profile records installer kind, package identity,
#                              executable path, environment shaping, checksum.
#   2. PATH-only executable  — typed interface, provisioning explicitly
#                              disabled, resolved from PATH, and "the resulting
#                              action identity records the search path, resolved
#                              executable path, and configured probes". The spec
#                              calls this weak and local-only: NOT a
#                              reproducible package realization.
#   3. Reprobuild-built      — commands "call other strongly typed executable
#                              objects instead of untyped ambient programs".
#
# A bare `findExe("tar")` + `execCmdEx(...)` is none of those. It resolves an
# arbitrary host binary through ambient PATH and records nothing, so the action
# is neither reproducible nor auditable.
#
# WHAT THIS IS NOT
# ----------------
# This is a RATCHET, not a migration. The repository currently carries ~170
# findExe, ~192 execCmdEx and ~411 getEnv call sites across a dozen libraries.
# Those are pre-existing and are not fixed by this script. ALLOWLIST below is
# the baseline: every file that already pollutes. The check fails only when a
# file NOT on that list acquires a banned call — i.e. it stops the surface from
# growing while the existing entries are migrated to typed execution profiles.
#
# Shrinking ALLOWLIST is the work. Adding to it needs a reason in review.
#
# The authoritative enforcement is the compile-time linter in
# `libs/repro_core/src/repro_core/ambient_execution.nim` (re-exported from
# `lints/ambient_execution.nim`; see docs/ambient-execution-linter.md). This
# script exists because pre-commit cannot afford a full compile, and because
# grep catches the violation before it is committed rather than after.
set -euo pipefail

cd "$(dirname "$0")/.."

# Byte collation, everywhere. The committed baseline is in C order, but the
# scan below sorts in the AMBIENT locale, so on an en_US.UTF-8 machine
# `--write-baseline` reshuffles ~20 unrelated lines (`.` and `/` swap rank)
# on top of whatever it actually changed. `comm` then also has to see both
# streams in the same order to compare them at all.
export LC_ALL=C

# Banned APIs: ambient resolution or execution of a binary this project did not
# provision. `getEnv` is deliberately NOT here — it is pervasive, mostly benign
# (reading configuration), and banning it would drown the signal.
#
# `startDirect` is on the list even though it is reprobuild's OWN typed launch
# primitive rather than a stdlib ambient call. It hands an argv straight to the
# process backend with no lease and, crucially, with whatever monitor wrapper
# the caller did or did not prepend — so a file that acquires a `startDirect`
# call is a file that acquired a way to run a build action. Every such call
# belongs in the build engine, next to the launch-path enumeration that
# documents it; a new one anywhere else must be argued for in review. The
# engine module is already on the baseline, so that entry relaxes nothing and
# adds no baseline entries.
#
# `launchProcess` is `startDirect`'s own callee, from the shared
# `runquota_process` backend, and it is importable directly. A file that
# imports it spawns exactly the way `startDirect` spawns while naming nothing
# `startDirect` names. It adds ONE baseline entry — `repro_runquota.nim`,
# which is where `startDirect` and the RunQuota launch wrappers are defined.
# That entry is correct rather than a concession: that file genuinely is a
# launch site, and until now this ratchet could not see it at all.
#
# `execCmd` and `execProcesses` are the reason this comment exists. They are
# `std/osproc` exports, they start children, and NEITHER was matched by any
# other alternative below: `execCmd(` is not `execCmdEx(` and
# `execProcesses(` is not `execProcess(`, because every alternative is
# anchored on the `(`. A new file that called either one was not a new
# offender here — measured, with a working side channel that ran a build
# action's raw argv through `execCmd` while this script exited 0. Adding them
# costs ZERO baseline entries: all nine production files that already call
# `execCmd` call something else on the list too, and `execProcesses` has no
# production call site at all. Pure tightening.
#
# NOT added, deliberately: `commandSpec`, the argv/env builder those launch
# primitives take. It builds no process on its own, and the name is generic
# enough that a repo-wide grep for it would flag unrelated code as a launch
# site. It is pinned instead where the name can be resolved to a module —
# tests/integration/t_every_launch_path_is_monitored.nim, which scans the
# build-engine library with comments and string literals removed.
BANNED='findExe|execCmdEx|execCmd|execProcesses|execProcess|execShellCmd'
BANNED="${BANNED}|startProcess|startDirect|launchProcess"

# Baseline: files that already contain a banned call. Regenerate with
#   scripts/check_ambient_execution.sh --write-baseline
BASELINE="scripts/ambient-execution-baseline.txt"

scan() {
  # Only production Nim sources. Tests legitimately shell out to build fixtures.
  # The linter implementation necessarily names and wraps every banned API.
  grep -rlnE "\b(${BANNED})\(" --include=*.nim libs repro.nim apps 2>/dev/null \
    | grep -v '/tests/' \
    | grep -v '^libs/repro_core/src/repro_core/ambient_execution\.nim$' \
    | sort -u
}

normalized_baseline() {
  # Git may check the baseline out with CRLF on Windows. ``comm`` compares
  # bytes, so normalize it before comparing with grep's LF-only path stream.
  tr -d '\r' < "$BASELINE" | sort -u
}

if [[ "${1:-}" == "--write-baseline" ]]; then
  scan > "$BASELINE"
  echo "wrote $(wc -l < "$BASELINE") entries to $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "error: $BASELINE is missing; regenerate with --write-baseline" >&2
  exit 2
fi

current=$(scan)
# Anything in `current` that is not in the baseline is a new offender.
new_offenders=$(comm -23 <(printf '%s\n' "$current") <(normalized_baseline) || true)

if [[ -n "$new_offenders" ]]; then
  echo "error: ambient binary resolution/execution added to file(s) not on the baseline:" >&2
  printf '%s\n' "$new_offenders" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  Every executed binary must come from the repro store or from a declared" >&2
  echo "  execution profile — see reprobuild-specs/Package-Model.md:254-273 and" >&2
  echo "  docs/ambient-execution-linter.md." >&2
  echo "" >&2
  echo "  If this file is genuinely part of the PATH-only bootstrap tier, it must" >&2
  echo "  record the search path, resolved executable path and probes into the" >&2
  echo "  action identity (spec class 2) — and then be added to the baseline with" >&2
  echo "  that justification in the commit message." >&2
  exit 1
fi

# Also report shrinkage so the ratchet is visible in CI logs: a baseline entry
# that no longer pollutes should be removed from the file.
stale=$(comm -13 <(printf '%s\n' "$current") <(normalized_baseline) || true)
if [[ -n "$stale" ]]; then
  echo "note: these baseline entries no longer contain banned calls — remove them" >&2
  echo "      from $BASELINE to lock in the improvement:" >&2
  printf '%s\n' "$stale" | sed 's/^/    /' >&2
fi

echo "ambient-execution check: no new violations ($(printf '%s\n' "$current" | grep -c . || true) baseline files)"
