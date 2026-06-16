#!/usr/bin/env bash
# D4 P1: ReproOS Darling-augmented ISO build driver.
#
# Builds an ISO that boots into systemd + autologin root, with Darling
# + 3 pinned macOS tools (fzf 0.60.0 / jq 1.7.1 / ripgrep 14.1.1) staged
# under /opt/reproos-foreign/. The 3 shims at /usr/local/bin/darling-{fzf,
# jq,ripgrep} route through reprobuild-sandbox-launcher with D3 launcher
# manifests carrying runtime=darling.
#
# Parallel to build-mvp-wine-iso.sh (W4); a separate driver per the
# W4/D4 brief (purpose-built for D4, no Linux foreign packages — those
# merge in M1's tri-OS ISO).
#
# Layout produced inside the VM rootfs:
#
#   /opt/reproos-foreign/darling-binaries/    Darling binaries + libs
#     usr/bin/darling                          .deb-harvested closure
#     usr/libexec/darling/                     (~285 MB extracted)
#     usr/lib/x86_64-linux-gnu/darling/        from upstream Ubuntu
#     usr/share/darling/                       noble .debs.
#
#   /opt/reproos-foreign/dprefixes/           Per-tool DPREFIXes (D3
#     fzf/                                     risk #1 + #3 — separate
#     jq/                                      server sockets). EMPTY
#     ripgrep/                                 on ISO; populated on
#                                              first boot by the D4
#                                              fourth-fix oneshot.
#
#   /opt/reproos-foreign/macho-payloads/      Per-tool Mach-O payloads
#     fzf/Applications/repro-store/fzf/        (D4 fourth fix — split
#     jq/Applications/repro-store/jq/          from DPREFIX so bake-
#     ripgrep/Applications/repro-store/ripgrep/then-relocate isn't on
#                                              the runtime path).
#
#   /opt/reproos-foreign/darling-{fzf,jq,ripgrep}/   Per-tool launcher
#     launcher.manifest                              dirs (runtime=darling).
#
#   /usr/local/bin/reprobuild-sandbox-launcher    Launcher binary (C3)
#   /usr/local/bin/darling-fzf                    fzf shim
#   /usr/local/bin/darling-jq                     jq shim
#   /usr/local/bin/darling-ripgrep                ripgrep shim
#
#   /usr/lib/systemd/system/reproos-darling-fuse.service
#                                                 Boot-time oneshot:
#     modprobe fuse + mknod /dev/fuse if missing  (D3 risk #3 — stock
#                                                  Hyper-V images need
#                                                  this; ReproOS R8
#                                                  kernel currently has
#                                                  CONFIG_FUSE_FS unset
#                                                  — see DOCUMENTATION
#                                                  block below).
#
# Per the D4 brief (D3 reviewer's risks), this driver:
#   * Resolves .deb provenance from the SAME upstream
#     debs_<date>.zip used by D1 P2 (currently darling_0.1.20260609~noble).
#   * Plants Darling at the canonical
#     /opt/reproos-foreign/darling-binaries/usr/bin/darling
#     (the path baked into D3-emitted manifests; risk #2).
#   * Reuses D3's build-mvp-darling-prefix.sh to populate per-tool
#     DPREFIXes + shims.
#   * Sets `--darling-bin` to the ReproOS path (no dev-host override).
#
# DOCUMENTATION — D4 second-fix: bundled glibc + patchelf'd Darling.
#
#   The upstream Darling .debs target Ubuntu noble (glibc 2.39, GLIBC_2.38
#   symbol versions). ReproOS R9's bootstrapped glibc is older, so the
#   Darling binaries fail at exec with:
#     /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
#   We do NOT bump R9's pinned reproducibility chain. Instead, we bundle
#   noble's libc6 + libstdc++6 + libgcc-s1 + libc6-i386 .deb payloads
#   under /opt/reproos-foreign/darling-binaries/{lib,lib64} and patchelf
#   every Darling ELF to use the bundled dynamic loader + RUNPATH. This
#   matches the "many versions side-by-side in the repro store" principle:
#   Darling becomes self-contained and does not depend on R9's system libc.
#
# DOCUMENTATION — historical, D4 first fix:
#
#   The R8 kernel originally had CONFIG_FUSE_FS unset. The first fix
#   landed CONFIG_FUSE_FS=y (+ FUSE_DAX/CUSE/VIRTIO_FS) in
#   recipes/bootstrap/kernel/configs/{hyperv-extra.fragment,
#   x86_64-hyperv.config}. The reproos-darling-fuse oneshot below is now
#   a no-op when the kernel auto-creates /dev/fuse (ConditionPathExists
#   skip path); it is retained as a belt-and-braces fallback for any
#   future ReproOS variant that drops the kernel knob.
#
# Usage:
#
#   bash build-mvp-darling-iso.sh
#     [MVP_STAGE=overlay|initramfs|iso]
#     [D4_OUT_DIR=<path>]                  default: $REPO/build/d4-darling
#     [D4_DEBS_ZIP=<path>]                 default: /tmp/debs.zip
#     [D4_DEBS_DIR=<path>]                 default: /tmp/debs_20260609
#                                          (extracted if missing)
#     [D4_GLIBC_DEBS_DIR=<path>]           default: /tmp/d4-glibc-debs
#                                          (apt-get download'd if missing,
#                                          contains libc6 + libstdc++6 +
#                                          libgcc-s1 + libc6-i386 noble .debs)
#
# Flags:
#   --config-out <dir>     where to place the assembled overlay tree
#                          (default: $OUT_DIR/overlay).
#   --store-root <dir>     reprobuild content-addressed store root
#                          (default: $OUT_DIR/store).
#   --iso-out <path>       where to write the final ISO
#                          (default: $OUT_DIR/reproos-d4-darling.iso).
#   --catalog-root <dir>   macOS catalog root
#                          (default: $REPO/recipes/catalog/macos).
#   --glibc-debs-dir <dir> directory containing the 4 noble glibc-closure
#                          .debs (libc6, libstdc++6, libgcc-s1, libc6-i386).
#                          Same precedence as --debs-dir for Darling .debs.
#   --verbose              pass --verbose through to sub-scripts.
#   --dry-run              skip every step that mutates non-tmp state.
#
# Exit codes (mirror W4):
#   0   success (ISO built or overlay staged depending on STAGE)
#   1   preflight error / argument error
#   2   darling .deb harvest failure
#   3   darling-prefix-init failure
#   4   build-mvp-darling-prefix.sh failure
#   5   initramfs/ISO assembly failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="${D4_OUT_DIR:-$REPO_ROOT/build/d4-darling}"
STAGE="${MVP_STAGE:-iso}"

