## The QEMU command line of an assembly boot (ReproOS Add-On Mode §6.5.2
## step 5): the image booted once on its `baseOs.buildBoot` machine, with no
## network device, its serial console in a file, and `-no-reboot` so the
## unit's `poweroff` -- or any reset -- ends QEMU.
##
## - `pc`: x86-64 (`q35`), booting the image's own boot loader from a virtio
##   disk; KVM when the build host offers it, TCG otherwise.
## - `raspi2b`: QEMU's Raspberry Pi 2B model
##   (https://www.qemu.org/docs/master/system/arm/raspi.html). It does not
##   run the Pi's GPU firmware, so the kernel and device tree come from the
##   boot partition (`kernel7.img`, `bcm2709-rpi-2-b.dtb`) and the command
##   line is given here, never the image's `cmdline.txt`. QEMU's BCM2835
##   watchdog model resets the board as soon as systemd arms the watchdog
##   (Raspberry Pi OS ships `RuntimeWatchdogSec=` in
##   `/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf`), so the
##   assembly boot alone passes `systemd.watchdog_sec=off`. Emulated, the
##   board is slow enough that udev can miss systemd's default 90 s device
##   timeout for the boot partition's `/dev/disk/by-partuuid` link, and the
##   boot then stops in emergency mode (measured on Raspberry Pi OS trixie
##   2026-10-06 under QEMU 10.2 TCG on a loaded host), so it also passes
##   `systemd.default_device_timeout_sec=900`. The SD model needs a
##   power-of-two card, which `baseOsProblem` requires of `diskSize`.

import std/strutils

const
  RaspiKernel* = "kernel7.img"
  RaspiDtb* = "bcm2709-rpi-2-b.dtb"

type
  AssemblyBoot* = object
    machine*: string      ## pc | raspi2b
    image*: string        ## the raw image, booted in place
    serialLog*: string
    kvm*: bool            ## pc: use KVM
    kernel*, dtb*: string ## raspi2b: extracted from the boot partition
    rootPartition*: int   ## raspi2b: the root partition's number
    memoryMB*: int        ## 0: the machine's default
    cpus*: int            ## 0: the machine's default

proc qemuSystemBinary*(machine: string): string =
  case machine
  of "pc": "qemu-system-x86_64"
  of "raspi2b": "qemu-system-arm"
  else: raise newException(ValueError, "no assembly machine " & machine)

proc assemblyBootArgv*(b: AssemblyBoot): seq[string] =
  ## The arguments after the QEMU binary.
  let common = @["-serial", "file:" & b.serialLog, "-display", "none",
                 "-monitor", "none", "-no-reboot"]
  case b.machine
  of "pc":
    result = @["-machine", "q35",
      "-accel", (if b.kvm: "kvm" else: "tcg"),
      "-cpu", (if b.kvm: "host" else: "max"),
      "-m", $(if b.memoryMB > 0: b.memoryMB else: 2048),
      "-smp", $(if b.cpus > 0: b.cpus else: 2),
      "-drive", "file=" & b.image & ",format=raw,if=virtio",
      "-nic", "none"] & common
  of "raspi2b":
    if b.kernel.len == 0 or b.dtb.len == 0 or b.rootPartition <= 0:
      raise newException(ValueError, "a raspi2b assembly boot needs the " &
        "kernel, the device tree and the root partition's number")
    # The model's RAM is fixed at 1 GiB and its four Cortex-A7 cores are
    # part of the board; -m must say 1G.
    result = @["-M", "raspi2b", "-m", "1G",
      "-kernel", b.kernel, "-dtb", b.dtb,
      "-drive", "file=" & b.image & ",format=raw,if=sd",
      "-append", "console=ttyAMA0,115200 root=/dev/mmcblk0p" &
        $b.rootPartition & " rootfstype=ext4 rootwait " &
        "systemd.watchdog_sec=off systemd.default_device_timeout_sec=900"] &
        common
  else:
    raise newException(ValueError, "no assembly machine " & b.machine)

proc isPowerOfTwo*(n: int64): bool = n > 0 and (n and (n - 1)) == 0

proc elfMachineArch*(header: string): string =
  ## The add-on architecture an ELF image is for, from its header (`e_machine`
  ## at 18, little-endian; 62 x86-64, 183 AArch64, 40 ARM), or "".
  if header.len < 20 or not header.startsWith("\x7fELF"): return ""
  let m = int(header[18].uint8) or (int(header[19].uint8) shl 8)
  case m
  of 62: "amd64"
  of 183: "arm64"
  of 40: "armhf"
  else: ""
