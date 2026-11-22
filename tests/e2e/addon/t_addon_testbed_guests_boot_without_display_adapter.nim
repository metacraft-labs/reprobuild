## The add-on test bed's QEMU guests boot without an emulated display
## adapter.
##
## A guest the gates reach over SSH and the serial console has no use for the
## q35 machine's default ``VGA`` adapter. Under a heavily loaded host the
## guest kernel's ``bochs-drm`` driver for it times out waiting for vblank,
## raises a ``WARNING`` and sets ``kernel.tainted`` (512, ``TAINT_WARN``), and
## a gate's fingerprint comparison then reads a change the add-on never made
## (reprobuild-pm issue
## ``2026-11-18-arch-test-bed-guests-emulated-display-raises-kernel-warnings-under-load``:
## two arch-ext4 cells of an AR4 measurement turned red that way). The test
## bed therefore asks gosti for ``noDisplayDevice`` (QEMU ``-vga none``) on
## every boot, unless a guest opts back in with ``displayAdapter``, or its
## base cannot boot without the adapter (``BaseImage.displayAdapter``:
## debian-13-amd64 resets right after GRUB without one).
##
## The spec checked is the one the REAL ``boot`` and ``bootNoWait`` hand
## ``bootFromMedia`` (``qemuBootSpec``), and the argv is gosti's own
## ``buildQemuBootArgs`` at the pinned revision. Removing ``noDisplayDevice``
## from ``qemuBootSpec`` turns the first three cases red.
##
## *Mocking.* None; no guest is booted (that is what the VM gates do).
## Needs gosti (``GOSTI_SRC`` or a sibling checkout) at a revision with
## ``noDisplayDevice`` (``gosti.pin`` has it, and the gates refuse any
## other); without one the case is skipped with that reason.

import std/[strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

when defined(gostiAvailable):
  import gosti
  const Checkable = GostiHasNoDisplayDevice
else:
  const Checkable = false

when Checkable:
  proc guestOf(base: string): Guest =
    for b in BaseImages:
      if b.name == base:
        return Guest(base: b, kind: gkQemu, name: "repro-addon-tb-unit",
                     diskPath: "/nonexistent/disk.qcow2",
                     serialLog: "/nonexistent/serial.log")
    raise newException(TestBedError, "no base " & base)

  proc argvOf(spec: BootMediaSpec): seq[string] =
    ## The argv ``qemu-boot`` builds for ``spec``'s display choice.
    buildQemuBootArgs(QemuBootLaunch(vmName: spec.name,
      diskPath: spec.mediaPath, serialLogPath: spec.serialLogPath,
      serialSocketPath: "/nonexistent/serial.sock",
      noDisplayDevice: spec.noDisplayDevice))

  proc hasNoVga(argv: seq[string]): bool =
    for i in 0 ..< argv.len - 1:
      if argv[i] == "-vga" and argv[i + 1] == "none": return true

suite "test-bed guests boot without an emulated display adapter":
  when Checkable:
    test "a booted amd64 guest has no display adapter":
      let spec = guestOf("debian-12-amd64").qemuBootSpec()
      check spec.noDisplayDevice
      check hasNoVga(argvOf(spec))

    test "a read-only and a serial-only boot have none either":
      let g = guestOf("ubuntu-24.04-amd64")
      check g.qemuBootSpec(readonly = true).noDisplayDevice
      check g.qemuBootSpec(serialOnly = true).noDisplayDevice

    test "an arm64 guest has none":
      check guestOf("debian-13-arm64").qemuBootSpec().noDisplayDevice

    test "a base that cannot boot without the adapter keeps it":
      # debian-13-amd64 resets right after GRUB with ``-vga none``.
      let spec = guestOf("debian-13-amd64").qemuBootSpec()
      check not spec.noDisplayDevice
      check not hasNoVga(argvOf(spec))
      var only: seq[string]
      for b in BaseImages:
        if b.displayAdapter: only.add(b.name)
      check only == @["debian-13-amd64"]

    test "a guest that asks for the adapter keeps it":
      let g = guestOf("debian-12-amd64")
      g.displayAdapter = true
      let spec = g.qemuBootSpec()
      check not spec.noDisplayDevice
      check not hasNoVga(argvOf(spec))
      check "-vga" notin argvOf(spec).join(" ").splitWhitespace()
  elif defined(gostiAvailable):
    test "a booted guest has no display adapter":
      skip("the gosti compiled against predates BootMediaSpec." &
           "noDisplayDevice; the add-on gates run the pinned gosti " &
           "(tests/e2e/addon/gosti.pin), which has it")
  else:
    test "a booted guest has no display adapter":
      skip("gosti is not available: set GOSTI_SRC to gosti's src directory " &
           "or check gosti out beside reprobuild")
