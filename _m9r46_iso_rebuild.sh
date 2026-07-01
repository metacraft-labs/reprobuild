#!/usr/bin/env bash
# M9.R.46 - ISO rebuild that picks up the relocate-nix-to-repro.sh
# Phase 6b in stage-de-rootfs.sh.  Based on the M9.R.43 rebuild driver.
#
# Goal: produce reproos.iso with NO /nix/store directory inside the
# squashfs, and verify the post-stage leak audit passes.
#
# Outputs:
#   /tmp/m9r46_iso_build.log    ISO build log
#   recipes/reproos-iso/build/reproos.iso  the relocated ISO
#
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r46_iso_build.log
date > "$LOG"
echo "=== M9.R.46 ISO rebuild (relocate /nix/store -> /repro/store) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Nuke previous stage so Phase 6b fires.
chmod -R u+w recipes/reproos-iso/build/de-rootfs 2>/dev/null || true
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

chmod -R u+w apps/reproos-installer/.repro 2>/dev/null || true
rm -rf apps/reproos-installer/.repro

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export REPRO_INSTALLER_AUTORUN=1
export IO_MON_SRC=/opt/repro/io-mon/src

echo "=== step 1: rebuild host build/bin/repro ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH bash scripts/build_apps.sh" >> "$LOG" 2>&1
HOST_APPS_RC=$?
echo "HOST_APPS_RC=$HOST_APPS_RC" >> "$LOG"
if [ "$HOST_APPS_RC" -ne 0 ]; then
  echo "FAIL: scripts/build_apps.sh RC=$HOST_APPS_RC" >> "$LOG"
  exit "$HOST_APPS_RC"
fi

echo "=== step 2: rebuild reproos-installer ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source apps/reproos-installer" >> "$LOG" 2>&1
INSTALLER_RC=$?
echo "INSTALLER_RC=$INSTALLER_RC" >> "$LOG"
if [ "$INSTALLER_RC" -ne 0 ]; then
  echo "FAIL: reproos-installer rebuild RC=$INSTALLER_RC" >> "$LOG"
  exit "$INSTALLER_RC"
fi

echo "=== step 3: rebuild ISO (stage-de-rootfs Phase 6b relocates /nix/store) ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH REPRO_INSTALLER_AUTORUN=1 repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

if [ "$RC" -eq 0 ]; then
  echo "=== M9.R.46 staged tree: /nix/store presence check ===" >> "$LOG"
  if [ -d recipes/reproos-iso/build/de-rootfs/nix ]; then
    echo "FAIL: recipes/reproos-iso/build/de-rootfs/nix STILL EXISTS" >> "$LOG"
    find recipes/reproos-iso/build/de-rootfs/nix -maxdepth 3 -print | head -10 >> "$LOG"
  else
    echo "OK: no /nix subtree on staged de-rootfs (relocate succeeded)" >> "$LOG"
  fi
  echo "=== M9.R.46 staged tree: /repro/store presence + size ===" >> "$LOG"
  if [ -d recipes/reproos-iso/build/de-rootfs/repro/store ]; then
    repro_store_n=$(ls recipes/reproos-iso/build/de-rootfs/repro/store | wc -l)
    repro_store_sz=$(du -sb recipes/reproos-iso/build/de-rootfs/repro/store | awk '{print $1}')
    echo "OK: /repro/store has $repro_store_n entries, $repro_store_sz bytes" >> "$LOG"
  else
    echo "WARN: no /repro/store on staged de-rootfs" >> "$LOG"
  fi

  echo "=== M9.R.46 Phase E leak audit on STAGED de-rootfs ===" >> "$LOG"
  nix-shell -p patchelf --run "bash _m9r46_phaseA_scan.sh recipes/reproos-iso/build/de-rootfs /tmp/m9r46_phaseE_staged" >> "$LOG" 2>&1
  if [ -f /tmp/m9r46_phaseE_staged/leak_summary.txt ]; then
    tail -30 /tmp/m9r46_phaseE_staged/leak_summary.txt >> "$LOG"
  fi
fi

exit $RC
