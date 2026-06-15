#!/usr/bin/env bash
# W1 P2: WINEPREFIX initialiser for the ReproOS-Multi-OS-Catalog-PoC
# campaign.
#
# Creates a fresh WINEPREFIX in a Linux environment per the architecture
# decided in docs/multi-os-windows-runtime.md (W1 P1):
#
#   * Single shared WINEPREFIX (~150 MB initialized).
#   * drive_c/repro-store/ subtree pre-created (W3 will populate it
#     with per-package payloads).
#   * GUI dialog nags suppressed (mscoree / mshtml / mountmgr).
#   * Headless-safe (no X11 / Xvfb required for the boot-skeleton init
#     of the PoC tools' WINE binaries).
#
# The script is consumed at ISO build time (per W1's bake-at-build-time
# decision) AND from the verification gate in CI / sub-agent runs.
#
# Usage
# -----
#
#   wine-prefix-init.sh --prefix-dir <path>
#                       [--wine-bin <path>]
#                       [--store-subdir <name>]
#                       [--verbose]
#                       [--dry-run]
#
# Defaults:
#   --prefix-dir         REQUIRED
#   --wine-bin           wine (resolved via PATH)
#   --store-subdir       repro-store
#   --verbose            off
#   --dry-run            off
#
# Exit codes:
#   0    WINEPREFIX initialised successfully (gate PASS).
#   1    argument / preflight error.
#   2    wine not found on PATH (or --wine-bin not executable).
#   3    wineboot -i failed.
#   4    post-init verification failed (drive_c missing, etc.).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PREFIX_DIR=""
WINE_BIN=""
STORE_SUBDIR="repro-store"
VERBOSE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
wine-prefix-init.sh -- W1 P2 WINEPREFIX initialiser

Usage:
  wine-prefix-init.sh --prefix-dir <path>
                      [--wine-bin <path>]
                      [--store-subdir <name>]
                      [--verbose]
                      [--dry-run]

Creates a fresh WINEPREFIX in the given directory, runs wineboot -i to
populate drive_c/, pre-creates drive_c/<store-subdir>/, and verifies
the result. See docs/multi-os-windows-runtime.md for the layout.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix-dir)    PREFIX_DIR="$2";    shift 2 ;;
    --prefix-dir=*)  PREFIX_DIR="${1#--prefix-dir=}"; shift ;;
    --wine-bin)      WINE_BIN="$2";      shift 2 ;;
    --wine-bin=*)    WINE_BIN="${1#--wine-bin=}";     shift ;;
    --store-subdir)  STORE_SUBDIR="$2";  shift 2 ;;
    --store-subdir=*) STORE_SUBDIR="${1#--store-subdir=}"; shift ;;
    --verbose)       VERBOSE=1;          shift ;;
    --dry-run)       DRY_RUN=1;          shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "[wine-init][error] unknown argument: $1" >&2
                     usage >&2
                     exit 1 ;;
  esac
done

log()  { echo "[wine-init] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[wine-init][verbose] $*" >&2 || true; }
die()  { echo "[wine-init][error] $*" >&2; exit 1; }

[ -n "$PREFIX_DIR" ] || { usage >&2; die "--prefix-dir is required"; }

