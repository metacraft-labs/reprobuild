#!/usr/bin/env bash
# fetch_target_sysroot.sh — copy a cross-compilation sysroot off a running
# Debian-family target host.
#
# Usage:
#   scripts/cross/fetch_target_sysroot.sh [--ssh <command>] [--triple <multiarch>] \
#       [--dev-package <name>]... <ssh-destination-or-empty> <sysroot-dir>
#
#   scripts/cross/fetch_target_sysroot.sh zahary@192.168.100.180 build/cross/armhf/sysroot
#   scripts/cross/fetch_target_sysroot.sh --ssh ./my-ssh-wrapper "" build/cross/armhf/sysroot
#
# WHY A SYSROOT COPIED FROM THE TARGET. `scripts/cross/build_linux_cross.sh`
# cross-compiles reprobuild on a fast build host and links it against THIS
# directory. Taking the sysroot from the very host the binaries will run on
# makes them link against that host's own glibc, libstdc++ and libraries, so
# no symbol version the target lacks can be referenced and no loader or RPATH
# has to be relocated afterwards: the binaries are what a native build on the
# target would have produced, without spending hours of a small board's CPU.
#
# WHAT IS COPIED. Only what a C link needs: `/usr/include`, the multiarch
# library directory and the GCC runtime directory (crt*.o, libgcc). Nothing is
# installed on the target. Link-time-only files that a runtime-only host lacks
# (the unversioned `libfoo.so` symlinks and headers of `-dev` packages) are
# fetched with `apt-get download` -- a download into a temporary directory on
# the target, never an install -- and unpacked into the sysroot here.
#
# Absolute symlinks inside the copy (Debian ships e.g.
# `libfoo.so -> /lib/<triple>/libfoo.so.1`) are rewritten relative to the
# sysroot, because the build host would otherwise resolve them against its own
# root.
set -euo pipefail

ssh_cmd=(ssh)
triple="arm-linux-gnueabihf"
# The -dev packages whose link-time files the cross build needs:
#   libzstd-dev     zstd.h + libzstd.so, linked by the Nim compiler itself
#   libssl-dev      libssl.so/libcrypto.so for the `--define:ssl` images
#   libsqlite3-dev  libsqlite3.so, linked by repro_local_store on Linux
dev_packages=(libzstd-dev libssl-dev libsqlite3-dev)
extra_dev_packages=()

usage() {
  sed -n '2,12p' "$0" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh) ssh_cmd=("$2"); shift 2 ;;
    --ssh=*) ssh_cmd=("${1#--ssh=}"); shift ;;
    --triple) triple="$2"; shift 2 ;;
    --triple=*) triple="${1#--triple=}"; shift ;;
    --dev-package) extra_dev_packages+=("$2"); shift 2 ;;
    --dev-package=*) extra_dev_packages+=("${1#--dev-package=}"); shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "fetch_target_sysroot: unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 2 ] || usage
destination="$1"
sysroot="$2"
dev_packages+=(${extra_dev_packages[@]+"${extra_dev_packages[@]}"})

remote() {
  if [ -n "${destination}" ]; then
    "${ssh_cmd[@]}" "${destination}" "$1"
  else
    "${ssh_cmd[@]}" "$1"
  fi
}

# Refuse a target whose multiarch triple is not the one asked for: a sysroot
# of the wrong architecture links nothing and fails far from here.
remote_triple="$(remote 'gcc -dumpmachine 2>/dev/null || dpkg-architecture -qDEB_HOST_MULTIARCH')"
remote_triple="${remote_triple%$'\r'}"
if [ "${remote_triple}" != "${triple}" ]; then
  echo "fetch_target_sysroot: the target reports '${remote_triple}', not '${triple}'" >&2
  exit 1
fi

mkdir -p "${sysroot}"
sysroot_abs="$(cd "${sysroot}" && pwd)"
staging="${sysroot_abs}.incoming"
rm -rf "${staging}"
mkdir -p "${staging}"

