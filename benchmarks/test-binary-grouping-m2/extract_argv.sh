#!/usr/bin/env bash
# extract_argv.sh <build-report.json> <out-dir>
# Test-Binary-Grouping M2 harness. Writes one file per `nim c` action of the
# report (a `repro build ... --dry-run --write-report` of `.#test-builds` or
# `.#test-builds-per-file`), named after the binary it outputs, holding the
# action's argv one argument per line. These are the ENGINE'S OWN commands, so
# a cold compile measured with them is the compile `.#test-builds` performs.
set -euo pipefail
report="$1"; out="$2"; mkdir -p "$out"
jq -r '.actions[] | select((.argv // []) | index("c")) | select(.outputs[0] // "" | startswith("build/test-bin/"))
       | [(.outputs[0] | split("/") | last), (.argv | @json)] | @tsv' "$report" |
while IFS=$'\t' read -r stem argv; do
  printf '%s' "$argv" | jq -r '.[]' > "$out/$stem.argv"
done
ls "$out" | wc -l
