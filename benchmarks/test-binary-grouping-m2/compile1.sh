#!/usr/bin/env bash
# compile1.sh <argv-file> <variant>   (cwd = repo root, inside nix develop)
# One cold compile with the engine's argv: fresh nimcache, plus
# --parallelBuild:1 so that N concurrent compiles mean N C compilers (the argv
# sets none, so each `nim c` would otherwise start one C job per CPU). CPU is
# user+sys of `nim c` and its waited-for C compiler children (GNU time).
set -u
M="${M2_OUT:-build/m2-results}"; mkdir -p "$M/logs/$2"
argvf="$1"; v="$2"; stem="$(basename "$argvf" .argv)"
mapfile -t A < "$argvf"
nc=""; for a in "${A[@]}"; do case "$a" in --nimcache:*) nc="${a#--nimcache:}";; esac; done
[ -n "$nc" ] && rm -rf "$nc"
GNU_TIME="${GNU_TIME:?set GNU_TIME to a GNU time binary (nixpkgs#time)}"
start=$(date +%s)
"$GNU_TIME" -o "$M/logs/$v/$stem.time" -f '%e %U %S %M %x' \
  "${A[@]:0:2}" --parallelBuild:1 "${A[@]:2}" > "$M/logs/$v/$stem.log" 2>&1
rc=$?
load=$(cut -d' ' -f1 /proc/loadavg)
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$stem" "$(tail -1 "$M/logs/$v/$stem.time")" "$rc" "$start" "$load" >> "$M/compile-results.tsv"
