#!/usr/bin/env bash
# M9.R.33.13 — fresh plasma-workspace build to prove M9.R.31 wasn't faked.
# Wipes .repro/build first per the task brief, so we exercise the
# M9.R.33.2 walker against a clean slate.
set -uo pipefail
cd /opt/repro/reprobuild
LOG=/tmp/m9r33_fresh_pw.log
date > "$LOG"
echo "=== M9.R.33.13 fresh plasma-workspace build ===" >> "$LOG"

# Kill any stale moc / cmake / ninja from sibling builds per the WSL
# stability mitigations in the task brief.
pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -f 'kcoreaddons-moc' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*plasma-workspace' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*plasma-workspace' 2>/dev/null || true

# M9.R.33.13 fresh-build semantics: wipe the build dir.
rm -rf recipes/packages/source/plasma-workspace/.repro/build
rm -rf recipes/packages/source/plasma-workspace/.repro/output

# Also wipe qcoro6 build/output so the M9.R.33.1 from-source build runs.
rm -rf recipes/packages/source/qcoro6/.repro/build
rm -rf recipes/packages/source/qcoro6/.repro/output

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== build plasma-workspace fresh ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source recipes/packages/source/plasma-workspace" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

# Quick artifact verification
echo "=== artifact verification ===" >> "$LOG"
ls -la recipes/packages/source/plasma-workspace/.repro/output/install/usr/bin/{plasmashell,startplasma-wayland} 2>&1 | tee -a "$LOG"
ls -la recipes/packages/source/plasma-workspace/.repro/output/install/usr/lib*/libPlasmaWorkspace.so* 2>&1 | tee -a "$LOG"

exit $RC