echo "fetch_target_sysroot: copying include + library directories from the target"
# The dynamic loader sits directly in /usr/lib on Debian (libc.so names
# /lib/ld-linux-*.so.*), so it is copied alongside the multiarch directory;
# so is usr/lib/linux, where linux-libc-dev keeps the uapi headers the
# multiarch include/<triple>/asm symlinks point into.
remote "cd / && tar -cf - usr/include usr/lib/${triple} usr/lib/gcc/${triple} usr/lib/linux usr/lib/ld-linux*" |
  tar -C "${staging}" -xf -
# Debian's merged-/usr: /lib is a symlink to usr/lib. Keep that shape so
# linker scripts naming /lib/<triple>/... (libc.so) resolve under --sysroot.
ln -sfn usr/lib "${staging}/lib"

echo "fetch_target_sysroot: unpacking link-time files of: ${dev_packages[*]}"
# Unpacked ON THE TARGET with its own `dpkg-deb -x` (a Debian host always has
# it; the build host need not have `ar` or `dpkg-deb`), into a temporary
# directory that is removed again, and streamed back as one tarball.
# The exact package versions unpacked are recorded (`dev_packages=`), read
# off the .deb control files: `dpkg-deb -f <deb> Package Version`.
dev_packages_record="$(mktemp)"
remote "set -e; d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT; cd \"\$d\"; \
apt-get download ${dev_packages[*]} >/dev/null; mkdir root; \
for deb in *.deb; do dpkg-deb -x \"\$deb\" root; echo \"  \$deb\" >&2; \
printf '%s=%s\\n' \"\$(dpkg-deb -f \"\$deb\" Package)\" \"\$(dpkg-deb -f \"\$deb\" Version)\" > root/.dev-package-\$(dpkg-deb -f \"\$deb\" Package); done; \
tar -C root -cf - ." |
  tar -C "${staging}" -xf -
cat "${staging}"/.dev-package-* | sort | tr '\n' ' ' | sed 's/ $//' > "${dev_packages_record}"
rm -f "${staging}"/.dev-package-*

# Rewrite absolute symlinks to point inside the sysroot.
while IFS= read -r -d '' link; do
  target="$(readlink "${link}")"
  case "${target}" in
    /*)
      rel_dir="$(dirname "${link#"${staging}"/}")"
      up=""
      IFS=/ read -r -a parts <<< "${rel_dir}"
      for _ in "${parts[@]}"; do up="../${up}"; done
      ln -sfn "${up}${target#/}" "${link}"
      ;;
  esac
done < <(find "${staging}" -type l -print0)

# A dangling link under include/ means a header the copy did not reach (the
# multiarch `asm/` links into usr/lib/linux were the first such case); say
# which, because the compile that trips over it only names the header.
dangling="$(find "${staging}/usr/include" -xtype l | sed "s|^${staging}||" | head -n 20)"
if [ -n "${dangling}" ]; then
  echo "fetch_target_sysroot: WARNING: dangling header links in the sysroot:" >&2
  printf '  %s\n' ${dangling} >&2
fi

rm -rf "${sysroot_abs}"
mv "${staging}" "${sysroot_abs}"
# What the sysroot IS, not when it was taken: the target's glibc and the exact
# versions of the -dev packages whose link-time files were unpacked. A
# timestamp would make two identical sysroots look different and two different
# ones (same date, different package versions) look the same.
{
  echo "# sysroot fetched by scripts/cross/fetch_target_sysroot.sh"
  echo "sysroot_triple=${triple}"
  echo "sysroot_glibc=$(remote 'ldd --version | head -n1')"
  echo "sysroot_dev_packages=$(cat "${dev_packages_record}")"
} > "${sysroot_abs}/.sysroot-info"
rm -f "${dev_packages_record}"
echo "fetch_target_sysroot: sysroot ready at ${sysroot_abs}"
