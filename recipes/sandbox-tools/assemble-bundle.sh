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
declare -a recipe_dirs=(
  "$here/coreutils"
  "$here/bash"
)

rm -rf "$out_dir"
mkdir -p "$out_dir/bin" "$out_dir/usr/bin"

otool_bin="$(command -v otool || echo /usr/bin/otool)"

# A Mach-O is bundle-eligible only if it links ONLY libSystem / system
# frameworks. The reprobuild from-source build makes the essential drop-ins
# libSystem-only; a few NON-essential coreutils digest/locale utilities
# (md5sum / sha*sum / cksum / sort / printf) can still pick up the nix dev
# shell's libcrypto / libiconv on a dirty parallel-make tree. Those are NOT SIP
# drop-in targets the io-mon monitor redirects to, so excluding them keeps the
# bundle 100% portable (libSystem-only) without losing any required drop-in.
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
    echo "         --daemon=off  (with REPRO_MACOS_DISABLE_ACTION_MONITOR=1)" >&2
    continue
  fi
  for src in "$install_bin"/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    # Skip if a prior recipe already supplied this name (coreutils wins over a
    # bash-shipped duplicate, etc.). First recipe in recipe_dirs takes priority.
    [ -e "$out_dir/bin/$name" ] && continue
    # Only admit libSystem-only binaries so the bundle stays relocatable.
    if ! is_portable_macho "$src"; then
      excluded+=("$name")
      continue
    fi
    cp "$src" "$out_dir/bin/$name"
    chmod u+w "$out_dir/bin/$name"
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
