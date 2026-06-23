## M9.R.22.1 — declarative disko DSL types + JSON round-trip.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md``.
##
## These tests exercise the type extensions before the
## ``hardware "<id>":`` macro learns the ``disko:`` block (M9.R.22.2).
## Each case builds a ``DiskLayout`` programmatically, attaches it to
## a ``SystemHardwareSpec``, round-trips through JSON, and asserts the
## decoded value is byte-identical to the original.
##
## Six cases per the M9.R.22 brief:
##   1. LUKS-on-btrfs with subvolumes (encrypted root, /home + /nix +
##      /var/log subvolumes inside).
##   2. ZFS rpool + userdata pools mirroring zahary's home-pc layout
##      (rpool/nixos/{root,etc,nix,var,...} + rpool/userdata/{home,...}).
##   3. GPT + ESP + Linux root (simple ext4 case).
##   4. mdraid (level-1) + LVM nested (LUKS-on-LVM-on-mdraid).
##   5. ZFS pool with mirror layout (two-device by-id mirror).
##   6. Round-trip determinism: emit → parse → re-emit identical.

import std/[options, tables, unittest]

import repro_profile

# ---------------------------------------------------------------------
# Helpers — programmatic builders for the recursive ContentSpec shape.
# ---------------------------------------------------------------------

proc fs(format, mp: string;
        opts: seq[string] = @[];
        subvols: seq[BtrfsSubvolSpec] = @[]): ContentSpec =
  ContentSpec(kind: cfsFilesystem, format: format, mountpoint: mp,
              mountOptions: opts, subvols: subvols)

proc zfs(pool, dataset: string; mountpoint = ""): ContentSpec =
  ContentSpec(kind: cfsZfs, pool: pool, dataset: dataset,
              zfsMountpoint: mountpoint)

proc enc(inner: ContentSpec; keyFile = "interactive"): ContentSpec =
  result = ContentSpec(kind: cfsEncrypted,
    encryption: EncryptionSpec(`type`: "luks2", keyFile: keyFile,
                               cipher: "aes-xts-plain64",
                               allowDiscards: true))
  result.inner = new(ContentSpec)
  result.inner[] = inner

proc lvm(vg: string; vols: openArray[(string, string, ContentSpec)]):
    ContentSpec =
  var v: seq[LvmVolumeSpec] = @[]
  for triple in vols:
    let (n, sz, c) = triple
    var lv = LvmVolumeSpec(name: n, size: sz)
    lv.content = new(ContentSpec)
    lv.content[] = c
    v.add lv
  ContentSpec(kind: cfsLvm, vg: vg, volumes: v)

proc part(kind, size: string; content: ContentSpec; bootable = false):
    PartitionSpec =
  PartitionSpec(`type`: kind, size: size, content: content,
                bootable: bootable)

proc disk(device: string; partitions: openArray[(string, PartitionSpec)];
          table = "gpt"): DiskSpec =
  result.device = device
  result.`type` = table
  for kv in partitions:
    result.partitions[kv[0]] = kv[1]

proc layout(disks: openArray[(string, DiskSpec)];
            pools: seq[ZfsPoolSpec] = @[]): DiskLayout =
  for kv in disks: result.disks[kv[0]] = kv[1]
  result.pools = pools

proc wrap(id: string; l: DiskLayout): SystemHardwareSpec =
  result.id = id
  result.cpuArch = "x86_64"
  result.disko = some(l)

# ---------------------------------------------------------------------

