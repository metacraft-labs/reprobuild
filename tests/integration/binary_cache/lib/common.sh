#!/usr/bin/env bash
# Shared bash helpers for the A2 integration tests.
#
# Each t_a2_*.sh test starts an isolated in-process server (or talks
# to a previously-provisioned `repro-cache` distro per
# $REPRO_BINARY_CACHE_HOST). The helpers below abstract the
# bring-up/tear-down so individual tests stay short.

set -euo pipefail

a2_repo_root() {
  local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
  echo "$dir"
}

a2_daemon_binary() {
  local repo_root
  repo_root="$(a2_repo_root)"
  if [[ -n "${A2_DAEMON_BINARY:-}" ]]; then
    echo "$A2_DAEMON_BINARY"
    return
  fi
  # The Windows host build of the daemon lives here after a
  # successful `nim c -o:... apps/repro-binary-cache/...` invocation.
  echo "$repo_root/build/test-bin/repro_binary_cache.exe"
}

a2_pick_port() {
  # Pick a random port in 24000-31000 that's not currently bound.
  python3 -c '
import socket, random
random.seed()
for _ in range(50):
    p = random.randint(24000, 31000)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        s.close()
        print(p)
        raise SystemExit(0)
    except OSError:
        s.close()
raise SystemExit(1)
'
}

a2_start_server() {
  # Boots an in-process daemon under a unique state dir + port.
  # Sets globals: A2_PORT, A2_ROOT, A2_PID, A2_BASE_URL.
  if [[ -n "${REPRO_BINARY_CACHE_HOST:-}" ]]; then
    A2_BASE_URL="$REPRO_BINARY_CACHE_HOST"
    A2_REMOTE=1
    return
  fi
  A2_REMOTE=0
  A2_PORT="$(a2_pick_port)"
  A2_ROOT="$(mktemp -d -t rbc-itest-XXXXXX)"
  local daemon
  daemon="$(a2_daemon_binary)"
  if [[ ! -x "$daemon" ]] && [[ ! -f "$daemon" ]]; then
    echo "a2 daemon binary not found at $daemon; build with:" >&2
    echo "  nim c -o:build/test-bin/repro_binary_cache.exe apps/repro-binary-cache/repro_binary_cache.nim" >&2
    exit 1
  fi
  "$daemon" --root="$(cygpath -w "$A2_ROOT" 2>/dev/null || echo "$A2_ROOT")" \
            --listen="127.0.0.1:$A2_PORT" \
            >"$A2_ROOT/stderr.log" 2>&1 &
  A2_PID=$!
  A2_BASE_URL="http://127.0.0.1:$A2_PORT"
  # Wait up to 5 s for the bind.
  local i
  for i in $(seq 1 50); do
    if curl -fsS "$A2_BASE_URL/healthz" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
  echo "a2 daemon failed to bind on $A2_BASE_URL within 5s. Logs:" >&2
  cat "$A2_ROOT/stderr.log" >&2 || true
  kill -9 "$A2_PID" 2>/dev/null || true
  exit 1
}

a2_stop_server() {
  if [[ "${A2_REMOTE:-0}" == "1" ]]; then
    return
  fi
  if [[ -n "${A2_PID:-}" ]]; then
    kill "$A2_PID" 2>/dev/null || true
    wait "$A2_PID" 2>/dev/null || true
  fi
  if [[ -n "${A2_ROOT:-}" ]] && [[ -d "$A2_ROOT" ]]; then
    rm -rf "$A2_ROOT"
  fi
}

a2_have_python_helper() {
  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1
}

a2_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  else
    python "$@"
  fi
}

# Build + sign a fresh manifest + payload pair as a multipart form
# body, then POST it. Echoes the entry-key hex on success.
#
# Args:
#   $1 = package name
#   $2 = package version
#   $3 = payload bytes (the literal string)
#   $4 = optional dep entry-key hex (creates depReferences entry)
#
# Requires: A2_BASE_URL set; the daemon's --print-pubkey output AND
# a publishing helper. We use the daemon's signing-on-publish mode
# WITHOUT pulling a Nim test binary into bash by leveraging the
# repro_binary_cache "publish-helper" subcommand wired into the
# build/test-bin alongside the daemon (built once per A2 gate).
a2_publish_entry() {
  local pkg="$1"
  local ver="$2"
  local payload="$3"
  local depHex="${4:-}"
  local helper
  helper="$(a2_repo_root)/build/test-bin/a2_publish_helper.exe"
  if [[ ! -f "$helper" ]]; then
    echo "a2_publish_helper not built. Build with:" >&2
    echo "  nim c -o:build/test-bin/a2_publish_helper.exe tests/integration/binary_cache/lib/a2_publish_helper.nim" >&2
    return 1
  fi
  "$helper" --url="$A2_BASE_URL" \
            --package="$pkg" \
            --version="$ver" \
            --payload="$payload" \
            ${depHex:+--dep="$depHex"}
}

# Publish-and-pass-producer-header variant used by A4 P1's auto-release
# leg. The X-Repro-Producer header tells the server "release any
# sentinel held by ME on success". The A2/A2.5/A3 tests omit the
# header — the server's peer-addr fallback keeps semantics intact for
# legacy callers.
a2_publish_entry_with_producer() {
  local pkg="$1"
  local ver="$2"
  local payload="$3"
  local producer="$4"
  local depHex="${5:-}"
  local helper
  helper="$(a2_repo_root)/build/test-bin/a2_publish_helper.exe"
  if [[ ! -f "$helper" ]]; then
    echo "a2_publish_helper not built. Build with:" >&2
    echo "  nim c -o:build/test-bin/a2_publish_helper.exe tests/integration/binary_cache/lib/a2_publish_helper.nim" >&2
    return 1
  fi
  "$helper" --url="$A2_BASE_URL" \
            --package="$pkg" \
            --version="$ver" \
            --payload="$payload" \
            --producer="$producer" \
            ${depHex:+--dep="$depHex"}
}

a2_fetch_manifest_bytes() {
  local entryHex="$1"
  curl -fsS "$A2_BASE_URL/manifests/$entryHex"
}

a2_fetch_payload_bytes() {
  local hex="$1"
  curl -fsS "$A2_BASE_URL/payloads/$hex"
}

a2_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

a2_ok() {
  echo "PASS: $*"
}
