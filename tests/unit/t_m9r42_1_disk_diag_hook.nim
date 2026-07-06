## M9.R.42.1 — pin the ``REPRO_DISK_DIAG`` kernel-state snapshot hook.
##
## Spec: ``recipes/reproos-iso/run-evidence/m9r41_complete.txt`` PHASE G
## (the Phase 2 race characterisation handoff).
##
## The M9.R.41.13 close-out documented an sgdisk false-alarm + a
## /dev/vda1 absence race on the M9.R.41 base-rootfs (Debian Trixie
## kernel 6.12.86 + virtio-blk + systemd-udev 257.13).  M9.R.41.8-12
## attempted 5 pragmatic workarounds (partprobe + sync, alignment,
## explicit start sector, tolerate exit 4, retry the probe) and all
## five were REVERTED because none actually closed the gap.
##
## M9.R.42.1 starts with characterisation BEFORE proposing a fix:
## ``REPRO_DISK_DIAG=<path>`` causes ``disk_apply.nim`` to append a
## kernel-state snapshot to ``<path>`` before AND after each sgdisk +
## partprobe call.  The snapshot captures /proc/partitions, /dev/<base>*,
## /sys/block, /dev/disk/by-partuuid, and an ``udevadm settle`` exit
## so the time-series of state can be inspected post-mortem inside
## the launcher diag tarball.
##
## This test pins:
##   1. The diag hook is OFF when REPRO_DISK_DIAG is unset (the
##      hot path stays clean — no file IO, no diag block emitted).
##   2. The diag hook fires when REPRO_DISK_DIAG is set: the diag
##      file is created + each labelled snapshot block lands.
##   3. The ``snapshotKernelState`` renderer emits the expected
##      label/device header + the ``$ <cmd>`` form per probe.

import std/[os, strutils, tables, unittest]

import repro_profile
import repro_cli_support/disk as cli_disk

const TmpRoot = "build/m9r42_1_tmp"

proc resetDir(sub: string): string =
  let dir = TmpRoot / sub
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

const FixtureSource = """
import repro_profile

hardware "01M9R42-DIAG":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "main":
        device: "/dev/loop99"
        table: gpt
        partitions:
          "esp":
            kind: esp
            size: "512M"
            bootable: true
            content:
              filesystem:
                format: "vfat"
                mountpoint: "/boot"
          "root":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/"
"""

suite "M9.R.42.1: disk-apply kernel-state diag hook":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")
    delEnv("REPRO_DISK_DIAG")

  test "Test#1: diag OFF when REPRO_DISK_DIAG unset (no file IO)":
    delEnv("REPRO_DISK_DIAG")
    check diagPath() == ""
    # Calling diagSnapshot when off must not create any file.
    let dir = resetDir("test1")
    let probePath = dir / "should-not-exist.diag"
    # Tactically point REPRO_DISK_DIAG at a path and unset it again to
    # prove a stale env var doesn't leak.
    putEnv("REPRO_DISK_DIAG", probePath)
    delEnv("REPRO_DISK_DIAG")
    diagSnapshot("test1-label", "/dev/loop99")
    check not fileExists(probePath)

  test "Test#2: snapshotKernelState renders label + device header":
    # Pure-render test: the snapshot block is a string we can
    # introspect even without a real /proc on Windows.
    let s = snapshotKernelState("before-sgdisk-n-esp", "/dev/loop99")
    check s.contains(
      "=== M9.R.42.1 SNAPSHOT label=before-sgdisk-n-esp " &
      "device=/dev/loop99 ts=")
    # Each probe renders as a "$ <cmd>" line.
    check s.contains("$ cat /proc/partitions 2>&1")
    check s.contains("$ ls -la /dev/loop99* 2>&1")
    check s.contains("$ ls /sys/class/block 2>&1")
    check s.contains("$ udevadm settle --timeout=10 2>&1")

  test "Test#3: diag ON wires through applyDiskLayout":
    let dir = resetDir("test3")
    let diagFile = dir / "diag.log"
    putEnv("REPRO_DISK_DIAG", diagFile)
    check diagPath() == diagFile
    # Build a layout fixture via the source path the CLI uses.
    let src = dir / "hardware.nim"
    writeFile(src, FixtureSource)
    # Drive the apply via the CLI under DRY_RUN so no real subprocess
    # spawns, but the diag-hook calls still fire around each sgdisk +
    # partprobe step.
    let rc = runDiskCommand(@["apply", src, "--confirm"])
    check rc == 0
    # The diag file must exist and carry at least the snapshot block
    # labels we wired in (one BEFORE + one AFTER for the gpt table,
    # and one BEFORE + one AFTER for each partition + partprobe).
    check fileExists(diagFile)
    let body = readFile(diagFile)
    check body.contains("label=before-table-main")
    check body.contains("label=after-table-main")
    check body.contains("label=before-sgdisk-n-esp")
    check body.contains("label=after-sgdisk-n-esp")
    check body.contains("label=before-sgdisk-n-root")
    check body.contains("label=after-sgdisk-n-root")
    # partprobe-around snapshots fire only when partprobe is in PATH;
    # on the Windows test host findExe returns "" so we expect either
    # both partprobe-snapshot blocks or neither — gate on
    # before+after consistency.
    let hasBeforePartprobe = body.contains(
      "label=before-partprobe-main")
    let hasAfterPartprobe = body.contains(
      "label=after-partprobe-main")
    check hasBeforePartprobe == hasAfterPartprobe