# Argument-overridable knobs (mirror W4's per-flag style as well as env vars).
ARG_CONFIG_OUT=""
ARG_STORE_ROOT=""
ARG_ISO_OUT=""
ARG_CATALOG_ROOT=""
ARG_GLIBC_DEBS_DIR=""
VERBOSE=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-out)        ARG_CONFIG_OUT="$2";        shift 2 ;;
    --config-out=*)      ARG_CONFIG_OUT="${1#--config-out=}"; shift ;;
    --store-root)        ARG_STORE_ROOT="$2";        shift 2 ;;
    --store-root=*)      ARG_STORE_ROOT="${1#--store-root=}"; shift ;;
    --iso-out)           ARG_ISO_OUT="$2";           shift 2 ;;
    --iso-out=*)         ARG_ISO_OUT="${1#--iso-out=}"; shift ;;
    --catalog-root)      ARG_CATALOG_ROOT="$2";      shift 2 ;;
    --catalog-root=*)    ARG_CATALOG_ROOT="${1#--catalog-root=}"; shift ;;
    --glibc-debs-dir)    ARG_GLIBC_DEBS_DIR="$2";    shift 2 ;;
    --glibc-debs-dir=*)  ARG_GLIBC_DEBS_DIR="${1#--glibc-debs-dir=}"; shift ;;
    --verbose)           VERBOSE=1;                  shift ;;
    --dry-run)           DRY_RUN=1;                  shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[d4][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

CONFIG_OUT="${ARG_CONFIG_OUT:-$OUT_DIR/overlay}"
STORE_ROOT="${ARG_STORE_ROOT:-$OUT_DIR/store}"
ISO_OUT="${ARG_ISO_OUT:-$OUT_DIR/reproos-d4-darling.iso}"
CATALOG_ROOT="${ARG_CATALOG_ROOT:-$REPO_ROOT/recipes/catalog/macos}"

DEBS_ZIP="${D4_DEBS_ZIP:-/tmp/debs.zip}"
DEBS_DIR="${D4_DEBS_DIR:-/tmp/debs_20260609}"
GLIBC_DEBS_DIR="${ARG_GLIBC_DEBS_DIR:-${D4_GLIBC_DEBS_DIR:-/tmp/d4-glibc-debs}}"

# Inside the VM, the Darling closure lands at this canonical path so the
# launcher's manifest darling_bin= resolves directly without env overrides.
VM_DARLING_ROOT="/opt/reproos-foreign/darling-binaries"
VM_DARLING_BIN="$VM_DARLING_ROOT/usr/bin/darling"
VM_DPREFIX_ROOT="/opt/reproos-foreign/dprefixes"
VM_LAUNCHER_PATH="/usr/local/bin/reprobuild-sandbox-launcher"

# Pinned upstream archive. Sha256s measured 2026-06-15 on repro-darling-test.
DARLING_DEBS_ZIP_SHA256="27469ef3932da2e91dd7fb34b70e3628a3e54b7af9fb5480051f44af35eca1fd"
DARLING_DEBS_ZIP_URL="https://github.com/darlinghq/darling/releases/download/v0.1.20260608/debs_20260608.zip"

# CLI subset (per docs/multi-os-macos-runtime.md:168-170).
CLI_DEBS=(
  "darling-core_0.1.20260609~noble_amd64.deb"
  "darling-system_0.1.20260609~noble_amd64.deb"
  "darling-cli_0.1.20260609~noble_amd64.deb"
  "darling-cli-gui-common_0.1.20260609~noble_amd64.deb"
  "darling-cli-python2-common_0.1.20260609~noble_amd64.deb"
)

# Pinned noble glibc-closure .debs (D4 second fix). The 4 packages cover
# every NEEDED lib of the 5 Darling ELFs:
#   libc.so.6 / ld-linux-x86-64.so.2  → libc6
#   libm.so.6 / libpthread.so.0 / librt.so.1 / ...  → libc6 (same payload)
#   libstdc++.so.6                   → libstdc++6
#   libgcc_s.so.1                    → libgcc-s1
#   ld-linux.so.2 + libc.so.6 (i386) → libc6-i386 (mldr32 only)
# Sha256 measured 2026-06-15 against archive.ubuntu.com noble-updates.
GLIBC_DEBS=(
  "libc6_2.39-0ubuntu8.7_amd64.deb"
  "libstdc++6_14.2.0-4ubuntu2~24.04.1_amd64.deb"
  "libgcc-s1_14.2.0-4ubuntu2~24.04.1_amd64.deb"
  "libc6-i386_2.39-0ubuntu8.7_amd64.deb"
)
declare -A GLIBC_DEB_SHA256=(
  ["libc6_2.39-0ubuntu8.7_amd64.deb"]="955644e8bc2930a9bf8eea5e4c2237c8a118c1e2ac2845b993b6f7f35eefd293"
  ["libstdc++6_14.2.0-4ubuntu2~24.04.1_amd64.deb"]="a51f8de7829211db961a31f02158058ad1a95f92ac6d0a5dff6350e2821c54c0"
  ["libgcc-s1_14.2.0-4ubuntu2~24.04.1_amd64.deb"]="aa7fadbe33b78bcf99885318040601c550c208929565b179891d9a3cc2aa68cd"
  ["libc6-i386_2.39-0ubuntu8.7_amd64.deb"]="a80dfe7331c74bda498aefcd49c20e531977736e287db224d53e9915bdd6d509"
)

# Runtime-target paths used by patchelf. The interpreter + RUNPATH point
# at the bundled closure INSIDE THE VM — NOT host build paths.
VM_DARLING_INTERP_X64="$VM_DARLING_ROOT/lib64/ld-linux-x86-64.so.2"
VM_DARLING_INTERP_I386="$VM_DARLING_ROOT/lib/ld-linux.so.2"
VM_DARLING_RPATH_X64="$VM_DARLING_ROOT/lib/x86_64-linux-gnu:$VM_DARLING_ROOT/lib64"
VM_DARLING_RPATH_I386="$VM_DARLING_ROOT/lib/i386-linux-gnu:$VM_DARLING_ROOT/lib"

log()  { echo "[d4] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[d4][verbose] $*" >&2 || true; }
die()  { echo "[d4][error] $*" >&2; exit "${2:-1}"; }

log "out dir:      $OUT_DIR"
log "stage:        $STAGE"
log "config-out:   $CONFIG_OUT"
log "store-root:   $STORE_ROOT"
log "iso-out:      $ISO_OUT"
log "catalog-root: $CATALOG_ROOT"
log "darling .debs zip:  $DEBS_ZIP"
log "darling .debs dir:  $DEBS_DIR"
log "glibc .debs dir:    $GLIBC_DEBS_DIR"
[ "$DRY_RUN" = 1 ] && log "dry-run: skipping all mutating steps"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *) die "non-Linux host: $(uname -s) — D4 build needs Linux/WSL" 1 ;;
esac

for tool in python3 unzip dpkg-deb sha256sum cpio gzip curl patchelf readelf file; do
  command -v "$tool" >/dev/null 2>&1 || die "preflight: '$tool' missing on PATH" 1
done

[ -d "$CATALOG_ROOT" ] || die "catalog root missing: $CATALOG_ROOT" 1

# ---------------------------------------------------------------------------
# Stage 0: locate/build the C3 launcher binary.
# ---------------------------------------------------------------------------

log "stage 0: locate/build C3 launcher"

LAUNCHER_BIN_SRC="$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher"
if [ ! -x "$LAUNCHER_BIN_SRC" ]; then
  log "building launcher via apps/reprobuild-sandbox-launcher/build.sh"
  if [ "$DRY_RUN" != 1 ]; then
    ( cd "$REPO_ROOT/apps/reprobuild-sandbox-launcher" && ./build.sh ) || \
      die "launcher build failed" 1
  fi
fi
if [ "$DRY_RUN" != 1 ]; then
  [ -x "$LAUNCHER_BIN_SRC" ] || die "launcher missing after build: $LAUNCHER_BIN_SRC" 1
