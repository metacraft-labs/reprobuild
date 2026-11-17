## M9.R.21.3 — ``repro hardware probe`` CLI command.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §3.
##
## Surface::
##
##   repro hardware probe
##     # → writes /etc/repro/hardware.nim from the live system
##
##   repro hardware probe --dry-run
##     # → emits the rendered hardware.nim to stdout
##
##   repro hardware probe --output PATH
##     # → write to PATH instead of /etc/repro/hardware.nim
##
##   repro hardware probe --regenerate
##     # → force-overwrite an existing target
##
## Without ``--regenerate`` the command refuses to overwrite an
## existing file (matches the spec's "never silently rewrite the
## per-host file" stance + the M83 audit-log policy).

import std/[os, strutils]

import repro_profile/hardware_probe
import repro_profile/types

import ./cli_program

const DefaultHardwarePath* = "/etc/repro/hardware.nim"

type
  HardwareProbeOptions* = object
    output*: string         ## destination path; empty → default
    dryRun*: bool           ## print to stdout instead of writing
    regenerate*: bool       ## overwrite an existing target

  HardwareProbeFailure* = enum
    hpfTargetExists       ## refused to overwrite without --regenerate
    hpfWriteFailed        ## fs error
    hpfNotLinux           ## live probe outside Linux

  HardwareProbeOutcome* = object
    text*: string           ## the rendered Nim source
    written*: bool          ## true when ``output`` was actually written
    targetPath*: string     ## resolved destination (empty for dry-run)
    failure*: bool
    failureKind*: HardwareProbeFailure
    failureMsg*: string

# ---------------------------------------------------------------------
# Pure (testable) entry point — caller hands in a `SystemHardwareSpec`,
# the proc handles the write/dry-run logic. The CLI handler wraps
# `runHardwareProbeFromSpec` after running the live probe.
# ---------------------------------------------------------------------

proc runHardwareProbeFromSpec*(spec: SystemHardwareSpec;
                               opts: HardwareProbeOptions):
    HardwareProbeOutcome =
  result.text = renderHardwareSpec(spec)
  if opts.dryRun:
    return
  let target = if opts.output.len > 0: opts.output
               else: DefaultHardwarePath
  result.targetPath = target
  if fileExists(target) and not opts.regenerate:
    result.failure = true
    result.failureKind = hpfTargetExists
    result.failureMsg = "refusing to overwrite " & target &
      " — pass --regenerate to force"
    return
  try:
    let parent = parentDir(target)
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
    writeFile(target, result.text)
    result.written = true
  except CatchableError as e:
    result.failure = true
    result.failureKind = hpfWriteFailed
    result.failureMsg = "write " & target & ": " & e.msg

# ---------------------------------------------------------------------
# CLI dispatch — `repro hardware <action> [args]`, its command line parsed
# from repro's description (`repro_cli_support/cli_description`).
# ---------------------------------------------------------------------

proc runHardwareProbeCli(opts: HardwareProbeOptions): int =
  # Live probe — Linux-only. On non-Linux hosts we still let callers
  # render a known-good SystemHardwareSpec via --output-only paths;
  # but the standard ``probe`` action needs /proc + /sys.
  when not defined(linux):
    stderr.writeLine("repro hardware probe: probing requires Linux " &
      "(host is " & hostOS & "); use the M9.R.21 macros directly to " &
      "hand-write hardware.nim on this OS.")
    return 1
  else:
    let p = probeAll()
    let spec = toSystemHardwareSpec(p)
    let outcome = runHardwareProbeFromSpec(spec, opts)
    if outcome.failure:
      stderr.writeLine("repro hardware probe: " & outcome.failureMsg)
      case outcome.failureKind
      of hpfTargetExists: return 2
      of hpfWriteFailed: return 1
      of hpfNotLinux: return 1
    if opts.dryRun:
      stdout.write outcome.text
    else:
      stderr.writeLine("repro hardware probe: wrote " & outcome.targetPath)
    return 0

proc hardwareProbeOptionsOf*(p: ReproCommandLineHardwareProbe):
    HardwareProbeOptions =
  ## What ``repro hardware probe`` was given, from its configuration object
  ## (repro's description, ``repro_cli_support/cli_description``).
  HardwareProbeOptions(output: p.output, dryRun: p.dryRun,
    regenerate: p.regenerate)

proc runHardwareCommand*(conf: ReproCommandLineHardware): int =
  ## ``repro hardware <action>``.
  case conf.command
  of ReproCommandLineHardwareCommand.probe:
    runHardwareProbeCli(hardwareProbeOptionsOf(conf.probe))
