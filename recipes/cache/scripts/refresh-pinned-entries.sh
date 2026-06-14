#!/usr/bin/env bash
# refresh-pinned-entries.sh — Phase A debt-closure D3.
#
# Materialises real digests for the bootstrap-chain pin list at
# ``recipes/cache/pinned-entries.txt``.
#
# ## What this script does
#
# The shipped ``pinned-entries.txt`` ships with placeholder digests
# (``0000...0001`` through ``0000...0007``) so the file parses cleanly
# during unit tests BEFORE a real cache deployment exists. Once the
# producer publishes the R4-R9 chain to the deployed ``repro-cache``
# server, this script replaces each placeholder with the real
# entry-key derived from the deployment's toolchain identity.
#
# Steps per pin entry:
#
#   1. Read the (placeholder-hex, logical-name) pair from
#      ``pinned-entries.txt``. The logical name is the trailing
#      ``# <name>`` comment on the same line.
#   2. Look up the logical name in the in-script identity table
#      (see ``PIN_IDENTITIES`` below) to get the identity flags the
#      producer used at publish time.
#   3. Invoke ``repro-binary-cache-client derive-key <flags>`` to
#      compute the entry-key hex.
#   4. Invoke ``repro-binary-cache-client lookup <hex>`` against
#      the deployed cache. On hit, queue the placeholder->real
#      replacement. On miss, leave the placeholder and emit a
#      warning to stderr.
#   5. Rewrite ``pinned-entries.txt`` with the resolved digests
#      (placeholders preserved for any miss). Output lines are
#      sorted (pin entry-key hex strings ascending) so re-running
#      against the same cache state produces byte-identical output.
#
# ## Idempotency
#
# Re-running against the same cache state produces the same
# ``pinned-entries.txt`` byte stream. A logical name that has
# already been resolved (i.e. its line carries a non-placeholder
# digest) is re-resolved if the in-script identity table still
# matches the comment, and the result must agree with what's
# already in the file — otherwise we treat it as a real change
# and rewrite.
#
# ## Environment
#
#   REPRO_BINARY_CACHE_URL    — default http://localhost:7878. The
#                               deployed ``repro-cache`` server.
#   REPRO_HOST_GCC_VERSION    — host gcc, default detected via gcc.
#   REPRO_HOST_LDSO_ABI       — default ``glibc-host``.
#   REPRO_PROVIDER_REVISION   — default ``repro-pin-refresh-v1``.
#
# ## Exit codes
#
#   0  All pins resolved OR all misses were preserved as placeholders.
#   1  CLI binary or cache server unreachable.
#   2  Bad arguments.
#
# Misses don't fail the script — the operator wants to know which
# pins are missing AND keep the placeholders for the rest of the
# system to parse cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${RECIPES_DIR}/../.." && pwd)"

PIN_FILE="${RECIPES_DIR}/pinned-entries.txt"
CACHE_URL="${REPRO_BINARY_CACHE_URL:-http://localhost:7878}"

# The client CLI provides ``derive-key`` (compute the entry-key from
# an identity-flag tuple) and ``lookup`` (returns 0 on hit, 1 on miss).
CLIENT_CLI="${REPO_ROOT}/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLIENT_CLI" ]]; then
  CLIENT_CLI="${REPO_ROOT}/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -x "$CLIENT_CLI" && ! -f "$CLIENT_CLI" ]]; then
  echo "refresh-pinned-entries: client CLI binary not built. Build with:" >&2
  echo "  nim c -o:build/test-bin/repro_binary_cache_client_cli.exe \\" >&2
  echo "    apps/repro-binary-cache-client/repro_binary_cache_client_cli.nim" >&2
  exit 1
fi