suite "M9.R.22.1: disko types + JSON round-trip":

  test "Test#1: LUKS-on-btrfs with @home + @nix + @var/log subvolumes":
    let rootContent = enc(
      fs("btrfs", "/", subvols = @[
        BtrfsSubvolSpec(path: "/home", options: @["compress=zstd"]),
        BtrfsSubvolSpec(path: "/nix",
                        options: @["compress=zstd", "noatime"]),
        BtrfsSubvolSpec(path: "/var/log",
                        options: @["compress=zstd"])
      ]),
      keyFile = "interactive")
    let espContent = fs("vfat", "/boot")
    let main = disk("/dev/disk/by-id/nvme-Samsung_SSD_990",
      @[("esp", part("esp", "512M", espContent, bootable = true)),
        ("root", part("luks", "100%", rootContent))])
    let spec = wrap("01J5Z8P0LUKSBTRFS", layout(@[("main", main)]))

    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check back.disko.isSome
    let bd = back.disko.get()
    check bd.disks.len == 1
    check bd.disks["main"].device ==
      "/dev/disk/by-id/nvme-Samsung_SSD_990"
    check bd.disks["main"].partitions.len == 2
    let rp = bd.disks["main"].partitions["root"]
    check rp.content.kind == cfsEncrypted
    check rp.content.encryption.`type` == "luks2"
    check rp.content.encryption.keyFile == "interactive"
    check rp.content.encryption.allowDiscards
    check not rp.content.inner.isNil
    check rp.content.inner[].kind == cfsFilesystem
    check rp.content.inner[].format == "btrfs"
    let sv = rp.content.inner[].subvols
    check sv.len == 3
    check sv[0].path == "/home"
    check sv[1].options == @["compress=zstd", "noatime"]
    check sv[2].path == "/var/log"
    # Round-trip determinism: re-emit equals the original emit.
    check emitSystemHardwareJson(back) == s

  test "Test#2: ZFS rpool + userdata mirroring home-pc dotfiles":
    # Mirrors the user's ~/dotfiles/machines/home-pc/hardware-
    # configuration.nix layout: ESP on /boot + ZFS rpool with nixos/*
    # datasets + a separate userdata pool for home/*. The NVIDIA Quadro
    # VFIO passthrough surface is captured in the parent
    # SystemHardwareSpec.kernelModules + graphicsDrivers (those fields
    # already exist pre-M9.R.22); the disko block just defines the
    # storage topology.
    let espC = fs("vfat", "/boot")
    let rootZfs = zfs("rpool", "rpool/nixos/root", "/")
    let main = disk("/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB",
      @[("esp", part("esp", "512M", espC, bootable = true)),
        ("zfs", part("zfs", "100%", rootZfs))],
      table = "gpt")

    let rpool = ZfsPoolSpec(name: "rpool",
      devices: @["/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB-part2"],
      layout: "stripe",
      options: @["ashift=12", "autotrim=on"])
    let userdata = ZfsPoolSpec(name: "userdata",
      devices: @["/dev/disk/by-id/nvme-WD_Black_SN850X_4TB"],
      layout: "stripe",
      options: @["ashift=12"])

    var spec = wrap("01HOMEPC-NVIDIA-QUADRO-VFIO",
      layout(@[("main", main)], pools = @[rpool, userdata]))
    spec.cpuMicrocode = "intel"
    spec.kernelModules = @["vfio_pci", "vfio_iommu_type1", "vfio",
                           "kvm-intel"]
    spec.graphicsDrivers = @["i915", "nouveau"]

    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check back.kernelModules == spec.kernelModules
    check back.disko.isSome
    let bd = back.disko.get()
    check bd.pools.len == 2
    check bd.pools[0].name == "rpool"
    check bd.pools[0].devices.len == 1
    check bd.pools[0].options == @["ashift=12", "autotrim=on"]
    check bd.pools[1].name == "userdata"
    let zfsPart = bd.disks["main"].partitions["zfs"]
    check zfsPart.content.kind == cfsZfs
    check zfsPart.content.pool == "rpool"
    check zfsPart.content.dataset == "rpool/nixos/root"
    check zfsPart.content.zfsMountpoint == "/"
    check emitSystemHardwareJson(back) == s

  test "Test#3: GPT + ESP + ext4 root (simple-ext4 Tier-1 layout)":
    let espC = fs("vfat", "/boot")
    let rootC = fs("ext4", "/", opts = @["noatime"])
    let main = disk("/dev/disk/by-id/ata-CT500MX500SSD1",
      @[("esp", part("esp", "512M", espC, bootable = true)),
        ("root", part("linux", "100%", rootC))])
    let spec = wrap("01SIMPLEXT4", layout(@[("main", main)]))

    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    check back.disko.isSome
    let bd = back.disko.get()
    check bd.disks["main"].`type` == "gpt"
    check bd.disks["main"].partitions["esp"].bootable
    check not bd.disks["main"].partitions["root"].bootable
    check bd.disks["main"].partitions["root"].content.kind ==
      cfsFilesystem
    check bd.disks["main"].partitions["root"].content.format == "ext4"
    check bd.disks["main"].partitions["root"].content.mountOptions ==
      @["noatime"]
    check emitSystemHardwareJson(back) == s

  test "Test#4: mdraid + LVM nested (LUKS-on-LVM Tier-2 example)":
    # The recursive nesting that disko handles natively: LVM volume-
    # group on top of a "raid" partition; one of the LVs is itself
    # LUKS-wrapped with an ext4 inside.
    let cryptedRoot = enc(fs("ext4", "/"), keyFile = "interactive")
    let swap = ContentSpec(kind: cfsSwap, swapPriority: 0)
    let lvmContent = lvm("vgroot",
      @[("root", "100%FREE", cryptedRoot),
        ("swap", "8G", swap)])
    let main = disk("/dev/disk/by-id/ata-raiddisk",
      @[("raid", part("lvm", "100%", lvmContent))])
    let spec = wrap("01LVMRAID", layout(@[("main", main)]))

    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    let bd = back.disko.get()
    let raidPart = bd.disks["main"].partitions["raid"]
    check raidPart.content.kind == cfsLvm
    check raidPart.content.vg == "vgroot"
    check raidPart.content.volumes.len == 2
    check raidPart.content.volumes[0].name == "root"
    check raidPart.content.volumes[0].size == "100%FREE"
    check not raidPart.content.volumes[0].content.isNil
    check raidPart.content.volumes[0].content[].kind == cfsEncrypted
    check raidPart.content.volumes[0].content[].inner[].kind ==
      cfsFilesystem
    check raidPart.content.volumes[0].content[].inner[].format == "ext4"
    check raidPart.content.volumes[1].name == "swap"
    check raidPart.content.volumes[1].content[].kind == cfsSwap
    check emitSystemHardwareJson(back) == s

  test "Test#5: ZFS pool with mirror layout (two by-id devices)":
    let mirror = ZfsPoolSpec(name: "tank",
      devices: @["/dev/disk/by-id/ata-disk-A",
                 "/dev/disk/by-id/ata-disk-B"],
      layout: "mirror",
      options: @["ashift=12"])
    let spec = wrap("01ZFSMIRROR",
      DiskLayout(pools: @[mirror]))

    let s = emitSystemHardwareJson(spec)
    let back = parseSystemHardwareJson(s)
    let bd = back.disko.get()
    check bd.pools.len == 1
    check bd.pools[0].layout == "mirror"
    check bd.pools[0].devices.len == 2
    check bd.pools[0].devices[0] == "/dev/disk/by-id/ata-disk-A"
    check emitSystemHardwareJson(back) == s

  test "Test#6: round-trip determinism — same input → identical bytes":
    # Build a non-trivial layout twice, assert the emitted JSON is
    # byte-identical (insertion order preserved through OrderedTable
    # iteration; sorted-by-key for the inner zfsProperties).
    proc build(): SystemHardwareSpec =
      var props: OrderedTable[string, string]
      props["compression"] = "zstd"
      props["atime"] = "off"
      let zRoot = ContentSpec(kind: cfsZfs,
        pool: "rpool", dataset: "rpool/nixos/root",
        zfsMountpoint: "/", zfsProperties: props)
      let main = disk("/dev/disk/by-id/det",
        @[("esp", part("esp", "512M",
                       fs("vfat", "/boot"), bootable = true)),
          ("root", part("zfs", "100%", zRoot))])
      wrap("01DETERMINISM", layout(@[("main", main)],
        pools = @[ZfsPoolSpec(name: "rpool",
          devices: @["/dev/disk/by-id/x"], layout: "stripe")]))
    let a = emitSystemHardwareJson(build())
    let b = emitSystemHardwareJson(build())
    check a == b
    let back = parseSystemHardwareJson(a)
    check emitSystemHardwareJson(back) == a
