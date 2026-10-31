#!/usr/bin/env bash
# Build the statically linked add-on `repro` and write its SHA-256.
#
#   scripts/build_addon_static.sh [--mutation NAME] [--test-seams] [--out DIR] ARCH...
#
# ARCH is one of x86_64 / amd64, aarch64 / arm64, armv7l / armhf. Each
# artefact lands at <out>/<debian-arch>/repro (default out: build/addon),
# with <out>/<debian-arch>/repro.sha256 and one SHA256SUMS for every
# artefact the run built. Those digest files are what "published SHA-256"
# means for the add-on's bootstrap binary: the release workflow attaches the
# artefacts together with SHA256SUMS, and an operator pins the digest on the
# command line that fetches and runs the binary (`sha256sum -c` before the
# first exec).
#
# WHY A SEPARATE BINARY. The full engine (`apps/repro`) cannot be linked
# statically: it dlopens its solver library at start-up and links TLS. An
# add-on host must keep working when a distribution release upgrade replaces
# the host's libc, so the add-on carries a musl-static binary of its own,
# built from `apps/repro-addon` (the add-on verbs plus the system-scope apply
# path).
#
# TOOLCHAINS come from this flake's pinned nixpkgs (`--inputs-from .`):
# `pkgsStatic` (x86_64) and `pkgsCross.<platform>.pkgsStatic` (aarch64,
# armv7l) -- musl, static sqlite. The Nim compiler and the Nim source paths
# come from the reprobuild dev shell, which this script must run in.
#
# --mutation NAME builds a deliberately broken variant for a gate's
# falsifying run (see libs/repro_addon/src/repro_addon/mutations.nim). It
# goes to build/addon-mutations/NAME/<arch>/ and is never published.
#
# --test-seams builds the variant with the switch's pause points compiled
# in (libs/repro_addon/src/repro_addon/seams.nim), for the gates that stop a
# switch at a step to reset the guest or change the host under it. It goes
# to build/addon-seams/<arch>/ (build/addon-seams-mutations/NAME/<arch>/
# together with --mutation) and is never published either.
#
# VERIFICATION. Every artefact is checked to be statically linked before
# its digest is written: `file` must say "statically linked", the ELF must
# have no PT_INTERP program header, and `ldd` must refuse it. A failure
# leaves no artefact and no digest behind.
set -euo pipefail

cd "$(dirname "$0")/.."

mutation=""
seams=""
out=""
arches=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mutation) mutation="$2"; shift 2 ;;
    --mutation=*) mutation="${1#--mutation=}"; shift ;;
    --test-seams) seams=1; shift ;;
    --out) out="$2"; shift 2 ;;
    --out=*) out="${1#--out=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) echo "build_addon_static: unknown option $1" >&2; exit 2 ;;
    *) arches+=("$1"); shift ;;
  esac
done
if [ ${#arches[@]} -eq 0 ]; then
  echo "build_addon_static: name at least one architecture" >&2
  exit 2
fi
if [ -z "$out" ]; then
  if [ -n "$seams" ] && [ -n "$mutation" ]; then out="build/addon-seams-mutations/$mutation"
  elif [ -n "$seams" ]; then out="build/addon-seams"
  elif [ -n "$mutation" ]; then out="build/addon-mutations/$mutation"
  else out="build/addon"; fi
fi
# One build per output directory at a time: concurrent gate runs from the
# same checkout share it and its nimcache. The artefact itself is replaced
# by a rename, so a run that is reading it never sees it missing or half
# written (it used to be deleted first; reprobuild-pm issue
# 2026-10-31-addon-gate-runs-race-on-the-shared-static-artefact).
mkdir -p "$out"
exec 9>"$out/.build.lock"
flock 9

# THE BUILD PATH. The artefact does not depend on where the checkout lives:
# the Nim compiler hashes types by their canonical module path (the fork,
# metacraft-labs/nim a0fabc99, `sighashes.typeHashPath`; it used to hash the
# absolute path), and the C compiler maps the checkout out of `__FILE__`
# (`-ffile-prefix-map`, below). scripts/check_addon_static_reproducible.sh
# builds a commit at two paths and requires identical bytes.

command -v nim >/dev/null || {
  echo "build_addon_static: nim is not on PATH; run inside the reprobuild dev shell (nix develop)" >&2
  exit 2
}

nix_attr_prefix() {
  case "$1" in
    amd64) echo "pkgsStatic" ;;
    arm64) echo "pkgsCross.aarch64-multiplatform.pkgsStatic" ;;
    armhf) echo "pkgsCross.armv7l-hf-multiplatform.pkgsStatic" ;;
  esac
}
nim_cpu() {
  case "$1" in amd64) echo amd64 ;; arm64) echo arm64 ;; armhf) echo arm ;; esac
}
elf_machine_word() {
  case "$1" in amd64) echo "x86-64" ;; arm64) echo "aarch64" ;; armhf) echo "ARM" ;; esac
}

