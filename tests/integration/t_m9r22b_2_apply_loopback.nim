## M9.R.22b.2 — apply driver against loopback devices.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §7 (operation
## ordering) + the apply-driver's 9-step plan.
##
## Four cases:
##   1. GPT + ESP (vfat) + ext4 root              — argv-shape under dry-run
##   2. GPT + LUKS + btrfs + subvols              — argv-shape + walker recursion
##   3. mdraid mirror + LVM + ext4                — argv-shape across multi-disk
##   4. --confirm gate: applyDiskLayout itself doesn't gate (that's
##      the CLI's job — verified separately in t_m9r22b_3_apply_cli.nim);
##      this case verifies that applyDiskLayout's failure path captures
##      the FIRST error and stops apply (no partial-apply continuation).
##
## All four cases run under ``REPRO_DISK_DRY_RUN=1`` by default so they
## work on Windows + any other host without the disk tools installed.
## On Linux + with ``REPRO_DISK_LOOPBACK_E2E=1``, case #1 ALSO runs
## end-to-end against a real loopback image and verifies the layout
## via ``blkid``.

import std/[options, os, osproc, sequtils, strutils, tables, unittest]

import repro_profile

# ---------------------------------------------------------------------
# Layout builders — keep the test bodies focused on assertions.
# ---------------------------------------------------------------------

proc buildSimpleEsp4Layout(device: string): DiskLayout =
  ## GPT + 512M ESP (vfat → /boot) + remainder ext4 root (→ /).
  var d: DiskSpec
  d.device = device
  d.`type` = "gpt"

  var esp: PartitionSpec
  esp.`type` = "esp"
  esp.size = "512M"
  esp.bootable = true
  esp.content = ContentSpec(kind: cfsFilesystem,
    format: "vfat", mountpoint: "/boot", label: "ESP")
  d.partitions["esp"] = esp

  var root: PartitionSpec
  root.`type` = "linux"
  root.size = "100%"
  root.content = ContentSpec(kind: cfsFilesystem,
    format: "ext4", mountpoint: "/", label: "rootfs")
  d.partitions["root"] = root

  result.disks["main"] = d

proc buildLuksBtrfsLayout(device: string): DiskLayout =
  ## GPT + ESP + LUKS-on-partition + btrfs-inside-LUKS w/ subvols.
  var d: DiskSpec
  d.device = device
  d.`type` = "gpt"

  var esp: PartitionSpec
  esp.`type` = "esp"
  esp.size = "512M"
  esp.bootable = true
  esp.content = ContentSpec(kind: cfsFilesystem,
    format: "vfat", mountpoint: "/boot", label: "ESP")
  d.partitions["esp"] = esp

  var luksPart: PartitionSpec
  luksPart.`type` = "luks"
  luksPart.size = "100%"
  var inner: ref ContentSpec
  inner = new(ContentSpec)
  inner[] = ContentSpec(kind: cfsFilesystem,
    format: "btrfs", mountpoint: "/", label: "rootfs",
    subvols: @[
      BtrfsSubvolSpec(path: "@",         options: @["compress=zstd"]),
      BtrfsSubvolSpec(path: "@home",     options: @["compress=zstd"]),
      BtrfsSubvolSpec(path: "@snapshots", options: @[])
    ])
  luksPart.content = ContentSpec(kind: cfsEncrypted,
    encryption: EncryptionSpec(
      `type`: "luks2",
      cipher: "aes-xts-plain64",
      allowDiscards: true),
    inner: inner)
  d.partitions["cryptroot"] = luksPart

  result.disks["main"] = d

proc buildMdraidLvmLayout(d1, d2: string): DiskLayout =
  ## Two-disk GPT + mirror + LVM on top of the mirror + ext4 root.
  ## For the apply-driver's argv walker we model the layout as two
  ## raw devices whose `linux` partitions feed the md array; the
  ## mdadm create + LVM PV/VG/LV happens at the partition-content
  ## level for d1, while d2 contributes the second mirror leg.
  var diskA: DiskSpec
  diskA.device = d1
  diskA.`type` = "gpt"
  var raidA: PartitionSpec
  raidA.`type` = "raid"
  raidA.size = "100%"
  # LVM on a single device (the md array we'd assemble in production
  # would normally feed the PV). For the apply argv shape we just
  # exercise the PV/VG/LV walker.
  var rootContent: ref ContentSpec
  rootContent = new(ContentSpec)
  rootContent[] = ContentSpec(kind: cfsFilesystem,
    format: "ext4", mountpoint: "/", label: "rootfs")
  raidA.content = ContentSpec(kind: cfsLvm,
    vg: "vgroot",
    volumes: @[LvmVolumeSpec(name: "root",
      size: "100%FREE", content: rootContent)])
  diskA.partitions["raid"] = raidA
  result.disks["main"] = diskA

  var diskB: DiskSpec
  diskB.device = d2
  diskB.`type` = "gpt"
  var raidB: PartitionSpec
  raidB.`type` = "raid"
  raidB.size = "100%"
  raidB.content = ContentSpec(kind: cfsNone)
  diskB.partitions["raid"] = raidB
  result.disks["mirror"] = diskB

