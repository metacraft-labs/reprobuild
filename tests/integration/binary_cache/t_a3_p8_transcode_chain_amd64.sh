#!/usr/bin/env bash
# t_a3_p8_transcode_chain_amd64.sh — A3 P8 transcoder gate.
#
# End-to-end exercise of the chain-amd64.json -> binary-cache manifest
# transcoder:
#   1. Boot an A2 cache server.
#   2. Generate a producer keypair.
#   3. Run tools/binary-cache/transcode-r4-chain.sh against
#      reprobuild-specs's chain-amd64.json.
#   4. Run tools/binary-cache/walk.sh; verify the terminal step
#      substitutes correctly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SPECS_ROOT="$(cd "$REPO_ROOT/../reprobuild-specs" 2>/dev/null && pwd || true)"
if [[ -z "$SPECS_ROOT" ]]; then
  echo "SKIP: reprobuild-specs repo not found at sibling path"
  exit 0
fi
CHAIN_JSON="$SPECS_ROOT/recipes/bootstrap/tcc-chain/chain-amd64.json"
if [[ ! -f "$CHAIN_JSON" ]]; then
  echo "SKIP: chain-amd64.json missing at $CHAIN_JSON"
  exit 0
fi

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLI_BIN" ]]; then
  a2_fail "CLI binary missing"
fi

a2_start_server
TMP="$(mktemp -d -t a3p8-XXXXXX)"
trap 'a2_stop_server; rm -rf "$TMP"' EXIT
KEY_PATH="$TMP/producer.key"
CERT_PATH="$TMP/producer.cert"
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" gen-key >/dev/null

export REPRO_BINARY_CACHE_URL="$A2_BASE_URL"
export REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH"
export REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH"
export REPRO_LOCAL_STORE="$TMP/client-store"
mkdir -p "$REPRO_LOCAL_STORE"

echo "=== transcoding chain-amd64.json -> binary-cache manifests ==="
bash "$REPO_ROOT/tools/binary-cache/transcode-r4-chain.sh" \
  "$CHAIN_JSON" "$A2_BASE_URL"

echo "=== walking the closure rooted at the terminal step ==="
bash "$REPO_ROOT/tools/binary-cache/walk.sh" "$A2_BASE_URL"

a2_ok "t_a3_p8_transcode_chain_amd64 — chain.json transcoded + walked"