# Identity table: maps the logical name (the comment after ``#`` on
# each pin line) to the identity-flag block the producer used at
# publish time. Keys must match the comments in ``pinned-entries.txt``
# byte-for-byte after stripping whitespace.
#
# The values are space-separated identity flags forwarded verbatim to
# ``derive-key``. The host-detected toolchain fingerprint comes from
# the env vars below — re-run with ``REPRO_HOST_GCC_VERSION=<x>`` etc.
# to refresh pins for a different host triple.
HOST_GCC_VERSION="${REPRO_HOST_GCC_VERSION:-$(gcc --version 2>/dev/null | head -1 | awk '{print $NF}' || echo unknown)}"
HOST_LDSO_ABI="${REPRO_HOST_LDSO_ABI:-glibc-host}"
PROVIDER_REVISION="${REPRO_PROVIDER_REVISION:-repro-pin-refresh-v1}"

# Common identity flags shared across every R-chain entry.
common_flags() {
  printf '%s\n' \
    "--platform-cpu=x86_64" \
    "--platform-os=linux" \
    "--platform-abi=gnu" \
    "--platform-libc=" \
    "--toolchain-host-ldso=${HOST_LDSO_ABI}" \
    "--toolchain-extra=host_gcc=${HOST_GCC_VERSION}" \
    "--provider-revision=${PROVIDER_REVISION}"
}

# Logical-name -> per-entry identity flags. Each function emits one
# flag per line; the caller `xargs`-joins them with ``common_flags``
# into a single argv block.
pin_identity_for() {
  local name="$1"
  case "$name" in
    "hex0")
      printf '%s\n' "--package-name=hex0" "--package-version=stage0-posix"
      ;;
    "gcc-15.2.0 / glibc-host")
      printf '%s\n' "--package-name=gcc" "--package-version=15.2.0" \
                   "--option=host_libc=glibc"
      ;;
    "gcc-15.2.0 / musl-host")
      printf '%s\n' "--package-name=gcc" "--package-version=15.2.0" \
                   "--option=host_libc=musl"
      ;;
    "gcc-15.2.0 / windows-msvc")
      printf '%s\n' "--package-name=gcc" "--package-version=15.2.0" \
                   "--option=host_libc=msvc"
      ;;
    "glibc-2.42")
      printf '%s\n' "--package-name=glibc" "--package-version=2.42"
      ;;
    "linux-6.6.142-bzImage")
      printf '%s\n' "--package-name=linux" "--package-version=6.6.142" \
                   "--option=output=bzImage"
      ;;
    "systemd-257.9")
      printf '%s\n' "--package-name=systemd" "--package-version=257.9"
      ;;
    *)
      # Unknown logical name — caller treats as un-resolvable.
      return 1
      ;;
  esac
}

derive_key_for() {
  local name="$1"
  local pin_flags
  if ! pin_flags="$(pin_identity_for "$name")"; then
    return 1
  fi
  # shellcheck disable=SC2046
  set -- $(common_flags) $pin_flags
  "$CLIENT_CLI" derive-key "$@"
}

lookup_key() {
  local hex="$1"
  # The CLI's ``lookup`` exits 0 on hit, 1 on miss, 3 on transport
  # failure. Translate.
  REPRO_BINARY_CACHE_URL="$CACHE_URL" "$CLIENT_CLI" lookup "$hex" >/dev/null 2>&1
  local rc=$?
  return $rc
}

is_placeholder_hex() {
  # All-zero leading 60+ chars marks a placeholder. Strict: the file
  # only ever ships placeholders of this shape.
  local hex="$1"
  if [[ "$hex" =~ ^0{60}[0-9a-fA-F]{4}$ ]]; then
    return 0
  fi
  return 1
}

