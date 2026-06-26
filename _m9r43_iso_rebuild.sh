#!/usr/bin/env bash
# M9.R.43 - ISO rebuild + host repro binary refresh, with NO /tmp engine.nim
# stub.
#
# Gap 1 closure (over M9.R.42):
#
#   * Pull reprobuild-ct-test-runner sibling so the M0b-3 subprocess seam
#     (commit 03c1acd) is on disk before any nim compile fires.  M9.R.42's
#     install attempts ran against the stale e9c9e37 in-process adapter
#     (`import engine`), which forced the local /tmp engine.nim stub
#     workaround.  With the sibling at M0b-3 the adapter compiles std-only
#     and the stub is unnecessary; this driver verifies the sibling commit
#     before continuing.
#
#   * Explicitly invoke ``bash scripts/build_apps.sh`` so the host
#     ``build/bin/repro`` is rebuilt from current source BEFORE
#     ``recipes/reproos-iso`` runs (which stages the same host binary
#     into the ISO via the de-rootfs builder).  M9.R.42's evidence proved
#     that an unrefreshed binary silently shipped stale disk-apply
#     behaviour onto the ISO.
set -uo pipefail
cd /opt/repro/reprobuild

LOG=/tmp/m9r43_iso_build.log
date > "$LOG"
echo "=== M9.R.43 ISO rebuild (REPRO_INSTALLER_AUTORUN=1) ===" >> "$LOG"

pkill -KILL -f 'moc$' 2>/dev/null || true
pkill -KILL -9 -f 'cmake.*reproos' 2>/dev/null || true
pkill -KILL -9 -f 'ninja.*reproos' 2>/dev/null || true

# ---------------------------------------------------------------------
# Step 0 - sibling refresh.  M0b-3 (reprobuild-ct-test-runner@03c1acd)
# is the engine-free subprocess seam reprobuild builds against; without
# it the adapter still has ``import engine`` and the apps build fails.
# Pull origin/main + verify.
# ---------------------------------------------------------------------
echo "=== step 0: refresh reprobuild-ct-test-runner sibling ===" >> "$LOG"
SIBLING=/opt/repro/reprobuild-ct-test-runner
sudo git -c safe.directory="$SIBLING" -C "$SIBLING" fetch origin >> "$LOG" 2>&1
sudo git -c safe.directory="$SIBLING" -C "$SIBLING" reset --hard origin/main >> "$LOG" 2>&1
SIBLING_HEAD="$(sudo git -c safe.directory="$SIBLING" -C "$SIBLING" rev-parse HEAD)"
echo "SIBLING_HEAD=$SIBLING_HEAD" >> "$LOG"
# Guard: the adapter source MUST NOT carry the old in-process ``import engine``.
if sudo grep -E '^import engine$' "$SIBLING/libs/ct_incremental_adapter/src/ct_incremental_adapter.nim" >/dev/null; then
  echo "FAIL: ct_incremental_adapter still has in-process 'import engine' — sibling is pre-M0b-3" >> "$LOG"
  exit 2
fi
echo "SIBLING ADAPTER IS M0b-3 (subprocess)" >> "$LOG"

# Nuke the staged de-rootfs + ISO so build phase re-fires.
chmod -R u+w recipes/reproos-iso/build/de-rootfs 2>/dev/null || true
rm -rf recipes/reproos-iso/build/de-rootfs
rm -f recipes/reproos-iso/build/reproos.iso

# Force a reproos-installer rebuild only if its sources changed.
chmod -R u+w apps/reproos-installer/.repro 2>/dev/null || true
rm -rf apps/reproos-installer/.repro

CLINGO_DIR="$(dirname "$(find /nix/store -maxdepth 3 -name 'libclingo.so' 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="${CLINGO_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export REPRO_INSTALLER_AUTORUN=1
export IO_MON_SRC=/opt/repro/io-mon/src

# ---------------------------------------------------------------------
# Step 1 - rebuild host build/bin/repro from current source.
#
# scripts/build_apps.sh walks apps/entrypoints.txt and nim-c's each
# binary.  ``repro`` lives at apps/repro/repro.nim and imports
# repro_cli_support which in turn imports ct_incremental_adapter from
# the sibling.  This step picks up any disk-apply / install-root
# changes that have landed since the last build.
#
# Without this step the build/bin/repro binary the recipes/reproos-iso
# stager bakes into the live ISO can be stale relative to the source
# tree (M9.R.42 phantom).
# ---------------------------------------------------------------------
echo "=== step 1: rebuild host build/bin/repro (scripts/build_apps.sh) ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH bash scripts/build_apps.sh" >> "$LOG" 2>&1
HOST_APPS_RC=$?
echo "HOST_APPS_RC=$HOST_APPS_RC" >> "$LOG"
ls -la build/bin/repro 2>&1 | tee -a "$LOG"
if [ "$HOST_APPS_RC" -ne 0 ]; then
  echo "FAIL: scripts/build_apps.sh RC=$HOST_APPS_RC; ISO build aborted" >> "$LOG"
  exit "$HOST_APPS_RC"
fi
HOST_REPRO_MTIME="$(stat -c%y build/bin/repro 2>/dev/null || echo MISSING)"
echo "HOST_REPRO_MTIME=$HOST_REPRO_MTIME" >> "$LOG"

# ---------------------------------------------------------------------
# Step 2 - rebuild reproos-installer.
# ---------------------------------------------------------------------
echo "=== step 2: rebuild reproos-installer ===" >> "$LOG"
nix-shell -p openssl patchelf gcc binutils gnumake autoconf automake libtool pkg-config gettext perl python3 bison flex xz gawk kmod cpio squashfsTools libisoburn grub2 mtools dosfstools curl docker rsync --run "PATH=/opt/repro/reprobuild/build/bin:\$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH repro build --daemon=off --tool-provisioning=from-source apps/reproos-installer" >> "$LOG" 2>&1
INSTALLER_RC=$?
echo "INSTALLER_RC=$INSTALLER_RC" >> "$LOG"
ls -la apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer 2>&1 | tee -a "$LOG"
if [ "$INSTALLER_RC" -ne 0 ]; then
  echo "FAIL: reproos-installer rebuild RC=$INSTALLER_RC; ISO build aborted" >> "$LOG"
  exit "$INSTALLER_RC"
fi

# ---------------------------------------------------------------------
# Step 3 - rebuild ISO with REPRO_INSTALLER_AUTORUN=1.
# ---------------------------------------------------------------------
echo "=== step 3: rebuild ISO with REPRO_INSTALLER_AUTORUN=1 ===" >> "$LOG"
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

# Confirm the host repro binary the ISO staged from is the same one we built.
ISO_REPRO_SHA="$(sha256sum recipes/reproos-iso/build/de-rootfs/usr/bin/repro 2>/dev/null | awk '{print $1}')"
HOST_REPRO_SHA="$(sha256sum build/bin/repro 2>/dev/null | awk '{print $1}')"
echo "ISO_REPRO_SHA=$ISO_REPRO_SHA" >> "$LOG"
echo "HOST_REPRO_SHA=$HOST_REPRO_SHA" >> "$LOG"
if [ -n "$ISO_REPRO_SHA" ] && [ "$ISO_REPRO_SHA" != "$HOST_REPRO_SHA" ]; then
  echo "WARN: staged ISO repro != freshly built host repro" >> "$LOG"
fi

exit $RC
