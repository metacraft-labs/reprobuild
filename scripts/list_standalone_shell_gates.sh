#!/usr/bin/env bash
# Which shell gates under tests/integration/ does anything actually run?
#
#   bash scripts/list_standalone_shell_gates.sh            # the table
#   bash scripts/list_standalone_shell_gates.sh --notice   # the one-paragraph
#                                                          # form `just test` prints
#
# N55. `tests/integration/buildusers/t_m6_*.sh` reported 48/0 and 20/0
# from a route NOTHING ELSE TOOK: the justfile enumerates `.nim` tests
# explicitly and had no `buildusers` reference, `scripts/run_tests.sh`
# builds and runs `.nim` test binaries and never looks for a `.sh`, and
# no workflow named them. A gate nothing runs is how a working feature
# quietly stops working.
#
# This script answers that question MECHANICALLY rather than from a
# hand-kept list, because a hand-kept list is the thing that goes stale.
# For every `*.sh` under `tests/integration/` (excluding `lib/` helper
# directories, which are sourced rather than run) it reports the justfile
# recipe that names it — by file, by basename, or by containing
# directory — or `NOTHING` when no recipe does.
#
# IT IS A NOTICE, NOT A GATE: it exits 0 whatever it finds. It does not
# fail a build for an unrun gate, because "wire every one of these in"
# is a decision per gate (several mutate system state and must never run
# by accident) and a red line in `just test` that no one can action is
# how a suite trains its readers to ignore it. What it does is make the
# set VISIBLE from the suite everybody already runs, so no future reader
# has to find these files by reading a milestone document.
#
# WHAT THIS DOES NOT CLAIM: a recipe naming a gate is not proof the
# recipe runs green, and `NOTHING` for a gate is not proof the gate is
# stale or wrong.
#
# WHAT IT FOUND THE FIRST TIME IT RAN, stated here because it is the
# reason the M6 gates were NOT simply given the same treatment as their
# neighbours: 56 gates, 54 of them run by nothing. The
# `tests/integration/binary_cache/` set that looked like the precedent to
# copy is itself entirely unrun — referenced only from prose in
# `recipes/cache/*.md` — and so are `de0/`, `de_g/`, `de_h/`, `de_k/`,
# `dem/`, `foreign_packages/`, `multi_os_runtime/` and
# `system_generations/`. Following that precedent would have propagated
# the gap rather than closed it. Closing it for all 54 is a separate,
# per-gate decision (several need root, a display server, or a bootable
# host); what this script does is stop the set from being invisible.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="${1:-table}"

# The justfile is `Justfile` in this repo, and the lookup MUST NOT be
# spelled with a guessed case. An earlier draft of this script hardcoded
# `$repo_root/justfile`; on Windows and macOS that resolves (the
# filesystem folds case) and the script reported 54-of-56, but on every
# case-sensitive filesystem -- i.e. every Linux CI runner and every Linux
# checkout, the only places `scripts/run_tests.sh` actually prints this
# notice -- the file did not exist, all four `grep`s missed against a
# missing path, their `2>/dev/null` hid the error, and the answer
# degraded SILENTLY to "56 total, 56 run by NO justfile recipe": the
# wrong number, exit 0, no diagnostic, and a claim that the M6 gates are
# unrun printed by the very suite whose sibling recipe runs them. That is
# the exact defect class this script exists to report, produced by this
# script. So: resolve by probing, and REFUSE rather than answer if no
# justfile is found. Refusing is not a verdict on the gates -- it says
# this script could not compute one, which is the only honest output when
# the file it reads from is missing.
justfile=''
for _candidate in Justfile justfile JUSTFILE; do
  if [ -f "$repo_root/$_candidate" ]; then justfile="$repo_root/$_candidate"; break; fi
done
if [ -z "$justfile" ]; then
  printf 'list_standalone_shell_gates: REFUSED: no justfile found at %s (looked for Justfile, justfile, JUSTFILE).
'     "$repo_root" >&2
  printf 'Refusing to report a gate count derived from a file that does not exist.
' >&2
  exit 2
