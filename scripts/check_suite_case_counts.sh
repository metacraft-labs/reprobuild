#!/usr/bin/env bash
#
# Refuse a push whose checked-in description of the test suite is stale.
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
# WHY IT CHECKS TWO ARTIFACTS AND NOT ONE
#
# `benchmarks/reports/reprobuild-suite-m0-inventory.json` describes the same
# suite in more detail -- one entry per source, with its language, owner,
# binary, class, classification reason and static case count. It went stale
# six times in the period the TSV beside it stayed current at every commit.
#
# The difference between the two was never diligence. It is that the TSV is a
# pure source scan a contributor can regenerate in a working tree, and this
# script gates it; while the inventory's CASE COUNTS come from probing each
# built test binary's `--list-json`, so regenerating the whole document needs
# a complete build of ~1,450 binaries -- hours -- and nothing gated it at all.
#
# So the inventory is SPLIT along that line, into two tracked files. The half
# that is a pure function of the source text -- the entry set itself, and each
# entry's language, owner, binary, class, classification reason, static case
# count, dependency shape and runtime-compiler-flow flag -- now lives in
# `benchmarks/reports/reprobuild-suite-m0-inventory-sources.json`, which
# `--write-inventory-sources` regenerates in a working tree with nothing
# built. That is the file this script checks, before anything is compiled.
# Every one of the six staleness events was an entry-set change, so every one
# of them would have been refused at this line.
#
# Splitting the FILE, rather than diffing the build-free half straight out of
# the big one, is the load-bearing part. Both catch the same drift; only one
# offers a remedy a contributor can perform. A gate whose fix is a four-hour
# build gets run with `--no-verify` inside a week.
#
# What this script deliberately does NOT check is the catalog-derived half:
# the authoritative per-binary case counts, the quarantine, and the staleness
# of binaries against their sources. Those cannot be produced without the
# build, so they stay an output of the job that already does the build. A
# green run here is not a statement about them.
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
# Both checks are SOURCE SCANS. Neither needs a compiler, a built test
# binary, a build directory, or nix -- together roughly two minutes on the
# full ~1,450-source tree, against the hours a build costs. That is what
# makes them appropriate for a hook: a gate that costs a build is a gate
# everyone learns to bypass, and a bypassed gate is worse than none.
#
# USAGE
#
#   scripts/check_suite_case_counts.sh [repo-root]
#
# Exit codes:
#   0 -- both artifacts match the tree.
#   1 -- one or both are stale; stderr names the sources that moved and the
#        exact command that regenerates each.
#
# BOTH checks always run. The second is not skipped when the first fails:
# they name different sources for different reasons, and a contributor who
# has to build to fix the second wants to know that on the first attempt
# rather than after regenerating the first and pushing again.
#
# Wired in four places, deliberately:
#   - flake.nix's `pre-commit-check`, at the `pre-push` stage (this hook);
#   - .github/workflows/suite-case-counts.yml, its own uncancellable job;
#   - .github/workflows/ci.yml, as an early step of the lint job;
#   - `just lint`, via the same two underlying flags.
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
entry_set="benchmarks/reports/reprobuild-suite-m0-inventory-sources.json"
regenerate="python3 ${inventory} --write-static-case-counts"
regenerate_entry_set="python3 ${inventory} --write-inventory-sources"

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
# Same rule for the second artifact. `--check-inventory` also refuses a
# missing document, but stating it here keeps the two inputs symmetrical and
# keeps the "absent input is a failure" rule visible at the call site.
if [ ! -f "${entry_set}" ]; then
  echo "FAIL: ${repo_root}/${entry_set} not found." >&2
  echo "      Generate it and commit it (no build required):" >&2
  echo "        ${regenerate_entry_set}" >&2
  exit 1
fi

python_bin="${PYTHON:-python3}"
if ! command -v "${python_bin}" >/dev/null 2>&1; then
  echo "FAIL: ${python_bin} not found on PATH." >&2
  echo "      Run inside the Nix devshell (nix develop)." >&2
  exit 1
fi

# `set -e` is in force, so each check is run with its status captured rather
# than as a bare command: both have to run even when the first one fails.
counts_status=0
"${python_bin}" "${inventory}" --check-static-case-counts || counts_status=$?
entries_status=0
"${python_bin}" "${inventory}" --check-inventory || entries_status=$?

if [ "${counts_status}" -eq 0 ] && [ "${entries_status}" -eq 0 ]; then
  exit 0
fi

# The checkers have already printed the per-source diffs and the regeneration
# commands on stderr. Repeat them here anyway: a hook's last lines are the
# ones the contributor reads, and they must be runnable as-is.
{
  echo
  echo "push refused: the checked-in description of the test suite is stale."
  if [ "${counts_status}" -ne 0 ]; then
    echo
    echo "  ${baseline}"
    echo "  Regenerate it and commit the diff alongside your change:"
    echo "    ${regenerate}"
  fi
  if [ "${entries_status}" -ne 0 ]; then
    echo
    echo "  ${entry_set}"
    echo "  Regenerate it and commit the diff alongside your change. It is a"
    echo "  source scan: no build, no compiler, no nix."
    echo "    ${regenerate_entry_set}"
  fi
} >&2
exit 1