# ---------------------------------------------------------------------

suite "M9.R.22b.2: apply driver against loopback / dry-run":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")

  test "Test#1: GPT + ESP (vfat) + ext4 root — argv shape":
    let layout = buildSimpleEsp4Layout("/dev/loop0")
    let r = applyDiskLayout(layout)
    check not r.failure
    # Expected operations (in canonical disko order):
    #   umount /dev/loop0, umount /dev/loop0p1, umount /dev/loop0p2
    #   wipefs -af /dev/loop0
    #   parted mklabel gpt
    #   sgdisk -n 1:0:+512M -t 1:EF00 -c 1:esp
    #   parted set 1 boot on
    #   sgdisk -n 2:0:0 -t 2:8300 -c 2:root
    #   mkfs.vfat -F 32 -n ESP /dev/loop0p1
    #   mkfs.ext4 -F -L rootfs /dev/loop0p2
    var seenTools: seq[string] = @[]
    for op in r.operations: seenTools.add op.tool
    check "wipefs" in seenTools
    check "parted" in seenTools
    check "sgdisk" in seenTools
    check "mkfs.vfat" in seenTools
    check "mkfs.ext4" in seenTools
    # The first mkfs operation is for the ESP (1st partition).
    var espOp: ExecResult
    var rootOp: ExecResult
    for op in r.operations:
      if op.tool == "mkfs.vfat": espOp = op
      if op.tool == "mkfs.ext4": rootOp = op
    check espOp.argv ==
      @["mkfs.vfat", "-F", "32", "-n", "ESP", "/dev/loop0p1"]
    check rootOp.argv ==
      @["mkfs.ext4", "-F", "-L", "rootfs", "/dev/loop0p2"]
    # Partition table goes through partedMklabel BEFORE any sgdisk -n.
    var labelIdx = -1
    var firstSgdiskIdx = -1
    for i, op in r.operations:
      if op.tool == "parted" and "mklabel" in op.argv and labelIdx < 0:
        labelIdx = i
      if op.tool == "sgdisk" and firstSgdiskIdx < 0:
        firstSgdiskIdx = i
    check labelIdx >= 0
    check firstSgdiskIdx >= 0
    check labelIdx < firstSgdiskIdx

  test "Test#2: GPT + LUKS + btrfs + subvols — walker recursion":
    let layout = buildLuksBtrfsLayout("/dev/loop1")
    let r = applyDiskLayout(layout, {
      "main.cryptroot": "swordfish"
    }.toTable)
    check not r.failure
    var seenTools: seq[string] = @[]
    for op in r.operations: seenTools.add op.tool
    # All expected stages present.
    check "wipefs" in seenTools
    check "parted" in seenTools
    check "sgdisk" in seenTools
    check "cryptsetup" in seenTools   # luksFormat + open
    check "mkfs.btrfs" in seenTools
    check "btrfs" in seenTools         # subvolume create
    # 3 btrfs subvol creates.
    var subvolCount = 0
    for op in r.operations:
      if op.tool == "btrfs" and "subvolume" in op.argv:
        inc subvolCount
    check subvolCount == 3
    # cryptsetup luksFormat comes BEFORE mkfs.btrfs (the FS is created
    # INSIDE the LUKS container; the mapper device is what mkfs sees).
    var luksFmtIdx = -1
    var mkfsBtrfsIdx = -1
    for i, op in r.operations:
      if op.tool == "cryptsetup" and "luksFormat" in op.argv:
        luksFmtIdx = i
      if op.tool == "mkfs.btrfs":
        mkfsBtrfsIdx = i
    check luksFmtIdx >= 0
    check mkfsBtrfsIdx >= 0
    check luksFmtIdx < mkfsBtrfsIdx

  test "Test#3: mdraid + LVM + ext4 — argv shape across multi-disk":
    let layout = buildMdraidLvmLayout("/dev/loop2", "/dev/loop3")
    let r = applyDiskLayout(layout)
    check not r.failure
    var seenTools: seq[string] = @[]
    for op in r.operations: seenTools.add op.tool
    check "pvcreate" in seenTools
    check "vgcreate" in seenTools
    check "lvcreate" in seenTools
    check "mkfs.ext4" in seenTools
    # Both disks wiped + partitioned.
    var wipeCount = 0
    for op in r.operations:
      if op.tool == "wipefs": inc wipeCount
    check wipeCount == 2
    # PV-then-VG-then-LV order strictly enforced.
    var pvIdx, vgIdx, lvIdx = -1
    for i, op in r.operations:
      if op.tool == "pvcreate" and pvIdx < 0: pvIdx = i
      if op.tool == "vgcreate" and vgIdx < 0: vgIdx = i
      if op.tool == "lvcreate" and lvIdx < 0: lvIdx = i
    check pvIdx >= 0
    check vgIdx > pvIdx
    check lvIdx > vgIdx
    # LV's underlying ext4 mkfs targets /dev/<vg>/<lv>.
    var mkfsTarget = ""
    for op in r.operations:
      if op.tool == "mkfs.ext4":
        mkfsTarget = op.argv[^1]
    check mkfsTarget == "/dev/vgroot/root"

  test "Test#4: failure path captures first error and stops":
    # Build a layout that's INVALID at the apply layer: a partition
    # asks for a filesystem format we don't support. The walker raises
    # DiskToolError mid-apply; applyDiskLayout catches it and surfaces
    # the failure structurally (NO graceful continue).
    var layout = buildSimpleEsp4Layout("/dev/loop4")
    layout.disks["main"].partitions["root"].content =
      ContentSpec(kind: cfsFilesystem,
        format: "bogusfs", mountpoint: "/")
    let r = applyDiskLayout(layout)
    check r.failure
    check "bogusfs" in r.failureMsg
    # Operations BEFORE the bogus one ran; the bogus one is where we
    # stopped. The ESP partition's mkfs.vfat preceded the bad root.
    var sawVfat = false
    var sawBogus = false
    for op in r.operations:
      if op.tool == "mkfs.vfat": sawVfat = true
      if op.tool == "bogusfs": sawBogus = true
    check sawVfat
    check not sawBogus

