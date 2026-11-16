#!/usr/bin/env bash
# stage_release_macos_tools.sh <package-dir>
#
# Put the non-SIP tools bundle (stackable-hooks-macos-tools) into a darwin
# release tree at libexec/stackable-hooks-macos-tools.
#
# WHY. A monitored action on macOS needs a non-SIP shell and non-SIP drop-ins
# for the system tools: SIP strips DYLD_INSERT_LIBRARIES when a protected
# binary such as /bin/sh is exec'd, so the monitor shim would not load. The
# engine and the shim find the bundle through the stackable-hooks resolver,
# whose last fallback is the bundle's BUILD-HOST store path, compiled in from
# the dev shell's STACKABLE_HOOKS_BUILT_TOOLS_DIR. On a Mac without that store
# path the release found no shell and every monitored launch failed with
# "SIP-safe monitored launch requires a non-SIP shell" (reprobuild-pm
# issues/2026-11-12-darwin-release-names-a-nix-store-path-for-its-non-sip-shell-and-fails-on-a-nix-less-mac.md).
# Distribution-And-Packaging.md §5.1, "The darwin non-SIP tools bundle": every
# darwin archive carries the bundle the engine was built against, copied
# unchanged, and the engine points STACKABLE_HOOKS_TOOLS_DIR at it.
#
# REFUSALS. The bundle is relocatable by construction (its own build-bundle.sh
# bundles every dylib). This script still refuses, rather than ships:
#   * an absolute symlink (it would point back into the build host),
#   * a Mach-O image that loads a library from, or has an LC_RPATH into,
#     /nix/store,
#   * a missing bin/sh, or one that does not run with PATH=/usr/bin:/bin.
#
# Run from the reprobuild checkout root, inside the dev shell, AFTER
# relocate_release_posix.sh (which rewrites the archive's own bin/ and lib/
# images; the bundle is copied unchanged). A no-op on non-darwin hosts.
set -euo pipefail

pkg="${1:?usage: stage_release_macos_tools.sh <package-dir>}"
[ -d "$pkg" ] || { echo "stage_release_macos_tools: no such directory: $pkg" >&2; exit 2; }

if [ "$(uname -s)" != Darwin ]; then
  exit 0
fi

src="${STACKABLE_HOOKS_BUILT_TOOLS_DIR:-}"
if [ -z "$src" ] || [ ! -d "$src" ]; then
  echo "stage_release_macos_tools: STACKABLE_HOOKS_BUILT_TOOLS_DIR is unset or not a directory ('$src'); run inside the reprobuild dev shell" >&2
  exit 1
fi

dest="$pkg/libexec/stackable-hooks-macos-tools"
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
# -R keeps relative symlinks as symlinks; -p keeps modes. The store copy is
# read-only, so make the staged tree writable for later packaging steps.
cp -Rp "$src" "$dest"
chmod -R u+w "$dest"

problems=()
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  case "$target" in
    /*) problems+=("absolute symlink ${link#"$pkg"/} -> $target") ;;
  esac
done < <(find "$dest" -type l -print0)

while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  if otool -L "$f" | tail -n +2 | grep -q '/nix/store/'; then
    problems+=("${f#"$pkg"/} loads from /nix/store: $(otool -L "$f" | tail -n +2 | grep '/nix/store/' | head -1 | awk '{print $1}')")
  fi
  if otool -l "$f" | awk '/cmd LC_RPATH/{r=1; next} r && /path /{print $2; r=0}' | grep -q '^/nix/store/'; then
    problems+=("${f#"$pkg"/} has an LC_RPATH into /nix/store")
  fi
done < <(find "$dest" -type f -print0)

sh_path="$dest/bin/sh"
if [ ! -x "$sh_path" ]; then
  problems+=("no executable libexec/stackable-hooks-macos-tools/bin/sh")
elif ! env -i PATH=/usr/bin:/bin "$sh_path" -c 'exit 0'; then
  problems+=("libexec/stackable-hooks-macos-tools/bin/sh does not run with PATH=/usr/bin:/bin")
fi

if [ "${#problems[@]}" -gt 0 ]; then
  echo "stage_release_macos_tools: refusing to ship the tools bundle from $src:" >&2
  printf '  %s\n' "${problems[@]}" >&2
  rm -rf "$dest"
  exit 1
fi
echo "stage_release_macos_tools: staged $src at ${dest#"$pkg"/}"
