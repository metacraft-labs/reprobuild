#!/usr/bin/env bash
# t_r1_client_trust.sh — Reprobuild-Binary-Cache-Fleet R1 gate.
#
# Drives the SHIPPING CLI (`repro-binary-cache-client substitute`)
# through the R1 config + default-untrusted trust model end-to-end:
#
#   1. Publish a real, signed entry to an A2 server (producer key P).
#   2. TRUSTED  — a caches.conf whose cache trusts P  => substitute HITS.
#   3. UNTRUSTED — a caches.conf whose cache trusts a DIFFERENT key
#      => substitute MISSES (the manifest is validly signed by P but
#      P is not trusted for this cache; a MISS, never a silent trust).
#   4. NO-TRUST — a caches.conf whose cache lists NO trusted-public-keys
#      => substitute MISSES even though the server serves a valid,
#      signed manifest (default-untrusted, the load-bearing property).
#
# Non-vacuity: without the client trust check, step 3 + step 4 would
# HIT (the manifest signature verifies), so a pre-R1 client fails this
# gate. The config path is REPRO_CACHES_CONFIG (single-file override).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
[[ -f "$CLI_BIN" ]] || a2_fail "CLI binary missing; build with:
  nim c -o:build/test-bin/repro_binary_cache_client_cli.exe \\
    libs/repro_binary_cache_client/tests/repro_binary_cache_client_cli.nim"

a2_start_server
TMP="$(mktemp -d -t r1trust-XXXXXX)"
trap 'a2_stop_server; rm -rf "$TMP"' EXIT

KEY_PATH="$TMP/producer.key"
CERT_PATH="$TMP/producer.cert"
OTHER_CERT="$TMP/other.cert"
OTHER_KEY="$TMP/other.key"
CLIENT_STORE="$TMP/client-store"
mkdir -p "$CLIENT_STORE"

# --- Producer keypair P (used to sign + publish) ---------------------------
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" gen-key >/dev/null
[[ -f "$CERT_PATH" ]] || a2_fail "producer keypair generation failed"
PUBKEY_P="$(tr -d '[:space:]' < "$CERT_PATH")"

# --- A DIFFERENT keypair O (the untrusted signer for step 3) ---------------
REPRO_BINARY_CACHE_KEY_PATH="$OTHER_KEY" \
REPRO_BINARY_CACHE_CERT_PATH="$OTHER_CERT" \
  "$CLI_BIN" gen-key >/dev/null
PUBKEY_O="$(tr -d '[:space:]' < "$OTHER_CERT")"

[[ "$PUBKEY_P" != "$PUBKEY_O" ]] || a2_fail "gen-key produced identical keys"

# --- Publish a real entry signed by P --------------------------------------
PREFIX_DIR="$TMP/prefix"
mkdir -p "$PREFIX_DIR"
printf 'r1-trusted-payload-deterministic\n' > "$PREFIX_DIR/artifact"

# Platform triple must match the client's detected local platform or
# the compat gate rejects the manifest before the trust decision even
# matters. Detect it the same way cache-helper.sh does.
case "$(uname -s)" in
  Linux*) HOST_OS=linux; HOST_ABI=gnu ;;
  Darwin*) HOST_OS=darwin; HOST_ABI="" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows; HOST_ABI=msvc ;;
  *) HOST_OS=linux; HOST_ABI=gnu ;;
esac
case "$(uname -m)" in
  aarch64|arm64) HOST_CPU=aarch64 ;;
  *) HOST_CPU=x86_64 ;;
esac
IDENTITY_FLAGS=( --package-name=r1pkg --package-version=1.0.0
                 --platform-cpu="$HOST_CPU" --platform-os="$HOST_OS"
                 --platform-abi="$HOST_ABI" --platform-libc=
                 --toolchain-name=r1tc --toolchain-version=1 )
ENTRY_HEX="$(REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
             REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
             "$CLI_BIN" derive-key "${IDENTITY_FLAGS[@]}")"
REPRO_BINARY_CACHE_URL="$A2_BASE_URL" \
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" publish "$ENTRY_HEX" "$PREFIX_DIR" "${IDENTITY_FLAGS[@]}" >/dev/null
a2_ok "published entry $ENTRY_HEX signed by producer P"

write_config() {
  # $1 = config path, $2 = trusted-public-keys value (may be empty)
  cat > "$1" <<EOF
[fleet]
url = "$A2_BASE_URL"
trusted-public-keys = "$2"
priority = 10
EOF
}

run_substitute() {
  # Returns 0 on HIT, non-zero on MISS. Fresh store each call so the
  # client-side index never masks a trust decision.
  local cfg="$1" out="$2"
  rm -rf "$CLIENT_STORE" "$out"; mkdir -p "$CLIENT_STORE"
  REPRO_CACHES_CONFIG="$cfg" \
  REPRO_LOCAL_STORE="$CLIENT_STORE" \
    "$CLI_BIN" substitute "$ENTRY_HEX" "$out"
}

# --- Step 2: TRUSTED key => HIT --------------------------------------------
CFG_TRUST="$TMP/trust.conf"
write_config "$CFG_TRUST" "$PUBKEY_P"
if run_substitute "$CFG_TRUST" "$TMP/out_trust" >/dev/null 2>&1; then
  [[ -f "$TMP/out_trust/artifact" ]] || \
    a2_fail "trusted substitute reported hit but did not materialise"
  a2_ok "TRUSTED key: substitute HIT + materialised"
else
  a2_fail "trusted-key substitute unexpectedly MISSED"
fi

# --- Step 3: UNTRUSTED (wrong) key => MISS ---------------------------------
CFG_WRONG="$TMP/wrong.conf"
write_config "$CFG_WRONG" "$PUBKEY_O"
if run_substitute "$CFG_WRONG" "$TMP/out_wrong" >/dev/null 2>&1; then
  a2_fail "untrusted-key substitute HIT — client trust check broken (SECURITY)"
fi
[[ ! -f "$TMP/out_wrong/artifact" ]] || \
  a2_fail "untrusted-key substitute materialised bytes (SECURITY)"
a2_ok "UNTRUSTED key: substitute MISS (validly-signed but not trusted)"

# --- Step 4: NO trust entry => MISS (default-untrusted) ---------------------
CFG_NONE="$TMP/none.conf"
write_config "$CFG_NONE" ""
if run_substitute "$CFG_NONE" "$TMP/out_none" >/dev/null 2>&1; then
  a2_fail "no-trust-entry substitute HIT — default-untrusted broken (SECURITY)"
fi
[[ ! -f "$TMP/out_none/artifact" ]] || \
  a2_fail "no-trust-entry substitute materialised bytes (SECURITY)"
a2_ok "NO trust entry: substitute MISS (default-untrusted enforced)"

a2_ok "t_r1_client_trust — config + client trust + default-untrusted verified"