fi
log "launcher: $LAUNCHER_BIN_SRC"

# ---------------------------------------------------------------------------
# Stage 1: harvest Darling .deb closure.
#
# The Darling project publishes Ubuntu noble .debs on every release as
# a single debs_<date>.zip from the GitHub release page (NOT in Debian
# or Ubuntu apt repos). See docs/multi-os-macos-runtime.md:161-219 for
# the rationale and the alternative-rejection log.
#
# Sources:
#   1. $DEBS_DIR pre-populated (preferred — D1 P2 / repro-darling-test).
#   2. $DEBS_ZIP pre-downloaded, extract on the fly.
#   3. Download fresh from $DARLING_DEBS_ZIP_URL (gated by online).
# ---------------------------------------------------------------------------

log "stage 1: harvest Darling .deb closure"

DARLING_HARVEST="$OUT_DIR/darling-harvest"
rm -rf "$DARLING_HARVEST"
mkdir -p "$DARLING_HARVEST"

if [ "$DRY_RUN" = 1 ]; then
  log "  dry-run: skipping .deb harvest + extract"
else
  if [ ! -d "$DEBS_DIR" ]; then
    if [ ! -f "$DEBS_ZIP" ]; then
      log "  $DEBS_ZIP missing; downloading from $DARLING_DEBS_ZIP_URL"
      curl -fsSL -o "$DEBS_ZIP.part" "$DARLING_DEBS_ZIP_URL" || \
        die "curl debs.zip failed" 2
      mv "$DEBS_ZIP.part" "$DEBS_ZIP"
    fi
    got_sha="$(sha256sum "$DEBS_ZIP" | awk '{print $1}')"
    if [ "$got_sha" != "$DARLING_DEBS_ZIP_SHA256" ]; then
      die "debs.zip sha256 mismatch (expected $DARLING_DEBS_ZIP_SHA256, got $got_sha)" 2
    fi
    log "  extracting $DEBS_ZIP -> $(dirname "$DEBS_DIR")"
    unzip -q -o "$DEBS_ZIP" -d "$(dirname "$DEBS_DIR")" || die "unzip debs.zip failed" 2
  fi

  for deb in "${CLI_DEBS[@]}"; do
    deb_path="$DEBS_DIR/$deb"
    [ -f "$deb_path" ] || die "  missing .deb: $deb_path" 2
    vlog "  dpkg-deb -x $deb -> $DARLING_HARVEST/"
    dpkg-deb -x "$deb_path" "$DARLING_HARVEST/" || die "dpkg-deb -x failed: $deb" 2
  done

  # Critical validation per D3 reviewer's risk #2: the path
  # /opt/reproos-foreign/darling-binaries/usr/bin/darling must contain
  # a real ELF binary post-extraction (baked into emitted manifests).
  harvested_darling="$DARLING_HARVEST/usr/bin/darling"
  if [ ! -f "$harvested_darling" ]; then
    die "harvested darling binary missing at $harvested_darling" 2
  fi
  if ! head -c4 "$harvested_darling" | od -An -tx1 2>/dev/null | grep -qE '7f 45 4c 46'; then
    log "WARN: $harvested_darling does not look like an ELF (first 4 bytes); proceeding anyway"
  fi
  if [ ! -d "$DARLING_HARVEST/usr/libexec/darling" ]; then
    die "harvested closure missing usr/libexec/darling/" 2
  fi

  harvest_size=$(du -sm "$DARLING_HARVEST" 2>/dev/null | awk '{print $1}')
  log "  Darling closure: $harvest_size MB at $DARLING_HARVEST"
fi

# ---------------------------------------------------------------------------
# Stage 1b: bundle noble glibc + libstdc++ + libgcc closure into the
# harvest tree (D4 second fix). Lands at:
#
#   $DARLING_HARVEST/lib64/ld-linux-x86-64.so.2          (x86_64 loader)
#   $DARLING_HARVEST/lib/x86_64-linux-gnu/*.so*          (x86_64 libs)
#   $DARLING_HARVEST/lib/ld-linux.so.2                   (i386 loader, mldr32)
#   $DARLING_HARVEST/lib/i386-linux-gnu/*.so*            (i386 libs, mldr32)
#
# Stage 2b's `cp -a $DARLING_HARVEST/.` carries these into the overlay at
# /opt/reproos-foreign/darling-binaries/{lib,lib64}/ unmodified.
#
# Sources (same precedence ladder as Stage 1):
#   1. $GLIBC_DEBS_DIR pre-populated.
#   2. Same dir + apt-get download (if apt is available + online).
# ---------------------------------------------------------------------------

log "stage 1b: bundle noble glibc closure"

if [ "$DRY_RUN" = 1 ]; then
  log "  dry-run: skipping glibc closure extract"
else
  if [ ! -d "$GLIBC_DEBS_DIR" ] || ! ls "$GLIBC_DEBS_DIR"/libc6_*.deb >/dev/null 2>&1; then
    log "  $GLIBC_DEBS_DIR missing or incomplete; fetching via apt-get download"
    mkdir -p "$GLIBC_DEBS_DIR"
    if ! command -v apt-get >/dev/null 2>&1; then
      die "  apt-get unavailable and $GLIBC_DEBS_DIR not pre-populated; \
pass --glibc-debs-dir <path>" 2
    fi
    ( cd "$GLIBC_DEBS_DIR" && apt-get download libc6 libstdc++6 libgcc-s1 libc6-i386 ) \
      || die "  apt-get download libc6+libstdc++6+libgcc-s1+libc6-i386 failed" 2
  fi

  # Verify each pinned .deb is present + sha256-correct.
  for deb in "${GLIBC_DEBS[@]}"; do
    deb_path="$GLIBC_DEBS_DIR/$deb"
    [ -f "$deb_path" ] || die "  missing glibc .deb: $deb_path" 2
    expected="${GLIBC_DEB_SHA256[$deb]}"
    got="$(sha256sum "$deb_path" | awk '{print $1}')"
    if [ "$got" != "$expected" ]; then
      die "  glibc .deb sha256 mismatch for $deb: expected $expected, got $got" 2
    fi
    vlog "  $deb: sha256 OK ($got)"
  done

  # Extract into a scratch dir (the noble .debs use usrmerge layout
  # `usr/lib*/...`; we copy the relevant subtrees into the harvest's
  # /lib + /lib64 conventional layout).
  GLIBC_STAGE="$OUT_DIR/glibc-stage"
  rm -rf "$GLIBC_STAGE"
  mkdir -p "$GLIBC_STAGE"
  for deb in "${GLIBC_DEBS[@]}"; do
    vlog "  dpkg-deb -x $deb -> $GLIBC_STAGE/"
    dpkg-deb -x "$GLIBC_DEBS_DIR/$deb" "$GLIBC_STAGE/" || \
      die "  dpkg-deb -x glibc-closure failed: $deb" 2
  done

  # x86_64 loader + libs.
  mkdir -p "$DARLING_HARVEST/lib64" "$DARLING_HARVEST/lib/x86_64-linux-gnu"
  cp -aL "$GLIBC_STAGE/usr/lib64/ld-linux-x86-64.so.2" \
         "$DARLING_HARVEST/lib64/ld-linux-x86-64.so.2"
  cp -aL "$GLIBC_STAGE/usr/lib/x86_64-linux-gnu/." \
         "$DARLING_HARVEST/lib/x86_64-linux-gnu/"

  # i386 loader + libs (mldr32 only).
  mkdir -p "$DARLING_HARVEST/lib/i386-linux-gnu"
  cp -aL "$GLIBC_STAGE/usr/lib32/ld-linux.so.2" \
         "$DARLING_HARVEST/lib/ld-linux.so.2"
  cp -aL "$GLIBC_STAGE/usr/lib32/." \
         "$DARLING_HARVEST/lib/i386-linux-gnu/"

  # Validate key files landed.
  for f in \
    "$DARLING_HARVEST/lib64/ld-linux-x86-64.so.2" \
    "$DARLING_HARVEST/lib/x86_64-linux-gnu/libc.so.6" \
    "$DARLING_HARVEST/lib/x86_64-linux-gnu/libm.so.6" \
    "$DARLING_HARVEST/lib/x86_64-linux-gnu/libstdc++.so.6" \
    "$DARLING_HARVEST/lib/x86_64-linux-gnu/libgcc_s.so.1" \
    "$DARLING_HARVEST/lib/ld-linux.so.2" \
    "$DARLING_HARVEST/lib/i386-linux-gnu/libc.so.6" ; do
    [ -e "$f" ] || die "  glibc closure missing: $f" 2
  done

  glibc_size=$(du -sm "$DARLING_HARVEST/lib" "$DARLING_HARVEST/lib64" 2>/dev/null \
               | awk '{s+=$1} END {print s}')
  log "  glibc closure: $glibc_size MB at $DARLING_HARVEST/{lib,lib64}"
