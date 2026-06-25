#!/usr/bin/env bash
# M9.R.38.1 — explicitly rebuild reproos-installer so M9.R.37.8's
# installer_state.cpp change lands in the binary.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r38_installer_build.log
date > "$LOG"
echo "=== M9.R.38.1 reproos-installer rebuild ===" >> "$LOG"

# CLINGO_DIR for repro to find libclingo
CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Remove the stale build outputs so cmake re-fires.
rm -rf apps/reproos-installer/.repro/build apps/reproos-installer/.repro/output

nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source apps/reproos-installer" >> "$LOG" 2>&1
RC=$?
echo "" >> "$LOG"
echo "RC=$RC" >> "$LOG"
date >> "$LOG"

echo "=== built installer ===" >> "$LOG"
ls -la apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer 2>&1 | tee -a "$LOG"
exit $RC
