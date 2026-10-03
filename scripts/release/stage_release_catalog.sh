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

root=""
for candidate in "${REPROBUILD_PACKAGES_ROOT:-}" ../reprobuild-packages; do
  if [[ -n "$candidate" ]] &&
      git -C "$candidate" rev-parse --verify --quiet "${pin}^{commit}" >/dev/null 2>&1; then
    root=$candidate
    break
  fi
done
[[ -n "$root" ]] ||
  fail "no git checkout holding reprobuild-packages $pin (tried \$REPROBUILD_PACKAGES_ROOT='${REPROBUILD_PACKAGES_ROOT:-}' and ../reprobuild-packages); clone it there, or fetch that commit into it"

echo "stage_release_catalog: reprobuild-packages <- $root @ $pin"
rm -rf "$dest"
mkdir -p "$dest"
# Extract from inside the destination: given `-C C:\...`, a tar reads the
# drive letter as a remote host.
git -C "$root" archive --format=tar "$pin" packages/interfaces |
  (cd "$dest" && tar -x)
# The fetch url, without any credentials a CI clone embedded in it.
url=$(git -C "$root" remote get-url origin 2>/dev/null |
  sed -E 's#^([a-z+]+://)[^/@]*@#\1#; s#\.git$##' || true)
[[ -n "$url" ]] || url="https://github.com/metacraft-labs/reprobuild-packages"
printf 'url=%s\nrevision=%s\n' "$url" "$pin" > "$dest/catalog-revision"
[[ -d "$dest/packages/interfaces" ]] ||
  fail "reprobuild-packages $pin has no packages/interfaces"
count=$(find "$dest/packages/interfaces" -name repro.nim -type f | wc -l)
echo "stage_release_catalog: staged $count package interface(s) at $dest"
