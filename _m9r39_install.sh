#!/usr/bin/env bash
# M9.R.39.2 — instrumented install run that bypasses the live-ISO
# login flow entirely.  The companion stage-de-rootfs.sh +
# build-iso.sh changes add a systemd ``reproos-installer-autorun
# .service`` unit gated on the ``repro.installer.autorun=1`` kernel
# cmdline, which the M9.R.39.2 GRUB menu entry passes.  When the live
# ISO boots with that cmdline, the unit runs the launcher in DIAG
# mode (``REPRO_INSTALLER_DIAG=1 QT_QPA_PLATFORM=offscreen``) BEFORE
# multi-user.target — so the M9.R.39.1 FIFO+login wedge (serial-getty
# autologin hangs in a terminfo-init loop) doesn't gate the
# investigation.
#
# After the installer exits (success or SIGABRT), the unit poweroffs
# the VM cleanly so QEMU's exit is the driver's "wait" termination.
#
# What the launcher's DIAG mode captures (see M9.R.39.1):
#
#   /tmp/installer.lddebug       — every library lookup decision the
#                                  glibc loader makes.  Phase B's
#                                  load-bearing channel for the
#                                  ABI-mismatch hypothesis.
#   /tmp/installer.strace        — every syscall.
#   /tmp/installer.kernelstacks  — per-tid kernel stacks (background
#                                  snapshotter while installer is
#                                  alive).
#   /tmp/installer.log           — installer stderr (including
#                                  munmap_chunk diagnostics).
#   /tmp/installer.binfo         — installer DT_NEEDED + RPATH + ldd
#                                  resolution + ldconfig view of
#                                  libstdc++/libQt6Core/libc.
#   /tmp/installer.rc            — installer exit code (134 = SIGABRT).
#
# The launcher tars + gzips these and dd's them to /dev/vdb's raw
# sectors with a 'M9R39DIAGv1 SIZE=...' header.  This script post-
# mortem reads the header off the qcow2 + extracts the tarball + cats
# the load-bearing logs to stdout for evidence capture.

set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r39_install.qcow2}"
DIAG_DISK="${DIAG_DISK:-/tmp/m9r39_diag.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r39_install.log}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-360}"
DIAG_OUT="${DIAG_OUT:-/tmp/m9r39_diag}"

[ -f "$ISO" ] || { echo "ISO $ISO does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r39_install_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
chmod u+w "$INSTALL_VARS"

date

rm -f "$DISK" "$DIAG_DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null
# Diag scratch disk: small (64 MiB) raw image the launcher writes diag
# logs to via dd.  Using raw (not qcow2) keeps the post-mortem extraction
# trivial — just dd the bytes off the host-side file at sector 0+.
truncate -s 64M "$DIAG_DISK"

# M9.R.39.2 — the ISO must be built with ``REPRO_INSTALLER_AUTORUN=1`` so
# the default GRUB menu entry's cmdline carries
# ``repro.installer.autorun=1``.  The ``reproos-installer-autorun.service``
# systemd unit (stage-de-rootfs.sh Phase 5) is gated on that param and
# runs the launcher in DIAG mode before multi-user.target.  No FIFO +
# login dance is needed.
#
# Sanity-check: verify the cmdline marker is in the staged grub.cfg.
# The driver doesn't rebuild the ISO automatically — that's an explicit
# ``_m9r39_iso_rebuild.sh`` step which sets REPRO_INSTALLER_AUTORUN=1.
ISO_GRUB_HAS_AUTORUN="$(strings "$ISO" 2>/dev/null | grep -c 'repro.installer.autorun=1' || true)"
if [ "${ISO_GRUB_HAS_AUTORUN:-0}" -lt 1 ]; then
  echo "[m9r39-install] WARNING: '$ISO' does NOT carry repro.installer.autorun=1"
  echo "[m9r39-install] Rebuild with REPRO_INSTALLER_AUTORUN=1 via _m9r39_iso_rebuild.sh."
  echo "[m9r39-install] Proceeding anyway so you can see boot output, but the unit will not fire."
fi

echo "=== M9.R.39.2 instrumented install (timeout ${INSTALL_TIMEOUT}s) ===" | tee "$INSTALL_LOG"
# M9.R.39.2 — keep stdin attached to ``tail -f /dev/null`` so serial stdio
# never EOFs (the M9.R.39.1 wedge cause: FIFO closing made agetty think
# the tty was gone, which hung the autologin chain in a terminfo-init
# loop).  ``tail -f /dev/null`` blocks forever without producing output,
# so qemu's serial line stays open + reads nothing.
nix-shell -p qemu OVMF --run "
  tail -f /dev/null | qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$INSTALL_VARS \
    -cdrom $ISO \
    -drive file=$DISK,if=virtio,format=qcow2 \
    -drive file=$DIAG_DISK,if=virtio,format=raw \
    -nographic -serial mon:stdio -display none
" >> "$INSTALL_LOG" 2>&1 &
QPID=$!

T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt $INSTALL_TIMEOUT ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r39-install] ${INSTALL_TIMEOUT}s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.39.2 install log (last 300 lines, ANSI stripped) ==="
sed 's/\x1B\[[0-9;]*[mK]//g' "$INSTALL_LOG" | tail -300

