#!/usr/bin/env bash
# prepare_jobs.sh <graph-test-builds.json> <graph-test-builds-per-file.json> <out-dir> <group>...
# (cwd = repo root, inside nix develop; needs jq)
#
# For each named group: writes the group module exactly as the graph's
# `writeText` edge would (its `builtinText`), and one argv file per compile --
# the group's from `.#test-builds`, each member's own from
# `.#test-builds-per-file` -- taken verbatim from `repro graph --format=json`.
# Then prints a job list "<variant> <argv-file>", group and per-file jobs
# interleaved by a stable hash so both see the same host load.
set -euo pipefail
tb="$1"; pf="$2"; out="$3"; shift 3
mkdir -p "$out/argv"
: > "$out/jobs.unsorted"
for g in "$@"; do
  jq -r --arg g "$g" '.actions[] | select(.id == "reprobuild.test_group_module." + $g) | .builtinText' "$tb" > "build/test-groups/$g.nim.tmp"
  [ -s "build/test-groups/$g.nim.tmp" ] || { echo "no module edge for $g" >&2; exit 1; }
  mv "build/test-groups/$g.nim.tmp" "build/test-groups/$g.nim"
  jq -r --arg o "build/test-bin/$g" '.actions[] | select(.outputs[0] == $o) | .argv[]' "$tb" > "$out/argv/$g.argv"
  echo "grouped $out/argv/$g.argv" >> "$out/jobs.unsorted"
  sed -n 's#^import "\.\./\.\./\(.*\)"$#\1#p' "build/test-groups/$g.nim" | while read -r m; do
    stem="$(basename "$m")"
    jq -r --arg o "build/test-bin/$stem" '.actions[] | select(.outputs[0] == $o) | .argv[]' "$pf" > "$out/argv/$stem.argv"
    [ -s "$out/argv/$stem.argv" ] || { echo "no per-file compile for $stem" >&2; exit 1; }
    echo "perfile $out/argv/$stem.argv" >> "$out/jobs.unsorted"
    echo "$g $m" >> "$out/members.tsv"
  done
done
while read -r v a; do printf '%s %s %s\n' "$(printf '%s' "$a" | sha1sum | cut -c1-8)" "$v" "$a"; done < "$out/jobs.unsorted" | sort | cut -d' ' -f2- > "$out/jobs.txt"
wc -l < "$out/jobs.txt"
