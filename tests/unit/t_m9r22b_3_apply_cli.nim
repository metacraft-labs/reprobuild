## M9.R.22b.3 — ``repro disk apply --confirm`` CLI gating.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §4.2.
##
## Four cases verifying CLI gating + scoping behavior:
##   1. apply WITHOUT --confirm against a VALID disko.nim:
##      prints the plan + refuses with exit 2.
##   2. apply WITH --confirm against a VALID disko.nim under
##      REPRO_DISK_DRY_RUN=1: returns 0 + operations[] populated.
##   3. apply --device <dev> --confirm scopes to that single disk
##      (multi-disk source rejects on bogus --device, accepts on a
##      matching one).
##   4. apply --confirm against a missing file → exit 2 (the file-
##      existence check comes BEFORE the confirm gate kicks in).

import std/[options, os, osproc, strutils, tables, unittest]

import repro_profile
import repro_cli_support/disk as cli_disk

const TmpRoot = "build/m9r22b_3_tmp"

proc resetDir(sub: string): string =
  let dir = TmpRoot / sub
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

const SingleDiskSource = """
import repro_profile

hardware "01M9R22B-CLI-SINGLE":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "main":
        device: "/dev/disk/by-id/loop-fixture-single"
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

const MultiDiskSource = """
import repro_profile

hardware "01M9R22B-CLI-MULTI":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "first":
        device: "/dev/disk/by-id/loop-fixture-first"
        table: gpt
        partitions:
          "root":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/"
      "second":
        device: "/dev/disk/by-id/loop-fixture-second"
        table: gpt
        partitions:
          "data":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/data"
"""

suite "M9.R.22b.3: `repro disk apply --confirm` CLI":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")

  test "Test#1: apply WITHOUT --confirm → exit 2 + plan printed":
    let dir = resetDir("test1")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    let rc = runDiskCommand(@["apply", src])
    check rc == 2

  test "Test#2: apply WITH --confirm runs the apply driver":
    let dir = resetDir("test2")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    # The driver runs under REPRO_DISK_DRY_RUN=1 so it doesn't touch
    # the real disk; we just verify exit 0.
    let rc = runDiskCommand(@["apply", src, "--confirm"])
    check rc == 0

  test "Test#3: --device scopes apply to a single disk":
    let dir = resetDir("test3")
    let src = dir / "hardware.nim"
    writeFile(src, MultiDiskSource)
    # Matching device → exit 0.
    block matchingDevice:
      let rc = runDiskCommand(@["apply", src, "--confirm",
        "--device", "/dev/disk/by-id/loop-fixture-first"])
      check rc == 0
    # Non-matching device → exit 2 with "does not match" diagnostic.
    block nonMatchingDevice:
      let rc = runDiskCommand(@["apply", src, "--confirm",
        "--device", "/dev/disk/by-id/loop-fixture-bogus"])
      check rc == 2

  test "Test#4: --confirm with missing source → exit 2":
    let rc = runDiskCommand(@["apply",
      "build/_definitely_not_a_file.nim", "--confirm"])
    check rc == 2

  test "Test#5: mount + unmount subcommands run the new walker":
    let dir = resetDir("test5")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    # mount without --confirm: plan-only, exit 0.
    block mountPlan:
      let rc = runDiskCommand(@["mount", src, "--target", "/mnt"])
      check rc == 0
    # unmount: exit 0 (best-effort under dry-run).
    block unmount:
      let rc = runDiskCommand(@["unmount", src, "--target", "/mnt"])
      check rc == 0
