#!/usr/bin/env bash
# M9.R.37.1 — diagnostic install run that exercises the M9.R.37
# instrumentation landed in stage-de-rootfs.sh + build-base-rootfs.sh.
#
# What the diagnostic mode captures:
#
#   /tmp/installer.strace        — every syscall on every thread of
#                                  the installer + its children
#                                  (strace -f -ttt -y -s 256, captured
#                                  with stdbuf line-buffered stdio).
#   /tmp/installer.kernelstacks  — every 5s, /proc/<pid>/{status,wchan,
#                                  stack} + per-tid wchan + first 10
#                                  lines of /proc/<tid>/stack.  Lets
#                                  us see which thread is wedged on
#                                  which kernel function (futex,
#                                  read, connect, wait4, ...) without
#                                  needing a corefile.
#   /tmp/installer.log           — the installer's stderr (line-
#                                  buffered).
#
# After a generous-but-bounded timeout (300s instead of 720s — the
# wedge surfaces within ~20s by historical M9.R.36 evidence, so 300s
# gives us 14+ kernelstack samples), we cat all three diagnostic logs
# to the serial console so they end up captured in /tmp/m9r37_install
# .log on the host.  The qcow2 disk also serves as a fallback —
# diag logs survive there too if /tmp didn't fully echo before
# poweroff.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r37_installed_disk.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r37_install.log}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-600}"

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r37_install_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
chmod u+w "$INSTALL_VARS"

date

rm -f "$DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null

INSTALL_FIFO="$(mktemp -d)/install-in.fifo"
mkfifo "$INSTALL_FIFO"
(
  sleep 100
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R37_INSTALL_BEGIN ==="
  sleep 1
  echo "ls -la /usr/bin/strace /usr/bin/stdbuf 2>&1"
  sleep 2
  echo "echo === M9R37_DIAG_INSTALLER_LAUNCH ==="
  sleep 1
  # Launch the installer in DIAG mode but DETACH it so we can monitor
  # progress while it runs (and cat the diagnostic logs after the wedge
  # without being blocked on its exit).  We use ``nohup ... </dev/null
  # >/tmp/installer.log 2>&1 &`` so the installer's stdio is captured
  # to a file (not to the serial console) — that way the kernel-stack
  # snapshotter can keep printing every 5s without competing with the
  # installer's stderr.
  echo "REPRO_INSTALLER_DIAG=1 QT_QPA_PLATFORM=offscreen nohup /usr/bin/reproos-installer-launcher.sh --automated /etc/reproos/auto-config.toml </dev/null >/tmp/installer.log 2>&1 &"
  sleep 2
  echo "INSTPID=\$!"
  echo "echo INSTPID=\$INSTPID"
  sleep 1
  echo "echo === M9R37_INSTALLER_DETACHED ==="
  # Wait for a moderate duration so the strace / kernelstack sampler
  # accumulate enough data.  The wedge surfaced inside ~30-60s in
  # M9.R.36, so 240s gives us 48+ samples.
  sleep 240
  echo "echo === M9R37_PROBING_INSTALLER_STATE ==="
  sleep 1
  echo "ps -ef | grep -E 'reproos-installer|strace|repro' | grep -v grep"
  sleep 2
  echo "cat /tmp/installer.diag.pid 2>/dev/null; echo"
  sleep 1
  echo "echo === M9R37_INSTALLER_LOG_TAIL ==="
  sleep 1
  echo "tail -200 /tmp/installer.log 2>&1"
  sleep 3
  echo "echo === M9R37_KERNELSTACKS_TAIL ==="
  sleep 1
  echo "tail -400 /tmp/installer.kernelstacks 2>&1"
  sleep 5
  echo "echo === M9R37_STRACE_TAIL ==="
  sleep 1
  echo "tail -800 /tmp/installer.strace 2>&1"
  sleep 8
  echo "echo === M9R37_STRACE_FIRST_300 ==="
  sleep 1
  echo "head -300 /tmp/installer.strace 2>&1"
  sleep 6
  # If the installer is still alive, send it SIGABRT to dump its
  # state (may not produce a core without ulimit -c unlimited, but
  # at least exits the wedge).
  echo "echo === M9R37_KILLING_INSTALLER_IF_ALIVE ==="
  sleep 1
  echo "kill -ABRT \$INSTPID 2>/dev/null; sleep 2; kill -KILL \$INSTPID 2>/dev/null; true"
  sleep 5
  echo "echo === M9R37_INSTALL_END ==="
  sleep 2
  echo "poweroff"
) > "$INSTALL_FIFO" &

echo "=== M9.R.37 diag install (timeout ${INSTALL_TIMEOUT}s) ===" | tee -a "$INSTALL_LOG"
nix-shell -p qemu OVMF --run "
  qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$INSTALL_VARS \
    -cdrom $ISO \
    -drive file=$DISK,if=virtio,format=qcow2 \
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
  echo "[m9r37-install] ${INSTALL_TIMEOUT}s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9R37 install log (last 250 lines) ==="
tail -250 "$INSTALL_LOG"

echo ""
echo "=== M9R37_KERNELSTACKS_TAIL ==="
sed -n '/M9R37_KERNELSTACKS_TAIL/,/M9R37_STRACE_TAIL/p' "$INSTALL_LOG" | head -200

echo ""
echo "=== M9R37_STRACE_TAIL ==="
sed -n '/M9R37_STRACE_TAIL/,/M9R37_STRACE_FIRST_300/p' "$INSTALL_LOG" | head -200

echo ""
echo "=== M9R37_STRACE_FIRST_300 ==="
sed -n '/M9R37_STRACE_FIRST_300/,/M9R37_KILLING_INSTALLER_IF_ALIVE/p' "$INSTALL_LOG" | head -200

date