mkdir -p "$out"
sums="$out/SHA256SUMS"
: > "$sums.tmp"
for raw in "${arches[@]}"; do
  case "$raw" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armhf|armv7) arch=armhf ;;
    *) echo "build_addon_static: unsupported architecture $raw" >&2; exit 2 ;;
  esac
  prefix="$(nix_attr_prefix "$arch")"
  mapfile -t paths < <(nix build --no-link --print-out-paths --inputs-from . \
    "nixpkgs#${prefix}.stdenv.cc" "nixpkgs#${prefix}.sqlite.out")
  # The outputs come back in no particular order (stdenv.cc also has a
  # man output): pick the compiler and the static sqlite by what they hold.
  cc=""
  sqlite_root=""
  for p in "${paths[@]}"; do
    for g in "$p"/bin/*-gcc; do [ -x "$g" ] && cc="$g"; done
    [ -f "$p/lib/libsqlite3.a" ] && sqlite_root="$p"
  done
  [ -n "$cc" ] || { echo "build_addon_static: no gcc among ${paths[*]}" >&2; exit 1; }
  [ -n "$sqlite_root" ] || { echo "build_addon_static: no static sqlite among ${paths[*]}" >&2; exit 1; }
  dest="$out/$arch"
  mkdir -p "$dest"
  tmp="$dest/repro.tmp.$$"
  # A failure removes only this run's temporary. The published artefact of
  # an earlier successful build stays as it was, with its own digest: the
  # caller sees this script fail (run_addon_gate.sh stops on it), so no gate
  # runs the earlier build as if it were this tree's.
  fail() { rm -f "$tmp"; exit 1; }
  defines=()
  [ -n "$mutation" ] && defines+=("--define:reproAddonMutation=$mutation")
  [ -n "$seams" ] && defines+=("--define:reproAddonTestSeams")
  echo "build_addon_static: $arch with $cc${mutation:+ (mutation $mutation)}"
  if ! (
    # The dev shell's link flags name glibc libraries; the system hash
    # libraries are glibc builds. Neither may reach a musl static link.
    unset NIX_LDFLAGS NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK REPROBUILD_USE_SYSTEM_HASH_LIBS
    export SQLITE_LIBDIR="$sqlite_root/lib"
    nim c --hints:off --warnings:off \
      --os:linux --cpu:"$(nim_cpu "$arch")" \
      --cc:gcc --gcc.exe:"$cc" --gcc.linkerexe:"$cc" \
      --"$(nim_cpu "$arch")".linux.gcc.exe:"$cc" \
      --"$(nim_cpu "$arch")".linux.gcc.linkerexe:"$cc" \
      --define:release --opt:size --stackTrace:off --lineTrace:off \
      --passL:-static --passL:-s \
      --passC:"-ffile-prefix-map=$(pwd -P)/=" \
      ${defines[@]+"${defines[@]}"} \
      --nimcache:"build/nimcache/repro-addon-static-$arch${mutation:+-$mutation}${seams:+-seams}" \
      --out:"$tmp" \
      apps/repro-addon/repro_addon_main.nim
  ); then
    echo "build_addon_static: $arch build failed" >&2
    fail
  fi
  # Static linking is verified, not assumed.
  desc="$(file -b "$tmp")"
  case "$desc" in
    *"statically linked"*) ;;
    *) echo "build_addon_static: $arch artefact is not static: $desc" >&2; fail ;;
  esac
  case "$desc" in
    *"$(elf_machine_word "$arch")"*) ;;
    *) echo "build_addon_static: $arch artefact has the wrong machine: $desc" >&2; fail ;;
  esac
  if readelf -lW "$tmp" | grep -q 'INTERP'; then
    echo "build_addon_static: $arch artefact has a PT_INTERP (dynamic loader)" >&2
    fail
  fi
  if ldd "$tmp" >/dev/null 2>&1; then
    echo "build_addon_static: ldd resolves libraries for the $arch artefact" >&2
    fail
  fi
  digest="$(sha256sum "$tmp" | cut -d' ' -f1)"
  echo "$digest  repro" > "$dest/repro.sha256.tmp.$$"
  mv "$tmp" "$dest/repro"
  mv "$dest/repro.sha256.tmp.$$" "$dest/repro.sha256"
  echo "$digest  $arch/repro" >> "$sums.tmp"
  echo "build_addon_static: $arch/repro $digest ($desc)"
done
# Keep entries for architectures this run did not rebuild.
if [ -f "$sums" ]; then
  while read -r d p; do
    grep -q "  $p\$" "$sums.tmp" || echo "$d  $p" >> "$sums.tmp"
  done < "$sums"
fi
sort -k2 "$sums.tmp" > "$sums"
rm -f "$sums.tmp"
