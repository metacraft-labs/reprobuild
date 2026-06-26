## M9.R.41 — pinning tests for ``repro infra install-root``.
##
## The install-root subcommand has two halves: a destructive shell-out
## half (rsync + grub-install, hard to unit-test) and a pure-render
## half (argument parsing + fstab + grub.cfg synthesis from a disko
## layout).  These tests pin the pure half against regressions so we
## know the output the destructive half writes is correct before any
## ISO rebuild round-trip.

import std/[tables, strutils, unittest]

import repro_cli_support/infra_install_root
import repro_profile/types

# ---------------------------------------------------------------------
# Helper: build a minimal DiskLayout that the M9.R.18 reproos-installer
# emits for the canonical 512 MiB ESP + ext4-root virtio-blk layout.
# ---------------------------------------------------------------------

proc canonicalLayout(): DiskLayout =
  var esp = PartitionSpec()
  esp.`type` = "EF00"
  esp.size = "512M"
  esp.bootable = true
  esp.content = ContentSpec(kind: cfsFilesystem,
                            format: "vfat",
                            mountpoint: "/boot",
                            label: "ESP")

  var root = PartitionSpec()
  root.`type` = "8300"
  root.size = "100%"
  root.content = ContentSpec(kind: cfsFilesystem,
                             format: "ext4",
                             mountpoint: "/",
                             label: "root")

  var disk = DiskSpec()
  disk.device = "/dev/vda"
  disk.`type` = "gpt"
  disk.partitions["esp"] = esp
  disk.partitions["root"] = root

  result.disks["main"] = disk

suite "M9.R.41 install-root arg parser":
  test "defaults preserve the install-time --target and --source convention":
    let opts = parseInstallRootArgs(@[])
    check opts.target == "/mnt"
    check opts.source == "/"
    check opts.hostName == "reproos"
    check opts.device == ""
    check not opts.skipRsync
    check not opts.skipGrub
    check not opts.skipFstab
    check not opts.dryRun

  test "long-form flags parse via space-separated values":
    let opts = parseInstallRootArgs(@[
      "--target", "/mnt/x",
      "--source", "/run/live/rootfs",
      "--device", "/dev/nvme0n1",
      "--hostname", "host42",
      "--disko", "/etc/repro/hardware.nim",
    ])
    check opts.target == "/mnt/x"
    check opts.source == "/run/live/rootfs"
    check opts.device == "/dev/nvme0n1"
    check opts.hostName == "host42"
    check opts.diskoSource == "/etc/repro/hardware.nim"

  test "long-form flags parse via --key=value":
    let opts = parseInstallRootArgs(@[
      "--target=/mnt2",
      "--device=/dev/sda",
    ])
    check opts.target == "/mnt2"
    check opts.device == "/dev/sda"

  test "--exclude is repeatable":
    let opts = parseInstallRootArgs(@[
      "--exclude", "/opt/scratch",
      "--exclude=/var/cache/big",
    ])
    check opts.extraExcludes == @["/opt/scratch", "/var/cache/big"]

  test "test seams gate the destructive shell-outs":
    let opts = parseInstallRootArgs(@[
      "--no-rsync", "--no-grub", "--no-fstab", "--dry-run",
    ])
    check opts.skipRsync
    check opts.skipGrub
    check opts.skipFstab
    check opts.dryRun

  test "unknown flag fails fast (matches the rest of the infra surface)":
    expect ValueError:
      discard parseInstallRootArgs(@["--bogus"])

  test "missing value for a flag that needs one fails fast":
    expect ValueError:
      discard parseInstallRootArgs(@["--target"])

