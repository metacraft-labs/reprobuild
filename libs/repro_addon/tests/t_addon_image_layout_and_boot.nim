## The pure halves of `repro infra image` (ReproOS Add-On Mode §6.5.2):
## reading an upstream image's partition table and filesystems without
## mounting them, checking them against a `baseOs:` layout, the assembly
## boot's QEMU command line, and the payload / result documents the build
## host and the assembly boot exchange.
##
## The inputs are the real shapes: `sfdisk --json` documents as util-linux
## 2.41 prints them for the two upstream images the A16 gates and rpi2 use
## (Debian 13 genericcloud amd64 20261026-2643: GPT with the root partition
## numbered 1 at the end of the disk; Raspberry Pi OS trixie armhf
## 2026-10-06: MBR, FAT32 `bootfs` then ext4 `rootfs`), and superblocks
## built byte for byte at the offsets the ext4 and FAT specifications
## give. No mocks.

import std/[strutils, tables, unittest]

import repro_profile/types
import repro_addon/image_layout
import repro_addon/image_boot
import repro_addon/image_assemble

const DebianSfdisk = """{
   "partitiontable": {
      "label": "gpt", "id": "B23B08A2-00AE-47E3-8CAB-A817E2D70E1B",
      "device": "deb.raw", "unit": "sectors", "firstlba": 2048,
      "lastlba": 6291422, "sectorsize": 512,
      "partitions": [
         {"node": "deb.raw1", "start": 262144, "size": 6027264,
          "type": "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709",
          "uuid": "84FD0772-D38A-4FE7-B574-DCB86F5E263F"},
         {"node": "deb.raw14", "start": 2048, "size": 6144,
          "type": "21686148-6449-6E6F-744E-656564454649",
          "uuid": "76D4C84C-A620-4F6C-937D-32BD65E03413"},
         {"node": "deb.raw15", "start": 8192, "size": 253952,
          "type": "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
          "uuid": "82E17562-9F24-4564-9735-BB223836C0B4"}]}}"""

const RaspiSfdisk = """{
   "partitiontable": {
      "label": "dos", "id": "0x4c032286",
      "device": "2026-10-06-raspios-trixie-armhf-lite.img",
      "unit": "sectors", "sectorsize": 512,
      "partitions": [
         {"node": "2026-10-06-raspios-trixie-armhf-lite.img1",
          "start": 16384, "size": 1048576, "type": "c"},
         {"node": "2026-10-06-raspios-trixie-armhf-lite.img2",
          "start": 1064960, "size": 4374528, "type": "83"}]}}"""

proc ext4Head(label: string; extents = true): string =
  result = "\0".repeat(2048)
  result[1024 + 0x38] = '\x53'; result[1024 + 0x39] = '\xEF'
  if extents: result[1024 + 0x60] = '\x42'     # EXTENTS | FILETYPE
  result[1024 + 0x5C] = '\x04'                 # HAS_JOURNAL
  for i, c in label: result[1024 + 0x78 + i] = c

proc fat32Head(label: string): string =
  result = "\0".repeat(2048)
  result[510] = '\x55'; result[511] = '\xAA'
  let l = label.alignLeft(11)
  for i in 0 ..< 11: result[71 + i] = l[i]
  for i, c in "FAT32   ": result[82 + i] = c

proc fat16Head(label: string): string =
  result = "\0".repeat(2048)
  result[510] = '\x55'; result[511] = '\xAA'
  let l = label.alignLeft(11)
  for i in 0 ..< 11: result[43 + i] = l[i]
  for i, c in "FAT16   ": result[54 + i] = c

proc fsPart(format, mountpoint: string; label = ""; size = "100%"): PartitionSpec =
  PartitionSpec(size: size, content: ContentSpec(kind: cfsFilesystem,
    format: format, mountpoint: mountpoint, label: label))

proc debianBaseOs(): BaseOsIntent =
  result = BaseOsIntent(declared: true, image: "file:///x.qcow2",
    sha256: "a".repeat(64), arch: "amd64", buildBoot: "pc", diskSize: "6G")
  var d = DiskSpec(`type`: "gpt")
  d.partitions["root"] = fsPart("ext4", "/")
  d.partitions["bios"] = PartitionSpec(size: "3M")
  d.partitions["esp"] = fsPart("vfat", "/boot/efi", size = "124M")
  result.layout.disks["main"] = d

