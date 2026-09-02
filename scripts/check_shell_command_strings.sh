#!/usr/bin/env bash
# check_shell_command_strings.sh — fail on a NEW command string that assumes a
# shell Nim does not always give it.
#
# WHY
# ---
# `execCmdEx` / `execProcess` take a command STRING and add `poEvalCommand`.
# On POSIX Nim runs that string through `/bin/sh -c`, so `<`, `>`, `|`, `&&`
# and backticks mean what a shell author expects. On Windows there is NO
# shell: `startProcess` hands the string to `CreateProcessW` verbatim, so
# every one of those characters becomes an ordinary argv token.
#
# The failure is silent. Nothing errors; the redirect simply does not happen
# and the child runs with extra arguments. Measured on this repository:
#
#   execCmdEx("git hash-object --stdin < payload")
#     -> exit 128, e69de29b… (the hash of EMPTY input), then
#        "fatal: could not open '<' for reading"
#
# That exact shape is why NO certificate signature ever verified on Windows:
# `ssh-keygen -Y verify` was handed its payload through `" < " & path`, read
# EOF, and reported every valid signature as bad (milestone W10).
#
# Quoting does not save you either. `quoteShell` on Windows quotes on
# WHITESPACE ONLY — `&`, `^`, `|`, `(`, `)` and `%VAR%` all pass through bare.
#
# WHY A GATE AND NOT AN AUDIT
# ---------------------------
# This is the FIFTH instance of the family in one campaign: W4's
# `quoteShell`-into-`cmd`, `runFixtureCmd`'s `quoteShell`-into-`sh`,
# `runCMakeDevelopCommand`'s ungated `sh -c`, `2>/dev/null` / `2>&1` tokens
# reaching argv in the integration suite, and W10's `ssh-keygen -Y verify`.
# A reviewer cannot just grep and stare, because most redirect tokens in the
# tree are FINE — they are inside an `execShellCmd`, an explicit `sh -c` body,
# or a POSIX-only `when`/`case` arm. Establishing which is which is a
# judgement, and `scripts/shell_command_strings.py` encodes that judgement
# once so no future reviewer re-derives it. See that file for the rule and its
# three structural exemptions.
#
# WHAT THIS IS NOT
# ----------------
# A ratchet, like `check_ambient_execution.sh`. BASELINE below is not a list of
# blessed sites — it is the list of sites that already carry the defect, each
# with its verdict written next to it. Shrinking it is the work. A candidate
# that is NOT on it fails the check.
#
# SCOPE
# -----
# First-party production Nim (`libs`, `apps`, `tools`, `repro.nim`), matching
# `check_ambient_execution.sh`. Tests are out of the gate because they
# legitimately drive fixtures through a shell and several are POSIX-VM-only by
# construction; point the scanner at them by hand when that matters:
#
#   python3 scripts/shell_command_strings.py tests --with-lines
set -euo pipefail

cd "$(dirname "$0")/.."

SCANNER="scripts/shell_command_strings.py"
BASELINE="scripts/shell-command-strings-baseline.txt"
PYTHON_BIN="${PYTHON:-python3}"

# Deliberately fatal rather than skipped: a check that quietly succeeds when
# its own inputs are missing reports green and proves nothing.
if [[ ! -f "$SCANNER" ]]; then
  echo "FAIL: $SCANNER not found; this check must run from a reprobuild checkout." >&2
  exit 2
fi
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "FAIL: $PYTHON_BIN not found on PATH (run inside the devshell)." >&2
  exit 2
fi

scan() {
  "$PYTHON_BIN" "$SCANNER" | sort -u
}

normalized_baseline() {
  # Git may check the baseline out with CRLF on Windows, and `comm` compares
  # bytes. Strip CR, drop comments and blank lines.
  tr -d '\r' < "$BASELINE" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | sort -u
}

