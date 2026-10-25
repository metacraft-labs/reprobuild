#!/usr/bin/env bash
# compile1.sh <variant> <source>   (cwd = repo root, inside nix develop)
# M1 cold compile: fresh nimcache, the .#test-builds argv + --parallelBuild:1.
set -u
M="${M1_OUT:-build/m1-results}"; mkdir -p "$M"
v="$1"; src="$2"; stem="$(basename "$src" .nim)"
nc="build/m1-nc/$v/$stem"; out="build/m1/$v/$stem"
rm -rf "$nc"; mkdir -p "$nc" "build/m1/$v" "$M/logs/$v"
mapfile -t F < "$(dirname "$0")/nimflags.txt"
NIM="${NIM:-$(command -v nim)}"  # the dev shell's nim-fork-2.3.1-codetracer
GNU_TIME="${GNU_TIME:?set GNU_TIME to a GNU time binary (nixpkgs#time)}"
start=$(date +%s)
"$GNU_TIME" -o "$M/logs/$v/$stem.time" -f '%e %U %S %M %x' \
  "$NIM" c "${F[@]}" --parallelBuild:1 "--nimcache:$nc" "--out:$out" "$src" > "$M/logs/$v/$stem.log" 2>&1
rc=$?
load=$(cut -d' ' -f1 /proc/loadavg)
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$stem" "$(cat "$M/logs/$v/$stem.time" | tail -1)" "$rc" "$start" "$load" >> "$M/compile-results.tsv"
