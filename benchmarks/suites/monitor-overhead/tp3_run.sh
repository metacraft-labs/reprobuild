#!/usr/bin/env bash
# Engine-Threadpool TP-3 acceptance driver.
#
# HM-6's driver with a THIRD arm and a rotating (rather than alternating)
# order. The arms are:
#
#   wrapped        the spawned `repro internal io monitor` form, today's
#                  default. It contains none of the threadpool code, so it is
#                  also the DRIFT CONTROL: it should move only with machine
#                  load.
#   hosted-serial  in-process hosting with the settle pass BLOCKING on each
#                  finish — the shape hosting had before TP-2 moved
#                  `finishMonitor` onto a pool worker.
#   hosted-pooled  in-process hosting with TP-2's worker tenancy.
#
# All three are the same binary and the same graph. `hosted-serial` differs
# from `hosted-pooled` by one environment variable
# (`REPROBUILD_FORCE_SERIAL_MONITOR_FINISH`, read once by the engine) and
# `wrapped` differs from both by one config field, so no arm is a comparison
# of two builds.
#
# The order ROTATES by round (wrapped/serial/pooled, then
# serial/pooled/wrapped, then pooled/wrapped/serial), so over three rounds
# every arm runs first, second and third once and a machine that drifts
# during the run drifts through all three.
#
# Every arm-round gets a fresh cache root and a fresh work tree, so no action
# is ever served from the action cache and every measured round really
# executes every action.
#
# Exit codes are written to files and read back on their own line; nothing
# here reads a status through a pipe.
#
# Build the harness first — `just build` does NOT build it and neither does
# the graph. See the header of hm6_run.sh for the build line.
#
# Usage (defaults in brackets):
#   REPO=<reprobuild root> ROUNDS=[3] PARALLELISM=[8] ACTIONS=[60] \
#   STRIDE=[13] WORK=[real|trivial] WORKERS=[<engine default>] \
#   TAG=[p$PARALLELISM] OUT=[<dir>] \
#     bash benchmarks/suites/monitor-overhead/tp3_run.sh
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BIN="$REPO/build/test-bin/hm6_acceptance"
ROUNDS="${ROUNDS:-3}"
PARALLELISM="${PARALLELISM:-8}"
ACTIONS="${ACTIONS:-60}"
STRIDE="${STRIDE:-13}"
WORK="${WORK:-real}"
WORKERS="${WORKERS:-}"
ARMS="${ARMS:-wrapped hosted-serial hosted-pooled}"
TAG="${TAG:-p$PARALLELISM}"
RUNS="${OUT:-$REPO/build/test-tmp/tp3-acceptance}/$TAG"

if [ ! -x "$BIN" ]; then
  echo "no harness at $BIN; see the build line in hm6_run.sh's header" >&2
  exit 2
fi

rm -rf "$RUNS"
mkdir -p "$RUNS"

read -r -a ARM_LIST <<< "$ARMS"
NARMS=${#ARM_LIST[@]}

for r in $(seq 1 "$ROUNDS"); do
  order=()
  for i in $(seq 0 $((NARMS - 1))); do
    order+=("${ARM_LIST[$(( (i + r - 1) % NARMS ))]}")
  done
  for arm in "${order[@]}"; do
    runroot="$RUNS/r$r-$arm"
    rm -rf "$runroot"
    mkdir -p "$runroot" "$runroot/tmp"
    # A fresh TMPDIR per arm-round makes io-mon's per-action shared-memory
    # fragment directories countable: it creates one per monitored action
    # under $TMPDIR and removes it at finish. The count is only trustworthy
    # when an action outlives the poll interval below — a real compile does;
    # a ~10 ms trivial action does not, and undercounts.
    (
      while [ ! -f "$runroot/DONE" ]; do
        ls "$runroot/tmp" 2>/dev/null \
          | grep '^repro-fs-snoop-fragments' >> "$runroot/fragdirs.raw" 2>/dev/null
        sleep 0.02
      done
    ) &
    poller=$!
    cd "$REPO" || exit 1
    if [ -n "$WORKERS" ]; then
      export REPROBUILD_ENGINE_POOL_WORKERS="$WORKERS"
    else
      unset REPROBUILD_ENGINE_POOL_WORKERS
    fi
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
    printf 'r%s %-13s rc=%s chains=%s  %s\n' \
      "$r" "$arm" "$(cat "$runroot/rc")" "$distinct" \
      "$(cat "$runroot/stdout.txt")"
    # Let the machine settle between arms so none inherits more of another's
    # page-cache pressure than the others do.
    sleep 3
  done
done
