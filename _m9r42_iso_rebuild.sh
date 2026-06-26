#!/usr/bin/env bash
# M9.R.42 — ISO rebuild that picks up:
#   * the M9.R.42.1 disk-apply REPRO_DISK_DIAG hook (the diag file
#     lands at /tmp/installer.disk-diag.log; the launcher passes the
#     env var through strace + the diag-persist tarball includes it).
#   * the M9.R.41 install-root subcommand stays — only the disk_apply
#     module gained the kernel-state snapshot instrumentation.
#
# Same shape as _m9r41_iso_rebuild.sh.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r42_iso_build.log
date > "$LOG"
echo "=== M9.R.42 ISO rebuild (REPRO_INSTALLER_AUTORUN=1) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Nuke the staged de-rootfs + ISO so build phase re-fires.
chmod -R u+w recipes/reproos-iso/build/de-rootfs 2>/dev/null || true
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

# Force a reproos-installer rebuild only if its sources changed.  The
# M9.R.42 milestone touched stage-de-rootfs.sh + the disk_apply +
# disk_tools modules — the installer C++ is unchanged from M9.R.41.
# But because base-rootfs is keyed on apt-pkg-list and stays the same
# as M9.R.41 (no apt-list change in M9.R.42), the cache hit should
# be valid and we re-use it.
chmod -R u+w apps/reproos-installer/.repro 2>/dev/null || true
rm -rf apps/reproos-installer/.repro

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export REPRO_INSTALLER_AUTORUN=1
export IO_MON_SRC=/opt/repro/io-mon/src

echo "=== step 1: rebuild reproos-installer ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source apps/reproos-installer" >> "$LOG" 2>&1
INSTALLER_RC=$?
echo "INSTALLER_RC=$INSTALLER_RC" >> "$LOG"
ls -la apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer 2>&1 | tee -a "$LOG"
if [ "$INSTALLER_RC" -ne 0 ]; then
  echo "FAIL: reproos-installer rebuild RC=$INSTALLER_RC; ISO build aborted" >> "$LOG"
  exit "$INSTALLER_RC"
fi

echo "=== step 2: rebuild ISO with REPRO_INSTALLER_AUTORUN=1 ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH REPRO_INSTALLER_AUTORUN=1 repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

echo "=== verify autorun cmdline staged ===" >> "$LOG"
nix-shell -p binutils --run "strings recipes/reproos-iso/build/reproos.iso | grep -c 'repro.installer.autorun=1'" 2>&1 | tee -a "$LOG"

echo "=== verify REPRO_DISK_DIAG passthrough in staged launcher ===" >> "$LOG"
grep -c 'REPRO_DISK_DIAG=/tmp/installer.disk-diag.log' \
  recipes/reproos-iso/build/de-rootfs/usr/bin/reproos-installer-launcher.sh \
  2>&1 | tee -a "$LOG"

echo "=== verify installer.disk-diag.log entry in diag-persist tarball list ===" >> "$LOG"
grep -c 'installer.disk-diag.log' \
  recipes/reproos-iso/build/de-rootfs/usr/bin/reproos-installer-launcher.sh \
  2>&1 | tee -a "$LOG"

echo "=== verify install-root subcommand is reachable on the live ISO ===" >> "$LOG"
nix-shell -p binutils --run "strings recipes/reproos-iso/build/de-rootfs/usr/bin/repro 2>/dev/null | grep -c 'install-root'" 2>&1 | tee -a "$LOG"

exit $RC
