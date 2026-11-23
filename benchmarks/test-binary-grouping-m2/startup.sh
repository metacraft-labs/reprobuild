#!/usr/bin/env bash
# startup.sh <binary> <reps>  -> "<stem> <median wall ms>"
# Module initialisation only: an unknown --run name initialises every module
# and exits with "test not found".
b="$1"; reps="$2"; tmp=$(mktemp -d)
for i in $(seq "$reps"); do
  t0=$EPOCHREALTIME
  NIMTEST_RESULT_FILE="$tmp/r.json" "$b" --run 'no such suite::no such test' > /dev/null 2>&1 < /dev/null
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f\n", (b-a)*1000}'
done | sort -n | awk -v s="$(basename "$b")" '{v[NR]=$1} END{print s, v[int((NR+1)/2)]}'
rm -rf "$tmp"
