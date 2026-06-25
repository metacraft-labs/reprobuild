#!/usr/bin/env bash
# M9.R.39.2 — ISO rebuild with REPRO_INSTALLER_AUTORUN=1 so the default
# GRUB menu entry boots straight into the launcher's DIAG mode via the
# ``reproos-installer-autorun.service`` systemd unit.
#
# The wrapper exports REPRO_INSTALLER_AUTORUN=1 BEFORE the engine
# invokes ``bash scripts/build-iso.sh``; build-iso.sh consumes the
# variable and appends ``repro.installer.autorun=1`` to the default
# Hyprland menu entry's linux line.  No other DE / menu entry carries
# the flag, so a non-investigator can still boot the ISO normally
# (e.g. by selecting GNOME / Plasma from the GRUB menu — but the
# default boots into the diag run).
#
# This is the M9.R.39.1 follow-up after we discovered that the
# FIFO+login driver chain wedges on a serial-getty autologin
# terminfo-init loop.  The autorun unit fires from systemd BEFORE
# multi-user.target, so it doesn't depend on login + bash + agetty
# being functional.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r39_iso_build.log
date > "$LOG"
echo "=== M9.R.39.2 ISO rebuild (REPRO_INSTALLER_AUTORUN=1) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# Nuke the staged de-rootfs + ISO so build phase re-fires.  M9.R.39.1
# learned that without the chmod -R u+w + clean rm, the engine's
# `rm -rf build/de-rootfs` partially fails on the from-source mirrors'
# read-only files, leaving stale content mixed with new.
chmod -R u+w recipes/reproos-iso/build/de-rootfs 2>/dev/null || true
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# M9.R.39.2 — flip the autorun flag ON for this build.
export REPRO_INSTALLER_AUTORUN=1

echo "=== building ISO with REPRO_INSTALLER_AUTORUN=1 ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH REPRO_INSTALLER_AUTORUN=1 repro build --daemon=off --tool-provisioning=from-source recipes/reproos-iso" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== ISO artifact ===" >> "$LOG"
ls -la recipes/reproos-iso/build/reproos.iso 2>&1 | tee -a "$LOG"

echo "=== verify autorun cmdline staged ===" >> "$LOG"
strings recipes/reproos-iso/build/reproos.iso | grep -c 'repro.installer.autorun=1' 2>&1 | tee -a "$LOG"

echo "=== verify reproos-installer-autorun.service staged ===" >> "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/etc/systemd/system/reproos-installer-autorun.service 2>&1 | tee -a "$LOG"
ls -la recipes/reproos-iso/build/de-rootfs/etc/systemd/system/multi-user.target.wants/reproos-installer-autorun.service 2>&1 | tee -a "$LOG"

exit $RC
