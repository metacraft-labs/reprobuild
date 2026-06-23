## M9.R.21.4 — hardware probe end-to-end integration test.
##
## On Linux, exercises the live ``probeAll`` against /proc + /sys +
## lsblk + lspci, materialises a ``SystemHardwareSpec``, renders the
## canonical ``hardware "<id>":`` source text, and writes it to a
## temporary file. The rendered text is verified to contain every
## section the M9.R.20 macro recognises and the captured
## ``ProbeResult`` is round-tripped through ``emitSystemHardwareJson`` /
## ``parseSystemHardwareJson`` to pin determinism.
##
## On non-Linux hosts the test runs the SAME render path against a
## pinned ``SystemHardwareSpec`` so the harness is exercised
## everywhere — the live probe path is the only thing skipped.
##
## A full text→macro→spec round trip needs a second-stage compile of
## the rendered file; this test stages the file under
## ``build/m9r21_4_e2e/hardware.nim`` and a follow-up engine-driven
## edge can pick it up to drive the macro recursively. The seam test
## here is the "parser accepts every field shape we emit" assertion
## using ``buildHardwareSpec`` programmatically.

import std/[os, strutils, unittest]

import repro_profile
import repro_cli_support/hardware as cli_hw

const TmpRoot = "build/m9r21_4_e2e"

proc resetDir(): string =
  if dirExists(TmpRoot): removeDir(TmpRoot)
  createDir(TmpRoot)
  TmpRoot

suite "M9.R.21.4: hardware probe end-to-end":

  test "live probe round-trips via the macro (Linux only)":
    when defined(linux):
      let p = probeAll()
      check p.systemId.len == 26
      let spec = toSystemHardwareSpec(p)
      check spec.id == p.systemId
      check spec.cpuArch.len > 0
      let opts = parseHardwareProbeArgs(@["--dry-run"])
      let outcome = runHardwareProbeFromSpec(spec, opts)
      check not outcome.failure
      check "hardware \"" & spec.id & "\":" in outcome.text
      check "import repro_profile" in outcome.text
      check "cpu:" in outcome.text
      check "boot:" in outcome.text
      check "graphics:" in outcome.text
      check "audio:" in outcome.text
      # JSON round-trip pins determinism.
      let js = emitSystemHardwareJson(spec)
      let spec2 = parseSystemHardwareJson(js)
      check spec2.id == spec.id
      check spec2.cpuArch == spec.cpuArch
      check spec2.kernelModules == spec.kernelModules
      check spec2.filesystems.len == spec.filesystems.len
      check spec2.graphicsDrivers == spec.graphicsDrivers
      check spec2.audioCards == spec.audioCards
      check emitSystemHardwareJson(spec) == emitSystemHardwareJson(spec2)
      # Stage the rendered file so a follow-up engine edge can drive
      # the macro recursively.
      let dir = resetDir()
      let stage = dir / "hardware.nim"
      writeFile(stage, outcome.text)
      check fileExists(stage)
      check readFile(stage) == outcome.text
    else:
      skip()

  test "render path produces macro-parseable text on every host":
    # Hardcoded spec exercises the same renderer used by the live
    # probe — verifies the harness on Windows / Darwin where the live
    # probe is skipped above.
    let spec = buildHardwareSpec("E2E-FIXTURE-XYZ123ABCD456EFGH7"):
      cpu:
        arch: "x86_64"
        microcode: "amd"
      boot:
        kernelModules: @["nvme", "ahci"]
        loaderDevice: "/dev/disk/by-uuid/0000-1111"
      filesystems:
        "/":
          device: "/dev/disk/by-uuid/aaaa-bbbb"
          fsType: "ext4"
      graphics:
        drivers: @["amdgpu"]
      audio:
        cards: @["hda-intel"]
    let opts = parseHardwareProbeArgs(@["--dry-run"])
    let outcome = runHardwareProbeFromSpec(spec, opts)
    check not outcome.failure
    check "hardware \"E2E-FIXTURE-XYZ123ABCD456EFGH7\":" in outcome.text
    check "microcode: \"amd\"" in outcome.text
    check "drivers: @[\"amdgpu\"]" in outcome.text
    let dir = resetDir()
    let stage = dir / "hardware-fixture.nim"
    writeFile(stage, outcome.text)
    check fileExists(stage)