fi

# ---------------------------------------------------------------------------
# Stage 1c: patchelf every Darling ELF to use the bundled loader + libs.
#
# Interpreter + RUNPATH are set to the runtime-target paths inside the
# VM (NOT the host build paths). After this step the harvested binaries
# are self-contained against any host glibc; they only resolve through
# /opt/reproos-foreign/darling-binaries/ when running inside ReproOS.
#
# 5 ELFs are patched (4 x86_64 + 1 i386 — the i386 mldr32 is included
# even though darling-cli-python2-common is the only path that exercises
# it, so we don't leave a stranded binary with the original interpreter).
# ---------------------------------------------------------------------------

log "stage 1c: patchelf Darling ELFs to use bundled loader + libs"

if [ "$DRY_RUN" = 1 ]; then
  log "  dry-run: skipping patchelf step"
else
  patched_count=0
  while IFS= read -r -d '' f; do
    info=$(file -L "$f" 2>/dev/null || true)
    case "$info" in
      *'ELF 64-bit'*'executable'*)
        if readelf -l "$f" 2>/dev/null | grep -q 'interpreter'; then
          patchelf --set-interpreter "$VM_DARLING_INTERP_X64" "$f"
          patchelf --set-rpath "$VM_DARLING_RPATH_X64" "$f"
          patched_count=$((patched_count + 1))
          vlog "  patched x86_64: ${f#$DARLING_HARVEST/}"
        fi
        ;;
      *'ELF 32-bit'*'executable'*)
        if readelf -l "$f" 2>/dev/null | grep -q 'interpreter'; then
          patchelf --set-interpreter "$VM_DARLING_INTERP_I386" "$f"
          patchelf --set-rpath "$VM_DARLING_RPATH_I386" "$f"
          patched_count=$((patched_count + 1))
          vlog "  patched i386:   ${f#$DARLING_HARVEST/}"
        fi
        ;;
    esac
  done < <(find "$DARLING_HARVEST/usr" -type f -executable -print0)

  [ "$patched_count" -ge 4 ] || die "  patchelf: expected >=4 ELFs patched, got $patched_count" 2
  log "  patchelf: $patched_count Darling ELFs patched"

  # Verification: the canonical entry binary must point at the bundled
  # loader + RUNPATH (assert literal strings; catches accidental host-
  # path leaks).
  darling_bin="$DARLING_HARVEST/usr/bin/darling"
  got_interp="$(readelf -l "$darling_bin" 2>/dev/null \
                | sed -n 's/.*Requesting program interpreter: \([^]]*\)\].*/\1/p')"
  if [ "$got_interp" != "$VM_DARLING_INTERP_X64" ]; then
    die "  verification: usr/bin/darling interpreter mismatch: got '$got_interp', expected '$VM_DARLING_INTERP_X64'" 2
  fi
  got_runpath="$(readelf -d "$darling_bin" 2>/dev/null \
                 | sed -n 's/.*RUNPATH.*\[\(.*\)\].*/\1/p')"
  if [ "$got_runpath" != "$VM_DARLING_RPATH_X64" ]; then
    die "  verification: usr/bin/darling RUNPATH mismatch: got '$got_runpath', expected '$VM_DARLING_RPATH_X64'" 2
  fi
  log "  verification: usr/bin/darling interpreter + RUNPATH match VM paths"
fi

# ---------------------------------------------------------------------------
# Stage 2: assemble the overlay skeleton.
# ---------------------------------------------------------------------------

log "stage 2: assemble overlay skeleton"

OVERLAY="$CONFIG_OUT"
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/usr/local/bin" \
         "$OVERLAY/usr/lib/systemd/system" \
         "$OVERLAY/usr/lib/systemd/system/multi-user.target.wants" \
         "$OVERLAY/opt/reproos-foreign"

# Stage 2a: copy the launcher.
if [ "$DRY_RUN" != 1 ]; then
  cp "$LAUNCHER_BIN_SRC" "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher"
  chmod +x "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher"
fi

# Stage 2b: plant the Darling closure under /opt/reproos-foreign/darling-binaries/.
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$OVERLAY/opt/reproos-foreign/darling-binaries"
  cp -a "$DARLING_HARVEST/." "$OVERLAY/opt/reproos-foreign/darling-binaries/"

  # Sanity: post-copy the canonical VM path must exist.
  planted_darling="$OVERLAY$VM_DARLING_BIN"
  [ -f "$planted_darling" ] || die "  planted Darling missing: $planted_darling" 2
  [ -x "$planted_darling" ] || die "  planted Darling not executable: $planted_darling" 2
  vlog "  Darling planted at $planted_darling"
fi

# Stage 2b': FHS path aliases for Darling.
#
# D4 third fix: the upstream `darling` binary execv's "/usr/bin/darlingserver"
# verbatim — the path is baked at build-time as INSTALL_PREFIX/bin (Ubuntu
# noble's .deb installs there). Our overlay relocates everything under
# /opt/reproos-foreign/darling-binaries/, so the bare exec fails with
# ENOENT and `darling` reports:
#     Failed to start darlingserver
#     Cannot open mnt namespace file: No such file or directory
# (the second line is a follow-on — the parent darling tries to enter the
# dead child's /proc/<pid>/ns/mnt). We add symlinks so the canonical FHS
# paths resolve into our relocated tree. Only /usr/bin/darlingserver is
# strictly required for the spawn; the rest are belt-and-braces in case
# future versions of Darling look for sibling tools at the same prefix.
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/libexec" "$OVERLAY/sbin"
  ln -sf /opt/reproos-foreign/darling-binaries/usr/bin/darling \
         "$OVERLAY/usr/bin/darling"
  ln -sf /opt/reproos-foreign/darling-binaries/usr/bin/darlingserver \
         "$OVERLAY/usr/bin/darlingserver"
  ln -sf /opt/reproos-foreign/darling-binaries/usr/libexec/darling \
         "$OVERLAY/usr/libexec/darling"
  ln -sf /opt/reproos-foreign/darling-binaries/sbin/launchd \
         "$OVERLAY/sbin/launchd"
  vlog "  FHS Darling symlinks planted (/usr/bin/darlingserver -> /opt/...)"