proc raspiBaseOs(): BaseOsIntent =
  result = BaseOsIntent(declared: true, image: "https://x/a.img.xz",
    sha256: "b".repeat(64), arch: "armhf", buildBoot: "raspi2b",
    diskSize: "8G")
  var d = DiskSpec(`type`: "mbr")
  d.partitions["bootfs"] = fsPart("vfat", "/boot/firmware", "bootfs", size = "512M")
  d.partitions["rootfs"] = fsPart("ext4", "/", "rootfs")
  result.layout.disks["sd"] = d

suite "reading an upstream image without mounting it":
  test "sfdisk's GPT document, ordered by partition number":
    let t = parseSfdiskJson(DebianSfdisk)
    check t.kind == itGpt and t.sectorSize == 512 and t.lastLba == 6291422
    check t.partitions.len == 3
    check t.partitions[0].number == 1 and t.partitions[1].number == 14 and
          t.partitions[2].number == 15
    # Debian's root, number 1, ends last on the disk: diskSize grows it.
    check endOfDiskIndex(t) == 0

  test "sfdisk's MBR document":
    let t = parseSfdiskJson(RaspiSfdisk)
    check t.kind == itMbr and t.partitions.len == 2
    check t.partitions[1].start == 1064960 and endOfDiskIndex(t) == 1

  test "a malformed or foreign table is refused":
    expect ImageLayoutError: discard parseSfdiskJson("{}")
    expect ImageLayoutError: discard parseSfdiskJson("""{"partitiontable":
      {"label": "sun", "unit": "sectors", "partitions": []}}""")

  test "filesystems are recognised by their own signatures":
    check probeFilesystemBytes(ext4Head("rootfs")) == FsProbe(format: "ext4", label: "rootfs")
    check probeFilesystemBytes(ext4Head("", extents = false)).format == "ext3"
    check probeFilesystemBytes(fat32Head("bootfs")) == FsProbe(format: "vfat", label: "bootfs")
    # Debian's ESP: FAT16 without a label ("NO NAME").
    check probeFilesystemBytes(fat16Head("NO NAME")) == FsProbe(format: "vfat", label: "")
    check probeFilesystemBytes("\0".repeat(2048)).format == ""

suite "the image against its declared layout":
  let debT = parseSfdiskJson(DebianSfdisk)
  let raspiT = parseSfdiskJson(RaspiSfdisk)
  let debProbes = @[probeFilesystemBytes(ext4Head("")), FsProbe(),
                    probeFilesystemBytes(fat16Head("NO NAME"))]
  let raspiProbes = @[probeFilesystemBytes(fat32Head("bootfs")),
                      probeFilesystemBytes(ext4Head("rootfs"))]

  test "the two upstream images match their layouts":
    check verifyLayout(debianBaseOs(), debT, debProbes) == ""
    check verifyLayout(raspiBaseOs(), raspiT, raspiProbes) == ""
    check partitionIndexAt(raspiBaseOs(), "/") == 1
    check partitionIndexAt(raspiBaseOs(), "/boot/firmware") == 0

  test "a different table type is refused":
    var b = raspiBaseOs()
    b.layout.disks["sd"].`type` = "gpt"
    check "partition table is mbr" in verifyLayout(b, raspiT, raspiProbes)

  test "a different number of partitions is refused":
    var b = raspiBaseOs()
    b.layout.disks["sd"].partitions["data"] = fsPart("ext4", "/srv")
    check "has 2 partition(s)" in verifyLayout(b, raspiT, raspiProbes)

  test "a different filesystem or label is refused, naming the partition":
    let swapped = @[raspiProbes[1], raspiProbes[0]]
    check "partition 1 (\"bootfs\") is ext4" in verifyLayout(raspiBaseOs(), raspiT, swapped)
    var b = raspiBaseOs()
    b.layout.disks["sd"].partitions["rootfs"].content.label = "writable"
    check "labelled \"rootfs\"" in verifyLayout(b, raspiT, raspiProbes)

  test "diskSize grows only an ext4 partition at the end of the disk":
    var b = debianBaseOs()
    b.layout.disks["main"].partitions["root"].content.format = "xfs"
    let probes = @[FsProbe(format: "xfs"), FsProbe(), debProbes[2]]
    check "the last on the disk, which is not ext4" in verifyLayout(b, debT, probes)
    b.diskSize = ""
    check verifyLayout(b, debT, probes) == ""