if [[ "${1:-}" == "--self-test" ]]; then
  # PROOF OF POWER. A gate nobody has tried to defeat is an assertion, not a
  # check. `scripts/shell-command-strings-probes/` holds one complete Nim file
  # per shape; the filename prefix states the expected verdict and this asserts
  # it in BOTH directions, so a documented blind spot cannot close silently and
  # a closed one cannot re-open silently. See that directory's README.md.
  PROBES="scripts/shell-command-strings-probes"
  if [[ ! -d "$PROBES" ]]; then
    echo "FAIL: $PROBES not found." >&2
    exit 2
  fi
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  probe_failures=0
  probe_total=0
  for probe in "$PROBES"/*.nim.probe; do
    base="$(basename "$probe" .nim.probe)"
    # One probe per scratch directory: the scanner reports per file, and a
    # shared directory would let one probe's rows answer for another's.
    mkdir -p "$work/$base"
    tr -d '\r' < "$probe" > "$work/$base/$base.nim"
    rows="$("$PYTHON_BIN" "$SCANNER" "$work/$base" || true)"
    count="$(printf '%s\n' "$rows" | grep -c . || true)"
    probe_total=$((probe_total + 1))
    case "$base" in
      caught_*)
        if [[ "$count" -lt 1 ]]; then
          echo "FAIL: $base is a real defect the scanner MUST report, and it reported nothing." >&2
          probe_failures=$((probe_failures + 1))
        fi
        ;;
      missed_*)
        if [[ "$count" -ge 1 ]]; then
          echo "FAIL: $base is a DOCUMENTED BLIND SPOT and the scanner now reports it." >&2
          echo "      That is an improvement — rename the probe to caught_… and delete its" >&2
          echo "      row from $PROBES/README.md so the gate's honesty stays current." >&2
          probe_failures=$((probe_failures + 1))
        fi
        ;;
      exempt_*)
        if [[ "$count" -ge 1 ]]; then
          echo "FAIL: $base is NOT a defect and the scanner reported it:" >&2
          printf '%s\n' "$rows" | sed 's/^/        /' >&2
          probe_failures=$((probe_failures + 1))
        fi
        ;;
      *)
        echo "FAIL: $base has no verdict prefix (caught_/missed_/exempt_)." >&2
        probe_failures=$((probe_failures + 1))
        ;;
    esac
  done
  if [[ "$probe_failures" -gt 0 ]]; then
    echo "shell-command-strings self-test: $probe_failures of $probe_total probes disagree" >&2
    exit 1
  fi
  caught=$(ls "$PROBES"/caught_*.nim.probe 2>/dev/null | wc -l | tr -d ' ')
  missed=$(ls "$PROBES"/missed_*.nim.probe 2>/dev/null | wc -l | tr -d ' ')
  exempt=$(ls "$PROBES"/exempt_*.nim.probe 2>/dev/null | wc -l | tr -d ' ')
  echo "shell-command-strings self-test: $probe_total probes agree" \
       "($caught caught, $missed documented blind spots, $exempt exemptions held)"
  exit 0
fi

if [[ "${1:-}" == "--write-baseline" ]]; then
  {
    echo "# shell-command-strings baseline — see scripts/check_shell_command_strings.sh"
    echo "# Regenerate with: scripts/check_shell_command_strings.sh --write-baseline"
    echo "# Then WRITE THE VERDICT for each entry: it is a defect until argued otherwise."
    scan
  } > "$BASELINE"
  echo "wrote $(scan | grep -c . || true) entries to $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "error: $BASELINE is missing; regenerate with --write-baseline" >&2
  exit 2
fi

current=$(scan)
new_offenders=$(comm -23 <(printf '%s\n' "$current" | grep -v '^$' || true) \
                         <(normalized_baseline) || true)

if [[ -n "$new_offenders" ]]; then
  echo "error: a command STRING with shell metacharacters reached an exec API that" >&2
  echo "       does not run a shell on every platform:" >&2
  printf '%s\n' "$new_offenders" | sed 's/^/    /' >&2
  echo "" >&2
  echo '  On Windows execCmdEx has no shell: <, >, |, && and backticks become' >&2
  echo '  ordinary argv tokens and the redirect silently does nothing.' >&2
  echo "" >&2
  echo '  Fix it by building an ARGV instead (startProcess + an explicit stdin' >&2
  echo '  write for a redirect — see verifyCertificateSignature/runFeedingStdin),' >&2
  echo '  or make the shell explicit (execShellCmd, or sh -c/cmd /c as argv[0]).' >&2
  echo "  Locate it with:  $PYTHON_BIN $SCANNER --with-lines" >&2
  exit 1
fi

stale=$(comm -13 <(printf '%s\n' "$current" | grep -v '^$' || true) \
                 <(normalized_baseline) || true)
if [[ -n "$stale" ]]; then
  echo "note: these baseline entries no longer match — remove them from" >&2
  echo "      $BASELINE to lock in the improvement:" >&2
  printf '%s\n' "$stale" | sed 's/^/    /' >&2
fi

echo "shell-command-strings check: no new violations ($(printf '%s\n' "$current" | grep -c . || true) baseline sites)"
