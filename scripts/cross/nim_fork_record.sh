# shellcheck shell=bash
# nim_fork_record.sh -- the Nim-fork half of an installed prefix's build
# record. Sourced, not executed.
#
#   nim_fork_record <stage> <revision>
#     Writes <stage>/nim/.nim-fork-revision (when the stage ships
#     nim/bin/nim) and prints the `nim_fork=<revision>` line for
#     share/repro/cross-build-info.
#
# An installed engine compiles providers and profiles with the Nim its prefix
# ships, and only when nim/.nim-fork-revision equals the record's nim_fork=
# (reprobuild-pm Distribution-And-Packaging.md §5.3, amendment N3;
# repro_core/installed_prefix_nim). The graph's `.#prefix` writes both from
# the catalog's nim-fork recipe. This script used to write neither the
# revision file nor a bare revision (`nim_fork=flake:nim-fork-src@<sha>`), so
# every provider compile from its prefix was refused (A15 re-review,
# 2026-11-05). One function writes both halves so they cannot disagree.
nim_fork_record() {
  local stage=$1 revision=$2
  if [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "nim_fork_record: '${revision}' is not a 40-hex revision" >&2
    return 1
  fi
  if [ -e "${stage}/nim/bin/nim" ]; then
    printf '%s\n' "${revision}" > "${stage}/nim/.nim-fork-revision"
  fi
  printf 'nim_fork=%s\n' "${revision}"
}
