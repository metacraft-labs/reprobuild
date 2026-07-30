#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
relocate="$repo_root/recipes/reproos-iso/scripts/relocate-nix-to-repro.sh"
patchelf_bin="$(command -v patchelf)"
true_bin="$(type -P true)"
host_loader="$($patchelf_bin --print-interpreter "$true_bin")"
host_glibc_dir="$(dirname "$host_loader")"

stage="$(mktemp -d -t reproos-source-glibc-test-XXXXXX)"
trap 'rm -rf "$stage"' EXIT

source_root="$stage/opt/repro/reprobuild/recipes/packages/source"
source_glibc_dir="$source_root/glibc/.repro/output/install/usr/lib64"
source_app_dir="$source_root/fixture/.repro/output/install/usr/bin"
bootstrap_dir="$stage/nix/store/test-glibc-2.40-1/lib"
mkdir -p "$source_glibc_dir" "$source_app_dir" "$bootstrap_dir" \
  "$stage/usr/bin"

cp -L "$host_loader" "$source_glibc_dir/ld-linux-x86-64.so.2"
cp -L "$host_glibc_dir/libc.so.6" "$source_glibc_dir/libc.so.6"
cp -L "$host_loader" "$bootstrap_dir/ld-linux-x86-64.so.2"
cp -L "$host_glibc_dir/libc.so.6" "$bootstrap_dir/libc.so.6"
cp "$true_bin" "$source_app_dir/fixture"
cp "$true_bin" "$stage/usr/bin/reproos-installer"
chmod u+w "$source_app_dir/fixture" "$stage/usr/bin/reproos-installer"

for source_elf in "$source_app_dir/fixture" \
                  "$stage/usr/bin/reproos-installer"; do
  $patchelf_bin --set-interpreter \
    /nix/store/test-glibc-2.40-1/lib/ld-linux-x86-64.so.2 "$source_elf"
done

source_loader=/opt/repro/reprobuild/recipes/packages/source/glibc/.repro/output/install/usr/lib64/ld-linux-x86-64.so.2
bash "$relocate" "$stage" "$source_root" "$source_loader"

for source_elf in "$source_app_dir/fixture" \
                  "$stage/usr/bin/reproos-installer"; do
  test "$($patchelf_bin --print-interpreter "$source_elf")" = "$source_loader"
  case ":$($patchelf_bin --print-rpath "$source_elf"):" in
    *":${source_loader%/*}:"*) ;;
    *) echo "source glibc directory missing from $source_elf RPATH" >&2; exit 1 ;;
  esac
done
