#!/usr/bin/env bash
# Assemble the portable macOS "sandbox-tools" bundle from the reprobuild-built
# tool trees.
#
# WHY (SIP / AMFI — see
# reprobuild-specs/Portable-Macos-Sandbox-Tools.milestones.org):
#   The io-mon monitor redirects an exec of a SIP-protected system binary
#   (/bin/sh, /bin/cat, /usr/bin/grep, …) to a NON-SIP drop-in we build, so the
#   injected shim follows the process tree across the SIP boundary instead of
#   going blind. ``rewriteSipPath`` resolves "/bin/cat" → "<DIR>/bin/cat" and
#   "/usr/bin/cat" → "<DIR>/usr/bin/cat", and "/bin/sh" → "<DIR>/bin/sh".
#
# WHAT THIS PRODUCES (mirrors the SIP filesystem layout):
#   <DIR>/bin/<tool>        (mirrors /bin)
#   <DIR>/usr/bin/<tool>    (mirrors /usr/bin)
#   <DIR>/bin/sh -> bash    (so a /bin/sh redirect lands on a real shell)
#
# This REPLACES the interim nix-symlink bundle
# (io-mon/scripts/build-sandbox-tools.sh) with reprobuild-from-source tools:
# every binary here was built by `repro build recipes/sandbox-tools/<tool>` and
# links ONLY /usr/lib/libSystem.B.dylib (verified below), so the bundle is
# relocatable and AMFI-safe with NO install_name_tool relocation step.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "assemble-bundle.sh is macOS-only (no-op on $(uname -s))" >&2
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${SANDBOX_BUNDLE_OUT_DIR:-$here/bundle}"

# Each reprobuild recipe stages its installed tree under
# <recipe>/.repro/output/install/usr/bin. We harvest from there so every
# binary the package built (coreutils ships ~100) is available, not only the
# handful the recipe registers as typed artifacts.
#
# ORDER MATTERS: the first recipe to supply a given binary name wins (see the
# "$out_dir/bin/$name" de-dup below). coreutils is listed first so its canonical
# POSIX userland takes priority over any same-named binary another package might
# ship. The full sandbox tool set is the 10 GNU/XZ packages below.
declare -a recipe_dirs=(
  "$here/coreutils"
  "$here/bash"
  "$here/findutils"
  "$here/gnugrep"
  "$here/gawk"
  "$here/gnused"
  "$here/gnutar"
  "$here/gzip"
  "$here/xz"
  "$here/which"
)

rm -rf "$out_dir"
mkdir -p "$out_dir/bin" "$out_dir/usr/bin"

otool_bin="$(command -v otool || echo /usr/bin/otool)"

# A Mach-O is bundle-eligible only if it links ONLY libSystem / system
# frameworks. The reprobuild from-source build now makes EVERY tool binary
# libSystem-only (coreutils via --without-openssl + iconv-off; grep/tar/bash via
# the iconv-off cache vars; the rest via -dead_strip_dylibs in the shared
# template), so in the expected case nothing is excluded. This gate remains as a
# DEFENSIVE backstop: should any future recipe regress and pull a /nix/store (or
# other non-system) dylib, that binary is dropped here rather than silently
# shipping a non-relocatable bundle.
is_portable_macho() {
  local f="$1"
  file "$f" 2>/dev/null | grep -q "Mach-O" || return 0   # non-Mach-O passes
  local nonsys
  nonsys="$("$otool_bin" -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/)' || true)"
  [ -z "$nonsys" ]
}