fi

# Stage 2c: drop the reproos-darling-fuse systemd oneshot (per D3 risk #3).
#
# Stock Hyper-V Linux images may need explicit `modprobe fuse` + `mknod
# /dev/fuse c 10 229` before the launcher's mount-NS gets /dev/fuse.
# This oneshot runs once at boot, BEFORE getty.target, so the per-tool
# shims at /usr/local/bin/darling-* find /dev/fuse available.
#
# When CONFIG_FUSE_FS is unset (current R8 default), modprobe fails
# silently and `mknod` will succeed only as a no-op on a kernel without
# the fuse char device — Darling will still error. This is the M1
# blocker documented in the header.
cat > "$OVERLAY/usr/lib/systemd/system/reproos-darling-fuse.service" <<'EOF'
[Unit]
Description=Provision /dev/fuse for Darling (D4)
DefaultDependencies=no
After=systemd-tmpfiles-setup-dev.service
Before=multi-user.target getty.target
ConditionPathExists=!/dev/fuse

[Service]
Type=oneshot
RemainAfterExit=yes
# Try to load the fuse module; ignore failure (R8 may have it built-in
# or absent entirely — see the M1 hand-off note).
ExecStart=-/sbin/modprobe fuse
# If /dev/fuse still missing, create the char device manually
# (major 10 / minor 229 are the FUSE-pinned values per the Linux kernel
# Documentation/admin-guide/devices.txt).
ExecStart=/bin/sh -c 'if [ ! -c /dev/fuse ]; then mknod /dev/fuse c 10 229 && chmod 666 /dev/fuse; fi'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ln -sf "/usr/lib/systemd/system/reproos-darling-fuse.service" \
   "$OVERLAY/usr/lib/systemd/system/multi-user.target.wants/reproos-darling-fuse.service"
vlog "  reproos-darling-fuse.service planted"

# ---------------------------------------------------------------------------
# Stage 3: invoke D3's build-mvp-darling-prefix.sh to materialise
# per-tool DPREFIXes + shims for fzf/jq/ripgrep.
#
# We pass the ReproOS default darling_bin (no override) so the emitted
# manifests bake the VM-target path. We use --init-darling-bin to point
# the host Darling at the standard /usr/bin/darling for DPREFIX cold-
# init (this is host-side only).
# ---------------------------------------------------------------------------

log "stage 3: materialise per-tool DPREFIXes via D3 build-mvp-darling-prefix.sh"

# Resolve host darling for DPREFIX init.
INIT_DARLING_BIN="${D4_INIT_DARLING_BIN:-}"
if [ -z "$INIT_DARLING_BIN" ]; then
  if command -v darling >/dev/null 2>&1; then
    INIT_DARLING_BIN="$(command -v darling)"
  fi
fi

D3_BUILD_SH="$SCRIPT_DIR/build-mvp-darling-prefix.sh"
[ -x "$D3_BUILD_SH" ] || [ -f "$D3_BUILD_SH" ] || \
  die "  build-mvp-darling-prefix.sh missing at $D3_BUILD_SH" 1

