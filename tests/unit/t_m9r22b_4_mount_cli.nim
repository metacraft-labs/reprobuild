## M9.R.22b.4 — ``repro disk mount`` mount-order + cleanup checks.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §4.3.
##
## Three cases verifying mount-order correctness + cleanup:
##   1. simple-ext4: "/" mounts BEFORE "/boot" (shallow first).
##   2. LUKS+btrfs+subvols: the top-level btrfs mounts BEFORE the
##      subvol mounts; mapper-path translation works (the inner
##      content mounts via /dev/mapper/<name>_crypt rather than the
##      LUKS-encrypted block device).
##   3. multi-fs nested: deeper mountpoints sort AFTER shallower ones
##      (so "/" → "/boot" → "/boot/efi" if such a layout exists).

import std/[options, os, strutils, tables, unittest]

import repro_profile

suite "M9.R.22b.4: mount-order correctness + cleanup":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")

  test "Test#1: simple-ext4 mount-plan ordering":
    var d: DiskSpec
    d.device = "/dev/loop0"
    d.`type` = "gpt"

    var esp: PartitionSpec
    esp.size = "512M"
    esp.bootable = true
    esp.content = ContentSpec(kind: cfsFilesystem,
      format: "vfat", mountpoint: "/boot")
    d.partitions["esp"] = esp

    var root: PartitionSpec
    root.size = "100%"
    root.content = ContentSpec(kind: cfsFilesystem,
      format: "ext4", mountpoint: "/")
    d.partitions["root"] = root

    var dl: DiskLayout
    dl.disks["main"] = d

    let plan = collectMountPlan(dl, "/mnt")
    check plan.len == 2
    # Shallow ("/" → /mnt) sorts before "/boot" → /mnt/boot.
    check plan[0] == ("/dev/loop0p2", "/mnt")
    check plan[1] == ("/dev/loop0p1", "/mnt/boot")

  test "Test#2: LUKS+btrfs+subvols translates mapper path":
    var d: DiskSpec
    d.device = "/dev/loop1"
    d.`type` = "gpt"

    var esp: PartitionSpec
    esp.size = "512M"
    esp.bootable = true
    esp.content = ContentSpec(kind: cfsFilesystem,
      format: "vfat", mountpoint: "/boot")
    d.partitions["esp"] = esp

    var luks: PartitionSpec
    luks.size = "100%"
    var inner: ref ContentSpec
    inner = new(ContentSpec)
    inner[] = ContentSpec(kind: cfsFilesystem,
      format: "btrfs", mountpoint: "/",
      subvols: @[
        BtrfsSubvolSpec(path: "@",     options: @[]),
        BtrfsSubvolSpec(path: "@home", options: @[])
      ])
    luks.content = ContentSpec(kind: cfsEncrypted,
      encryption: EncryptionSpec(`type`: "luks2"),
      inner: inner)
    d.partitions["cryptroot"] = luks

    var dl: DiskLayout
    dl.disks["main"] = d

    let plan = collectMountPlan(dl, "/mnt")
    # 4 entries expected:
    #   ("/dev/mapper/loop1p2_crypt", "/mnt")       — top-level btrfs
    #   ("/dev/loop1p1",              "/mnt/boot")  — ESP
    #   ("/dev/mapper/loop1p2_crypt", "/mnt/@")     — btrfs subvol @
    #   ("/dev/mapper/loop1p2_crypt", "/mnt/@home") — btrfs subvol @home
    check plan.len == 4
    # The "/" mount comes first (depth 1).
    var rootMp = ""
    var bootMp = ""
    var atMp = ""
    var homeMp = ""
    for (dev, mp) in plan:
      if mp == "/mnt": rootMp = dev
      elif mp == "/mnt/boot": bootMp = dev
      elif mp == "/mnt/@": atMp = dev
      elif mp == "/mnt/@home": homeMp = dev
    # Both partitions are numbered: esp -> loop1p1, cryptroot -> loop1p2.
    check rootMp == "/dev/mapper/loop1p2_crypt"
    check bootMp == "/dev/loop1p1"
    check atMp == "/dev/mapper/loop1p2_crypt"
    check homeMp == "/dev/mapper/loop1p2_crypt"
    # Ordering: shallowest first.
    check plan[0][1] == "/mnt"

  test "Test#3: deeper mountpoints come AFTER shallower":
    var d: DiskSpec
    d.device = "/dev/loop2"
    d.`type` = "gpt"

    var p1: PartitionSpec
    p1.size = "100M"
    p1.content = ContentSpec(kind: cfsFilesystem,
      format: "vfat", mountpoint: "/boot/efi")
    d.partitions["esp"] = p1

    var p2: PartitionSpec
    p2.size = "1G"
    p2.content = ContentSpec(kind: cfsFilesystem,
      format: "ext4", mountpoint: "/boot")
    d.partitions["boot"] = p2

    var p3: PartitionSpec
    p3.size = "100%"
    p3.content = ContentSpec(kind: cfsFilesystem,
      format: "ext4", mountpoint: "/")
    d.partitions["root"] = p3

    var dl: DiskLayout
    dl.disks["main"] = d

    let plan = collectMountPlan(dl, "/mnt")
    check plan.len == 3
    # The sort is stable + by-depth: "/" (1 slash) → "/boot" (2 slashes) → "/boot/efi" (3 slashes).
    check plan[0][1] == "/mnt"
    check plan[1][1] == "/mnt/boot"
    check plan[2][1] == "/mnt/boot/efi"

    # The unmount plan reverses the order so the deepest comes off
    # first — verified indirectly by checking that the apply driver's
    # unmountDiskLayout traverses in countdown order. (We can't
    # capture stderr here easily, so we just exercise the call to
    # make sure it doesn't raise.)
    unmountDiskLayout(plan)
