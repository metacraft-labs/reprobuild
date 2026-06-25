#!/usr/bin/env bash
# M9.R.36.2 — verify plasma-workspace recipe RC=0 with libkworkspace6 rename.
#
# Per M9.R.34 the recipe-revision fingerprint busts the patch-action cache on
# every repro.nim edit, so the M9.R.36.2 rename invalidates cached actions
# that consume the artifact identifier — but the install-mirror tree itself
# (built during M9.R.35.G3) is intact, and the cmake-build / cmake-install
# actions cache-hit on the unchanged source patches.
#
# The only action that needs to re-fire is the stage-library probe which
# looks up ``libkworkspace6.so`` (the renamed artifact) — and that file is
# already present in the install-mirror at:
#   .repro/output/install/usr/lib/libkworkspace6.so
#
# Expected: build cache-hits everything except the stage-library probe,
# which now succeeds (vs M9.R.35 RC=1 when it looked for the missing
# ``libPlasmaWorkspace.so``).
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r36_pw_verify.log
date > "$LOG"
echo "=== M9.R.36.2 plasma-workspace verify (libkworkspace6 rename) ===" >> "$LOG"

# Kill any stale moc / cmake / ninja from sibling builds per the WSL
# stability mitigations.
pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -f 'kcoreaddons-moc' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*plasma-workspace' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*plasma-workspace' 2>/dev/null || true

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== build plasma-workspace (M9.R.36.2 rename, NO fresh wipe) ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/packages/source/plasma-workspace" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

# Quick artifact verification
echo "=== artifact verification ===" >> "$LOG"
ls -la recipes/packages/source/plasma-workspace/.repro/output/install/usr/bin/{plasmashell,startplasma-wayland} 2>&1 | tee -a "$LOG"
ls -la recipes/packages/source/plasma-workspace/.repro/output/install/usr/lib/libkworkspace6.so* 2>&1 | tee -a "$LOG"
echo "" >> "$LOG"
echo "=== libkworkspace6 stage-output (M9.R.36.2 target) ===" >> "$LOG"
ls -la recipes/packages/source/plasma-workspace/.repro/output/libkworkspace6/ 2>&1 | tee -a "$LOG"

exit $RC
