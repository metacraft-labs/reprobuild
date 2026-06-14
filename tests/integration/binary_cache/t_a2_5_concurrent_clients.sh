#!/usr/bin/env bash
# t_a2_5_concurrent_clients.sh — ReproOS-Generations-And-Foreign-Packages
# A2.5 multi-user gate.
#
# Spec § Substitution daemon and concurrency:
#
#   Two `repro build` invocations concurrently from different shells.
#   Both request the same closure substitution. Daemon serves both
#   with ONE underlying fetch (no duplicate download).
#
# This integration test wraps the Nim-side concurrency runner
# (``tests/integration/binary_cache/lib/a2_5_concurrent_runner.nim``)
# which spins up the A2 server, builds the substitute service +
# real-IPC daemon shell, fires two concurrent ``substituteViaDaemon``
# calls from independent threads through the named-pipe / AF_UNIX
# endpoint, and asserts:
#
#   * Both clients see the same realized prefix paths (one CAS write).
#   * The daemon's request counter incremented twice (two real IPC
#     frames).
#   * Exactly ONE client reports ``totalBytesFetched > 0`` (the other
#     hits the warm-cache skipped path behind the single-writer lock).
#
# This is the closed equivalent of "exactly one curl HTTP/2 stream
# against the cache server" for the daemon's local accounting: the
# daemon's internal CAS-write counter is the ground-truth signal a
# bash test can observe portably.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

runner="$REPO_ROOT/build/test-bin/a2_5_concurrent_runner.exe"
if [[ ! -f "$runner" ]]; then
  echo "a2_5 concurrent runner not built. Build with:" >&2
  echo "  nim c --threads:on -o:build/test-bin/a2_5_concurrent_runner.exe \\" >&2
  echo "    tests/integration/binary_cache/lib/a2_5_concurrent_runner.nim" >&2
  exit 1
fi

# Surface the runner's stdout/stderr so any failure (the runner exits
# non-zero on assertion failure) lands in the test log unmodified.
"$runner"
echo "PASS: t_a2_5_concurrent_clients — two parallel substitute clients " \
     "shared one underlying CAS write through the daemon's single-writer lock"
