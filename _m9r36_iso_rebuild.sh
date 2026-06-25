#!/usr/bin/env bash
# M9.R.36.1 — ISO rebuild with the LD_LIBRARY_PATH fix landed in
# stage-de-rootfs.sh.  Only the staging action needs to re-fire since
# recipe-content + per-recipe install-mirrors are unchanged.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r36_iso_build.log
date > "$LOG"
echo "=== M9.R.36.1 ISO rebuild (LD_LIBRARY_PATH profile.d landed) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Force re-run of the stage-de-rootfs action — its weakFingerprint
# includes the script content via M9.R.34's recipe-revision fingerprint,
# but to be safe we also nuke the staged de-rootfs dir + the ISO so
# the build phase re-fires from squashfs upward.
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

echo "=== verify profile.d entry ===" >> "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/etc/profile.d/zz-reproos-nixstore-ldpath.sh 2>&1 | tee -a "$LOG"
head -3 recipes/reproos-iso/build/de-rootfs/etc/profile.d/zz-reproos-nixstore-ldpath.sh 2>&1 | tee -a "$LOG"

exit $RC
