## M9.R.21.4 — eli-wsl live-probe smoke runner.
##
## Linked into a Linux binary, this driver runs ``probeAll`` against the
## actual /proc + /sys + lsblk on the host. Used by the M9.R.21.4
## integration step: the agent compiles + runs this binary on eli-wsl,
## verifies the rendered text contains every required section, and
## captures the output as a regression fixture.

import std/strutils

import repro_profile
import repro_cli_support/hardware as cli_hw

proc main(): int =
  let p = probeAll()
  let spec = toSystemHardwareSpec(p)
  let opts = parseHardwareProbeArgs(@["--dry-run"])
  let outcome = runHardwareProbeFromSpec(spec, opts)
  if outcome.failure:
    stderr.writeLine("m9r21_4_smoke: render failed: " & outcome.failureMsg)
    return 1
  stdout.write outcome.text
  # Sanity assertions on stderr (parent script greps for these).
  let required = ["hardware \"" & spec.id & "\":",
                  "import repro_profile",
                  "cpu:",
                  "boot:",
                  "graphics:",
                  "audio:"]
  for r in required:
    if r notin outcome.text:
      stderr.writeLine("m9r21_4_smoke: missing required section: " & r)
      return 2
  stderr.writeLine("m9r21_4_smoke: OK — systemId=" & spec.id &
                   ", arch=" & spec.cpuArch &
                   ", microcode=" & spec.cpuMicrocode &
                   ", kernelModules=" & $spec.kernelModules.len &
                   ", filesystems=" & $spec.filesystems.len &
                   ", drivers=" & $spec.graphicsDrivers.len &
                   ", audioCards=" & $spec.audioCards.len)
  0

when isMainModule:
  quit main()
