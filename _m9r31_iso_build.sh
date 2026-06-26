#!/usr/bin/env bash
set -uo pipefail
cd /opt/repro/reprobuild
LOG=/tmp/m9r31_iso_build.txt
rm -f recipes/reproos-iso/build/reproos.iso
# Clean stamps to force re-stage
rm -rf recipes/reproos-iso/.repro/build/repro/{provider*,lowered-graph-cache,build-engine-cache,provider-graph} 2>/dev/null || true
CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" > "$LOG" 2>&1
rc=$?
echo "rc=$rc"
tail -5 "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>/dev/null || echo "ISO NOT PRODUCED"
exit $rc