# ---------------------------------------------------------------------
# Linux-only loopback e2e test (real apply against /tmp/disko-test.img).
# Skipped automatically on Windows + when REPRO_DISK_LOOPBACK_E2E≠1.
# ---------------------------------------------------------------------

when defined(linux):
  import std/posix

  suite "M9.R.22b.2: loopback end-to-end (Linux, --loopback gated)":

    proc canRunLoopbackE2e(): bool =
      if getEnv("REPRO_DISK_LOOPBACK_E2E") != "1": return false
      # losetup / parted / sgdisk / mkfs.ext4 / mkfs.vfat must exist.
      for tool in ["losetup", "parted", "sgdisk",
                   "mkfs.ext4", "mkfs.vfat", "wipefs"]:
        if findExe(tool).len == 0: return false
      # Root privilege required for losetup --find.
      if getEnv("USER") != "root" and posix.geteuid() != 0: return false
      return true

    test "Test#5 (loopback): simple-ext4 against a 128M image":
      if not canRunLoopbackE2e():
        skip()
        return
      # Set up a real 128M loopback image.
      let img = "/tmp/disko-test-m9r22b-2.img"
      if fileExists(img): removeFile(img)
      let dd = execCmdEx("dd if=/dev/zero of=" & img &
        " bs=1M count=128 status=none")
      check dd.exitCode == 0
      defer:
        try: removeFile(img) except: discard
      # Create the loop device.
      let loopDev = losetupCreate(img)
      defer:
        try: discard losetupDetach(loopDev) except: discard
      # Apply: GPT + ESP + ext4 root.
      let layout = buildSimpleEsp4Layout(loopDev)
      let r = applyDiskLayout(layout)
      check not r.failure
      if r.failure:
        echo "operations log:"
        for op in r.operations:
          echo "  ", op.tool, ": ", op.cmd, " (exit ", op.exit, ")"
        echo "failure: ", r.failureMsg
      # Verify with blkid: the ext4 root should be detected on the
      # second partition (loopNp2 on Linux).
      let p2 = partitionDevicePath(loopDev, 2)
      let blkidR = execCmdEx("blkid -s TYPE -o value " & p2)
      check blkidR.exitCode == 0
      check blkidR.output.strip() == "ext4"
      # ESP on p1.
      let p1 = partitionDevicePath(loopDev, 1)
      let blkidP1 = execCmdEx("blkid -s TYPE -o value " & p1)
      check blkidP1.exitCode == 0
      check blkidP1.output.strip() == "vfat"
