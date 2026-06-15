#!/usr/bin/env bash
# W4 P1: ReproOS Wine-augmented ISO build driver.
#
# Builds an ISO that boots into systemd + autologin root, with WINE + 3
# pinned Windows tools (gh 2.40.0 / just 1.24.0 / ninja 1.12.1) staged
# under /opt/reproos-foreign/. The 3 shims at /usr/local/bin/wine-{gh,
# just,ninja} route through reprobuild-sandbox-launcher with W3 launcher
# manifests carrying runtime=wine.
#
# Layout produced inside the VM rootfs:
#
#   /opt/reproos-foreign/wine-binaries/      WINE binaries + libraries
#     usr/bin/wine                            (apt-harvested from
#     usr/bin/wine-stable                      Debian bookworm)
#     usr/bin/wineboot
#     usr/bin/wineserver
#     usr/lib/wine/wine64
#     usr/lib/wine/wineserver64
#     usr/lib/x86_64-linux-gnu/wine/         WINE DLL + .so closure
#       ntdll.so, kernel32.so, advapi32.so, libwine.so.1.0, etc.
#
#   /opt/reproos-foreign/wine-prefix/        SHARED WINEPREFIX (post-
#     drive_c/                                wineboot -i; baked at
#       windows/...                           build time per W1 decision).
#       users/...
#       repro-store/
#         gh/bin/gh.exe                       Per-package payloads
#         just/bin/just.exe                   planted by build-windows-
#         ninja/bin/ninja.exe                 prefix.sh.
#
#   /opt/reproos-foreign/wine-{gh,just,ninja}/   Per-tool launcher dirs
#     launcher.manifest                          (manifest + W3 shim
#     (shim is at /usr/local/bin/wine-<name>)    points at VM paths).
#
#   /usr/local/bin/reprobuild-sandbox-launcher    Launcher binary
#   /usr/local/bin/wine-gh                        Per-tool shim
#   /usr/local/bin/wine-just
#   /usr/local/bin/wine-ninja
#
# Per the W4 brief (campaign spec line 188-205), this is a separate driver
# from build-mvp-multi-iso.sh (Option B): purpose-built for W4, doesn't
# include the Linux foreign packages. M1 will merge the Linux + Windows
# + macOS halves into the tri-OS ISO.
#
# Strict scope:
#   * 3 Windows tools (gh / just / ninja) per W3 catalog.
#   * wineboot -i runs ONCE before the per-catalog phase (not per tool).
#   * Shims embed launcher path as /usr/local/bin/reprobuild-sandbox-launcher.
#   * Wine binaries harvested from the build host's apt-installed wine
#     package; W4 doesn't run the C2 apt harvester for WINE (post-PoC
#     follow-up; per the W1 doc that's an acceptable shortcut for the PoC).
#
# Usage:
#
#   bash build-mvp-wine-iso.sh
#     [MVP_STAGE=overlay|initramfs|iso]
#     [W4_OUT_DIR=<path>]                  default: $REPO/build/w4-wine
#     [WINE_SRC_ROOT=<path>]               default: /usr  (host's apt-wine)
#
# Exit codes:
#   0   success (ISO built or overlay staged depending on STAGE)
#   1   preflight error / argument error
#   2   wine harvest failure
#   3   wine-prefix-init failure
#   4   build-windows-prefix.sh failure
#   5   initramfs/ISO assembly failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="${W4_OUT_DIR:-$REPO_ROOT/build/w4-wine}"
STAGE="${MVP_STAGE:-iso}"
WINE_SRC_ROOT="${WINE_SRC_ROOT:-/usr}"
VENDORED_DIR="${W4_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/windows}"

# Inside the VM, the Wine binaries land at this canonical path so wine64
# can find its DLL closure via the hardcoded /usr/lib/x86_64-linux-gnu/wine
# string baked into the wine64 ELF. We bind these into FHS positions in
# the overlay using symlinks/copies so /usr/bin/wine + /usr/lib/wine/wine64
# resolve directly.
VM_WINE_BIN="/usr/bin/wine"
VM_WINE_PREFIX="/opt/reproos-foreign/wine-prefix"
VM_LAUNCHER_PATH="/usr/local/bin/reprobuild-sandbox-launcher"