# Darling's overlayfs + chown setup of the DPREFIX is REJECTED on
# Windows DrvFs mounts (i.e. /mnt/d/...). It must run on a native
# Linux filesystem. We materialise into a /tmp scratch dir and copy
# the result into the Windows-backed overlay afterwards.
D3_OVERLAY_TMP="$OUT_DIR/d3-overlay"
case "$OUT_DIR" in
  /mnt/*|/cygdrive/*)
    D3_STORE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/d4-d3store.XXXXXX")"
    log "  redirecting D3 store-root to native-FS path (DrvFs incompat): $D3_STORE_TMP"
    ;;
  *)
    D3_STORE_TMP="$STORE_ROOT/d3"
    ;;
esac

# Cleanup hook in case we created a tmp store.
case "$D3_STORE_TMP" in
  /tmp/d4-d3store.*) trap 'rm -rf "$D3_STORE_TMP"' EXIT ;;
esac

if [ "$DRY_RUN" = 1 ]; then
  log "  dry-run: skipping D3 sub-script invocation"
else
  rm -rf "$D3_OVERLAY_TMP" "$D3_STORE_TMP"
  mkdir -p "$D3_OVERLAY_TMP" "$D3_STORE_TMP"

  if [ -z "$INIT_DARLING_BIN" ]; then
    die "  host darling not on PATH (set D4_INIT_DARLING_BIN to point at it)" 3
  fi

  d3_args=(
    --catalog-dir "$CATALOG_ROOT"
    --store-root  "$D3_STORE_TMP"
    --overlay     "$D3_OVERLAY_TMP"
    --launcher-bin "$VM_LAUNCHER_PATH"
    --darling-bin "$VM_DARLING_BIN"
    --init-darling-bin "$INIT_DARLING_BIN"
    --allow-online
  )
  [ "$VERBOSE" = 1 ] && d3_args+=(--verbose)

  vlog "  invoking: bash $D3_BUILD_SH ${d3_args[*]}"
  bash "$D3_BUILD_SH" "${d3_args[@]}" 2> "$OUT_DIR/build-mvp-darling-prefix.log" || \
    die "build-mvp-darling-prefix.sh failed (see $OUT_DIR/build-mvp-darling-prefix.log)" 4

  # Sanity: shims must be in D3_OVERLAY_TMP/usr/local/bin/.
  for n in fzf jq ripgrep; do
    [ -f "$D3_OVERLAY_TMP/usr/local/bin/darling-$n" ] || \
      die "  expected shim missing post-D3: darling-$n" 4
    [ -f "$D3_STORE_TMP/prefixes-mac/$n/launcher.manifest" ] || \
      die "  expected manifest missing post-D3: $n/launcher.manifest" 4
  done
  log "  3 DPREFIXes + 3 shims + 3 manifests emitted by D3"
fi

# ---------------------------------------------------------------------------
# Stage 4: rewrite paths + assemble final overlay.
#
# D3 emits manifests with darling_prefix=$D3_STORE_TMP/dprefixes/<n>
# (build-host absolute path); rewrite to /opt/reproos-foreign/dprefixes/<n>.
# Shims reference --manifest=$D3_STORE_TMP/prefixes-mac/<n>/launcher.manifest;
# rewrite to /opt/reproos-foreign/darling-<n>/launcher.manifest.
# ---------------------------------------------------------------------------

log "stage 4: rewrite paths + finalise overlay"

if [ "$DRY_RUN" = 1 ]; then
  log "  dry-run: skipping final overlay assembly"
else
  sed_escape() {
    printf '%s' "$1" | sed -e 's/[&\\/|]/\\&/g'
  }

  for n in fzf jq ripgrep; do
    src_dprefix="$D3_STORE_TMP/dprefixes/$n"
    vm_dprefix="$VM_DPREFIX_ROOT/$n"
    [ -d "$src_dprefix" ] || die "  $n: DPREFIX missing post-D3: $src_dprefix" 4

    # Stage 4a: plant DPREFIX content under /opt/reproos-foreign/dprefixes/<n>/.
    # Use tar instead of cp -a because DrvFs (Windows-backed mount)
    # rejects Unix-domain socket creation. Darlingserver re-creates
    # the sockets on first invocation inside the VM anyway, so we skip
    # them on host-side copy. The exclude list also drops PID files +
    # the sentinel .init.pid that darling-shell leaves behind.
    mkdir -p "$OVERLAY$VM_DPREFIX_ROOT/$n"
    ( cd "$src_dprefix" && \
      tar --exclude='.darlingserver.sock' \
          --exclude='var/run/*.sock' \
          --exclude='var/run/*.pid' \
          --exclude='var/tmp/launchd/sock' \
          --exclude='.init.pid' \
          -cf - . ) | \
      ( cd "$OVERLAY$VM_DPREFIX_ROOT/$n" && tar -xf - ) || \
      die "  $n: tar-pipe DPREFIX copy failed" 4
    vlog "  $n: DPREFIX planted at $OVERLAY$vm_dprefix"

    # Stage 4b: place the per-tool manifest dir at /opt/reproos-foreign/darling-<n>/.
    tooldir="$OVERLAY/opt/reproos-foreign/darling-$n"
    mkdir -p "$tooldir"
    cp "$D3_STORE_TMP/prefixes-mac/$n/launcher.manifest" "$tooldir/launcher.manifest"

    # Stage 4c: rewrite the manifest's darling_prefix=<build-host>
    # to the VM path. Defence-in-depth: do NOT introduce an identity
    # rbind line for the new path (D2 reviewer's risk #1).
    SDP_ESC=$(sed_escape "$src_dprefix")
    VDP_ESC=$(sed_escape "$vm_dprefix")
    sed -i -e "s|${SDP_ESC}|${VDP_ESC}|g" "$tooldir/launcher.manifest"
    # Strip residual build-host catalog paths in comments.
    sed -i -e "s|# Source catalog: $REPO_ROOT/|# Source catalog: |g" "$tooldir/launcher.manifest"
    sed -i -e "s|# Source catalog: /mnt/d/metacraft/reprobuild/|# Source catalog: |g" "$tooldir/launcher.manifest"

    # Validate: no residual build-host paths in non-comment lines.
    if grep -vE '^[[:space:]]*#' "$tooldir/launcher.manifest" | grep -qE "(D:/|/mnt/d/|$D3_STORE_TMP)" 2>/dev/null; then
      log "  WARN: residual build-host path in $tooldir/launcher.manifest:"
      grep -vE '^[[:space:]]*#' "$tooldir/launcher.manifest" | grep -E "(D:/|/mnt/d/)" | head -3 | sed 's/^/    /' >&2
    fi

    # Defence-in-depth: scan for identity rbind on darling_prefix.
    if grep -E "^${vm_dprefix//\//\\/}:${vm_dprefix//\//\\/}:r?bind" "$tooldir/launcher.manifest" >/dev/null 2>&1; then
      die "  $n: emitted manifest contains identity rbind on darling_prefix" 4
    fi

    # Assert baseline directives.
    grep -qE "^runtime=darling\$" "$tooldir/launcher.manifest" || die "  $n: missing runtime=darling" 4
    grep -qE "^darling_prefix=$vm_dprefix\$" "$tooldir/launcher.manifest" || die "  $n: darling_prefix mismatch" 4
    grep -qE "^darling_bin=$VM_DARLING_BIN\$" "$tooldir/launcher.manifest" || die "  $n: darling_bin mismatch" 4
    grep -qE "^/dev/fuse:/dev/fuse:rbind\$" "$tooldir/launcher.manifest" || die "  $n: /dev/fuse rbind missing" 4

    # Stage 4d: copy + rewrite the shim. The D3 shim references the
    # build-host manifest path; remap to the VM path.
    shim_src="$D3_OVERLAY_TMP/usr/local/bin/darling-$n"
    shim_dst="$OVERLAY/usr/local/bin/darling-$n"
    cp "$shim_src" "$shim_dst"
    HMP_ESC=$(sed_escape "$D3_STORE_TMP/prefixes-mac/$n/launcher.manifest")
    VMP_ESC=$(sed_escape "/opt/reproos-foreign/darling-$n/launcher.manifest")
    sed -i -e "s|${HMP_ESC}|${VMP_ESC}|g" "$shim_dst"
    chmod +x "$shim_dst"

    if grep -vE '^[[:space:]]*#' "$shim_dst" | grep -qE "(D:/|/mnt/d/|$D3_STORE_TMP)" 2>/dev/null; then
      log "  WARN: residual build-host path in shim $shim_dst:"
      grep -vE '^[[:space:]]*#' "$shim_dst" | grep -E "(D:/|/mnt/d/)" | head -3 | sed 's/^/    /' >&2
    fi
    vlog "  $n: shim rewritten to use VM manifest path"
  done
fi

# ---------------------------------------------------------------------------
# Stage 4d': split Mach-O payloads from the DPREFIX (D4 fourth fix).
#
# The bake-then-relocate model leaves the DPREFIX in a "previously
# initialised" state but stripped of its runtime-only Unix sockets
# (shellspawn.sock + .darlingserver.sock + var/run/launchd/sock). When
# Darling is invoked at runtime it sees the populated prefix, skips its
# cold-init path, then hangs forever waiting for shellspawn.sock.
#
# Fix: move each tool's Mach-O payload out of the DPREFIX into a
# separate per-tool tree under /opt/reproos-foreign/macho-payloads/<n>/
# (mirroring the in-prefix Applications/repro-store/<n>/bin/<exe>
# layout), then wipe the DPREFIX so the first-boot oneshot
# (reproos-darling-prefix-coldinit.service) can do a true cold-init and
# copy the payload back into place.
#
# The launcher manifests (Stage 4c) still bake the in-DPREFIX path
# /opt/reproos-foreign/dprefixes/<n>/Applications/repro-store/<n>/bin/<exe>
# — that's the canonical runtime path AFTER the oneshot runs. Banner-
# check assertions fire after multi-user.target which depends on the
# oneshot, so the manifest path is valid when the launcher is invoked.
# ---------------------------------------------------------------------------

log "stage 4d': split payloads + wipe DPREFIXes (D4 fourth fix)"

if [ "$DRY_RUN" != 1 ]; then
  for n in fzf jq ripgrep; do
    src_dprefix="$OVERLAY$VM_DPREFIX_ROOT/$n"
    payload_dest="$OVERLAY/opt/reproos-foreign/macho-payloads/$n"

    [ -d "$src_dprefix/Applications/repro-store" ] || \
      die "  $n: DPREFIX Applications/repro-store/ missing pre-split: $src_dprefix" 4

    # Stage the Mach-O outside the DPREFIX. Preserve the full
    # Applications/repro-store/<...>/bin/<...> path structure so the
    # first-boot oneshot can `cp -a Applications/.` into the freshly
    # cold-inited DPREFIX without further path munging.
    mkdir -p "$payload_dest/Applications"
    cp -a "$src_dprefix/Applications/." "$payload_dest/Applications/"

    # Sanity: at least one Mach-O binary must have landed.
    if ! find "$payload_dest/Applications/repro-store" -type f 2>/dev/null | grep -q .; then
      die "  $n: no Mach-O files copied into $payload_dest" 4
    fi
    vlog "  $n: payload staged at $payload_dest"

    # Wipe the DPREFIX so darling-prefix-init.sh's "empty or absent"
    # detector fires on first boot. We leave the empty parent dir so
    # the systemd oneshot doesn't have to mkdir + chmod the tree root.
    rm -rf "$src_dprefix"
    vlog "  $n: DPREFIX wiped"
  done

  # Validation: payloads tree must hold all 3 tools, dprefixes must be
  # empty post-split.
  for n in fzf jq ripgrep; do
    [ -d "$OVERLAY/opt/reproos-foreign/macho-payloads/$n/Applications" ] || \
      die "  payload-tree missing: macho-payloads/$n/Applications" 4
    [ -e "$OVERLAY$VM_DPREFIX_ROOT/$n" ] && \
      die "  DPREFIX not wiped: $OVERLAY$VM_DPREFIX_ROOT/$n" 4
  done
  log "  payloads split + DPREFIXes wiped for 3 tools"
fi

# ---------------------------------------------------------------------------
# Stage 4d'': plant the first-boot DPREFIX cold-init oneshot.
#
# Three artefacts land on the rootfs:
#   /etc/systemd/system/reproos-darling-prefix-coldinit.service
#   /usr/local/sbin/reproos-darling-prefix-coldinit.sh
#   /usr/local/sbin/darling-prefix-init.sh
#
# The oneshot's WantedBy=multi-user.target requires a symlink under
# multi-user.target.wants/. We also need a `local-fs.target.wants/`
# style ordering — handled by After= + Before= directives in the unit
# file rather than wants symlinks.
# ---------------------------------------------------------------------------

log "stage 4d'': plant reproos-darling-prefix-coldinit oneshot + busybox userland"

if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$OVERLAY/etc/systemd/system" \
           "$OVERLAY/etc/systemd/system/multi-user.target.wants" \
           "$OVERLAY/usr/local/sbin"

  cp "$SCRIPT_DIR/systemd/reproos-darling-prefix-coldinit.service" \
     "$OVERLAY/etc/systemd/system/reproos-darling-prefix-coldinit.service"
  # systemd warns ("Proceeding anyway") if a unit file is world-writable
  # or executable; the host build sits on DrvFs which returns 0755 for
  # every file by default. Reset to 0644 to silence the warning.
  chmod 0644 "$OVERLAY/etc/systemd/system/reproos-darling-prefix-coldinit.service"

  cp "$SCRIPT_DIR/scripts/reproos-darling-prefix-coldinit.sh" \
     "$OVERLAY/usr/local/sbin/reproos-darling-prefix-coldinit.sh"
  chmod 0755 "$OVERLAY/usr/local/sbin/reproos-darling-prefix-coldinit.sh"

  cp "$SCRIPT_DIR/darling-prefix-init.sh" \
     "$OVERLAY/usr/local/sbin/darling-prefix-init.sh"
  chmod 0755 "$OVERLAY/usr/local/sbin/darling-prefix-init.sh"

  # R9 ships /bin/bash as a busybox-1.30.1 symlink but busybox doesn't
  # include the bash applet in this build — invoking the script as
  # `bash` errors "applet not found" and the systemd oneshot exits 127.
  # Rewrite both shebangs to `#!/bin/sh` (busybox ash). Both scripts
  # are POSIX-clean (audited 2026-06-15): no `[[`, no arrays, no
  # process substitution; `local`, `set -o pipefail` (busybox ash
  # only; dash chokes), and POSIX arithmetic `$((...))` are all OK.
  #
  # We also strip `set -o pipefail` -> `set -e` because the script may
  # be re-invoked from contexts where /bin/sh isn't busybox ash. Drop
  # `pipefail` for portability; we don't depend on it (the hot paths
  # use direct `|| exit` checks).
  #
  # busybox-1.30.1's mktemp requires TEMPLATE to END with XXXXXX (no
  # suffix allowed); GNU mktemp tolerates suffixes. Rewrite the two
  # `mktemp -t darling-{init,smoke}.XXXXXX.log` calls to drop the
  # `.log` suffix on the on-ISO copy of darling-prefix-init.sh.
  sed -i -e '1s|^#![[:space:]]*/usr/bin/env[[:space:]]\+bash[[:space:]]*$|#!/bin/sh|' \
         -e '1s|^#![[:space:]]*/bin/bash[[:space:]]*$|#!/bin/sh|' \
         -e 's|^set -euo pipefail$|set -eu|' \
         -e 's|mktemp -t darling-init\.XXXXXX\.log|mktemp -t darling-initXXXXXX|g' \
         -e 's|mktemp -t darling-smoke\.XXXXXX\.log|mktemp -t darling-smokeXXXXXX|g' \
         "$OVERLAY/usr/local/sbin/darling-prefix-init.sh" \
         "$OVERLAY/usr/local/sbin/reproos-darling-prefix-coldinit.sh"
  vlog "  shebangs rewritten to #!/bin/sh + pipefail stripped + mktemp templates fixed"

  ln -sf "../reproos-darling-prefix-coldinit.service" \
         "$OVERLAY/etc/systemd/system/multi-user.target.wants/reproos-darling-prefix-coldinit.service"

  vlog "  systemd oneshot + scripts planted"

  # D4 P4 (fourth fix, second sub-fix): R9 ships busybox at /usr/bin/
  # busybox but doesn't expose its applet symlinks. The coldinit
  # oneshot + darling-prefix-init.sh need a small set of standard
  # Unix utilities (find, mknod, modprobe, touch, dirname, sed,
  # grep, awk, mktemp, date, du, file, sort, head, tr) that aren't
  # in R9's static binary set. Symlink each needed applet to
  # /usr/bin/busybox so coldinit's shebang-driven utility lookups
  # resolve. The kernel built FUSE in (D4 first fix), so modprobe
  # is only a defence-in-depth no-op; we link it anyway so other
  # services that probe `/sbin/modprobe` find it.
  BUSYBOX_APPLETS=(
    find mknod modprobe touch dirname basename
    sed grep awk mktemp date du file
    sort head tail tr wc readlink stat
    test true false sleep pwd uname
    # D4 fifth-fix: `mount --make-rslave /` in the coldinit script.
    # `mount` is already in R9 base (busybox applet), but we re-link
    # it here in case future R9 variants drop it. `unshare` is needed
    # if we ever need to do unshare(CLONE_NEWNS) manually from script.
    mount unshare
  )
  mkdir -p "$OVERLAY/sbin"
  for applet in "${BUSYBOX_APPLETS[@]}"; do
    # Always overwrite (-sf) so re-building a partial overlay doesn't
    # leave stale symlinks pointing at an old busybox path.
    if [ ! -e "$OVERLAY/usr/bin/$applet" ]; then
      ln -sf busybox "$OVERLAY/usr/bin/$applet"
    fi
  done
  # systemd's modprobe.service references /sbin/modprobe specifically.
  ln -sf /usr/bin/busybox "$OVERLAY/sbin/modprobe"
  vlog "  busybox applet symlinks planted (/usr/bin/{${BUSYBOX_APPLETS[*]// /,}} + /sbin/modprobe)"

  # D4 fifth-fix: plant a stub `xdg-user-dir` so darlingserver's setup
  # of the macOS Users/<name>/{Desktop,Documents,Downloads,Movies,Music,
  # Pictures,Public} directories doesn't fail 7 times. Darling shells out
  # to `xdg-user-dir KIND` to determine where on the host the user's
  # corresponding directory is, then mkdir + chown the macOS-named
  # equivalent inside the DPREFIX. R9's minimal rootfs doesn't ship
  # xdg-user-dirs (a Debian/Ubuntu-only package); the stub prints
  # $HOME for any KIND so darling defaults the symlink targets back to
  # the user's home. Effectively a no-op for the headless container.
  cat > "$OVERLAY/usr/bin/xdg-user-dir" <<'EOF'
