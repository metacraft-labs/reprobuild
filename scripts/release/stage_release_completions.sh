#!/usr/bin/env bash
# stage_release_completions.sh <package-dir> [shell ...]
#
# Generate repro's shell completion scripts into a release tree, at
#
#   <package-dir>/share/repro/completions/repro.bash   (bash)
#   <package-dir>/share/repro/completions/_repro       (zsh)
#   <package-dir>/share/repro/completions/repro.fish   (fish)
#   <package-dir>/share/repro/completions/repro.ps1    (powershell)
#
# With no shell named, all four are written. The Windows archive names only
# `powershell` (scripts/release/package_windows_release.ps1).
#
# WHY HERE, AND WHY FROM THE LEG'S OWN BINARY. The archive is the one source
# every package format copies from: scripts/release/repro-build-packages.sh
# installs these files where each distribution's shells load completion
# without setup (bash-completion's completions/, zsh's fpath, fish's
# vendor_completions.d), and scripts/install/repro-install.sh installs them
# per user for a tarball install. Generating them once per release leg, from
# the binary that leg just built, keeps every format byte-identical to the
# archive and means the packaging step never has to run repro. Every leg
# builds natively, so the binary runs on the host that built it.
#
# The scripts are thin: each hands the words being completed back to the
# installed `repro __complete`, which answers from the command line the binary
# declares. A script that does not call `__complete` cannot complete anything,
# so one that is empty or lacks that call is REFUSED here rather than shipped,
# and so is a zsh script whose first line is not `#compdef repro`: zsh's
# compinit registers only files that start with that tag
# (https://zsh.sourceforge.io/Doc/Release/Completion-System.html#Use-of-compinit).
#
# Run from the reprobuild checkout root, after `cp -a build/*` into the tree
# and before the tree is relocated or archived. REPRO_COMPLETION_BIN names a
# different binary (default build/bin/repro).
set -euo pipefail

pkg="${1:?usage: stage_release_completions.sh <package-dir> [bash|zsh|fish|powershell ...]}"
shift
[ -d "$pkg" ] || { echo "stage_release_completions: no such directory: $pkg" >&2; exit 2; }

repro="${REPRO_COMPLETION_BIN:-build/bin/repro}"
[ -x "$repro" ] || [ -x "$repro.exe" ] || {
  echo "stage_release_completions: $repro is not an executable; build first (bash ./scripts/build_apps.sh)" >&2
  exit 1
}

if [ "$#" -eq 0 ]; then
  set -- bash zsh fish powershell
fi

dest="$pkg/share/repro/completions"
mkdir -p "$dest"

for shell in "$@"; do
  case "$shell" in
    bash)       name='repro.bash' ;;
    zsh)        name='_repro' ;;
    fish)       name='repro.fish' ;;
    powershell) name='repro.ps1' ;;
    *) echo "stage_release_completions: unknown shell '$shell' (bash, zsh, fish or powershell)" >&2; exit 2 ;;
  esac
  out="$dest/$name"
  tmp="$out.tmp"
  # Redirected straight to the file: the bytes the binary printed are the
  # bytes shipped, with no shell or PowerShell text conversion in between.
  if ! "$repro" completion "$shell" > "$tmp"; then
    rm -f "$tmp"
    echo "stage_release_completions: '$repro completion $shell' failed" >&2
    exit 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "stage_release_completions: '$repro completion $shell' printed nothing; refusing to ship an empty $name" >&2
    exit 1
  fi
  if ! grep -q -- '__complete' "$tmp"; then
    rm -f "$tmp"
    echo "stage_release_completions: the $shell script does not call 'repro __complete'; refusing to ship $name" >&2
    exit 1
  fi
  if [ "$shell" = zsh ] && [ "$(head -n 1 "$tmp")" != '#compdef repro' ]; then
    rm -f "$tmp"
    echo "stage_release_completions: the zsh script does not start with '#compdef repro'; compinit would ignore $name" >&2
    exit 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$out"
  echo "stage_release_completions: wrote ${out#"$pkg"/} ($(wc -c < "$out" | tr -d ' ') bytes)"
done
