#!/usr/bin/env bash
#
# Refuse a push whose suite case-count baseline is stale.
#
# WHY THIS EXISTS
#
# `scripts/reprobuild-suite-static-case-counts.tsv` is the checked-in record
# of how many test cases each declared test source contains. Adding a `test
# "…":` declaration without refreshing it leaves the baseline disagreeing
# with the tree, and `just lint` -- which every contributor and CI run
# executes -- fails from that moment on. The failure is not the author's to
# see: it lands on whoever branches next, who then has to carry someone
# else's regeneration in order to get their own change green.
#
# The baseline check itself already existed and already ran in `just lint`.
# What was missing was any gate BEFORE the push: `just lint` runs at commit
# time only if the contributor did not bypass the hook, and in CI only after
# the commit has already reached the branch. This script closes that window.
#
# WHY PRE-PUSH AND NOT PRE-COMMIT
#
# Push is this repository's publication boundary -- the point at which a
# commit becomes everyone's problem. A pre-commit gate would also refuse the
# intermediate commits of a series that regenerates the baseline at the end,
# which is a legitimate way to work. Pre-push asks the only question that
# matters: is what I am about to publish self-consistent?
#
# WHY IT IS CHEAP
#
# The baseline is a SOURCE SCAN. It needs no compiler, no built test
# binaries, and no build directory -- roughly five seconds on the full tree.
# That is what makes it appropriate for a hook: a gate that costs a build is
# a gate everyone learns to bypass, and a bypassed gate is worse than none.
#
# USAGE
#
#   scripts/check_suite_case_counts.sh [repo-root]
#
# Exit codes:
#   0 -- the baseline matches the tree.
#   1 -- the baseline is stale; stderr names the sources that moved and the
#        exact command that regenerates it.
#
# Wired in three places, deliberately:
#   - flake.nix's `pre-commit-check`, at the `pre-push` stage (this hook);
#   - .github/workflows/ci.yml, as an early step of the lint job;
#   - `just lint`, via the same underlying `--check-static-case-counts`.
set -euo pipefail

repo_root="${1:-}"
if [ -z "${repo_root}" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "${repo_root}" ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "${repo_root}"

inventory="scripts/reprobuild_suite_inventory.py"
baseline="scripts/reprobuild-suite-static-case-counts.tsv"
regenerate="python3 ${inventory} --write-static-case-counts"

# Deliberately fatal rather than skipped. A check that quietly succeeds when
# its own inputs are missing reports green and proves nothing -- which is the
# exact failure mode that let a stale baseline reach the branch twice.
if [ ! -f "${inventory}" ]; then
  echo "FAIL: ${repo_root}/${inventory} not found." >&2
  echo "      This check must run from a reprobuild checkout." >&2
  exit 1
fi
if [ ! -f "${baseline}" ]; then
  echo "FAIL: ${repo_root}/${baseline} not found." >&2
  echo "      Generate it and commit it:" >&2
  echo "        ${regenerate}" >&2
  exit 1
fi

python_bin="${PYTHON:-python3}"
if ! command -v "${python_bin}" >/dev/null 2>&1; then
  echo "FAIL: ${python_bin} not found on PATH." >&2
  echo "      Run inside the Nix devshell (nix develop)." >&2
  exit 1
fi

if "${python_bin}" "${inventory}" --check-static-case-counts; then
  exit 0
fi

# The checker has already printed the per-source diff and the regeneration
# command on stderr. Repeat the command here anyway: a hook's last line is
# the one the contributor reads, and it must be runnable as-is.
{
  echo
  echo "push refused: the suite case-count baseline is stale."
  echo "Regenerate it and commit the diff alongside your change:"
  echo "  ${regenerate}"
} >&2
exit 1
