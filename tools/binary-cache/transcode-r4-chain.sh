#!/usr/bin/env bash
# transcode-r4-chain.sh — A3 P8 one-shot transcoder.
#
# Walks recipes/bootstrap/tcc-chain/chain-amd64.json from the specs
# repo, derives a binary-cache CacheEntryKey for every step, and
# publishes a minimal binary-cache manifest pointing at the upstream
# blob's sha256 (carried verbatim from the chain JSON).
#
# Usage:
#   ./tools/binary-cache/transcode-r4-chain.sh <chain-amd64.json> [server-url]
#
# Defaults: server-url = ${REPRO_BINARY_CACHE_URL:-http://localhost:7878}.
#
# Required env (same as the build-script postlude):
#   REPRO_BINARY_CACHE_KEY_PATH    ECDSA-P256 producer private key
#   REPRO_BINARY_CACHE_CERT_PATH   matching public key
#
# This script does NOT re-acquire the upstream blobs; it publishes
# zero-byte "placeholder" payloads so the manifest envelope verifies.
# The expected use case is "populate a fresh binary cache with the
# R4 manifest skeleton so the build-script substitute path can land
# on existing entries when blobs arrive via the standard rebuild
# pipeline." For full byte transcoding, run the actual build scripts
# (build-hex0.sh / build-stage0-posix.sh / ...) which publish the
# bytes via their postlude.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHAIN_JSON="${1:?usage: transcode-r4-chain.sh <chain-amd64.json> [server-url]}"
SERVER_URL="${2:-${REPRO_BINARY_CACHE_URL:-http://localhost:7878}}"

if [[ -z "${REPRO_BINARY_CACHE_KEY_PATH:-}" ||
      -z "${REPRO_BINARY_CACHE_CERT_PATH:-}" ]]; then
  echo "transcode-r4-chain.sh: REPRO_BINARY_CACHE_KEY_PATH + " \
       "REPRO_BINARY_CACHE_CERT_PATH must be set" >&2
  exit 2
fi

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLI_BIN" ]]; then
  echo "transcode-r4-chain.sh: CLI binary missing; build with:" >&2
  echo "  nim c -o:build/test-bin/repro_binary_cache_client_cli.exe \\" >&2
  echo "    apps/repro-binary-cache-client/repro_binary_cache_client_cli.nim" >&2
  exit 2
fi

# Host-platform detection: the transcoder defaults to linux/gnu (the
# native R4 target) but accepts overrides via $REPRO_HOST_OS / $REPRO_HOST_ABI
# so a Windows sandbox host can transcode + walk locally without
# tripping the substitute compat-check.
case "$(uname -s)" in
  Linux*) DEFAULT_HOST_OS=linux ; DEFAULT_HOST_ABI=gnu ;;
  Darwin*) DEFAULT_HOST_OS=darwin ; DEFAULT_HOST_ABI="" ;;
  MINGW*|MSYS*|CYGWIN*) DEFAULT_HOST_OS=windows ; DEFAULT_HOST_ABI=msvc ;;
  *) DEFAULT_HOST_OS=linux ; DEFAULT_HOST_ABI=gnu ;;
esac
export TRANSCODE_HOST_OS="${REPRO_HOST_OS:-$DEFAULT_HOST_OS}"
export TRANSCODE_HOST_ABI="${REPRO_HOST_ABI:-$DEFAULT_HOST_ABI}"

# Use python to parse the JSON + iterate the steps.
python3 - "$CHAIN_JSON" "$SERVER_URL" "$CLI_BIN" <<'PY'
import json, os, subprocess, sys, tempfile

chain_path, server_url, cli_bin = sys.argv[1:4]
host_os = os.environ.get("TRANSCODE_HOST_OS", "linux")
host_abi = os.environ.get("TRANSCODE_HOST_ABI", "gnu")
with open(chain_path, "r", encoding="utf-8") as f:
    chain = json.load(f)

stage0_release = chain.get("stage0_posix_release", "Release_1.9.1")
provider_rev = f"{chain.get('chain_manifest_version','?')}/{stage0_release}/" \
               f"{chain.get('stage0_posix_commit','')[:12]}"

def derive_key(step, dep_keys):
    args = [
        cli_bin, "derive-key",
        f"--package-name={step['name']}",
        f"--package-version=chain-amd64-{stage0_release}",
        "--platform-cpu=x86_64",
        f"--platform-os={host_os}",
        f"--platform-abi={host_abi}",
        "--platform-libc=",
        "--toolchain-name=stage0-posix",
        f"--toolchain-version={stage0_release}",
        "--toolchain-host-ldso=",
        f"--toolchain-extra=chain-amd64",
        f"--provider-revision={provider_rev}",
    ]
    for dep in dep_keys:
        args.append(f"--dep={dep}")
    out = subprocess.check_output(args, text=True).strip()
    return out

name_to_key = {}
ordered = chain.get("steps", [])
published = 0
for step in ordered:
    name = step["name"]
    deps = step.get("deps", []) or []
    dep_keys = []
    for d in deps:
        dep_name = d.get("step") or d.get("name") or ""
        if dep_name in name_to_key:
            dep_keys.append(name_to_key[dep_name])
    key = derive_key(step, dep_keys)
    name_to_key[name] = key
    # Publish a placeholder prefix containing the step's name +
    # canonical sha256.
    with tempfile.TemporaryDirectory(prefix="r4-transcode-") as tmp:
        out_blob = os.path.join(tmp, "blob")
        with open(out_blob, "w", encoding="utf-8") as f:
            f.write(f"placeholder for {name}; "
                    f"upstream-sha={step['output']['artifact_sha256']}\n")
        args = [
            cli_bin, "publish", key, out_blob,
            f"--package-name={name}",
            f"--package-version=chain-amd64-{stage0_release}",
            "--platform-cpu=x86_64",
            f"--platform-os={host_os}",
            f"--platform-abi={host_abi}",
            "--platform-libc=",
            "--toolchain-name=stage0-posix",
            f"--toolchain-version={stage0_release}",
            "--toolchain-host-ldso=",
            f"--toolchain-extra=chain-amd64",
            f"--provider-revision={provider_rev}",
        ]
        for dep in dep_keys:
            args.append(f"--dep={dep}")
        env = dict(os.environ)
        env["REPRO_BINARY_CACHE_URL"] = server_url
        try:
            subprocess.check_call(args, env=env)
            published += 1
            print(f"  -> step={name}  key={key}")
        except subprocess.CalledProcessError as e:
            print(f"  ! publish failed for step={name}: {e}", file=sys.stderr)

print(f"\nTranscoded + published {published}/{len(ordered)} chain entries to {server_url}")
PY
