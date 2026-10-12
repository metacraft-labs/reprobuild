#!/usr/bin/env bash
# stage_release_catalog.sh <package-dir>
#
# Ship the reprobuild-packages catalog an INSTALLED reprobuild resolves moved
# packages from.
#
# WHY. A package that moved out of the stdlib (sqlite3, shellcheck, shfmt,
# prek) resolves only from the catalog, and a recipe that uses one does not
# compile without it (Provisioning-Contributions.md, "Catalog Lookup And
# Provisioning"). In a workspace the catalog is a sibling checkout; an
# installed reprobuild has no workspace, so it carries one. The lookup's last
# place is "beside the reprobuild checkout the DSL was compiled from", which
# for the installed layout is
#
#   <pkg>/share/repro/source  ->  <pkg>/share/repro/reprobuild-packages
#
# so that is where the catalog goes, and the lookup needs no special case.
#
# WHAT. The package interfaces (packages/interfaces) of the revision this
# repository PINS in .github/sibling-repos, read out of git at that commit --
# not the sibling's working tree, which may have moved -- plus a
# `catalog-revision` marker naming the url and commit
# (reprobuild_packages_catalog.CatalogRevisionMarkerFile). A lock refreshed by
# the installed reprobuild records that revision for the catalog.
#
# The checkout holding the pinned commit is $REPROBUILD_PACKAGES_ROOT when it is
# set, else ../reprobuild-packages (where setup-dev-env clones the sibling list).
#
# Run from the reprobuild checkout root (it reads .github/sibling-repos there).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
pkg=$1
dest="$pkg/share/repro/reprobuild-packages"
fail() { echo "stage_release_catalog: ERROR: $*" >&2; exit 1; }

[[ -f .github/sibling-repos ]] ||
  fail "no .github/sibling-repos here; run from the reprobuild checkout root"
pin=$(tr -d '\r' < .github/sibling-repos |
  sed -n 's/^reprobuild-packages=\([0-9a-f]\{40\}\)[[:space:]]*$/\1/p' | head -n 1)
[[ -n "$pin" ]] ||
  fail ".github/sibling-repos pins no 40-hex reprobuild-packages revision"

# Every git call on the catalog checkout goes through this. The checkout is
# one the workflow itself just cloned beside this one, and every call is a
# read (rev-parse, archive, remote get-url), so git's ownership check
# (`safe.directory`, https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory)
# protects nothing here, and on a runner whose service account does not own
# the work directory it would make a present checkout read as absent. Scoped
# to these calls only; nothing is written to config.
pkg_git() { "$git_bin" -c safe.directory='*' -C "$@"; }

# Resolve git once. On the Windows release leg this script runs in Git for
# Windows' bash, whose PATH there carries `<git>/usr/bin` (bash, coreutils)
# but not the directories holding git itself, so a bare `git` is "command not
# found" (v0.2.8 run 37941621127). Inside that bash the install root is `/`,
# and git lives at /cmd/git or /mingw64/bin/git
# (https://github.com/git-for-windows/git/wiki/FAQ).
git_bin=$(command -v git || true)
if [[ -z "$git_bin" ]]; then
  for candidate in /cmd/git /mingw64/bin/git /clangarm64/bin/git; do
    if [[ -x "$candidate" || -x "$candidate.exe" ]]; then
      git_bin=$candidate
      break
    fi
  done
fi
[[ -n "$git_bin" ]] ||
  fail "git is not on PATH, and none of Git for Windows' /cmd/git, /mingw64/bin/git is present"

root=""
tried=""
for candidate in "${REPROBUILD_PACKAGES_ROOT:-}" ../reprobuild-packages; do
  [[ -n "$candidate" ]] || continue
  # Keep git's own answer: "not a git repository", "dubious ownership" and
  # "unknown revision" each need a different remedy, and discarding stderr
  # left a CI log that could only say the checkout was not there.
  if why=$(pkg_git "$candidate" rev-parse --verify --quiet "${pin}^{commit}" 2>&1 >/dev/null); then
    root=$candidate
    break
  fi
  if [[ ! -e "$candidate" ]]; then
    why="does not exist"
  elif [[ -z "$why" ]]; then
    why="commit not present (shallow clone of another revision?)"
  fi
  tried+=$'\n'"  $candidate: ${why//$'\n'/ }"
done
[[ -n "$root" ]] ||
  fail "no git checkout holding reprobuild-packages $pin; clone it at ../reprobuild-packages or set \$REPROBUILD_PACKAGES_ROOT, or fetch that commit into it. Tried:$tried"

echo "stage_release_catalog: reprobuild-packages <- $root @ $pin"
rm -rf "$dest"
mkdir -p "$dest"
# Extract from inside the destination: given `-C C:\...`, a tar reads the
# drive letter as a remote host.
pkg_git "$root" archive --format=tar "$pin" packages/interfaces |
  (cd "$dest" && tar -x)
# The fetch url, without any credentials a CI clone embedded in it.
url=$(pkg_git "$root" remote get-url origin 2>/dev/null |
  sed -E 's#^([a-z+]+://)[^/@]*@#\1#; s#\.git$##' || true)
[[ -n "$url" ]] || url="https://github.com/metacraft-labs/reprobuild-packages"
printf 'url=%s\nrevision=%s\n' "$url" "$pin" > "$dest/catalog-revision"
[[ -d "$dest/packages/interfaces" ]] ||
  fail "reprobuild-packages $pin has no packages/interfaces"
count=$(find "$dest/packages/interfaces" -name repro.nim -type f | wc -l)
echo "stage_release_catalog: staged $count package interface(s) at $dest"