#!/bin/sh
# D4 fifth-fix stub for Darling cold-init.
# Real xdg-user-dir queries ~/.config/user-dirs.dirs; on a headless
# minimal rootfs that file doesn't exist, so fall back to $HOME for
# every KIND. Darling then symlinks $DPREFIX/Users/<user>/<MacName>
# to $HOME, which is correct enough for a CLI-only container.
echo "${HOME:-/root}"
EOF
  chmod 0755 "$OVERLAY/usr/bin/xdg-user-dir"
  vlog "  xdg-user-dir stub planted at /usr/bin/xdg-user-dir"
fi

# Stage 4e: README for the overlay.
if [ "$DRY_RUN" != 1 ]; then
  cat > "$OVERLAY/opt/reproos-foreign/README" <<EOF
ReproOS D4 (macOS-via-Darling) overlay.

Generated by recipes/reproos-mvp-config/build-mvp-darling-iso.sh from D3
catalogs (recipes/catalog/macos/{fzf,jq,ripgrep}.json).

Layout:

  darling-binaries/      Darling .deb-harvested closure
                         (~$harvest_size MB if measured; canonical
                         path /opt/reproos-foreign/darling-binaries/
                         usr/bin/darling).
  dprefixes/<name>/      Per-tool DPREFIX (D3 risk #1+#3 separation).
                         EMPTY on the ISO; populated on first boot by
                         reproos-darling-prefix-coldinit.service (D4
                         fourth fix — bake-then-relocate is broken).
                         After first boot:
                         Applications/repro-store/<name>/bin/<exe>
                         holds the macOS Mach-O.
  macho-payloads/<name>/ Per-tool Mach-O payload (D4 fourth fix).
                         Applications/repro-store/<name>/bin/<exe>
                         is the source the first-boot oneshot copies
                         into the freshly cold-inited DPREFIX.
  darling-<name>/        One per macOS package; carries
                         launcher.manifest (runtime=darling).

PATH shims:
  /usr/local/bin/darling-fzf      fzf 0.60.0     (fuzzy finder)
  /usr/local/bin/darling-jq       jq 1.7.1       (JSON processor)
  /usr/local/bin/darling-ripgrep  ripgrep 14.1.1 (rg)

Each shim invokes:
  /usr/local/bin/reprobuild-sandbox-launcher --manifest=<...> -- \$@

The launcher (C3 native binary, runtime=darling path from D2) sets
DPREFIX, exec()s $VM_DARLING_BIN with shell <darling_exec> as
argv[1..2], forwarding "\$@".

Darling-binaries refresh:
  Source upstream from $DARLING_DEBS_ZIP_URL
  Pinned sha256: $DARLING_DEBS_ZIP_SHA256
  Selected CLI subset (5 of 21 .debs):
    darling-core, darling-system, darling-cli,
    darling-cli-gui-common, darling-cli-python2-common
  Extract via dpkg-deb -x; place under
    /opt/reproos-foreign/darling-binaries/
  See docs/multi-os-macos-runtime.md:161-219 for provisioning rationale.

Bundled glibc closure (D4 second fix):
  Source upstream from Ubuntu noble-updates archive (.debs):
    libc6 2.39-0ubuntu8.7
    libstdc++6 14.2.0-4ubuntu2~24.04.1
    libgcc-s1 14.2.0-4ubuntu2~24.04.1
    libc6-i386 2.39-0ubuntu8.7
  Landed at:
    /opt/reproos-foreign/darling-binaries/lib64/ld-linux-x86-64.so.2
    /opt/reproos-foreign/darling-binaries/lib/x86_64-linux-gnu/*.so*
    /opt/reproos-foreign/darling-binaries/lib/ld-linux.so.2
    /opt/reproos-foreign/darling-binaries/lib/i386-linux-gnu/*.so*
  All Darling ELFs are patchelf'd at build time to point INTERP +
  RUNPATH at the bundled closure, so they are independent of the
  host R9 glibc.
EOF
fi

# Stage 4f: size accounting.
if [ "$DRY_RUN" != 1 ]; then
  log "stage 4f: overlay size accounting"
  {
    echo "=== D4 overlay size accounting ==="
    echo
    du -shm "$OVERLAY/opt/reproos-foreign/darling-binaries/" 2>/dev/null || true
    du -shm "$OVERLAY/opt/reproos-foreign/darling-binaries/lib/" 2>/dev/null || true
    du -shm "$OVERLAY/opt/reproos-foreign/darling-binaries/lib64/" 2>/dev/null || true
    du -shm "$OVERLAY/opt/reproos-foreign/dprefixes/" 2>/dev/null || true
    du -shm "$OVERLAY/opt/reproos-foreign/macho-payloads/" 2>/dev/null || true
    for n in fzf jq ripgrep; do
      du -shm "$OVERLAY/opt/reproos-foreign/dprefixes/$n/" 2>/dev/null || true
      du -shm "$OVERLAY/opt/reproos-foreign/macho-payloads/$n/" 2>/dev/null || true
      du -shm "$OVERLAY/opt/reproos-foreign/darling-$n/" 2>/dev/null || true
    done
    echo
    echo "=== TOTAL ==="
    du -shm "$OVERLAY" 2>/dev/null || true
  } > "$OUT_DIR/SIZE-ACCOUNTING.txt"
  cat "$OUT_DIR/SIZE-ACCOUNTING.txt" >&2
fi

log "overlay staged at $OVERLAY"

# ---------------------------------------------------------------------------
# Stage 5: initramfs + ISO assembly (gated on STAGE).
# ---------------------------------------------------------------------------

if [ "$STAGE" != "iso" ] && [ "$STAGE" != "initramfs" ]; then
  log "stage 5: skipping initramfs+ISO assembly (STAGE=$STAGE)"
  log "  rerun with MVP_STAGE=iso to assemble"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "stage 5: dry-run; skipping initramfs+ISO"
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

AUGMENTED_INITRAMFS="$OUT_DIR/initramfs-d4-darling.cpio.gz"
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

SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
  bash "$REPO_ROOT/recipes/reproos-iso/scripts/build-iso.sh" \
    "$R8_DIR/bzImage" \
    "$AUGMENTED_INITRAMFS" \
    "$ISO_OUT" 2> "$OUT_DIR/build-iso.log" || \
  die "build-iso.sh failed (see $OUT_DIR/build-iso.log)" 5

iso_sz=$(stat -c %s "$ISO_OUT")
iso_sha=$(sha256sum "$ISO_OUT" | awk '{print $1}')
log "============================================================"
log "D4 ISO assembled: $ISO_OUT"
log "  size:  $iso_sz bytes ($((iso_sz / 1024 / 1024)) MB)"
log "  sha256: $iso_sha"
log "============================================================"
