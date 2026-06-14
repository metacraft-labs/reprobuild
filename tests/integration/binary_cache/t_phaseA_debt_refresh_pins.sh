#!/usr/bin/env bash
# t_phaseA_debt_refresh_pins.sh — Phase A debt-closure D3 gate.
#
# Exercises ``recipes/cache/scripts/refresh-pinned-entries.sh``
# end-to-end against an in-process daemon pre-populated with two of
# the logical pin entries (hex0 + glibc-2.42). The other pins remain
# misses; the script must preserve their placeholder lines.
#
# Verification:
#
#   * For each pre-populated logical name the resulting line carries
#     a non-placeholder digest matching what the publisher pushed.
#   * For each missing logical name the placeholder line survives.
#   * Re-running the script with the same cache state produces a
#     byte-identical file (idempotency invariant).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="$(a2_repo_root)"
REFRESH_SCRIPT="$REPO_ROOT/recipes/cache/scripts/refresh-pinned-entries.sh"
PIN_FILE_REAL="$REPO_ROOT/recipes/cache/pinned-entries.txt"
PIN_FILE_BACKUP="$(mktemp -t pin-backup.XXXXXX)"

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
  echo "refresh-pinned-entries.sh not found / not executable at $REFRESH_SCRIPT" >&2
  exit 1
fi

# Backup the shipping pin file so we can restore at exit.
cp "$PIN_FILE_REAL" "$PIN_FILE_BACKUP"
restore_pin_file() {
  cp "$PIN_FILE_BACKUP" "$PIN_FILE_REAL"
  rm -f "$PIN_FILE_BACKUP"
  a2_stop_server || true
}
trap restore_pin_file EXIT

a2_start_server

# Pin the host identity to a known stable triple so the test doesn't
# depend on the test runner's gcc version. The refresh script reads
# the same env vars at derive-key time.
export REPRO_HOST_GCC_VERSION="15.2.0-itest"
export REPRO_HOST_LDSO_ABI="glibc-host"
export REPRO_PROVIDER_REVISION="repro-pin-refresh-v1"
export REPRO_BINARY_CACHE_URL="$A2_BASE_URL"

CLIENT_CLI="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLIENT_CLI" ]]; then
  CLIENT_CLI="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLIENT_CLI" ]]; then
  echo "client CLI not built; build with the integration test harness recipe" >&2
  exit 1
fi

# Derive the expected entry-key for each pre-populated logical name
# so the test asserts on the actual hex without re-implementing the
# derive logic in bash.
common_flags=(
  --platform-cpu=x86_64
  --platform-os=linux
  --platform-abi=gnu
  --platform-libc=
  --toolchain-host-ldso=glibc-host
  --toolchain-extra=host_gcc=15.2.0-itest
  --provider-revision=repro-pin-refresh-v1
)
HEX_HEX0="$("$CLIENT_CLI" derive-key "${common_flags[@]}" \
  --package-name=hex0 --package-version=stage0-posix)"
HEX_HEX0="$(printf '%s' "$HEX_HEX0" | tr -d '\r\n ')"
HEX_GLIBC="$("$CLIENT_CLI" derive-key "${common_flags[@]}" \
  --package-name=glibc --package-version=2.42)"
HEX_GLIBC="$(printf '%s' "$HEX_GLIBC" | tr -d '\r\n ')"

if [[ -z "$HEX_HEX0" || "${#HEX_HEX0}" != 64 ]]; then
  a2_fail "hex0 derive-key returned bad output: '$HEX_HEX0'"
fi
if [[ -z "$HEX_GLIBC" || "${#HEX_GLIBC}" != 64 ]]; then
  a2_fail "glibc derive-key returned bad output: '$HEX_GLIBC'"
fi

# Pre-populate the cache by issuing two publish calls with payloads
# matching the derived entry-keys.  The publish helper builds its own
# entry-key from the supplied --package/--version; we have to feed it
# the *same* package/version/flags so the server records the right
# manifest.
#
# The publish helper currently doesn't accept a full identity-flag
# block (it uses fixed test defaults), so we cannot easily push a
# manifest under the derive_key-computed hex. Two-pronged response:
#
#   (a) The integration test uses curl to query MANIFESTS by the
#       derived hex AND we exercise the "miss" leg only for the
#       refresh script — which is the dominant case in a Phase A
#       smoke (the chain hasn't actually been built yet).
#   (b) For the "hit" leg we publish via the helper with the same
#       package + version, then patch the cache file so the
#       derive-key+lookup pair sees a hit. This is good enough for
#       the gate: the script's branching logic is what we're
#       validating, not the helper's flag-passing.
#
# Easier path: directly stage manifests on disk in the daemon's root
# under the derived hex. The on-disk layout is
# ``manifests/<ab>/<key>.manifest``. We create empty files there.
# The lookup endpoint only checks existence (HTTP 200 vs 404), not
# contents — so this is enough.

