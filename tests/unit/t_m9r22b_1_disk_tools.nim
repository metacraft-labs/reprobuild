## M9.R.22b.1 — typed Nim wrappers for the disko underlying tools.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §6.2.
##
## All tests run under ``REPRO_DISK_DRY_RUN=1`` so they don't spawn
## any real disk tools (and don't require root). The dry-run mode
## still builds the argv that *would* have run, which is the unit
## that matters at this layer.
##
## Eight cases cover the argv shape across the wrapper matrix:
##   1. partedMklabel + partedSetBootable + sgdiskCreatePartition
##   2. cryptsetupFormat + cryptsetupOpen (mapper path return)
##   3. mkfs.{ext4,vfat,btrfs,swap,xfs}
##   4. btrfsCreateSubvol
##   5. lvmPvCreate + lvmVgCreate + lvmLvCreate (fixed size + %FREE)
##   6. zpoolCreate + zfsCreate (sorted property emission)
##   7. mdadmCreate
##   8. losetupCreate / losetupDetach + partitionDevicePath conventions

import std/[os, strutils, tables, unittest]

import repro_profile

suite "M9.R.22b.1: typed Nim wrappers for the disko underlying tools":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")

  test "Test#1: parted mklabel + set bootable + sgdisk create":
    let mklabel = partedMklabel("/dev/loop0", "gpt")
    check mklabel.exit == 0
    check mklabel.argv == @["parted", "-s", "/dev/loop0", "mklabel",
                            "gpt"]

    let mbr = partedMklabel("/dev/loop0", "mbr")
    check mbr.argv[^1] == "msdos"

    let setBoot = partedSetBootable("/dev/loop0", 1, true)
    check setBoot.argv ==
      @["parted", "-s", "/dev/loop0", "set", "1", "boot", "on"]

    let setNoBoot = partedSetBootable("/dev/loop0", 2, false)
    check setNoBoot.argv[^1] == "off"

    let esp = sgdiskCreatePartition("/dev/loop0", 1, "1MiB",
      "+512MiB", "EF00", "ESP")
    check esp.argv == @["sgdisk",
      "-n", "1:1MiB:+512MiB",
      "-t", "1:EF00",
      "-c", "1:ESP",
      "/dev/loop0"]

    # Empty start/size → "0" placeholders (sgdisk's "default" sentinel).
    let root = sgdiskCreatePartition("/dev/loop0", 2, "", "", "8300", "")
    check root.argv == @["sgdisk",
      "-n", "2:0:0",
      "-t", "2:8300",
      "/dev/loop0"]

    # Invalid partition number rejected.
    expect DiskToolError:
      discard sgdiskCreatePartition("/dev/loop0", 0, "", "", "8300", "")

    # Invalid label kind rejected.
    expect DiskToolError:
      discard partedMklabel("/dev/loop0", "apfs")

  test "Test#2: cryptsetup format + open (mapper path return)":
    var enc: EncryptionSpec
    enc.`type` = "luks2"
    enc.cipher = "aes-xts-plain64"
    enc.allowDiscards = true
    let fmt = cryptsetupFormat("/dev/loop0p2", enc, "swordfish")
    check fmt.argv == @["cryptsetup", "luksFormat",
      "--type", "luks2",
      "--batch-mode",
      "--key-file=-",
      "--cipher", "aes-xts-plain64",
      "--allow-discards",
      "/dev/loop0p2"]

    # Empty passphrase rejected.
    expect DiskToolError:
      discard cryptsetupFormat("/dev/loop0p2", enc, "")

    # Unsupported LUKS type rejected.
    var bad: EncryptionSpec
    bad.`type` = "bitlocker"
    expect DiskToolError:
      discard cryptsetupFormat("/dev/loop0p2", bad, "swordfish")

    # cryptsetupOpen returns the mapper path.
    let mapper = cryptsetupOpen("/dev/loop0p2", "cryptroot", "swordfish")
    check mapper == "/dev/mapper/cryptroot"

    # Empty name rejected.
    expect DiskToolError:
      discard cryptsetupOpen("/dev/loop0p2", "", "swordfish")

    let close = cryptsetupClose("cryptroot")
    check close.argv == @["cryptsetup", "close", "cryptroot"]

  test "Test#3: mkfs.{ext4,vfat,btrfs,swap,xfs} argv shape":
    let ext4 = mkfsExt4("/dev/loop0p2", "rootfs")
    check ext4.argv ==
      @["mkfs.ext4", "-F", "-L", "rootfs", "/dev/loop0p2"]

    let ext4NoLabel = mkfsExt4("/dev/loop0p2")
    check ext4NoLabel.argv == @["mkfs.ext4", "-F", "/dev/loop0p2"]

    let vfat = mkfsVfat("/dev/loop0p1", "ESP")
    check vfat.argv ==
      @["mkfs.vfat", "-F", "32", "-n", "ESP", "/dev/loop0p1"]

    let btrfs = mkfsBtrfs("/dev/loop0p2", "rootfs")
    check btrfs.argv ==
      @["mkfs.btrfs", "-f", "-L", "rootfs", "/dev/loop0p2"]

    let swap = mkfsSwap("/dev/loop0p3", "swap")
    check swap.argv == @["mkswap", "-L", "swap", "/dev/loop0p3"]

    let xfs = mkfsXfs("/dev/loop0p2", "datafs")
    check xfs.argv ==
      @["mkfs.xfs", "-f", "-L", "datafs", "/dev/loop0p2"]

  test "Test#4: btrfsCreateSubvol path composition":
    let s = btrfsCreateSubvol("/mnt/btrfs", "@home")
    check s.argv == @["btrfs", "subvolume", "create",
      "/mnt/btrfs/@home"]

    expect DiskToolError:
      discard btrfsCreateSubvol("", "@home")
    expect DiskToolError:
      discard btrfsCreateSubvol("/mnt/btrfs", "")

  test "Test#5: lvm pvcreate + vgcreate + lvcreate (size + %FREE)":
    let pv = lvmPvCreate("/dev/loop0p2")
    check pv.argv == @["pvcreate", "-ff", "-y", "/dev/loop0p2"]

    let vg = lvmVgCreate("vgroot",
      @["/dev/loop0p2", "/dev/loop1p2"])
    check vg.argv == @["vgcreate", "vgroot",
      "/dev/loop0p2", "/dev/loop1p2"]

    expect DiskToolError:
      discard lvmVgCreate("", @["/dev/sda1"])
    expect DiskToolError:
      discard lvmVgCreate("vgroot", @[])

    let lvFixed = lvmLvCreate("vgroot", "root", "20G")
    check lvFixed.argv ==
      @["lvcreate", "-n", "root", "-L", "20G", "vgroot"]

    let lvFree = lvmLvCreate("vgroot", "home", "100%FREE")
    check lvFree.argv ==
      @["lvcreate", "-n", "home", "-l", "100%FREE", "vgroot"]

    expect DiskToolError:
      discard lvmLvCreate("vgroot", "root", "")

  test "Test#6: zpool create + zfs create (sorted property emission)":
    var props = initTable[string, string]()
    props["ashift"] = "12"
    props["altroot"] = "/mnt"
    let mirror = zpoolCreate("rpool", "mirror",
      @["/dev/loop0p2", "/dev/loop1p2"], props)
    # Sorted keys → altroot before ashift.
    check mirror.argv == @["zpool", "create",
      "-o", "altroot=/mnt",
      "-o", "ashift=12",
      "rpool", "mirror",
      "/dev/loop0p2", "/dev/loop1p2"]

    var empty = initTable[string, string]()
    let stripe = zpoolCreate("tank", "", @["/dev/loop2"], empty)
    check stripe.argv ==
      @["zpool", "create", "tank", "/dev/loop2"]

    let stripeKw = zpoolCreate("tank2", "stripe",
      @["/dev/loop3"], empty)
    # "stripe" is the zpool default → no keyword emitted in argv.
    check stripeKw.argv ==
      @["zpool", "create", "tank2", "/dev/loop3"]

    expect DiskToolError:
      discard zpoolCreate("", "stripe", @["/dev/loop2"], empty)
    expect DiskToolError:
      discard zpoolCreate("rpool", "stripe", @[], empty)
    expect DiskToolError:
      discard zpoolCreate("rpool", "raidzZ", @["/dev/loop2"], empty)

    var dprops = initTable[string, string]()
    dprops["compression"] = "zstd"
    dprops["atime"] = "off"
    let ds = zfsCreate("rpool/root", dprops)
    # Sorted → atime before compression.
    check ds.argv == @["zfs", "create",
      "-o", "atime=off",
      "-o", "compression=zstd",
      "rpool/root"]

    expect DiskToolError:
      discard zfsCreate("", initTable[string, string]())

  test "Test#7: mdadmCreate argv shape + level validation":
    let m1 = mdadmCreate("/dev/md0", "1",
      @["/dev/loop0p1", "/dev/loop1p1"])
    check m1.argv == @["mdadm",
      "--create", "/dev/md0",
      "--level=1",
      "--raid-devices=2",
      "--metadata=1.2",
      "--run",
      "/dev/loop0p1", "/dev/loop1p1"]

    let mMirror = mdadmCreate("/dev/md1", "mirror",
      @["/dev/loop2p1", "/dev/loop3p1"])
    check "--level=1" in mMirror.argv

    let m5 = mdadmCreate("/dev/md0", "5",
      @["/dev/loop0p1", "/dev/loop1p1", "/dev/loop2p1"])
    check "--level=5" in m5.argv
    check "--raid-devices=3" in m5.argv

    expect DiskToolError:
      discard mdadmCreate("/dev/md0", "1", @["/dev/loop0p1"])
    expect DiskToolError:
      discard mdadmCreate("/dev/md0", "raid42", @["/d1", "/d2"])
    expect DiskToolError:
      discard mdadmCreate("", "1", @["/d1", "/d2"])

  test "Test#8: loop devices + partition device path conventions":
    let loop = losetupCreate("/tmp/disko-test.img")
    # Dry-run returns deterministic /dev/loop99.
    check loop == "/dev/loop99"

    let det = losetupDetach("/dev/loop99")
    check det.argv == @["losetup", "--detach", "/dev/loop99"]

    expect DiskToolError:
      discard losetupCreate("")
    expect DiskToolError:
      discard losetupDetach("")

    # partitionDevicePath conventions.
    check partitionDevicePath("/dev/sda", 1) == "/dev/sda1"
    check partitionDevicePath("/dev/sda", 2) == "/dev/sda2"
    check partitionDevicePath("/dev/nvme0n1", 1) == "/dev/nvme0n1p1"
    check partitionDevicePath("/dev/loop0", 1) == "/dev/loop0p1"
    check partitionDevicePath("/dev/mmcblk0", 3) == "/dev/mmcblk0p3"
    check partitionDevicePath(
      "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB", 1) ==
      "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB-part1"
    check partitionDevicePath(
      "/dev/disk/by-path/pci-0000:00:1f.2-ata-1", 2) ==
      "/dev/disk/by-path/pci-0000:00:1f.2-ata-1-part2"

    expect DiskToolError:
      discard partitionDevicePath("/dev/sda", 0)

    # gptTypeCodeFor closed-set mapping.
    check gptTypeCodeFor("esp") == "EF00"
    check gptTypeCodeFor("ptEsp") == "EF00"
    check gptTypeCodeFor("linux") == "8300"
    check gptTypeCodeFor("luks") == "8309"
    check gptTypeCodeFor("lvm") == "8E00"
    check gptTypeCodeFor("swap") == "8200"
    check gptTypeCodeFor("raid") == "FD00"
    check gptTypeCodeFor("zfs") == "BF00"
    check gptTypeCodeFor("bios") == "EF02"
    check gptTypeCodeFor("") == ""
    check gptTypeCodeFor("nonsense") == ""

    # wipefs + mount + umount argv shape (kept here to keep the file
    # focused and avoid a 9th test case for the closing primitives).
    let wipe = wipefsAll("/dev/loop0")
    check wipe.argv == @["wipefs", "-af", "/dev/loop0"]

    let mounted = mountFs("/dev/loop0p2", "/mnt/repro",
                         fsType = "ext4",
                         options = @["noatime", "nodiratime"])
    check mounted.argv == @["mount",
      "-t", "ext4",
      "-o", "noatime,nodiratime",
      "/dev/loop0p2", "/mnt/repro"]

    let umounted = umountFs("/mnt/repro")
    check umounted.argv == @["umount", "/mnt/repro"]