suite "the assembly boot's QEMU command line":
  test "pc: KVM, a virtio disk, no network, -no-reboot":
    let a = assemblyBootArgv(AssemblyBoot(machine: "pc", image: "/w/image.raw",
      serialLog: "/w/serial.log", kvm: true))
    check qemuSystemBinary("pc") == "qemu-system-x86_64"
    check a[a.find("-accel") + 1] == "kvm" and a[a.find("-cpu") + 1] == "host"
    check "file=/w/image.raw,format=raw,if=virtio" in a
    check a[a.find("-nic") + 1] == "none" and "-no-reboot" in a
    check "file:/w/serial.log" in a
    let tcg = assemblyBootArgv(AssemblyBoot(machine: "pc", image: "i", serialLog: "s"))
    check tcg[tcg.find("-accel") + 1] == "tcg"

  test "raspi2b: the boot partition's kernel and device tree, watchdog off":
    let a = assemblyBootArgv(AssemblyBoot(machine: "raspi2b", image: "/w/i.raw",
      serialLog: "/w/s.log", kernel: "/w/kernel7.img", dtb: "/w/bcm2709-rpi-2-b.dtb",
      rootPartition: 2))
    check qemuSystemBinary("raspi2b") == "qemu-system-arm"
    check a[a.find("-M") + 1] == "raspi2b" and a[a.find("-m") + 1] == "1G"
    check "file=/w/i.raw,format=raw,if=sd" in a
    let cmdline = a[a.find("-append") + 1]
    check "root=/dev/mmcblk0p2" in cmdline
    check "systemd.watchdog_sec=off" in cmdline
    check "systemd.default_device_timeout_sec=900" in cmdline
    check "maxcpus=1" in cmdline   # the sdhost DMA race (image_boot.nim)
    check "console=ttyAMA0,115200" in cmdline
    expect ValueError:
      discard assemblyBootArgv(AssemblyBoot(machine: "raspi2b", image: "i",
        serialLog: "s"))
    expect ValueError:
      discard qemuSystemBinary("riscv-virt")

  test "the add-on binary's architecture from its ELF header":
    var h = "\x7fELF" & "\0".repeat(60)
    h[18] = char(62)
    check elfMachineArch(h) == "amd64"
    h[18] = char(40)
    check elfMachineArch(h) == "armhf"
    h[18] = char(183)
    check elfMachineArch(h) == "arm64"
    check elfMachineArch("#!/bin/sh\n" & "\0".repeat(30)) == ""
    check isPowerOfTwo(8'i64 shl 30) and not isPowerOfTwo(6'i64 shl 30)

suite "the documents the build host and the assembly boot exchange":
  test "assembly.json round-trips, machine-id bytes included":
    let s = AssemblySpec(binarySha256: "c".repeat(64),
      preflightFlags: @["--deploy-signers", "/var/lib/addon-image-assembly/x"],
      profileFile: "profile.txt", machineId: "uninitialized\n",
      keepSshHostKeys: @["ssh_host_ed25519_key"], stagedDebs: @["d.deb"],
      removeDebCacheParents: @["/var/cache/repro/apt", "/var/cache/repro"])
    let back = parseAssemblySpec(renderAssemblySpec(s))
    check back == s
    var bad = s
    bad.profileFile = "../etc/shadow"
    expect ValueError: discard parseAssemblySpec(renderAssemblySpec(bad))

  test "result.json round-trips":
    let r = AssemblyResult(ok: true, planDigest: "p", generationId: "g",
      reproExe: "/repro/store/x/bin/repro", ledgerSha256: "l",
      storePrefixes: @["/repro/store/prefixes/apt-closure-tb-hello/1.0-1-abc"],
      steps: @[AssemblyStep(name: "preflight", ok: true)])
    check parseAssemblyResult(renderAssemblyResult(r)) == r
