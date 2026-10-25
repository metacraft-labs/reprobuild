#!/usr/bin/env bash
# runcases.sh <binary> <resultdir>  — M1 correctness harness.
# Lists cases with --list-json, then runs each case in its own process with
# --run <name> and NIMTEST_RESULT_FILE, exactly as repro_test_runner does.
# Writes <resultdir>/<stem>.list.json and <stem>.cases.tsv:
#   file  name  exit  docstatus  ms
# cwd must be the repo root. Cases run sequentially (concurrency is across binaries).
set -u
b="$1"; rd="$2"; stem="$(basename "$b")"
mkdir -p "$rd/docs"
export NIMTEST_OUTPUT_LVL=PRINT_ALL NIMTEST_COLOR=never
timeout 300 "$b" --list-json > "$rd/$stem.list.json" 2> "$rd/$stem.list.err"
echo "$?" > "$rd/$stem.list.exit"
: > "$rd/$stem.cases.tsv"
jq -r '.tests[] | [.file, .name] | @tsv' "$rd/$stem.list.json" 2>/dev/null |
while IFS=$'\t' read -r file name; do
  safe="$(printf '%s' "$stem::$name" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-200)"
  doc="$rd/docs/$safe.json"; rm -f "$doc"
  t0=$EPOCHREALTIME
  NIMTEST_RESULT_FILE="$doc" timeout 900 "$b" --run "$name" > "$rd/docs/$safe.out" 2>&1 < /dev/null
  rc=$?
  t1=$EPOCHREALTIME
  st="$(jq -r '.status // "NODOC"' "$doc" 2>/dev/null || echo NODOC)"
  [ -z "$st" ] && st=NODOC
  ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d", (b-a)*1000}')
  printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$file")" "$name" "$rc" "$st" "$ms" >> "$rd/$stem.cases.tsv"
done