log() { echo "[w4] $*" >&2; }
die() { echo "[w4][error] $*" >&2; exit "${2:-1}"; }

mkdir -p "$OUT_DIR"
log "out dir: $OUT_DIR"
log "stage: $STAGE"
log "wine source: $WINE_SRC_ROOT"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *) die "non-Linux host: $(uname -s) — W4 build needs Linux/WSL" 1 ;;
esac

for tool in wine wineboot wineserver python3 unzip sha256sum cpio gzip; do
  command -v "$tool" >/dev/null 2>&1 || die "preflight: '$tool' missing on PATH" 1
done

for f in "$VENDORED_DIR/gh_2.40.0_windows_amd64.zip" \
         "$VENDORED_DIR/just-1.24.0-x86_64-pc-windows-msvc.zip" \
         "$VENDORED_DIR/ninja-win.zip"; do
  [ -f "$f" ] || die "vendored archive missing: $f (run fetch-real-archives.sh first)" 1
done

# Wine source tree sanity. Wine 6+ moved most DLLs to PE-only (no .so
# helper); kernel32.dll is PE, only ntdll/user32/gdi32 etc. keep .so
# helpers. We probe a small representative set.
for p in "$WINE_SRC_ROOT/lib/wine/wine64" \
         "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/libwine.so.1.0" \
         "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/ntdll.so" \
         "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/user32.so" \
         "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/kernel32.dll"; do
  [ -f "$p" ] || die "preflight: wine source path missing: $p" 1
done

# ---------------------------------------------------------------------------
# Stage 0: build/locate the launcher binary (the same C3 launcher D1+D2
# use; the wine runtime path lives inside it from W2).
# ---------------------------------------------------------------------------

log "stage 0: locate/build C3 launcher (musl-static needed for ReproOS R9)"

LAUNCHER_BIN_SRC="$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher"
if [ ! -x "$LAUNCHER_BIN_SRC" ]; then
  log "building launcher via apps/reprobuild-sandbox-launcher/build.sh"
  ( cd "$REPO_ROOT/apps/reprobuild-sandbox-launcher" && ./build.sh ) || \
    die "launcher build failed" 1
fi
[ -x "$LAUNCHER_BIN_SRC" ] || die "launcher missing after build: $LAUNCHER_BIN_SRC" 1
log "launcher: $LAUNCHER_BIN_SRC"

# ---------------------------------------------------------------------------
# Stage 1: stage WINE binary closure into the overlay.
#
# The VM rootfs lands wine at /opt/reproos-foreign/wine-binaries/usr/...
# because the launcher's bind-mount path resolves under that subtree.
# We ALSO drop /usr/bin/wine + /usr/lib/wine + /usr/lib/x86_64-linux-gnu/wine
# directly into the overlay so wine64's hardcoded DLL search path resolves
# without env-var hacks. (wine64 has the path
# /usr/lib/x86_64-linux-gnu/wine baked into its ELF.)
# ---------------------------------------------------------------------------

log "stage 1: harvest WINE binary closure"

OVERLAY="$OUT_DIR/overlay"
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/lib/wine" \
         "$OVERLAY/usr/lib/x86_64-linux-gnu/wine" \
         "$OVERLAY/usr/local/bin" \
         "$OVERLAY/opt/reproos-foreign"

# WINE binaries that are real ELF files. The /usr/bin/wine etc. on the
# host are POSIX shell wrappers; we keep them as wrappers in the overlay
# too so wine64 ends up via the same indirection path.
log "  copy /usr/bin/wine-stable + wrapper"
cp -L "$WINE_SRC_ROOT/bin/wine-stable"      "$OVERLAY/usr/bin/wine-stable"
cp -L "$WINE_SRC_ROOT/bin/wine64-stable"    "$OVERLAY/usr/bin/wine64-stable"
cp -L "$WINE_SRC_ROOT/bin/wineboot-stable"  "$OVERLAY/usr/bin/wineboot-stable"
cp -L "$WINE_SRC_ROOT/bin/wineserver-stable" "$OVERLAY/usr/bin/wineserver-stable"

