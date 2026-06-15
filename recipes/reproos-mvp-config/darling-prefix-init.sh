#!/usr/bin/env bash
# D1 P3: DPREFIX initialiser for the ReproOS-Multi-OS-Catalog-PoC
# campaign.
#
# Creates a fresh DPREFIX in a Linux environment per the architecture
# decided in docs/multi-os-macos-runtime.md (D1 P1):
#
#   * Single shared DPREFIX (~5 MB overlay upper layer; the heavy data
#     ~285 MB lives in /usr/libexec/darling/ as part of the Darling
#     install, not the prefix).
#   * Applications/repro-store/ subtree pre-created (D3 will populate
#     it with per-package payloads).
#   * Headless-safe (no X11 / Wayland required for the boot-skeleton
#     init of the PoC tools' Mach-O binaries).
#
# The script is consumed at ISO build time (per D1's bake-at-build-time
# decision) AND from the verification gate in CI / sub-agent runs.
#
# Usage
# -----
#
#   darling-prefix-init.sh --prefix-dir <path>
#                          [--darling-bin <path>]
#                          [--store-subdir <name>]
#                          [--smoke-binary <macos-mach-o-path>]
#                          [--verbose]
#                          [--dry-run]
#
# Defaults:
#   --prefix-dir         REQUIRED
#   --darling-bin        darling (resolved via PATH)
#   --store-subdir       repro-store
#   --smoke-binary       (none — only --version stays inside Darling)
#   --verbose            off
#   --dry-run            off
#
# Exit codes:
#   0    DPREFIX initialised successfully (gate PASS).
#   1    argument / preflight error.
#   2    darling not found on PATH (or --darling-bin not executable).
#   3    `darling shell echo ok` failed.
#   4    post-init verification failed (Applications missing, etc.).
#   5    --smoke-binary supplied but its execution under Darling failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PREFIX_DIR=""
DARLING_BIN=""
STORE_SUBDIR="repro-store"
SMOKE_BIN=""
VERBOSE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
darling-prefix-init.sh -- D1 P3 DPREFIX initialiser

Usage:
  darling-prefix-init.sh --prefix-dir <path>
                         [--darling-bin <path>]
                         [--store-subdir <name>]
                         [--smoke-binary <macos-mach-o-path>]
                         [--verbose]
                         [--dry-run]

Creates a fresh DPREFIX in the given directory, runs `darling shell echo ok`
to populate the macOS-shaped filesystem, pre-creates
Applications/<store-subdir>/, and verifies the result. See
docs/multi-os-macos-runtime.md for the layout.

The optional --smoke-binary argument names a host-filesystem path to a
macOS Mach-O binary; the script invokes it under `darling shell` (via
the /Volumes/SystemRoot mount) and reports its --version output. Used
to validate that a candidate PoC tool actually runs under Darling
before D3 commits to it in the catalog.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix-dir)    PREFIX_DIR="$2";    shift 2 ;;
    --prefix-dir=*)  PREFIX_DIR="${1#--prefix-dir=}"; shift ;;
    --darling-bin)   DARLING_BIN="$2";   shift 2 ;;
    --darling-bin=*) DARLING_BIN="${1#--darling-bin=}"; shift ;;
    --store-subdir)  STORE_SUBDIR="$2";  shift 2 ;;
    --store-subdir=*) STORE_SUBDIR="${1#--store-subdir=}"; shift ;;
    --smoke-binary)  SMOKE_BIN="$2";     shift 2 ;;
    --smoke-binary=*) SMOKE_BIN="${1#--smoke-binary=}"; shift ;;
    --verbose)       VERBOSE=1;          shift ;;
    --dry-run)       DRY_RUN=1;          shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "[darling-init][error] unknown argument: $1" >&2
                     usage >&2
                     exit 1 ;;
  esac
done

log()  { echo "[darling-init] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[darling-init][verbose] $*" >&2 || true; }
die()  { echo "[darling-init][error] $*" >&2; exit 1; }

[ -n "$PREFIX_DIR" ] || { usage >&2; die "--prefix-dir is required"; }

