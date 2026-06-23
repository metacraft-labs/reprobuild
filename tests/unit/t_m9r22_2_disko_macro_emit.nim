## M9.R.22.2 — ``hardware "<id>": ... disko:`` macro parses + emits.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §2.2 surface +
## §3.1 Tier-1 layouts.
##
## Four cases:
##   1. Empty ``disko:`` block produces an empty DiskLayout.
##   2. Single GPT disk with ext4 root (simple-ext4 Tier-1 layout).
##   3. LUKS encryption wrapping btrfs + subvolumes (luks-btrfs Tier-1).
##   4. ZFS pool composition mirrors zahary's home-pc dotfiles
##      (zfs-rpool-userdata Tier-1).
##
## Each test uses ``buildHardwareSpec`` (the programmatic-builder form
## of the ``hardware`` macro) to construct a SystemHardwareSpec at
## compile time, then asserts the disko sub-tree matches the
## hand-rolled expectation.

import std/[options, tables, unittest]

import repro_profile

suite "M9.R.22.2: disko macro parses + emits":

  test "Test#1: empty disko: block → present-but-empty DiskLayout":
    let spec = buildHardwareSpec("01EMPTY"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
      disko:
        discard
    check spec.disko.isSome
    let dl = spec.disko.get()
    check dl.disks.len == 0
    check dl.pools.len == 0
    # JSON round-trip preserves the empty disko block.
    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check back.disko.isSome
    check back.disko.get().disks.len == 0
    check back.disko.get().pools.len == 0

  test "Test#2: simple-ext4 GPT + ESP + ext4 root":
    let spec = buildHardwareSpec("01SIMPLE"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
      disko:
        disks:
          "main":
            device: "/dev/disk/by-id/ata-SimpleSSD"
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
                    mountOptions: @["noatime"]

    check spec.disko.isSome
    let dl = spec.disko.get()
    check dl.disks.len == 1
    let main = dl.disks["main"]
    check main.device == "/dev/disk/by-id/ata-SimpleSSD"
    check main.`type` == "gpt"
    check main.partitions.len == 2
    let esp = main.partitions["esp"]
    check esp.`type` == "esp"
    check esp.size == "512M"
    check esp.bootable
    check esp.content.kind == cfsFilesystem
    check esp.content.format == "vfat"
    check esp.content.mountpoint == "/boot"
    let root = main.partitions["root"]
    check root.size == "100%"
    check not root.bootable
    check root.content.kind == cfsFilesystem
    check root.content.format == "ext4"
    check root.content.mountOptions == @["noatime"]
    # JSON round-trip yields identical bytes.
    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check emitSystemHardwareJson(back) == s

  test "Test#3: LUKS encryption wrapping btrfs + subvolumes":
    let spec = buildHardwareSpec("01LUKSBTRFS"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
      disko:
        disks:
          "main":
            device: "/dev/disk/by-id/nvme-Crypted"
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
                kind: luks
                size: "100%"
                content:
                  encrypted:
                    encryption:
                      kind: "luks2"
                      keyFile: "interactive"
                      cipher: "aes-xts-plain64"
                      allowDiscards: true
                    inner:
                      filesystem:
                        format: "btrfs"
                        mountpoint: "/"
                        subvols:
                          "@home":
                            path: "/home"
                            options: @["compress=zstd"]
                          "@nix":
                            path: "/nix"
                            options: @["compress=zstd", "noatime"]

    let dl = spec.disko.get()
    let root = dl.disks["main"].partitions["root"]
    check root.content.kind == cfsEncrypted
    check root.content.encryption.`type` == "luks2"
    check root.content.encryption.keyFile == "interactive"
    check root.content.encryption.cipher == "aes-xts-plain64"
    check root.content.encryption.allowDiscards
    check not root.content.inner.isNil
    check root.content.inner[].kind == cfsFilesystem
    check root.content.inner[].format == "btrfs"
    let sv = root.content.inner[].subvols
    check sv.len == 2
    check sv[0].path == "/home"
    check sv[0].options == @["compress=zstd"]
    check sv[1].path == "/nix"
    check sv[1].options == @["compress=zstd", "noatime"]

  test "Test#4: ZFS pool composition mirrors home-pc dotfiles":
    # Mirrors ~/dotfiles/machines/home-pc/hardware-configuration.nix:
    # the rpool holds nixos/* system datasets, userdata holds the home
    # tree, and the partition's content is a ZFS reference.
    let spec = buildHardwareSpec("01HOMEPC"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
      boot:
        kernelModules: @["xhci_pci", "ahci", "nvme", "sd_mod"]
        loaderDevice: "/dev/disk/by-uuid/DC9C-BB8C"
      disko:
        disks:
          "boot":
            device: "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB"
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
              "rpool":
                kind: zfs
                size: "100%"
                content:
                  zfs:
                    pool: "rpool"
                    dataset: "rpool/nixos/root"
                    mountpoint: "/"
        pools:
          "rpool":
            devices: @["/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB-part2"]
            layout: "stripe"
            options: @["ashift=12", "autotrim=on"]
          "userdata":
            devices: @["/dev/disk/by-id/nvme-WD_Black_SN850X_4TB"]
            layout: "stripe"
            options: @["ashift=12"]

    let dl = spec.disko.get()
    check dl.disks.len == 1
    check dl.pools.len == 2
    check dl.pools[0].name == "rpool"
    check dl.pools[0].layout == "stripe"
    check dl.pools[0].options == @["ashift=12", "autotrim=on"]
    check dl.pools[1].name == "userdata"
    check dl.pools[1].devices ==
      @["/dev/disk/by-id/nvme-WD_Black_SN850X_4TB"]
    let zp = dl.disks["boot"].partitions["rpool"]
    check zp.content.kind == cfsZfs
    check zp.content.pool == "rpool"
    check zp.content.dataset == "rpool/nixos/root"
    check zp.content.zfsMountpoint == "/"
    # Round-trip determinism.
    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check emitSystemHardwareJson(back) == s
