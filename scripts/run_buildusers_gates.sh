#!/usr/bin/env bash
# M6 clause 2 build-user gates — the one route that runs them.
#
#   just test-buildusers          # from a checkout, on a disposable Linux host, as root
#   bash scripts/run_buildusers_gates.sh
#
# N55. `tests/integration/buildusers/t_m6_buildusers_system_state.sh`
# (48 checks) and `t_m6_default_install_unchanged.sh` (20 checks) were
# standalone: nothing in the justfile, in `scripts/run_tests.sh` or in
# CI named them, so their figures came from a route nothing else took and
# a change that broke them would not have been reported by any suite.
# This script is that route, and `scripts/list_standalone_shell_gates.sh`
# is how a reader finds out it exists.
#
# ## Why these are NOT wired into `just test`
#
# Not because wiring is hard — because running them by accident is
# harmful. `t_m6_buildusers_system_state.sh` CREATES AND DELETES SYSTEM
# ACCOUNTS AND GROUPS; its own header says "Run it only on a disposable
# host, as root." A `just test` that ran it whenever the invoker happened
# to be root would mutate a developer's real machine as a side effect of
# running the test suite, which is a worse failure than the one N55
# names. So the gates get an EXPLICIT target, and `just test` prints a
# notice saying the target exists (see `scripts/list_standalone_shell_gates.sh`).
#
# ## Refusal, not skip
#
# This script was asked for by name. When the host cannot run the gates
# it exits NON-ZERO with a sentence naming the missing property. It never
# prints a pass it did not earn, and it never prints a silent skip: a
# skip that reads as a pass is the defect class this campaign keeps
# finding.
#
# Set REPRO_BUILDUSERS_GATES_PROBE=1 to run only the host-capability
# check and report what it found, without touching any account. That
# mode is how the refusal path itself can be exercised from a host that
# is deliberately not root.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
gates_dir="$repo_root/tests/integration/buildusers"

# The pre-M6 installer, extracted from git so "before" is a real
# artifact and not a reconstruction. `install-on-distributions.sh` has
# exactly two commits: 031c1428 added it and 6e911281 is "M6 clause 2:
# opt-in system build users, launcher-side only". So the parent of
# 6e911281 IS the pre-M6 tree. The gate's own phase 0 asserts the two
# blobs differ by sha256 — handing it the CURRENT installer would make
# its phase 2 vacuous, and that assertion is what catches it.
PRE_M6_REV="${REPRO_PRE_M6_REV:-6e911281^}"

die() { printf '\nREFUSED: %s\n' "$*" >&2; exit 1; }

# --- host capability, measured rather than assumed ---------------------
host_os="$(uname -s 2>/dev/null || echo unknown)"
host_uid="$(id -u)"
missing_tools=''
for t in getent useradd groupadd userdel groupdel stat git; do
  command -v "$t" >/dev/null 2>&1 || missing_tools="$missing_tools $t"
done

printf 'buildusers gates: os=%s uid=%s repo=%s\n' "$host_os" "$host_uid" "$repo_root"
printf 'buildusers gates: pre-M6 installer rev = %s\n' "$PRE_M6_REV"
if [ -n "$missing_tools" ]; then
  printf 'buildusers gates: MISSING TOOLS:%s\n' "$missing_tools"
else
  printf 'buildusers gates: all required account tools present\n'
fi

if [ "${REPRO_BUILDUSERS_GATES_PROBE:-0}" = '1' ]; then
  printf 'buildusers gates: PROBE mode — capability reported, no gate run, no account touched\n'
  exit 0
fi

[ "$host_os" = 'Linux' ] || die \
  "these gates provision Linux system accounts with useradd/groupadd and read them back through getent(1); this host is '$host_os'. Run them on a disposable Linux host (the multi-distro WSL instances and eli-wsl both qualify)."
[ "$host_uid" -eq 0 ] || die \
  "these gates create and delete system groups and accounts, so they need uid 0; this shell is uid $host_uid. Re-run as root ON A DISPOSABLE HOST — t_m6_buildusers_system_state.sh mutates real system accounts and is not safe on a machine you care about."
if [ -n "$missing_tools" ]; then
  die "missing the account tools these gates drive:$missing_tools"
fi

base_installer="${TMPDIR:-/tmp}/pre-m6-install-on-distributions.sh"
git -C "$repo_root" cat-file blob "$PRE_M6_REV:install-on-distributions.sh" > "$base_installer" \
  || die "could not extract $PRE_M6_REV:install-on-distributions.sh — set REPRO_PRE_M6_REV to a revision that has it"
[ -s "$base_installer" ] || die "the extracted pre-M6 installer is empty"
printf 'buildusers gates: baseline installer -> %s (%s bytes)\n' \
  "$base_installer" "$(wc -c < "$base_installer" | tr -d ' ')"

# --- run both, keep going, aggregate -----------------------------------
# `set -e` is off around each gate on purpose: a red first gate must not
# hide the second gate's verdict. The count below is read from a
# variable, never from an inline `$?` — see the campaign's rc=$? trap.
failed=0
ran=0

run_gate() {
  _label="$1"; shift
  printf '\n========================================================\n'
  printf 'GATE %s\n' "$_label"
  printf '========================================================\n'
  set +e
  bash "$@"
  _rc=$?
  set -e
  ran=$((ran + 1))
  if [ "$_rc" -eq 0 ]; then
    printf 'GATE %s: exit 0\n' "$_label"
  else
    printf 'GATE %s: exit %s -- FAILED\n' "$_label" "$_rc"
    failed=$((failed + 1))
  fi
}

run_gate 't_m6_buildusers_system_state' \
  "$gates_dir/t_m6_buildusers_system_state.sh" "$repo_root"
run_gate 't_m6_default_install_unchanged' \
  "$gates_dir/t_m6_default_install_unchanged.sh" "$repo_root" "$base_installer"

printf '\nbuildusers gates: RAN=%s FAILED=%s\n' "$ran" "$failed"
[ "$ran" -eq 2 ] || { printf 'buildusers gates: RESULT: FAIL (expected 2 gates, ran %s)\n' "$ran"; exit 1; }
[ "$failed" -eq 0 ] || { printf 'buildusers gates: RESULT: FAIL\n'; exit 1; }
printf 'buildusers gates: RESULT: PASS\n'