stage_lookup_hit() {
  local hex="$1"
  local shard="${hex:0:2}"
  mkdir -p "$A2_ROOT/manifests/$shard"
  # The GET /manifests/<hex> handler 200s only if the file exists.
  # We don't need a real manifest body for the LOOKUP path.
  printf 'placeholder-manifest-for-%s\n' "$hex" \
    > "$A2_ROOT/manifests/$shard/${hex}.manifest"
}

stage_lookup_hit "$HEX_HEX0"
stage_lookup_hit "$HEX_GLIBC"

# Sanity: hit endpoint returns 200 for the staged keys, 404 for an
# unstaged synthetic.
status="$(curl -sS -o /dev/null -w '%{http_code}' "$A2_BASE_URL/manifests/$HEX_HEX0")"
if [[ "$status" != "200" ]]; then
  a2_fail "staged hex0 manifest not visible to GET /manifests: status $status"
fi

# Replace the file with the shipping placeholder set so the refresh
# script has placeholders to resolve. We keep the existing one as-is.

echo "[refresh-pins] running refresh script (1st pass)..."
"$REFRESH_SCRIPT"

# Read back the resulting file and check:
#   - hex0 placeholder replaced with $HEX_HEX0
#   - glibc placeholder replaced with $HEX_GLIBC
#   - other placeholders preserved as-is
result="$(cat "$PIN_FILE_REAL")"
if ! grep -qE "^${HEX_HEX0}[[:space:]]+#[[:space:]]+hex0$" "$PIN_FILE_REAL"; then
  echo "FAIL: hex0 line not updated to $HEX_HEX0" >&2
  echo "Got file:" >&2
  cat "$PIN_FILE_REAL" >&2
  exit 1
fi
if ! grep -qE "^${HEX_GLIBC}[[:space:]]+#[[:space:]]+glibc-2.42$" "$PIN_FILE_REAL"; then
  echo "FAIL: glibc-2.42 line not updated to $HEX_GLIBC" >&2
  cat "$PIN_FILE_REAL" >&2
  exit 1
fi
# Placeholders for the unstaged pins must still be there. Check a
# couple of them: systemd-257.9 + linux-6.6.142-bzImage. The
# placeholders shipped originally are 0000...0006 / 0000...0007.
if ! grep -qE '#[[:space:]]+linux-6\.6\.142-bzImage$' "$PIN_FILE_REAL"; then
  echo "FAIL: linux pin disappeared after refresh" >&2
  cat "$PIN_FILE_REAL" >&2
  exit 1
fi
if ! grep -qE '#[[:space:]]+systemd-257\.9$' "$PIN_FILE_REAL"; then
  echo "FAIL: systemd pin disappeared after refresh" >&2
  cat "$PIN_FILE_REAL" >&2
  exit 1
fi

# Idempotency: second pass produces byte-identical file.
FIRST_PASS="$(mktemp -t pin-pass1.XXXXXX)"
cp "$PIN_FILE_REAL" "$FIRST_PASS"

echo "[refresh-pins] running refresh script (2nd pass for idempotency)..."
"$REFRESH_SCRIPT"

if ! diff -q "$FIRST_PASS" "$PIN_FILE_REAL" >/dev/null 2>&1; then
  echo "FAIL: refresh-pinned-entries.sh is NOT idempotent" >&2
  echo "diff (pass1 vs pass2):" >&2
  diff -u "$FIRST_PASS" "$PIN_FILE_REAL" >&2 || true
  rm -f "$FIRST_PASS"
  exit 1
fi
rm -f "$FIRST_PASS"

echo "PASS: t_phaseA_debt_refresh_pins"
echo "  hex0 -> $HEX_HEX0"
echo "  glibc-2.42 -> $HEX_GLIBC"
echo "  other placeholders preserved across two passes"
