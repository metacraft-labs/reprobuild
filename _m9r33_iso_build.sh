#!/usr/bin/env bash
# M9.R.33.13 — ISO rebuild driver. Fresh-build semantics: wipe the
# reproos-iso build dir + base-rootfs cache so we get a real PKG_LIST
# rebuild reflecting M9.R.33.4-12 apt removals + M9.R.33.3 stage loop.
set -uo pipefail
cd /opt/repro/reprobuild
LOG=/tmp/m9r33_iso_build.log
date > "$LOG"
echo "=== M9.R.33.13 ISO rebuild ===" >> "$LOG"

# Kill any stale build orphans before we start.
pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Wipe ISO build dir + base-rootfs cache to force a real rebuild.
rm -f recipes/reproos-iso/build/reproos.iso
rm -rf recipes/reproos-iso/.repro/build
rm -rf /var/cache/reprobuild/base-rootfs/* 2>/dev/null || true

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== building ISO ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

# Verify ISO was produced.
echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

exit $RC
