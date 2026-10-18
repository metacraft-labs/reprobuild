#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

version="$1"
case "${version}" in
  *[!0-9.]*|"") echo "version must contain digits and dots only" >&2; exit 2 ;;
esac

perl -0pi -e "s/version = \"[^\"]+\"/version = \"${version}\"/" reprobuild.nimble

# package.nix carries the version as a literal (nixpkgs forbids reading it
# from reprobuild.nimble at evaluation time), so a bump moves both;
# scripts/check_package_nix_version.sh (in `just lint` and the flake check
# nixpkgs-package-version-sync) refuses a tree where they differ.
package_nix=nix/pkgs/by-name/re/reprobuild/package.nix
perl -pi -e "s/^  version = \"[^\"]+\";/  version = \"${version}\";/" "${package_nix}"
bash ./scripts/check_package_nix_version.sh

# The literal's `src` snapshot cannot move in the same commit: it must name a
# PUBLISHED commit whose reprobuild.nimble already says this version.
echo "note: once this bump is pushed, move ${package_nix}'s \`src\` (rev, hash)" \
  "and *Src defaults to it; nixpkgs-package-src-sync checks that snapshot" \
  "(nix/README.md)." >&2
