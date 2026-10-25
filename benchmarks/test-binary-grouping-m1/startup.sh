#!/usr/bin/env bash
# startup.sh <binary> <reps> <case-name>  -> "<stem> <case> <median wall ms> <median user+sys ms> <rc>"
# Runs `<binary> --run <case-name>` <reps> times, sequentially, with NIMTEST_RESULT_FILE.
b="$1"; reps="$2"; name="$3"
M="${M1_OUT:-build/m1-results}"; mkdir -p "$M"
T="${GNU_TIME:?set GNU_TIME to a GNU time binary}"
tmp=$(mktemp -d)
for i in $(seq "$reps"); do
  t0=$EPOCHREALTIME; NIMTEST_RESULT_FILE="$tmp/r.json" NIMTEST_OUTPUT_LVL=PRINT_ALL NIMTEST_COLOR=never \
    $T -o "$tmp/t" -f '%e %U %S %x' "$b" --run "$name" > /dev/null 2>&1 < /dev/null
  t1=$EPOCHREALTIME; echo "$(awk -v a=$t0 -v b=$t1 "BEGIN{print b-a}") $(tail -1 "$tmp/t" | cut -d" " -f2-)" >> "$tmp/all"
done
awk -v s="$(basename "$b")" -v n="$name" '{w[NR]=$1*1000; c[NR]=($2+$3)*1000; rc=$4}
  END{asort(w); asort(c); m=int((NR+1)/2); printf "%s\t%s\t%.0f\t%.0f\t%s\n", s, n, w[m], c[m], rc}' "$tmp/all"
rm -rf "$tmp"
