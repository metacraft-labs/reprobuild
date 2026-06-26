#!/usr/bin/env bash
# M9.R.41 — ISO rebuild that picks up:
#   * the new `repro infra install-root` subcommand on build/bin/repro
#     (M9.R.41.1 — shipped to the live ISO via stage-de-rootfs.sh)
#   * the rebuilt reproos-installer that calls install-root in Phase 5
#     (M9.R.41.2 — recipes/packages/system/reproos-installer is the
#     CMake recipe the engine rebuilds from source on every ISO build)
#   * rsync added to the base-rootfs apt list (M9.R.41.3 — invalidates
#     the base-rootfs cache, forcing a fresh apt resolution)
#
# Adapted from _m9r39_iso_rebuild.sh; the recipe set + nix-shell env
# are unchanged.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r41_iso_build.log
date > "$LOG"
echo "=== M9.R.41 ISO rebuild (REPRO_INSTALLER_AUTORUN=1) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Nuke the staged de-rootfs + ISO so build phase re-fires.  Same
# clean-dance as M9.R.39 — the from-source mirrors are chmod -R 555,
# so a bare rm -rf partially fails and leaves stale content.
chmod -R u+w recipes/reproos-iso/build/de-rootfs 2>/dev/null || true
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

# Force a reproos-installer rebuild: clear the recipe cache so the new
# installer_state.cpp gets compiled in.  The recipe lives at
# apps/reproos-installer/repro.nim (M9.R.18.13) and the engine writes
# its outputs under apps/reproos-installer/.repro/output/.
chmod -R u+w apps/reproos-installer/.repro 2>/dev/null || true
rm -rf apps/reproos-installer/.repro

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# M9.R.39.2 — flip the autorun flag ON for this build.
export REPRO_INSTALLER_AUTORUN=1

# M9.R.41 io-mon override (eli-wsl has no sibling under the nix-store
# path; the override resolves it via the local clone).
export IO_MON_SRC=/opt/repro/io-mon/src

echo "=== building ISO with REPRO_INSTALLER_AUTORUN=1 ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH REPRO_INSTALLER_AUTORUN=1 repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

echo "=== verify autorun cmdline staged ===" >> "$LOG"
nix-shell -p binutils --run "strings recipes/reproos-iso/build/reproos.iso | grep -c 'repro.installer.autorun=1'" 2>&1 | tee -a "$LOG"

echo "=== verify reproos-installer-autorun.service staged ===" >> "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/etc/systemd/system/reproos-installer-autorun.service 2>&1 | tee -a "$LOG"

echo "=== verify rsync is on the live ISO (M9.R.41.3) ===" >> "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/usr/bin/rsync 2>&1 | tee -a "$LOG"

echo "=== verify install-root subcommand is reachable on the live ISO ===" >> "$LOG"
nix-shell -p binutils --run "strings recipes/reproos-iso/build/de-rootfs/usr/bin/repro 2>/dev/null | grep -c 'install-root'" 2>&1 | tee -a "$LOG"

echo "=== verify rebuilt installer carries the M9.R.41.2 changes ===" >> "$LOG"
ls -la apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer 2>&1 | tee -a "$LOG"

exit $RC
