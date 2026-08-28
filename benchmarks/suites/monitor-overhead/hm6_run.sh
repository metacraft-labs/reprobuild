#!/usr/bin/env bash
# HM-6 acceptance driver — In-Process-Monitor-Hosting.
#
# Interleaves the hosted and wrapped arms INSIDE each round and alternates
# which arm goes first, so a machine that drifts during the run drifts through
# both arms rather than through one. The wrapped arm contains no hosting code
# and is therefore the drift control: it should move only with machine load.
#
# Every round gets a fresh cache root and a fresh work tree, so no action is
# ever served from the action cache and every measured round really executes
# every action.
#
# Exit codes are written to files and read back on their own line; nothing
# here reads a status through a pipe.
#
# Build the harness first — `just build` does NOT build test binaries, and
# this one is not in the graph either:
#
#   nim c --threads:on --hints:off --warnings:off \
#     --out:build/test-bin/hm6_acceptance \
#     --nimcache:build/nimcache/hm6_acceptance \
#     benchmarks/suites/monitor-overhead/hm6_acceptance.nim
#
# add the `--passL:-Wl,-rpath,<dir>` entries repro.nim's
# nixRuntimePassLForLibraries() derives for libclingo/libzstd, and run the
# whole thing under `direnv exec <repo>` or the link fails on -lcrypto.
#
# Usage (defaults in brackets):
#   REPO=<reprobuild root> ROUNDS=[3] PARALLELISM=[8] ACTIONS=[60] \
#   STRIDE=[13] WORK=[real|trivial] TAG=[p$PARALLELISM] OUT=[<dir>] \
#     bash benchmarks/suites/monitor-overhead/hm6_run.sh
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BIN="$REPO/build/test-bin/hm6_acceptance"
ROUNDS="${ROUNDS:-3}"
PARALLELISM="${PARALLELISM:-8}"
ACTIONS="${ACTIONS:-60}"
STRIDE="${STRIDE:-13}"
WORK="${WORK:-real}"
TAG="${TAG:-p$PARALLELISM}"
RUNS="${OUT:-$REPO/build/test-tmp/hm6-acceptance}/$TAG"

if [ ! -x "$BIN" ]; then
  echo "no harness at $BIN; see the build line in this script's header" >&2
  exit 2
fi

rm -rf "$RUNS"
mkdir -p "$RUNS"

for r in $(seq 1 "$ROUNDS"); do
  if (( r % 2 == 1 )); then order="hosted wrapped"; else order="wrapped hosted"; fi
  for arm in $order; do
    runroot="$RUNS/r$r-$arm"
    rm -rf "$runroot"
    mkdir -p "$runroot" "$runroot/tmp"
    # A fresh TMPDIR per arm-round makes io-mon's per-action shared-memory
    # fragment directories countable: it creates one per monitored action
    # under $TMPDIR and removes it at finish, so a poller sampling the
    # directory counts the chains a run created. The count is only
    # trustworthy when an action outlives the poll interval below — a real
    # compile does; a ~10 ms trivial action does not, and undercounts.
    (
      while [ ! -f "$runroot/DONE" ]; do
        ls "$runroot/tmp" 2>/dev/null \
          | grep '^repro-fs-snoop-fragments' >> "$runroot/fragdirs.raw" 2>/dev/null
        sleep 0.02
      done
    ) &
    poller=$!
    cd "$REPO" || exit 1
    TMPDIR="$runroot/tmp" "$BIN" \
      --repo="$REPO" \
      --arm="$arm" \
      --parallelism="$PARALLELISM" \
      --actions="$ACTIONS" \
      --stride="$STRIDE" \
      --work="$WORK" \
      --runroot="$runroot" \
      --out="$runroot/record.json" \
      > "$runroot/stdout.txt" 2> "$runroot/stderr.txt"
    echo $? > "$runroot/rc"
    touch "$runroot/DONE"
    wait "$poller" 2>/dev/null
    distinct=$(sort -u "$runroot/fragdirs.raw" 2>/dev/null | wc -l)
    echo "$distinct" > "$runroot/distinct-chains"
    printf 'r%s %-7s rc=%s chains=%s  %s\n' \
      "$r" "$arm" "$(cat "$runroot/rc")" "$distinct" \
      "$(cat "$runroot/stdout.txt")"
    # Let the machine settle between arms so neither inherits more of the
    # other's page-cache pressure than the other does.
    sleep 3
  done
done