# Post-mortem: extract the M9R39DIAGv1 tarball from /tmp/m9r39_diag.qcow2's
# raw header.  The launcher writes:
#   sector 0     : ASCII header 'M9R39DIAGv1 SIZE=<bytes>\n' padded.
#   sector 1+    : gzipped tarball of /tmp/installer.* files.
echo ""
echo "=== M9.R.39.2 post-mortem diag extraction ==="
rm -rf "$DIAG_OUT"
mkdir -p "$DIAG_OUT"
HEADER="$(dd if="$DIAG_DISK" bs=512 count=1 status=none 2>/dev/null | tr -d '\0' | head -1)"
echo "diag-header=$HEADER"
DIAG_SIZE="$(echo "$HEADER" | sed -nE 's/^M9R39DIAGv1 SIZE=([0-9]+).*$/\1/p')"
if [ -z "$DIAG_SIZE" ] || [ "$DIAG_SIZE" = "0" ]; then
  echo "[m9r39-install] no M9R39DIAGv1 header on /dev/vdb image; launcher diag-persist did not fire"
  date
  exit 0
fi
echo "[m9r39-install] extracting $DIAG_SIZE bytes from $DIAG_DISK sector 1+"
dd if="$DIAG_DISK" bs=512 skip=1 count=$(( (DIAG_SIZE + 511) / 512 )) \
  status=none 2>/dev/null \
  | head -c "$DIAG_SIZE" \
  > "$DIAG_OUT/installer.diag.tar.gz"
ls -la "$DIAG_OUT/"
tar -tzf "$DIAG_OUT/installer.diag.tar.gz" 2>&1 | head -20
tar -xzf "$DIAG_OUT/installer.diag.tar.gz" -C "$DIAG_OUT" 2>&1

echo ""
echo "=== installer.rc ==="
cat "$DIAG_OUT/installer.rc" 2>&1 || echo MISSING
echo ""
echo "=== installer.binfo ==="
cat "$DIAG_OUT/installer.binfo" 2>&1 | head -150
echo ""
echo "=== installer.log (last 120) ==="
tail -120 "$DIAG_OUT/installer.log" 2>&1
echo ""
echo "=== installer.lddebug (lib resolution decisions for libstdc++/libQt6/libc/libgcc_s) ==="
grep -E 'libstdc\+\+|libQt6Core|libQt6Gui|libQt6Qml|libc\.so|libgcc_s|libm\.so' \
  "$DIAG_OUT/installer.lddebug" 2>&1 | head -300
echo ""
echo "=== installer.strace (last 200) ==="
tail -200 "$DIAG_OUT/installer.strace" 2>&1
echo ""

date
