#!/usr/bin/env bash
# M9.R.39.1 — instrumented install run that captures LD_DEBUG=libs +
# strace + per-pid kernel stacks, persists them to a second virtio
# scratch disk BEFORE QEMU exits (so the M9.R.38 tmpfs-log loss problem
# doesn't recur), then extracts the tarball from the qcow2 raw header
# the launcher writes.
#
# What the diagnostic mode captures (via the M9.R.39.1 launcher fork):
#
#   /tmp/installer.lddebug       — every library lookup decision the
#                                  glibc loader makes, including the
#                                  exact path it chose for libstdc++,
#                                  libc, libQt6Core, libQt6Gui.  This
#                                  is the load-bearing channel for
#                                  identifying ABI / version mismatches.
#   /tmp/installer.strace        — every syscall on every thread.
#   /tmp/installer.kernelstacks  — per-tid kernel stack snapshots.
#   /tmp/installer.log           — installer stderr (including any
#                                  munmap_chunk diagnostic glibc emits).
#   /tmp/installer.binfo         — installer binary DT_NEEDED/RPATH +
#                                  ldconfig view of libstdc++/libQt6Core/
#                                  libc resolution.
#   /tmp/installer.rc            — exit code (134 = SIGABRT).
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

INSTALL_FIFO="$(mktemp -d)/install-in.fifo"
mkfifo "$INSTALL_FIFO"
(
  # Wait for live ISO to boot + login prompt to surface on ttyS0.
  sleep 100
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R39_INSTALL_BEGIN ==="
  sleep 1
  echo "ls -la /dev/vdb 2>&1"
  sleep 1
  # Run installer in foreground with diag mode on.  The launcher itself
  # runs the installer synchronously + persists logs to /dev/vdb before
  # returning.  We DO NOT detach (M9.R.37 / M9.R.38 detached pattern lost
  # logs on poweroff).
  echo "REPRO_INSTALLER_DIAG=1 QT_QPA_PLATFORM=offscreen /usr/bin/reproos-installer-launcher.sh --automated /etc/reproos/auto-config.toml; echo INSTALLER_RC=\$?"
  sleep 10
  echo "echo === M9R39_LDDEBUG_SUMMARY ==="
  sleep 1
  # Pre-poweroff summary: in case the dd-to-vdb path didn't fire (e.g.
  # vdb wasn't attached), we still get something on the serial console.
  echo "test -f /tmp/installer.lddebug && echo lddebug-bytes=\$(stat -c %s /tmp/installer.lddebug) || echo lddebug-MISSING"
  sleep 1
  echo "test -f /tmp/installer.lddebug && grep -E 'libstdc|libQt6Core|libc.so|libgcc_s|libQt6Gui|libQt6Qml' /tmp/installer.lddebug 2>&1 | head -80"
  sleep 3
  echo "echo === M9R39_STRACE_TAIL ==="
  sleep 1
  echo "tail -120 /tmp/installer.strace 2>&1"
  sleep 3
  echo "echo === M9R39_INSTALLER_LOG_TAIL ==="
  sleep 1
  echo "tail -80 /tmp/installer.log 2>&1"
  sleep 2
  echo "echo === M9R39_BINFO ==="
  sleep 1
  echo "cat /tmp/installer.binfo 2>&1 | head -120"
  sleep 2
  echo "echo === M9R39_DIAG_VDB_HEADER ==="
  sleep 1
  # Sanity: read the first 512 bytes of vdb to confirm the launcher
  # wrote the M9R39DIAGv1 header.
  echo "dd if=/dev/vdb bs=512 count=1 status=none 2>/dev/null | head -c 64; echo"
  sleep 2
  echo "echo === M9R39_INSTALL_END ==="
  sleep 2
  echo "poweroff"
) > "$INSTALL_FIFO" &

echo "=== M9.R.39.1 instrumented install (timeout ${INSTALL_TIMEOUT}s) ===" | tee "$INSTALL_LOG"
nix-shell -p qemu OVMF --run "
  qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$INSTALL_VARS \
    -cdrom $ISO \
    -drive file=$DISK,if=virtio,format=qcow2 \
    -drive file=$DIAG_DISK,if=virtio,format=raw \
    -nographic -serial mon:stdio -display none \
    < $INSTALL_FIFO
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
echo "=== M9.R.39.1 install log (last 250 lines) ==="
tail -250 "$INSTALL_LOG"

# Post-mortem: extract the M9R39DIAGv1 tarball from /tmp/m9r39_diag.qcow2's
# raw header.  The launcher writes:
#   sector 0     : ASCII header 'M9R39DIAGv1 SIZE=<bytes>\n' padded.
#   sector 1+    : gzipped tarball of /tmp/installer.* files.
echo ""
echo "=== M9.R.39.1 post-mortem diag extraction ==="
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
cat "$DIAG_OUT/installer.binfo" 2>&1 | head -100
echo ""
echo "=== installer.log (last 100) ==="
tail -100 "$DIAG_OUT/installer.log" 2>&1
echo ""
echo "=== installer.lddebug (lib resolution decisions for libstdc++/libQt6/libc/libgcc_s) ==="
grep -E 'libstdc\+\+|libQt6Core|libQt6Gui|libQt6Qml|libc\.so|libgcc_s|libm\.so' \
  "$DIAG_OUT/installer.lddebug" 2>&1 | head -200
echo ""
echo "=== installer.strace (last 200) ==="
tail -200 "$DIAG_OUT/installer.strace" 2>&1
echo ""

date