# Resolve /usr/bin/wine wrapper. It's a shell script that picks
# /usr/lib/wine/wine (i386) or /usr/lib/wine/wine64 — we copy the script
# content (small POSIX-sh) so we don't depend on /etc/alternatives in the
# ReproOS rootfs.
WINE_WRAPPER="$WINE_SRC_ROOT/bin/wine-stable"
cp -L "$WINE_WRAPPER" "$OVERLAY/usr/bin/wine"
cp -L "$WINE_SRC_ROOT/bin/wine64-stable" "$OVERLAY/usr/bin/wine64"
cp -L "$WINE_SRC_ROOT/bin/wineboot-stable" "$OVERLAY/usr/bin/wineboot"
cp -L "$WINE_SRC_ROOT/bin/wineserver-stable" "$OVERLAY/usr/bin/wineserver"
chmod +x "$OVERLAY/usr/bin/"wine*

log "  copy /usr/lib/wine/ (wine64 + wineserver64)"
cp -L "$WINE_SRC_ROOT/lib/wine/wine64"       "$OVERLAY/usr/lib/wine/wine64"
cp -L "$WINE_SRC_ROOT/lib/wine/wineserver64" "$OVERLAY/usr/lib/wine/wineserver64"
cp -L "$WINE_SRC_ROOT/lib/wine/wineserver"   "$OVERLAY/usr/lib/wine/wineserver" 2>/dev/null || true
cp -L "$WINE_SRC_ROOT/lib/wine/wineapploader" "$OVERLAY/usr/lib/wine/wineapploader" 2>/dev/null || true
chmod +x "$OVERLAY/usr/lib/wine/"*

log "  copy /usr/lib/x86_64-linux-gnu/wine/ (DLL + .so closure)"
# Full WINE DLL/.so closure — 94 files, ~525 MB. The R8/R9 kernel doesn't
# have most of the X11/audio runtime deps these .so's link against, but
# for CLI-only --version invocations (gh/just/ninja) the dynamic linker
# only resolves what's actually pulled in by the running executable's
# import table, which for these tools is kernel32 + advapi32 + ntdll only.
cp -rL "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/." \
       "$OVERLAY/usr/lib/x86_64-linux-gnu/wine/"

log "  copy /usr/share/wine/ (NLS data + wine.inf)"
# wineserver loads l_intl.nls + other locale data from /usr/share/wine/wine/nls/.
# Without these, every wine invocation that touches a WINEPREFIX dies with
# 'wineserver: failed to load l_intl.nls'. Small (~10 MB).
mkdir -p "$OVERLAY/usr/share/wine"
cp -rL "$WINE_SRC_ROOT/share/wine/." "$OVERLAY/usr/share/wine/"

# ---------------------------------------------------------------------------
# Stage 1b: harvest runtime library closure for wine64 + the DLL .so's
# that the CLI tools actually pull in.
#
# wine64 needs libc + ld-linux (provided by R9). The DLL .so's pull in
# a long list (X11, audio, gnutls, ...). For PoC CLI-only smoke tests we
# only need the libraries that ntdll.so + kernel32.so + advapi32.so +
# libwine.so themselves depend on (a small subset). Take the union of
# their ldd output, dedup, copy.
# ---------------------------------------------------------------------------

log "stage 1b: harvest runtime library closure"

# Probes: critical .so files we know are loaded. We deliberately do NOT
# walk the full /usr/lib/x86_64-linux-gnu/wine/*.so set's ldd output
# because that pulls X11 + audio + gstreamer + 200+ MB of libs we don't
# need for --version. The probes here are the import-table closure for
# our PoC tools (gh, just, ninja) plus the WINE bootstrap.
WINE_PROBES=(
  "$WINE_SRC_ROOT/lib/wine/wine64"
  "$WINE_SRC_ROOT/lib/wine/wineserver64"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/libwine.so.1.0"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/ntdll.so"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/user32.so"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/gdi32.so"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/ws2_32.so"
  "$WINE_SRC_ROOT/lib/x86_64-linux-gnu/wine/iphlpapi.dll.so"
)