fi

# Targeted, not a walk of the tree: this host OOM-kills broad filesystem
# walks, and the answer only ever concerns tests/integration.
# `lib/` directories and `_`-prefixed files are SOURCED by the gates, not
# run as gates themselves (`_b3_common.sh` documents `source "$(dirname
# "${BASH_SOURCE[0]}")/_b3_common.sh"` in its own header and seven B3
# gates source it), so counting them would inflate the "nothing runs
# this" number with files nothing is supposed to run.
mapfile -t gates < <(
  find "$repo_root/tests/integration" -type f -name '*.sh' \
    -not -path '*/lib/*' -not -name '_*' \
    | sed "s|^$repo_root/||" | LC_ALL=C sort
)

runner_for() {
  # A recipe "names" a gate if the justfile mentions its path, its
  # basename, or its immediate parent directory name. Reported as the
  # matching line, so a reader can see WHY it matched.
  _path="$1"
  _base="$(basename "$_path")"
  _dir="$(basename "$(dirname "$_path")")"
  # COMMENT LINES DO NOT COUNT. A `#` line that merely mentions a gate
  # runs nothing, and treating one as a runner is the same vacuous-pass
  # shape this script reports on: a prose note added to the justfile
  # would silently move a gate out of the NOTHING column without any
  # recipe existing. Stripped here so the `via <driver>` probe below --
  # which finds the recipe that really does invoke the gate -- is what
  # answers for the M6 pair.
  _hit="$(grep -n -F -e "$_path" -e "$_base" "$justfile" 2>/dev/null             | grep -v '^[0-9]*:[[:space:]]*#' | head -1 || true)"
  if [ -z "$_hit" ]; then
    _hit="$(grep -n -F -e "tests/integration/$_dir" "$justfile" 2>/dev/null               | grep -v '^[0-9]*:[[:space:]]*#' | head -1 || true)"
  fi
  if [ -z "$_hit" ]; then
    # Indirect: a recipe may call a driver script that names the gate.
    for _drv in "$repo_root"/scripts/run_*.sh; do
      [ -f "$_drv" ] || continue
      if grep -q -F -e "$_base" "$_drv" 2>/dev/null; then
        _rel="${_drv#"$repo_root"/}"
        if grep -F "$(basename "$_drv")" "$justfile" 2>/dev/null              | grep -qv '^[[:space:]]*#'; then
          _hit="via $_rel"
          break
        fi
      fi
    done
  fi
  printf '%s' "${_hit:-NOTHING}"
}

total=0
unrun=0
unrun_list=''
table=''
for g in "${gates[@]}"; do
  total=$((total + 1))
  r="$(runner_for "$g")"
  if [ "$r" = 'NOTHING' ]; then
    unrun=$((unrun + 1))
    unrun_list="$unrun_list $g"
  fi
  table="$table$(printf '%-64s %s\n' "$g" "$r")"$'\n'
done

if [ "$mode" = '--notice' ]; then
  printf '\n'
  printf 'STANDALONE SHELL GATES under tests/integration/: %s total, %s run by NO justfile recipe.\n' \
    "$total" "$unrun"
  printf 'This suite runs .nim test binaries only, so it ran NONE of them.\n'
  printf 'The M6 build-user gates have an explicit target (they mutate system accounts,\n'
  printf 'so they must never run as a side effect of `just test`):\n'
  printf '    just test-buildusers        # disposable Linux host, as root\n'
  printf 'For the full picture, including which gates nothing runs at all:\n'
  printf '    bash scripts/list_standalone_shell_gates.sh\n'
  printf '\n'
  exit 0
fi

printf '%-64s %s\n' 'GATE' 'RUN BY'
printf '%-64s %s\n' '----' '------'
printf '%s' "$table"
printf '\n%s gate(s) total; %s run by NO justfile recipe:\n' "$total" "$unrun"
for u in $unrun_list; do printf '  %s\n' "$u"; done
printf '\nRun the M6 build-user gates with:  just test-buildusers\n'
printf '(disposable Linux host, as root — they create and delete system accounts)\n'
