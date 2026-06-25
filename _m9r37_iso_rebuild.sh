#!/usr/bin/env bash
# M9.R.37.1 — ISO rebuild after the diagnostic instrumentation
# (strace+gdb in base PKG_LIST + REPRO_INSTALLER_DIAG=1 launcher mode)
# landed in build-base-rootfs.sh + stage-de-rootfs.sh.
#
# The PKG_LIST changed (added strace gdb), so the base-rootfs cache
# misses + the from-source mirror Phase doesn't.  ISO assembly fires
# again.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r37_iso_build.log
date > "$LOG"
echo "=== M9.R.37.1 ISO rebuild (strace/gdb + diag launcher) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Nuke the staged de-rootfs + ISO so build phase re-fires.
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== building ISO ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

echo "=== verify diag launcher mode landed ===" >> "$LOG"
grep -n "REPRO_INSTALLER_DIAG" recipes/reproos-iso/build/de-rootfs/usr/bin/reproos-installer-launcher.sh 2>&1 | tee -a "$LOG"

echo "=== verify strace shipped ===" >> "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/usr/bin/strace 2>&1 | tee -a "$LOG"

exit $RC
