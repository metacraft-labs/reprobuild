#!/usr/bin/env bash
# M9.R.32.1 plasma-workspace build driver. Mirrors _m9r31_iso_build.sh.
set -uo pipefail
cd /opt/repro/reprobuild
LOG=/tmp/m9r32_1_pw_v5.log
date > "$LOG"
CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/packages/source/plasma-workspace" >> "$LOG" 2>&1
echo "RC=$?" >> "$LOG"
date >> "$LOG"