# Absolute-path the prefix dir (wineboot rejects relative paths quietly).
case "$PREFIX_DIR" in
  /*) ;;
  *)  PREFIX_DIR="$(pwd)/$PREFIX_DIR" ;;
esac

# ---------------------------------------------------------------------------
# Preflight: locate wine
# ---------------------------------------------------------------------------

if [ -z "$WINE_BIN" ]; then
  if command -v wine >/dev/null 2>&1; then
    WINE_BIN="$(command -v wine)"
  else
    log "wine not found on PATH"
    log "  install via: apt-get install -y wine wine64    (Debian/Ubuntu)"
    log "            or: dnf install -y wine               (Fedora)"
    log "            or: pacman -S wine                    (Arch)"
    exit 2
  fi
fi

if [ ! -x "$WINE_BIN" ]; then
  die "wine binary not executable: $WINE_BIN"
fi

# wineboot may live alongside wine as a separate binary OR be invocable
# as `wine wineboot.exe -i`. We prefer the standalone binary when
# present; fall back to the indirect form otherwise.
WINEBOOT_BIN=""
WINE_DIR="$(dirname "$WINE_BIN")"
if [ -x "$WINE_DIR/wineboot" ]; then
  WINEBOOT_BIN="$WINE_DIR/wineboot"
elif command -v wineboot >/dev/null 2>&1; then
  WINEBOOT_BIN="$(command -v wineboot)"
fi

vlog "wine_bin=$WINE_BIN"
vlog "wineboot_bin=${WINEBOOT_BIN:-<invoke via wine>}"

# Report the wine version (this also serves as a sanity check that the
# binary runs at all — version is cheap; if it deadlocks something's
# really wrong upstream).
if [ "$DRY_RUN" = 0 ]; then
  WINE_VERSION="$("$WINE_BIN" --version 2>/dev/null || echo unknown)"
  log "wine version: $WINE_VERSION"
fi

# ---------------------------------------------------------------------------
# Prepare the prefix directory
# ---------------------------------------------------------------------------

if [ -e "$PREFIX_DIR" ]; then
  # Refuse to clobber an existing prefix unless it's clearly a half-baked
  # mkdir from a previous failed run (i.e. empty).
  if [ -d "$PREFIX_DIR" ] && [ -z "$(ls -A "$PREFIX_DIR" 2>/dev/null)" ]; then
    vlog "prefix dir exists and is empty; reusing: $PREFIX_DIR"
  else
    die "prefix dir already populated; refusing to clobber: $PREFIX_DIR"
  fi
fi

log "prefix dir: $PREFIX_DIR"
log "store subdir: drive_c/$STORE_SUBDIR/"

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: skipping mkdir + wineboot + verification"
  exit 0
fi

mkdir -p "$PREFIX_DIR"

# ---------------------------------------------------------------------------
# Run wineboot -i with GUI nags suppressed
# ---------------------------------------------------------------------------

# WINEDEBUG=-all      silences fixme:/warn: spam in the wineboot output.
# WINEDLLOVERRIDES=mscoree,mshtml=    disables the Mono/Gecko download
#                                     prompts (we ship neither in the PoC).
# DISPLAY unset       wineboot's -i path doesn't need an X11 server for
#                     the registry + skeleton init we need; clearing
#                     DISPLAY prevents WINE from trying to open one.
# WINEPREFIX=<path>   the target prefix to populate.

export WINEPREFIX="$PREFIX_DIR"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
unset DISPLAY

log "running wineboot -i (this may take 10-30s on first invocation)"

WINEBOOT_LOG="$(mktemp -t wine-init.XXXXXX.log)"
trap 'rm -f "$WINEBOOT_LOG"' EXIT

WINEBOOT_EXIT=0
if [ -n "$WINEBOOT_BIN" ]; then
  vlog "invoking: $WINEBOOT_BIN -i"
  "$WINEBOOT_BIN" -i > "$WINEBOOT_LOG" 2>&1 || WINEBOOT_EXIT=$?
else
  vlog "invoking: $WINE_BIN wineboot.exe -i"
  "$WINE_BIN" wineboot.exe -i > "$WINEBOOT_LOG" 2>&1 || WINEBOOT_EXIT=$?
fi

if [ "$VERBOSE" = 1 ] || [ "$WINEBOOT_EXIT" -ne 0 ]; then
  log "wineboot output:"
  sed 's/^/[wineboot] /' < "$WINEBOOT_LOG" >&2 || true
fi

if [ "$WINEBOOT_EXIT" -ne 0 ]; then
  log "wineboot -i exited with status $WINEBOOT_EXIT"
  exit 3
fi

# wineboot -i returns as soon as its foreground task exits, but
# wineserver continues to flush registry hives (system.reg / userdef.reg
# / user.reg) asynchronously. Force a drain so the post-init verification
# below sees a quiesced prefix. `wineserver -w` blocks until wineserver
# exits (after all clients have disconnected).
WINESERVER_BIN=""
if [ -x "$WINE_DIR/wineserver" ]; then
  WINESERVER_BIN="$WINE_DIR/wineserver"
elif command -v wineserver >/dev/null 2>&1; then
  WINESERVER_BIN="$(command -v wineserver)"
fi

if [ -n "$WINESERVER_BIN" ]; then
  vlog "draining wineserver: $WINESERVER_BIN -w"
  "$WINESERVER_BIN" -w 2>/dev/null || true
else
  vlog "wineserver binary not found; sleeping 2s as a fallback drain"
  sleep 2
fi

# ---------------------------------------------------------------------------
# Pre-create the per-package store subtree
# ---------------------------------------------------------------------------

DRIVE_C="$PREFIX_DIR/drive_c"
STORE_DIR="$DRIVE_C/$STORE_SUBDIR"

mkdir -p "$STORE_DIR"
vlog "pre-created store subdir: $STORE_DIR"

# Drop a sentinel marker so W2/W3 + the ISO-build pipeline can confirm
# this prefix was initialised by this exact script + WINE version.
cat > "$PREFIX_DIR/.reproos-wine-prefix.json" <<EOF
{
  "wine_prefix_id": "shared",
  "wine_version": "$WINE_VERSION",
  "store_subdir": "$STORE_SUBDIR",
  "initialized_by": "wine-prefix-init.sh",
  "initialized_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
vlog "wrote sentinel: $PREFIX_DIR/.reproos-wine-prefix.json"

# ---------------------------------------------------------------------------
# Verification gate
# ---------------------------------------------------------------------------

VERIFY_ERRORS=0

verify() {
  local what="$1"
  local path="$2"
  if [ -e "$path" ]; then
    vlog "OK    $what: $path"
  else
    log "MISS  $what: $path"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
  fi
}

verify "drive_c dir"            "$DRIVE_C"
verify "drive_c/windows"        "$DRIVE_C/windows"
verify "drive_c/users"          "$DRIVE_C/users"
verify "drive_c/$STORE_SUBDIR"  "$STORE_DIR"
verify "system.reg hive"        "$PREFIX_DIR/system.reg"
verify "userdef.reg hive"       "$PREFIX_DIR/userdef.reg"

if [ "$VERIFY_ERRORS" -ne 0 ]; then
  log "verification FAILED: $VERIFY_ERRORS missing artefacts"
  exit 4
fi

log "verification PASS"
log "  prefix:        $PREFIX_DIR"
log "  drive_c:       $DRIVE_C"
log "  store subdir:  $STORE_DIR"
log "  wine version:  $WINE_VERSION"
exit 0