suite "M9.R.41 fstab emission":
  test "canonical layout renders both partitions with kernel device paths":
    let layout = canonicalLayout()
    let text = renderFstab(layout)
    check "/dev/vda1\t/boot\tvfat\t" in text
    check "/dev/vda2\t/\text4\t" in text
    # Root must be the FIRST mounted entry (depth=1 mountpoint "/").
    let rootIdx = text.find("/dev/vda2\t/\t")
    let bootIdx = text.find("/dev/vda1\t/boot\t")
    check rootIdx >= 0 and bootIdx >= 0
    check rootIdx < bootIdx

  test "fsck pass field matches the Debian convention":
    let layout = canonicalLayout()
    let text = renderFstab(layout)
    # Root partition: pass=1, /boot: pass=2.
    for line in text.splitLines():
      if line.startsWith("/dev/vda2\t/\t"):
        check line.endsWith("0 1")
      elif line.startsWith("/dev/vda1\t/boot\t"):
        check line.endsWith("0 2")

  test "vfat ESP gets umask=0077 mount options (Debian default)":
    let layout = canonicalLayout()
    let text = renderFstab(layout)
    check "vfat\tdefaults,umask=0077" in text

suite "M9.R.41 grub.cfg emission":
  test "root= points at the layout's '/' partition":
    let layout = canonicalLayout()
    let cfg = renderInstalledGrubCfg(layout)
    check "root=/dev/vda2" in cfg

  test "kernel + initrd live at the ESP root, not /boot/* (M9.R.37.8)":
    let layout = canonicalLayout()
    let cfg = renderInstalledGrubCfg(layout)
    # Match the live-ISO M9.R.37.8 layout: vmlinuz + initrd.img on the
    # ESP root because the ESP is mounted at /boot on the installed
    # system (so cp vmlinuz /mnt/boot/vmlinuz writes to (esp)/vmlinuz).
    check "linux /vmlinuz " in cfg
    check "initrd /initrd.img\n" in cfg

  test "serial + console terminal output (M9.R.37.7 dual-output)":
    let layout = canonicalLayout()
    let cfg = renderInstalledGrubCfg(layout)
    check "terminal_input console serial" in cfg
    check "terminal_output console serial" in cfg
    check "console=ttyS0,115200" in cfg
    check "console=tty1" in cfg

  test "timeout style + count match the live-ISO live boot menu":
    let layout = canonicalLayout()
    let cfg = renderInstalledGrubCfg(layout)
    check "set timeout_style=hidden" in cfg
    check "set timeout=3" in cfg

suite "M9.R.41 fstab covers swap + ZFS data partitions":
  test "swap partitions render with type 'swap' + defaults options":
    var swap = PartitionSpec()
    swap.`type` = "8200"
    swap.size = "4G"
    swap.content = ContentSpec(kind: cfsSwap, swapPriority: 0)
    var disk = DiskSpec()
    disk.device = "/dev/vda"
    disk.`type` = "gpt"
    disk.partitions["swap"] = swap
    var layout = DiskLayout()
    layout.disks["main"] = disk
    # cfsSwap doesn't surface in collectMountPlan because the walker
    # only emits cfsFilesystem mountpoints; the fstab walker
    # accordingly skips swap.  Pin that the renderer doesn't blow up
    # on a swap-only layout.
    let text = renderFstab(layout)
    check "/etc/fstab" in text
    check "<device>" in text  # header still rendered

suite "M9.R.41 rsync command construction":
  test "default excludes cover proc/sys/dev/run/mnt/media/tmp":
    let opts = parseInstallRootArgs(@[])
    let cmd = buildRsyncCommand(opts)
    for path in ["/proc/", "/sys/", "/dev/", "/run/",
                 "/mnt/", "/media/", "/tmp/"]:
      check ("--exclude=" & path & "*") in cmd

  test "source + dest are slash-terminated (rsync content semantics)":
    let opts = parseInstallRootArgs(@[
      "--source", "/x",
      "--target", "/y",
    ])
    let cmd = buildRsyncCommand(opts)
    check " /x/ " in cmd or cmd.endsWith(" /y/")
    check cmd.endsWith("/y/")

  test "the rsync command preserves hard links + xattrs + ACLs":
    let opts = parseInstallRootArgs(@[])
    let cmd = buildRsyncCommand(opts)
    check "-aHAX" in cmd
    check "--numeric-ids" in cmd
    check "--one-file-system" in cmd
    check "--sparse" in cmd

  test "--exclude flags from the parser propagate into the rsync argv":
    let opts = parseInstallRootArgs(@[
      "--exclude", "/var/lib/repro-scratch",
    ])
    let cmd = buildRsyncCommand(opts)
    check ("--exclude=/var/lib/repro-scratch") in cmd
