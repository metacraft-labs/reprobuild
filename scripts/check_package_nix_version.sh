#!/usr/bin/env bash
# The package.nix version literal must equal reprobuild.nimble's version.
#
# nix/pkgs/by-name/re/reprobuild/package.nix carries `version` as a literal,
# because a nixpkgs package may not read `${src}/reprobuild.nimble` at
# evaluation time (import-from-derivation). The literal therefore drifts
# whenever reprobuild.nimble's version moves without it -- by a version bump
# that edits only the nimble file, or by a merge that brings a release commit
# in (reprobuild-pm issues 2026-09-27-nixpkgs-package-version-sync-check-is-red-on-dev
# and 2026-10-17-nixpkgs-package-version-sync-red-again-on-agents; the second
# arrived through the merge fa56e147d).
#
# This is the ONE implementation of that comparison. Two callers:
#
#   * `just lint` runs it on the tree (no arguments). The `agents` branch has
#     no CI, so before this line the only thing that compared the literals was
#     `nix flake check`, which nobody runs per commit -- and both regressions
#     sat red until a whole-flake run happened to look.
#   * the flake check `nixpkgs-package-version-sync` runs it in the sandbox
#     with `--nimble-version`, the version the flake itself parsed out of
#     reprobuild.nimble and builds with.
#
# Matching is COUNTED, not merely run: a literal line that stops matching
# (renamed argument, reformatted file) fails here rather than passing on an
# empty match, and so does a nimble file with zero or two version lines.
#
# Usage: check_package_nix_version.sh [--package-nix FILE]
#                                     [--nimble FILE | --nimble-version V]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_nix="${here}/nix/pkgs/by-name/re/reprobuild/package.nix"
nimble="${here}/reprobuild.nimble"
nimble_version=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --package-nix) package_nix="$2"; shift 2 ;;
    --nimble) nimble="$2"; shift 2 ;;
    --nimble-version) nimble_version="$2"; shift 2 ;;
    *) echo "check_package_nix_version: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() {
  echo "check_package_nix_version: $*" >&2
  exit 1
}

if [ -z "${nimble_version}" ]; then
  # The same line shape the flake's `nimbleVersionOf` matches.
  count=$(grep -cE '^version = "[^"]+"$' "${nimble}" || true)
  [ "${count}" = 1 ] ||
    fail "${nimble}: expected exactly 1 \`version = \"...\"\` line, found ${count}"
  nimble_version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "${nimble}")
fi

count=$(grep -c '^  version = "' "${package_nix}" || true)
[ "${count}" = 1 ] ||
  fail "${package_nix}: expected exactly 1 version-default line, found ${count}"
literal=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "${package_nix}")
[ -n "${literal}" ] || fail "${package_nix}: could not extract the version literal"

if [ "${literal}" != "${nimble_version}" ]; then
  echo "package.nix version literal (${literal}) != reprobuild.nimble version (${nimble_version})" >&2
  echo "  Set package.nix's \`version\` to ${nimble_version}, and move its \`src\` (rev and" >&2
  echo "  hash) and *Src defaults to one published commit whose reprobuild.nimble says" >&2
  echo "  ${nimble_version} -- nixpkgs-package-src-sync checks that snapshot (nix/README.md)." >&2
  exit 1
fi
echo "package.nix and reprobuild.nimble agree on version ${literal}"