declare -a copied=()
declare -a excluded=()
for recipe in "${recipe_dirs[@]}"; do
  install_bin="$recipe/.repro/output/install/usr/bin"
  if [ ! -d "$install_bin" ]; then
    echo "WARNING: $recipe not built — missing $install_bin" >&2
    echo "  run: repro build $recipe --tool-provisioning=path --no-runquota \\" >&2
    echo "         --daemon=off" >&2
    continue
  fi
  for src in "$install_bin"/*; do
    # ``-f`` follows symlinks, so a same-package link to a real file (gawk's
    # ``awk`` → ``gawk``, xz's ``unxz`` → ``xz``) is admitted and ``cp``
    # dereferences it into a standalone binary under the new name — keeping the
    # bundle self-contained without dangling links.
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    # Skip if a prior recipe already supplied this name (coreutils wins over a
    # bash-shipped duplicate, etc.). First recipe in recipe_dirs takes priority.
    [ -e "$out_dir/bin/$name" ] && continue
    # Only admit libSystem-only binaries so the bundle stays relocatable.
    # (is_portable_macho returns success for non-Mach-O files — i.e. the GNU
    # script wrappers egrep/fgrep/gunzip/zcat — which are handled just below.)
    if ! is_portable_macho "$src"; then
      excluded+=("$name")
      continue
    fi
    cp "$src" "$out_dir/bin/$name"
    chmod u+w "$out_dir/bin/$name"
    # GNU ships egrep/fgrep/gunzip/zcat as #! shell-script wrappers. Autotools
    # bakes the BUILD shell into the shebang (here /nix/store/.../bash), which
    # would NOT exist on a target machine — breaking relocatability. Rewrite any
    # absolute interpreter shebang to the bundle-relative POSIX shell so the
    # wrapper runs the bundle's own bin/sh (→ bash) drop-in. We also normalise
    # any hard-coded ``exec /abs/path/grep`` to a bare ``grep`` so PATH (seeded
    # to the bundle by the monitor) resolves the sibling drop-in.
    if head -c2 "$out_dir/bin/$name" 2>/dev/null | grep -q '#!'; then
      # Replace ``#!<abs>/(ba)?sh ...`` with ``#!/bin/sh`` (which inside the
      # sandbox redirect resolves to the bundle's bin/sh → bash), AND neutralise
      # any baked-in ``/nix/store/<hash>-<pkg>/bin/<tool>`` absolute tool path in
      # the script body (e.g. updatedb's ``sort=/nix/.../sort``, zgrep's
      # ``grep=/nix/.../grep``) down to the bare tool name so PATH — which the
      # monitor seeds to point at this bundle — resolves the sibling drop-in
      # instead of a Nix path that will not exist on a target machine. Use a temp
      # file + mv rather than ``sed -i`` to stay portable across BSD (macOS) and
      # GNU sed, whose ``-i`` argument conventions differ.
      tmp="$out_dir/bin/.$name.tmp"
      sed -E \
        -e '1 s|^#![^[:space:]]*/(ba)?sh|#!/bin/sh|' \
        -e 's@/nix/store/[a-z0-9]+-[^/[:space:]]+/bin/([A-Za-z0-9_.-]+)@\1@g' \
        "$out_dir/bin/$name" > "$tmp" && mv "$tmp" "$out_dir/bin/$name"
      chmod u+wx "$out_dir/bin/$name"
    fi
    copied+=("$name")
  done
done

# bash provides the POSIX shell: expose it as `sh` so a /bin/sh SIP redirect
# lands on a real shell. Relative symlink keeps the bundle relocatable.
if [ -f "$out_dir/bin/bash" ]; then
  ln -sf bash "$out_dir/bin/sh"
fi

# Mirror every produced tool into usr/bin so a /usr/bin/<tool> SIP redirect
# resolves too (macOS ships many tools at BOTH /bin and /usr/bin). Relative
# symlinks keep the bundle relocatable.
for f in "$out_dir/bin"/*; do
  [ -e "$f" ] || continue
  ln -sf "../../bin/$(basename "$f")" "$out_dir/usr/bin/$(basename "$f")"
done

# Verify the libSystem-only portability invariant on every real Mach-O. The
# reprobuild from-source build is supposed to link ONLY libSystem; a
# /nix/store (or any non-/usr/lib, non-/System) reference would mean the binary
# is NOT relocatable and would fail on a machine without Nix.
portability_ok=1
for f in "$out_dir/bin"/*; do
  [ -f "$f" ] || continue           # skip the sh symlink
  if file "$f" 2>/dev/null | grep -q "Mach-O"; then
    nonsys="$("$otool_bin" -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
      | grep -vE '^(/usr/lib/|/System/)' || true)"
    if [ -n "$nonsys" ]; then
      echo "WARNING: $f links non-system libraries:" >&2
      echo "$nonsys" | sed 's/^/    /' >&2
      portability_ok=0
    fi
  else
    # Non-Mach-O script wrappers (egrep/gunzip/zgrep/...): they must not retain
    # any /nix/store reference in a position that would be executed. We ALLOW
    # such strings inside comments (gzexe ships a documentation banner that
    # literally prints "/nix/.../bash"), so we only flag a /nix/store token on a
    # non-comment line.
    nixref="$(grep -nE '/nix/store/' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [ -n "$nixref" ]; then
      echo "WARNING: $f retains an executable /nix/store reference:" >&2
      echo "$nixref" | sed 's/^/    /' >&2
      portability_ok=0
    fi
  fi
done

echo "sandbox-tools bundle: $out_dir"
echo "  copied: ${#copied[@]} tools"
if [ "${#excluded[@]}" -gt 0 ]; then
  echo "  excluded (non-libSystem, non-essential): ${excluded[*]}" >&2
fi
echo "  shell:  bin/sh -> bash"
if [ "$portability_ok" -eq 1 ]; then
  echo "  portability: OK (libSystem-only — no /nix/store, no extra dylibs)"
else
  echo "  portability: INCOMPLETE (see warnings above)" >&2
  exit 1
fi