# Absolute-path the prefix dir (darling silently rejects relative paths
# in DPREFIX via the overlayfs mount).
case "$PREFIX_DIR" in
  /*) ;;
  *)  PREFIX_DIR="$(pwd)/$PREFIX_DIR" ;;
esac

# ---------------------------------------------------------------------------
# Preflight: locate darling
# ---------------------------------------------------------------------------

if [ -z "$DARLING_BIN" ]; then
  if command -v darling >/dev/null 2>&1; then
    DARLING_BIN="$(command -v darling)"
  else
    log "darling not found on PATH"
    log "  install via upstream .debs:"
    log "    curl -L -o /tmp/debs.zip \\"
    log "      https://github.com/darlinghq/darling/releases/download/<tag>/debs_<date>.zip"
    log "    unzip /tmp/debs.zip -d /tmp/debs"
    log "    cd /tmp/debs/debs_<date> && apt-get install -y --no-install-recommends \\"
    log "      ./darling-core_*.deb ./darling-system_*.deb ./darling-cli_*.deb \\"
    log "      ./darling-cli-gui-common_*.deb ./darling-cli-python2-common_*.deb"
    exit 2
  fi
fi

if [ ! -x "$DARLING_BIN" ]; then
  die "darling binary not executable: $DARLING_BIN"
fi

vlog "darling_bin=$DARLING_BIN"

# Report the darling version (sanity check + recorded for the manifest
# sidecar). Darling has no --version flag on the launcher; we read the
# package-version line from the .deb manifest in `dpkg -s` when
# available; otherwise fall back to a marker.
DARLING_VERSION=""
if command -v dpkg-query >/dev/null 2>&1; then
  DARLING_VERSION="$(dpkg-query -W -f='${Version}' darling-core 2>/dev/null || echo "")"
fi
[ -n "$DARLING_VERSION" ] || DARLING_VERSION="unknown"
log "darling version: $DARLING_VERSION"

# ---------------------------------------------------------------------------
# Prepare the prefix directory
# ---------------------------------------------------------------------------

if [ -e "$PREFIX_DIR" ]; then
  # Refuse to clobber an existing prefix unless it's clearly a half-baked
  # remnant from a previous failed run (i.e. empty).
  #
  # NOTE: Darling's overlayfs init detects "first run" by absence of
  # the prefix dir itself. If the dir already exists (even empty),
  # darling skips the `Setting up a new Darling prefix` step and then
  # fails to connect to the (un-launched) shellspawn socket:
  #   `Error connecting to shellspawn in the container
  #    (.../var/run/shellspawn.sock): No such file or directory`
  # To recover cleanly we rmdir the empty dir so Darling re-creates it.
  if [ -d "$PREFIX_DIR" ] && [ -z "$(ls -A "$PREFIX_DIR" 2>/dev/null)" ]; then
    vlog "prefix dir exists and is empty; rmdir-ing so darling re-creates it"
    rmdir "$PREFIX_DIR"
  else
    die "prefix dir already populated; refusing to clobber: $PREFIX_DIR"
  fi
fi

# Also ensure the parent dir exists (darling will create $PREFIX_DIR
# itself, but the parent must already be there).
PREFIX_PARENT="$(dirname "$PREFIX_DIR")"
if [ ! -d "$PREFIX_PARENT" ]; then
  mkdir -p "$PREFIX_PARENT"
  vlog "created parent dir: $PREFIX_PARENT"
fi

log "prefix dir: $PREFIX_DIR"
log "store subdir: Applications/$STORE_SUBDIR/"

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: skipping darling-shell + verification"
  exit 0
fi

# ---------------------------------------------------------------------------
# Run `darling shell echo ok` to cold-init the prefix
# ---------------------------------------------------------------------------
#
# DPREFIX=<path>      the target prefix to populate.
# DISPLAY unset       Darling's CLI-shell path doesn't need an X11
#                     server; clearing DISPLAY prevents Darling from
#                     trying to open one.
# WAYLAND_DISPLAY     same as above for wayland.
#
# We invoke `darling shell echo ok` (positional arg-vector form; per
# the Darling README. The `--command` flag form documented in some
# third-party tutorials is not what the current darling supports — it
# treats `--command` as a program name and tries to exec it).

export DPREFIX="$PREFIX_DIR"
unset DISPLAY
unset WAYLAND_DISPLAY

log "running darling shell echo ok (this may take ~10s on first invocation)"

DARLING_INIT_LOG="$(mktemp -t darling-init.XXXXXX.log)"
trap 'rm -f "$DARLING_INIT_LOG"' EXIT

DARLING_INIT_EXIT=0
vlog "invoking: $DARLING_BIN shell echo ok"
"$DARLING_BIN" shell echo ok > "$DARLING_INIT_LOG" 2>&1 || DARLING_INIT_EXIT=$?

if [ "$VERBOSE" = 1 ] || [ "$DARLING_INIT_EXIT" -ne 0 ]; then
  log "darling-shell output:"
  sed 's/^/[darling-shell] /' < "$DARLING_INIT_LOG" >&2 || true
fi

if [ "$DARLING_INIT_EXIT" -ne 0 ]; then
  log "darling shell echo ok exited with status $DARLING_INIT_EXIT"
  exit 3
fi

# Sanity-check the output: the `echo ok` should print exactly `ok`
# followed by a newline (modulo darlingserver "Setting up a new Darling
# prefix" preamble lines emitted on cold init).
if ! grep -qE '^ok$' "$DARLING_INIT_LOG"; then
  log "darling shell did not produce 'ok' output; saw:"
  sed 's/^/[darling-shell] /' < "$DARLING_INIT_LOG" >&2 || true
  exit 3
fi

# darling shell exits cleanly after its command completes, but
# darlingserver may keep running in the background. We don't actively
# shut it down here — the prefix is already quiesced from the host's
# perspective (the overlay upper layer is flushed before
# darling-shell returns), and a follow-up `darling shutdown` is
# cheap if the caller wants to stop the server.

# ---------------------------------------------------------------------------
# Pre-create the per-package store subtree
# ---------------------------------------------------------------------------

APPLICATIONS_DIR="$PREFIX_DIR/Applications"
STORE_DIR="$APPLICATIONS_DIR/$STORE_SUBDIR"

mkdir -p "$STORE_DIR"
vlog "pre-created store subdir: $STORE_DIR"

# Drop a sentinel marker so D2/D3 + the ISO-build pipeline can confirm
# this prefix was initialised by this exact script + Darling version.
cat > "$PREFIX_DIR/.reproos-darling-prefix.json" <<EOF
{
  "darling_prefix_id": "shared",
  "darling_version": "$DARLING_VERSION",
  "store_subdir": "$STORE_SUBDIR",
  "initialized_by": "darling-prefix-init.sh",
  "initialized_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
vlog "wrote sentinel: $PREFIX_DIR/.reproos-darling-prefix.json"

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

# Darling populates the prefix with the macOS-shaped filesystem
# (Applications/, Library/, System/, Users/, Volumes/, and a
# .darlingserver.sock + .init.pid pair). We assert the expected
# top-level dirs.
verify "Applications dir"            "$APPLICATIONS_DIR"
verify "Library dir"                 "$PREFIX_DIR/Library"
verify "System dir"                  "$PREFIX_DIR/System"
verify "Users dir"                   "$PREFIX_DIR/Users"
verify "Volumes dir"                 "$PREFIX_DIR/Volumes"
verify "darlingserver socket"        "$PREFIX_DIR/.darlingserver.sock"
verify "Applications/$STORE_SUBDIR"  "$STORE_DIR"

if [ "$VERIFY_ERRORS" -ne 0 ]; then
  log "verification FAILED: $VERIFY_ERRORS missing artefacts"
  exit 4
fi

# ---------------------------------------------------------------------------
# Optional smoke test against a candidate macOS binary
# ---------------------------------------------------------------------------
#
# Darling exposes the host filesystem under /Volumes/SystemRoot inside
# the macOS-shaped namespace. So if the user passes
# --smoke-binary=/path/on/host, we exec
# `darling shell /Volumes/SystemRoot/<path> --version` and capture the
# result. This is how D3 will validate each catalog candidate before
# committing to its banner.

if [ -n "$SMOKE_BIN" ]; then
  if [ ! -x "$SMOKE_BIN" ]; then
    log "smoke binary not executable: $SMOKE_BIN"
    exit 5
  fi

  # Verify it's a Mach-O so we don't silently waste a probe slot.
  if command -v file >/dev/null 2>&1; then
    if ! file "$SMOKE_BIN" 2>/dev/null | grep -q "Mach-O"; then
      log "smoke binary is not a Mach-O executable: $SMOKE_BIN"
      log "  (`file $SMOKE_BIN`)"
      exit 5
    fi
  fi

  SMOKE_MACOS_PATH="/Volumes/SystemRoot$SMOKE_BIN"
  log "smoke-testing under Darling: $SMOKE_BIN -> $SMOKE_MACOS_PATH --version"

  SMOKE_LOG="$(mktemp -t darling-smoke.XXXXXX.log)"
  trap 'rm -f "$DARLING_INIT_LOG" "$SMOKE_LOG"' EXIT

  SMOKE_EXIT=0
  "$DARLING_BIN" shell "$SMOKE_MACOS_PATH" --version </dev/null > "$SMOKE_LOG" 2>&1 || SMOKE_EXIT=$?

  log "smoke exit status: $SMOKE_EXIT"
  log "smoke output (first 5 lines):"
  head -n 5 "$SMOKE_LOG" | sed 's/^/[smoke] /' >&2 || true

  if [ "$SMOKE_EXIT" -ne 0 ]; then
    log "smoke FAILED: candidate did not return 0 from --version"
    exit 5
  fi
fi

log "verification PASS"
log "  prefix:         $PREFIX_DIR"
log "  applications:   $APPLICATIONS_DIR"
log "  store subdir:   $STORE_DIR"
log "  darling version: $DARLING_VERSION"

# Report the cold-size for the doc / sidecar.
if command -v du >/dev/null 2>&1; then
  COLD_SIZE="$(du -sh "$PREFIX_DIR" 2>/dev/null | awk '{print $1}')"
  log "  cold size:      $COLD_SIZE"
fi
exit 0