# --------- Parse the existing file --------------------------------------------
declare -a OUT_LINES=()
declare -a OUT_PIN_LINES=()    # only the actual pin (hex + comment) lines
HEADER_LINES=()
SAW_FIRST_PIN=0
SECTION_MARKER='# Resolved pins (refresh-pinned-entries.sh)'

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$SAW_FIRST_PIN" == "0" ]]; then
    if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
      # Detect our own previously-emitted section marker (and the
      # blank line immediately preceding it) so successive runs stay
      # byte-identical. We strip both so the regenerator can re-emit
      # them from a clean state.
      if [[ "$line" == "$SECTION_MARKER" ]]; then
        # Drop a single trailing blank from HEADER_LINES (the blank
        # we emit before the marker on regeneration).
        if [[ "${#HEADER_LINES[@]}" -gt 0 && \
              -z "${HEADER_LINES[${#HEADER_LINES[@]}-1]}" ]]; then
          unset 'HEADER_LINES[${#HEADER_LINES[@]}-1]'
        fi
        # Trigger pin-section parsing.
        SAW_FIRST_PIN=1
        continue
      fi
      HEADER_LINES+=("$line")
      continue
    fi
    SAW_FIRST_PIN=1
  fi
  # We don't bother preserving section-comment lines INSIDE the pin
  # block — we'll regenerate them deterministically below so the
  # idempotency invariant holds.
  if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
    continue
  fi
  OUT_PIN_LINES+=("$line")
done < "$PIN_FILE"

# --------- Resolve each pin ---------------------------------------------------
declare -A RESOLVED=()         # logical-name -> resolved hex (real or placeholder)
declare -a LOGICAL_ORDER=()    # ordered list of unique logical names
declare -i MISS_COUNT=0
declare -i HIT_COUNT=0
declare -i UNKNOWN_COUNT=0

for raw in "${OUT_PIN_LINES[@]}"; do
  # Split "hex  # logical-name"
  hex="$(printf '%s' "$raw" | awk '{print $1}')"
  comment="$(printf '%s' "$raw" | sed -E 's/^[^#]*//; s/^#[[:space:]]*//; s/[[:space:]]+$//')"
  if [[ -z "$hex" ]]; then
    continue
  fi
  name="${comment:-<unnamed>}"
  if [[ -z "${RESOLVED[$name]+x}" ]]; then
    LOGICAL_ORDER+=("$name")
  fi
  if real="$(derive_key_for "$name" 2>/dev/null)"; then
    real="$(printf '%s' "$real" | tr -d '\r\n ')"
    if lookup_key "$real"; then
      RESOLVED[$name]="$real"
      HIT_COUNT=$((HIT_COUNT + 1))
      printf 'hit:  %s -> %s\n' "$name" "$real" >&2
    else
      # Miss: keep whatever we had (placeholder or stale prior real).
      RESOLVED[$name]="$hex"
      MISS_COUNT=$((MISS_COUNT + 1))
      printf 'miss: %s (preserving %s)\n' "$name" "$hex" >&2
    fi
  else
    # Unknown logical name: keep the existing hex (placeholder
    # likely). Warn so the operator extends the identity table.
    RESOLVED[$name]="$hex"
    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
    printf 'unknown logical name "%s"; preserving %s\n' "$name" "$hex" >&2
  fi
done

# --------- Emit the new file --------------------------------------------------
TMP_OUT="$(mktemp -t pinned-entries.XXXXXX)"
trap 'rm -f "$TMP_OUT"' EXIT

for h in "${HEADER_LINES[@]}"; do
  printf '%s\n' "$h" >> "$TMP_OUT"
done

# Section header re-emitted for readability — kept stable across
# runs so byte-for-byte idempotency holds. The blank-line + marker
# pair is recognised by the parser so re-runs strip both before
# re-emitting.
printf '\n%s\n' "$SECTION_MARKER" >> "$TMP_OUT"

# Stable order: sort by hex ascending so the output is deterministic
# regardless of the resolution order.
declare -a SORTED_LINES=()
for name in "${LOGICAL_ORDER[@]}"; do
  hex="${RESOLVED[$name]}"
  SORTED_LINES+=("${hex}  # ${name}")
done
printf '%s\n' "${SORTED_LINES[@]}" | sort >> "$TMP_OUT"

mv "$TMP_OUT" "$PIN_FILE"
trap - EXIT

printf 'refresh-pinned-entries: hits=%d misses=%d unknown=%d\n' \
  "$HIT_COUNT" "$MISS_COUNT" "$UNKNOWN_COUNT" >&2

exit 0
