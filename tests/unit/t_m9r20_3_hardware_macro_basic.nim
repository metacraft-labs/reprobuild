## M9.R.20.3 — `hardware "<id>":` macro skeleton.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §3.3.
## v0.1 captures CPU + boot + filesystems + graphics + audio fields.
## The `repro hardware probe` command + DMI / lsblk / lspci / sysfs
## drivers are M9.R.21 work; this macro provides the parse-and-store
## endpoint that the probe will write to.

import std/unittest

import repro_profile

suite "M9.R.20.3: hardware macro skeleton":

  test "Test#1: empty hardware block captures stable id":
    let h = buildHardwareSpec("01J5Z8P0-PR0DUCT-NAME-CHASSIS-SN"):
      discard
    check h.id == "01J5Z8P0-PR0DUCT-NAME-CHASSIS-SN"
    check h.cpuArch == ""
    check h.kernelModules.len == 0
    check h.filesystems.len == 0

  test "Test#2: cpu: arch + microcode captured":
    let h = buildHardwareSpec("hostA"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
    check h.cpuArch == "x86_64"
    check h.cpuMicrocode == "intel"

  test "Test#3: boot kernelModules + loaderDevice captured":
    let h = buildHardwareSpec("hostA"):
      boot:
        kernelModules: @["nvme", "xhci_pci", "usb_storage", "sd_mod"]
        loaderDevice: "/dev/disk/by-uuid/abcd"
    check h.kernelModules == @["nvme", "xhci_pci", "usb_storage", "sd_mod"]
    check h.loaderDevice == "/dev/disk/by-uuid/abcd"

  test "Test#4: full hardware block round-trips via JSON":
    let h = buildHardwareSpec("hostA"):
      cpu:
        arch: "x86_64"
        microcode: "intel"
      boot:
        kernelModules: @["nvme", "xhci_pci"]
        loaderDevice: "/dev/disk/by-uuid/abcd"
      filesystems:
        "/":
          device: "/dev/disk/by-uuid/root-uuid"
          fsType: "ext4"
        "/boot":
          device: "/dev/disk/by-uuid/boot-uuid"
          fsType: "vfat"
      graphics:
        drivers: @["amdgpu"]
      audio:
        cards: @["hda-intel"]
    check h.filesystems.len == 2
    check h.filesystems[0].mountPoint == "/"
    check h.filesystems[0].device == "/dev/disk/by-uuid/root-uuid"
    check h.filesystems[0].fsType == "ext4"
    check h.filesystems[1].mountPoint == "/boot"
    check h.filesystems[1].fsType == "vfat"
    check h.graphicsDrivers == @["amdgpu"]
    check h.audioCards == @["hda-intel"]
    let js = emitSystemHardwareJson(h)
    let h2 = parseSystemHardwareJson(js)
    check h2.id == "hostA"
    check h2.cpuArch == "x86_64"
    check h2.kernelModules == @["nvme", "xhci_pci"]
    check h2.filesystems.len == 2
    check h2.filesystems[0].mountPoint == "/"
    check h2.graphicsDrivers == @["amdgpu"]
    check h2.audioCards == @["hda-intel"]
    # Determinism check.
    check emitSystemHardwareJson(h) == emitSystemHardwareJson(h2)