# Collect unique library paths. Skip libc/libm/libpthread/libdl/ld-linux
# (provided by R9 already) and wine's own libs.
declare -A SEEN_LIBS
RUNTIME_LIBS=()
for probe in "${WINE_PROBES[@]}"; do
  [ -f "$probe" ] || continue
  ldd "$probe" 2>/dev/null | awk '/=>/ {print $3}' | while read -r lib; do
    case "$lib" in
      ""|"not"*) continue ;;
      /lib/x86_64-linux-gnu/libc.so.6|\
      /lib/x86_64-linux-gnu/libm.so.6|\
      /lib/x86_64-linux-gnu/libpthread.so.0|\
      /lib/x86_64-linux-gnu/libdl.so.2|\
      /lib/x86_64-linux-gnu/libresolv.so.2|\
      /lib64/ld-linux*|\
      /usr/lib/x86_64-linux-gnu/wine/*) continue ;;
      *) echo "$lib" ;;
    esac
  done
done | sort -u > "$OUT_DIR/runtime-libs.txt"

n_libs=$(wc -l < "$OUT_DIR/runtime-libs.txt")
log "  found $n_libs runtime libs needed (not provided by R9)"

while read -r lib; do
  [ -n "$lib" ] && [ -f "$lib" ] || continue
  # Place at the same FHS path inside the overlay so wine64's RPATH
  # discovers them via ld-linux's default search.
  rel="${lib#/}"
  mkdir -p "$OVERLAY/$(dirname "$rel")"
  cp -L "$lib" "$OVERLAY/$rel"
done < "$OUT_DIR/runtime-libs.txt"

# ---------------------------------------------------------------------------
# Stage 2: initialise WINEPREFIX (W1's wineboot -i, baked at build time).
#
# The init script writes to a build-host path; we'll plant the resulting
# directory tree at /opt/reproos-foreign/wine-prefix in the VM. The
# wineboot-time registry hives include the build-host's prefix path in
# absolute form, but WINE reads $WINEPREFIX at runtime to resolve those
# paths so the runtime VM path takes precedence. No path-rewriting of
# system.reg needed.
# ---------------------------------------------------------------------------

log "stage 2: WINEPREFIX init (wineboot -i)"

WINE_PREFIX_BUILD="$OUT_DIR/wine-prefix"
rm -rf "$WINE_PREFIX_BUILD"

# Per W4 brief risk #4: wineboot -i runs ONCE here (build time), NOT per
# tool. build-windows-prefix.sh below is invoked WITHOUT --init-prefix
# so the per-tool stage skips wineboot.
bash "$SCRIPT_DIR/wine-prefix-init.sh" \
  --prefix-dir "$WINE_PREFIX_BUILD" \
  --verbose 2> "$OUT_DIR/wine-prefix-init.log" || \
  die "wine-prefix-init.sh failed (see $OUT_DIR/wine-prefix-init.log)" 3

# ---------------------------------------------------------------------------
# Stage 2b: trim WINEPREFIX. The W1 doc's known-limitation #6 measured a
# 533 MB cold prefix dominated by drive_c/windows/Installer/ (Mono+Gecko
# MSI installers — inert for the PoC tools since mscoree+mshtml are
# disabled via WINEDLLOVERRIDES). Trim closes the gap.
# ---------------------------------------------------------------------------

log "stage 2b: trim drive_c/windows/Installer/ (Mono/Gecko MSI cache)"
INSTALLER_DIR="$WINE_PREFIX_BUILD/drive_c/windows/Installer"
if [ -d "$INSTALLER_DIR" ]; then
  inst_size=$(du -sm "$INSTALLER_DIR" 2>/dev/null | awk '{print $1}')
  log "  Installer/ size before trim: ${inst_size} MB"
  rm -rf "$INSTALLER_DIR"
fi

prefix_size_after=$(du -sm "$WINE_PREFIX_BUILD" 2>/dev/null | awk '{print $1}')
log "  WINEPREFIX size after trim: ${prefix_size_after} MB"

# ---------------------------------------------------------------------------
# Stage 3: run build-windows-prefix.sh — plants gh/just/ninja under
# drive_c/repro-store/ + emits launcher manifests + shims. Use
# --launcher-bin /usr/local/bin/reprobuild-sandbox-launcher per W4 brief
# risk #3 so the shims embed the VM-target launcher path.
#
# NOTE: build-windows-prefix.sh writes manifests with wine_prefix=$WINE_PREFIX_DIR
# (build-host path); we patch those to the VM path in stage 4b.
# ---------------------------------------------------------------------------

log "stage 3: plant 3 Windows tools into WINEPREFIX (gh + just + ninja)"

OVERLAY_TOOLS_TMP="$OUT_DIR/tools-overlay"
rm -rf "$OVERLAY_TOOLS_TMP"
mkdir -p "$OVERLAY_TOOLS_TMP"

bash "$SCRIPT_DIR/build-windows-prefix.sh" \
  --catalog-dir "$REPO_ROOT/recipes/catalog/windows" \
  --wine-prefix "$WINE_PREFIX_BUILD" \
  --store-root "$OUT_DIR/store" \
  --overlay "$OVERLAY_TOOLS_TMP" \
  --vendored "$VENDORED_DIR" \
  --launcher-bin "$VM_LAUNCHER_PATH" \
  --verbose 2> "$OUT_DIR/build-windows-prefix.log" || \
  die "build-windows-prefix.sh failed (see $OUT_DIR/build-windows-prefix.log)" 4

# Sanity: 3 shims should be in OVERLAY_TOOLS_TMP/usr/local/bin/.
for n in gh just ninja; do
  [ -f "$OVERLAY_TOOLS_TMP/usr/local/bin/wine-$n" ] || \
    die "expected shim missing: wine-$n" 4
done
log "  3 shims emitted"

# ---------------------------------------------------------------------------
# Stage 4: assemble the overlay.
#
# The build-windows-prefix.sh shims reference:
#   - wine_prefix=<build-host>/wine-prefix (in launcher.manifest)
#   - manifest=<build-host>/store/prefixes-win/<name>/launcher.manifest (in shim)
#   - LAUNCHER_BIN=$VM_LAUNCHER_PATH (set above, already VM path)
# Path rewrites needed for both manifest and shim.
# ---------------------------------------------------------------------------

log "stage 4: rewrite paths + assemble overlay"

# Stage 4a: copy the launcher.
cp "$LAUNCHER_BIN_SRC" "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher"
chmod +x "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher"

# Stage 4b: place WINEPREFIX at /opt/reproos-foreign/wine-prefix.
mkdir -p "$OVERLAY/opt/reproos-foreign"
cp -r "$WINE_PREFIX_BUILD" "$OVERLAY/opt/reproos-foreign/wine-prefix"

# Stage 4c: place per-tool dirs at /opt/reproos-foreign/wine-<name>/,
# pulling the manifest from the per-tool store-prefix dir. Each per-tool
# dir holds the launcher.manifest the shim references.
for n in gh just ninja; do
  tooldir="$OVERLAY/opt/reproos-foreign/wine-$n"
  mkdir -p "$tooldir"
  cp "$OUT_DIR/store/prefixes-win/$n/launcher.manifest" "$tooldir/launcher.manifest"
done

# Stage 4d: copy the 3 shims into the overlay /usr/local/bin/.
for n in gh just ninja; do
  cp "$OVERLAY_TOOLS_TMP/usr/local/bin/wine-$n" "$OVERLAY/usr/local/bin/wine-$n"
  chmod +x "$OVERLAY/usr/local/bin/wine-$n"
done

# Stage 4e: rewrite manifests + shims to VM paths.
#   Manifest:  wine_prefix=$WINE_PREFIX_BUILD       -> $VM_WINE_PREFIX
#   Manifest:  $WINE_PREFIX_BUILD:$WINE_PREFIX_BUILD:rbind  -> $VM_WINE_PREFIX:$VM_WINE_PREFIX:rbind
#   Manifest:  wine_bin=/usr/bin/wine                -> wine_bin=$VM_WINE_BIN (already match)
#   Shim:      --manifest=$OUT_DIR/store/prefixes-win/<n>/launcher.manifest
#              -> --manifest=/opt/reproos-foreign/wine-<n>/launcher.manifest

sed_escape() {
  printf '%s' "$1" | sed -e 's/[&\\/|]/\\&/g'
}

WPB_ESC=$(sed_escape "$WINE_PREFIX_BUILD")
VWP_ESC=$(sed_escape "$VM_WINE_PREFIX")

for n in gh just ninja; do
  mf="$OVERLAY/opt/reproos-foreign/wine-$n/launcher.manifest"
  sed -i -e "s|${WPB_ESC}|${VWP_ESC}|g" "$mf"
  # Also strip the build-host catalog-path from the header comment to keep
  # the manifest free of build-host residue (the path is informational
  # only; build-windows-prefix.sh writes "# Source catalog: <abspath>").
  sed -i -e "s|# Source catalog: $REPO_ROOT/|# Source catalog: |g" "$mf"
  sed -i -e "s|# Source catalog: /mnt/d/metacraft/reprobuild/|# Source catalog: |g" "$mf"

  # Confirm no residual build-host paths in non-comment lines.
  if grep -vE '^[[:space:]]*#' "$mf" | grep -qE "(D:/|/mnt/d/|$WINE_PREFIX_BUILD)" 2>/dev/null; then
    log "warn: residual build-host path in $mf (non-comment)"
    grep -vE '^[[:space:]]*#' "$mf" | grep -E "(D:/|/mnt/d/)" | head -3 | sed 's/^/  /' >&2
  fi

  # Shim rewrite. build-windows-prefix.sh wrote manifest path
  # =$OUT_DIR/store/prefixes-win/<n>/launcher.manifest; remap to the
  # per-tool VM path.
  shim="$OVERLAY/usr/local/bin/wine-$n"
  store_mf_path="$OUT_DIR/store/prefixes-win/$n/launcher.manifest"
  vm_mf_path="/opt/reproos-foreign/wine-$n/launcher.manifest"
  SMP_ESC=$(sed_escape "$store_mf_path")
  VMP_ESC=$(sed_escape "$vm_mf_path")
  sed -i -e "s|${SMP_ESC}|${VMP_ESC}|g" "$shim"
  # Strip the build-host catalog path from the header comment.
  sed -i -e "s|catalog $REPO_ROOT/|catalog |g" "$shim"
  sed -i -e "s|catalog /mnt/d/metacraft/reprobuild/|catalog |g" "$shim"

  # Validate shim ends with our launcher path + manifest path; mode +x.
  [ -x "$shim" ] || chmod +x "$shim"

  # Final residue check on the shim (non-comment only).
  if grep -vE '^[[:space:]]*#' "$shim" | grep -qE "(D:/|/mnt/d/)" 2>/dev/null; then
    log "warn: residual build-host path in $shim (non-comment)"
  fi
done

# ---------------------------------------------------------------------------
# Stage 4f: README for the overlay.
# ---------------------------------------------------------------------------

cat > "$OVERLAY/opt/reproos-foreign/README" <<EOF
ReproOS W4 (Windows-via-WINE) overlay.

Generated by recipes/reproos-mvp-config/build-mvp-wine-iso.sh from W3
catalogs (recipes/catalog/windows/{gh,just,ninja}.json).

Layout:

  wine-binaries/         Not directly populated here; the wine64 binary +
                         DLL closure live at standard FHS paths so wine64
                         can resolve them without env overrides.
  wine-prefix/           SHARED WINEPREFIX initialised via
                           wine-prefix-init.sh + wineboot -i.
                         drive_c/repro-store/<name>/ holds per-tool .exe.
  wine-<name>/           One per Windows package; carries
                         launcher.manifest (runtime=wine).

PATH shims:
  /usr/local/bin/wine-gh      gh 2.40.0 (GitHub CLI)
  /usr/local/bin/wine-just    just 1.24.0 (task runner)
  /usr/local/bin/wine-ninja   ninja 1.12.1 (build tool)

Each shim invokes:
  /usr/local/bin/reprobuild-sandbox-launcher --manifest=<...> -- <args>

The launcher (C3 native binary, runtime=wine path from W2) sets
\$WINEPREFIX, exec()s /usr/bin/wine with wine_exec as argv[1].
EOF

# ---------------------------------------------------------------------------
# Stage 4g: size accounting.
# ---------------------------------------------------------------------------

log "stage 4g: overlay size accounting"
{
  echo "=== W4 overlay size accounting ==="
  echo
  du -shm "$OVERLAY/usr/lib/wine/" 2>/dev/null || true
  du -shm "$OVERLAY/usr/lib/x86_64-linux-gnu/wine/" 2>/dev/null || true
  du -shm "$OVERLAY/opt/reproos-foreign/wine-prefix/" 2>/dev/null || true
  du -shm "$OVERLAY/opt/reproos-foreign/wine-prefix/drive_c/repro-store/" 2>/dev/null || true
  for n in gh just ninja; do
    du -shm "$OVERLAY/opt/reproos-foreign/wine-$n/" 2>/dev/null || true
  done
  echo
  echo "=== TOTAL ==="
  du -shm "$OVERLAY" 2>/dev/null || true
} > "$OUT_DIR/SIZE-ACCOUNTING.txt"
cat "$OUT_DIR/SIZE-ACCOUNTING.txt" >&2

log "overlay staged at $OVERLAY"

# ---------------------------------------------------------------------------
# Stage 5: initramfs + ISO assembly (gated on STAGE).
# ---------------------------------------------------------------------------

if [ "$STAGE" != "iso" ] && [ "$STAGE" != "initramfs" ]; then
  log "stage 5: skipping initramfs+ISO assembly (STAGE=$STAGE)"
  log "  rerun with MVP_STAGE=iso to assemble"
  exit 0
fi

log "stage 5: assembling initramfs + ISO"

R9_DIR="${R9_BUILD_DIR:-$REPO_ROOT/build/r9-build}"
R8_DIR="${R8_BUILD_DIR:-$REPO_ROOT/build/r8-build}"

if [ ! -f "$R9_DIR/initramfs-systemd.cpio.gz" ]; then
  log "warn: $R9_DIR/initramfs-systemd.cpio.gz not found; skipping ISO assembly"
  log "       (build R9 inside repro-ubuntu via recipes/bootstrap/systemd/scripts/build-initramfs.sh)"
  exit 0
fi
if [ ! -f "$R8_DIR/bzImage" ]; then
  log "warn: $R8_DIR/bzImage not found; skipping ISO assembly"
  exit 0
fi

AUGMENTED_INITRAMFS="$OUT_DIR/initramfs-w4-wine.cpio.gz"
EXTRA_CPIO="$OUT_DIR/overlay.cpio.gz"

log "  building extra cpio from overlay tree (this is the heavy step)..."
( cd "$OVERLAY" && \
  find . -print0 | LC_ALL=C sort -z | \
  cpio --null --owner=0:0 -o -H newc 2>/dev/null ) | \
  gzip -9 -n > "$EXTRA_CPIO" || die "cpio of overlay failed" 5
extra_sz=$(stat -c %s "$EXTRA_CPIO")
log "  overlay cpio: $EXTRA_CPIO ($extra_sz bytes)"

# Concatenated gzip streams form a valid cpio initramfs.
cat "$R9_DIR/initramfs-systemd.cpio.gz" "$EXTRA_CPIO" > "$AUGMENTED_INITRAMFS"
aug_sz=$(stat -c %s "$AUGMENTED_INITRAMFS")
log "  augmented initramfs: $AUGMENTED_INITRAMFS ($aug_sz bytes)"

if [ "$STAGE" = "initramfs" ]; then
  log "stage 5: STAGE=initramfs — stopping before ISO assembly"
  exit 0
fi

if ! command -v grub-mkrescue >/dev/null 2>&1; then
  log "warn: grub-mkrescue missing; skipping final ISO assembly"
  exit 0
fi

W4_ISO="$OUT_DIR/reproos-w4-wine.iso"
SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
  bash "$REPO_ROOT/recipes/reproos-iso/scripts/build-iso.sh" \
    "$R8_DIR/bzImage" \
    "$AUGMENTED_INITRAMFS" \
    "$W4_ISO" 2> "$OUT_DIR/build-iso.log" || \
  die "build-iso.sh failed (see $OUT_DIR/build-iso.log)" 5

iso_sz=$(stat -c %s "$W4_ISO")
iso_sha=$(sha256sum "$W4_ISO" | awk '{print $1}')
log "============================================================"
log "W4 ISO assembled: $W4_ISO"
log "  size:  $iso_sz bytes ($((iso_sz / 1024 / 1024)) MB)"
log "  sha256: $iso_sha"
log "============================================================"
