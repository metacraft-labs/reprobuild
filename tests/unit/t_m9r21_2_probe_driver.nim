## M9.R.21.2 — hardware probe sub-function fixtures.
##
## Each sub-function is exercised against an inlined fixture so the
## parser semantics are pinned at the unit-test layer. The live
## wrappers (``probeCpu`` / ``probeBoot`` / ...) are exercised
## end-to-end in M9.R.21.4.
##
## Six cases per the M9.R.21 task brief:
##   1. /proc/cpuinfo Intel example → x86_64 + intel microcode.
##   2. /proc/cpuinfo AMD example → x86_64 + amd microcode.
##   3. /proc/modules → kernelModules list; cmdline → loaderDevice.
##   4. lsblk JSON with btrfs + ext4 mix.
##   5. lspci graphics: i915 + amdgpu + nvidia (multiple vendors).
##   6. Determinism: same fixture text → byte-identical output.

import std/unittest

import repro_profile

suite "M9.R.21.2: probe sub-function fixtures":

  test "Test#1: Intel cpuinfo → x86_64 + intel microcode":
    let intel = """
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 158
model name	: Intel(R) Core(TM) i9-9900K CPU @ 3.60GHz

processor	: 1
vendor_id	: GenuineIntel
cpu family	: 6
"""
    let c = probeCpuFrom(intel)
    check c.arch == "x86_64"
    check c.microcode == "intel"

  test "Test#2: AMD cpuinfo → x86_64 + amd microcode":
    let amd = """
processor	: 0
vendor_id	: AuthenticAMD
cpu family	: 25
model		: 33
model name	: AMD Ryzen 9 7950X 16-Core Processor
"""
    let c = probeCpuFrom(amd)
    check c.arch == "x86_64"
    check c.microcode == "amd"

  test "Test#3: /proc/modules + cmdline → kernelModules + loaderDevice":
    let modules = """
nvme 65536 4 - Live 0xffffffffc04a0000
xhci_pci 12288 0 - Live 0xffffffffc04b0000
xhci_pci_renesas 12288 1 xhci_pci, Live 0xffffffffc04c0000
i915 3170304 23 - Live 0xffffffffc1500000
"""
    # Loader device passed in directly (the wrapper resolves via
    # findmnt; the pure form just stores what it's given).
    let bA = probeBootFrom(modules, "BOOT_IMAGE=/vmlinuz",
                           "/dev/disk/by-uuid/0123-ABCD")
    check bA.kernelModules == @["nvme", "xhci_pci", "xhci_pci_renesas",
                                "i915"]
    check bA.loaderDevice == "/dev/disk/by-uuid/0123-ABCD"
    # Fallback: cmdline ``root=`` parsing when loader is empty.
    let bB = probeBootFrom(modules,
                           "BOOT_IMAGE=/vmlinuz root=UUID=abcd-1234 ro quiet",
                           "")
    check bB.loaderDevice == "UUID=abcd-1234"
    check bB.kernelModules.len == 4

  test "Test#4: lsblk JSON btrfs + ext4 mix":
    let lsblk = """{
      "blockdevices": [
        {
          "name": "nvme0n1", "uuid": null, "fstype": null,
          "mountpoint": null, "size": "476.9G",
          "children": [
            {
              "name": "nvme0n1p1", "uuid": "0123-ABCD",
              "fstype": "vfat", "mountpoint": "/boot", "size": "1G"
            },
            {
              "name": "nvme0n1p2", "uuid": "deadbeef-1234-5678-abcd-ef0123456789",
              "fstype": "btrfs", "mountpoint": "/", "size": "475G"
            }
          ]
        },
        {
          "name": "sda", "uuid": null, "fstype": null,
          "mountpoint": null, "size": "1T",
          "children": [
            {
              "name": "sda1", "uuid": "cafebabe-1111-2222-3333-444455556666",
              "fstype": "ext4", "mountpoint": "/home", "size": "1T"
            }
          ]
        }
      ]
    }"""
    let fs = probeFilesystemsFrom(lsblk)
    check fs.len == 3
    check fs[0].mountPoint == "/boot"
    check fs[0].fsType == "vfat"
    check fs[0].device == "/dev/disk/by-uuid/0123-ABCD"
    check fs[1].mountPoint == "/"
    check fs[1].fsType == "btrfs"
    check fs[2].mountPoint == "/home"
    check fs[2].fsType == "ext4"

  test "Test#5: lspci multi-GPU → i915 + amdgpu + nouveau":
    let lspci = """
00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics 630 (rev 02) [8086:3e98]
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP104 [GeForce GTX 1080] (rev a1) [10de:1b80]
02:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT/XTX] [1002:744c] (rev cc)
"""
    let g = probeGraphicsFrom(lspci)
    check g.drivers == @["i915", "nouveau", "amdgpu"]

  test "Test#6: determinism — same fixtures → same output":
    let intel = "vendor_id\t: GenuineIntel\n"
    check probeCpuFrom(intel) == probeCpuFrom(intel)
    let asoundCards = """
 0 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xfe800000 irq 33
 1 [HDMI           ]: HDA-Intel - HDA Intel HDMI
                      HDA Intel HDMI at 0xfe900000 irq 34
"""
    let a1 = probeAudioFrom(asoundCards)
    let a2 = probeAudioFrom(asoundCards)
    check a1 == a2
    check a1.cards == @["hda-intel"]
    # Graphics + filesystems both deterministic too.
    let lspci = "00:02.0 VGA compatible controller [0300]: Intel UHD [8086:3e98]\n"
    check probeGraphicsFrom(lspci) == probeGraphicsFrom(lspci)
    let lsblk = """{
      "blockdevices": [
        {"name": "vda", "uuid": "u1", "fstype": "ext4",
         "mountpoint": "/", "size": "10G"}
      ]
    }"""
    check probeFilesystemsFrom(lsblk) == probeFilesystemsFrom(lsblk)
