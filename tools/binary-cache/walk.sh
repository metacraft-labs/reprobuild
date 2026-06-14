#!/usr/bin/env bash
# walk.sh — A3 P8 closure-walk verifier for the R4 binary-cache chain.
#
# Counterpart to tools/bootstrap-cache/test_chain_walk.sh: walks the
# R4 chain end-to-end through binary-cache manifests instead of the
# legacy attestation envelopes. For the terminal step (tcc) it
# requests the closure substitute and verifies every manifest's
# signature + every dep reference resolves.
#
# Usage:
#   ./tools/binary-cache/walk.sh [server-url] [terminal-step-key]
#
# If <terminal-step-key> is omitted, we derive it from chain-amd64.json
# (terminal_step field). The server-url defaults to
# ${REPRO_BINARY_CACHE_URL:-http://localhost:7878}.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPECS_ROOT="$(cd "$REPO_ROOT/../reprobuild-specs" 2>/dev/null && pwd || true)"

SERVER_URL="${1:-${REPRO_BINARY_CACHE_URL:-http://localhost:7878}}"
TERMINAL_KEY="${2:-}"

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLI_BIN" ]]; then
  echo "walk.sh: CLI binary missing" >&2
  exit 2
fi

if [[ -z "$TERMINAL_KEY" ]]; then
  chain_json="${SPECS_ROOT}/recipes/bootstrap/tcc-chain/chain-amd64.json"
  if [[ ! -f "$chain_json" ]]; then
    echo "walk.sh: chain-amd64.json not found; pass <terminal-step-key>" >&2
    exit 2
  fi
  terminal_step="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(c.get("terminal_step", "tcc"))
' "$chain_json")"
  # Derive the terminal-step key the same way transcode-r4-chain.sh does.
  case "$(uname -s)" in
    Linux*) DEFAULT_HOST_OS=linux ; DEFAULT_HOST_ABI=gnu ;;
    Darwin*) DEFAULT_HOST_OS=darwin ; DEFAULT_HOST_ABI="" ;;
    MINGW*|MSYS*|CYGWIN*) DEFAULT_HOST_OS=windows ; DEFAULT_HOST_ABI=msvc ;;
    *) DEFAULT_HOST_OS=linux ; DEFAULT_HOST_ABI=gnu ;;
  esac
  export TRANSCODE_HOST_OS="${REPRO_HOST_OS:-$DEFAULT_HOST_OS}"
  export TRANSCODE_HOST_ABI="${REPRO_HOST_ABI:-$DEFAULT_HOST_ABI}"
  TERMINAL_KEY="$(python3 - "$chain_json" "$terminal_step" "$CLI_BIN" <<'PY'
import json, os, subprocess, sys
chain_path, terminal, cli = sys.argv[1:4]
host_os = os.environ.get("TRANSCODE_HOST_OS", "linux")
host_abi = os.environ.get("TRANSCODE_HOST_ABI", "gnu")
with open(chain_path) as f: c = json.load(f)
release = c.get("stage0_posix_release", "Release_1.9.1")
provider_rev = f"{c.get('chain_manifest_version','?')}/{release}/" \
               f"{c.get('stage0_posix_commit','')[:12]}"
name_to_key = {}
def derive(step, dep_keys):
    args = [cli, "derive-key",
            f"--package-name={step['name']}",
            f"--package-version=chain-amd64-{release}",
            "--platform-cpu=x86_64", f"--platform-os={host_os}",
            f"--platform-abi={host_abi}", "--platform-libc=",
            "--toolchain-name=stage0-posix",
            f"--toolchain-version={release}",
            "--toolchain-host-ldso=",
            f"--toolchain-extra=chain-amd64",
            f"--provider-revision={provider_rev}"]
    for d in dep_keys: args.append(f"--dep={d}")
    return subprocess.check_output(args, text=True).strip()
for step in c.get("steps", []):
    name = step["name"]
    deps = step.get("deps", []) or []
    dep_keys = []
    for d in deps:
        dn = d.get("step") or d.get("name") or ""
        if dn in name_to_key: dep_keys.append(name_to_key[dn])
    name_to_key[name] = derive(step, dep_keys)
print(name_to_key[terminal])
PY
)"
fi

echo "walk.sh: walking closure rooted at $TERMINAL_KEY against $SERVER_URL"

# Substitute the full closure to an ephemeral store + walk each manifest.
OUT_DIR="$(mktemp -d -t r4-walk-XXXXXX)"
REPRO_LOCAL_STORE="$(mktemp -d -t r4-walk-store-XXXXXX)"
export REPRO_LOCAL_STORE
trap 'rm -rf "$OUT_DIR" "$REPRO_LOCAL_STORE"' EXIT

REPRO_BINARY_CACHE_URL="$SERVER_URL" \
  "$CLI_BIN" substitute "$TERMINAL_KEY" "$OUT_DIR" 2>&1 || {
    echo "walk.sh: substitute failed for $TERMINAL_KEY" >&2
    exit 1
  }
echo "walk.sh: substitute closure succeeded; root materialised at $OUT_DIR"
echo "PASS: walk.sh"
