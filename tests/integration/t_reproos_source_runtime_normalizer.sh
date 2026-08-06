#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
normalizer="$repo_root/recipes/reproos-iso/scripts/normalize-source-runtime.sh"
patchelf_bin="$(command -v patchelf)"
true_bin="$(type -P true)"
host_loader="$("$patchelf_bin" --print-interpreter "$true_bin")"
host_glibc_dir="$(dirname "$host_loader")"

stage="$(mktemp -d -t reproos-source-runtime-test-XXXXXX)"
trap 'rm -rf "$stage"' EXIT

source_root="$stage/opt/repro/reprobuild/recipes/packages/source"
source_glibc_dir="$source_root/glibc/.repro/output/install/usr/lib64"
source_app_dir="$source_root/fixture/.repro/output/install/usr/bin"
runtime_helper="$stage/usr/lib/systemd/systemd-executor"
mkdir -p "$source_glibc_dir" "$source_app_dir" "$stage/usr/bin" \
  "$(dirname "$runtime_helper")"

cp -L "$host_loader" "$source_glibc_dir/ld-linux-x86-64.so.2"
cp -L "$host_glibc_dir/libc.so.6" "$source_glibc_dir/libc.so.6"
# The Nix-shell coreutils binary can use split runtime libraries in addition
# to libc. Mirror its complete transitive ldd set as fixture providers.
while IFS=$'\t' read -r needed provider; do
  [ -n "$needed" ] && [ -f "$provider" ] || continue
  needed="${needed##*/}"
  [ -e "$source_glibc_dir/$needed" ] || \
    cp -L "$provider" "$source_glibc_dir/$needed"
done < <(
  ldd "$true_bin" | sed -nE \
    's|^[[:space:]]*([^[:space:]]+)[[:space:]]+=>[[:space:]]+(/[^[:space:]]+).*$|\1\t\2|p'
)
cp "$true_bin" "$source_app_dir/fixture"
chmod u+w "$source_app_dir/fixture"
cp "$true_bin" "$runtime_helper"
chmod u+w "$runtime_helper"

for interpreter in bash sh perl python3 gawk; do
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$stage/usr/bin/$interpreter"
  chmod +x "$stage/usr/bin/$interpreter"
done

printf '%s\n' '#!/nix/store/test-bash/bin/bash' 'exit 0' \
  > "$source_app_dir/bash-script"
printf '%s\n' '#! /nix/store/test-perl/bin/perl -w' 'exit 0;' \
  > "$source_app_dir/perl-script"
printf '%s\n' '#!/usr/bin/env /nix/store/test-python/bin/python3' 'pass' \
  > "$source_app_dir/python-script"
printf '%s\n' '#!/run/current-system/sw/bin/gawk -f' '{ print }' \
  > "$source_app_dir/gawk-script"
chmod +x "$source_app_dir"/*-script

bootstrap_loader=/nix/store/test-glibc-2.1/lib/ld-linux-x86-64.so.2
source_loader=/opt/repro/reprobuild/recipes/packages/source/glibc/.repro/output/install/usr/lib64/ld-linux-x86-64.so.2
"$patchelf_bin" --set-interpreter "$bootstrap_loader" "$source_app_dir/fixture"
"$patchelf_bin" --set-interpreter "$bootstrap_loader" "$runtime_helper"

# An unknown store interpreter must fail the complete preflight without
# modifying an otherwise valid ELF or script.
printf '%s\n' '#!/nix/store/test-ruby/bin/ruby' 'exit 0' \
  > "$source_app_dir/unknown-script"
chmod +x "$source_app_dir/unknown-script"
if bash "$normalizer" "$stage" "$source_root" "$source_loader"; then
  echo "normalizer accepted an unknown runtime interpreter" >&2
  exit 1
fi
test "$("$patchelf_bin" --print-interpreter "$source_app_dir/fixture")" = \
  "$bootstrap_loader"
test "$("$patchelf_bin" --print-interpreter "$runtime_helper")" = \
  "$bootstrap_loader"
test "$(head -n1 "$source_app_dir/bash-script")" = \
  '#!/nix/store/test-bash/bin/bash'

rm "$source_app_dir/unknown-script"
bash "$normalizer" "$stage" "$source_root" "$source_loader"

test "$("$patchelf_bin" --print-interpreter "$source_app_dir/fixture")" = \
  "$source_loader"
test "$("$patchelf_bin" --print-interpreter "$runtime_helper")" = \
  "$source_loader"
test "$(head -n1 "$source_app_dir/bash-script")" = '#!/usr/bin/bash'
test "$(head -n1 "$source_app_dir/perl-script")" = '#!/usr/bin/perl -w'
test "$(head -n1 "$source_app_dir/python-script")" = '#!/usr/bin/python3'
test "$(head -n1 "$source_app_dir/gawk-script")" = '#!/usr/bin/gawk -f'

if grep -RIlE '^#!.*(/nix/store/|/repro/store/|/run/current-system/sw/)' \
    "$source_root" >/dev/null; then
  echo "runtime store shebang remained after normalization" >&2
  exit 1
fi
