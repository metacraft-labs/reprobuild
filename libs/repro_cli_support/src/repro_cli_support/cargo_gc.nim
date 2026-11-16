## `repro cargo`: the cargo target-directory janitor's command line.
##
## Surface:
##
##   repro cargo gc [--target-dir DIR] [--keep-sets N] [--min-age DURATION]
##                  [--dry-run] [--cargo-home [DIR]]
##   repro cargo record-live [--target-dir DIR] [--from FILE|-] [--tee]
##                           [--keep-sets N]
##   repro cargo run [-j N] [--products FILE] [--fragment FILE --action-id ID]
##                   [--relative-to DIR] [--libs] -- cargo ARGS...
##
## The command line is parsed from repro's description
## (`repro_cli_support/cli_description`); everything else is
## `repro_cargo_gc` and `repro_cargo_edge`.
##
## Exit codes: 0 success, 1 failure, 2 usage, 75 (EX_TEMPFAIL) a cargo build
## or another janitor holds a lock, so nothing was touched and the caller may
## simply try again later.

import std/[options, os]
import repro_cargo_gc
import repro_cargo_edge/edge
import repro_cargo_edge/edge_cli as cargo_edge_cli

import ./cli_program

const
  ExitBusy* = 75
proc envReader(name: string): string = getEnv(name)

proc targetDirFrom(flag: string): string =
  if flag.len > 0: flag
  elif getEnv("CARGO_TARGET_DIR").len > 0: getEnv("CARGO_TARGET_DIR")
  else: "target"

proc humanBytes(n: int64): string = $n & " B"

proc runGc(c: ReproCommandLineCargoGc): int =
  let targetFlag = c.targetDir
  let keepFlag = c.keepSets
  let ageFlag = c.minAge
  let dryRun = c.dryRun
  let sweepHome = c.cargoHome.isSome
  let homeDir = c.cargoHome.get("")
  let resolved = resolveGcConfig(envReader, keepFlag, ageFlag)
  for problem in resolved.problems:
    stderr.writeLine "repro cargo gc: warning: " & problem
  if (keepFlag.len > 0 and resolved.keepSource != csFlag) or
      (ageFlag.len > 0 and resolved.minAgeSource != csFlag):
    # An explicit flag that did not parse is an error, not a fallback.
    stderr.writeLine "repro cargo gc: invalid --keep-sets or --min-age"
    return 2
  var config = resolved.config
  config.dryRun = dryRun
  let target = targetDirFrom(targetFlag)
  try:
    let report = collectGarbage(target, config)
    stdout.write renderReport(report)
    stdout.writeLine "settings: " & describe(resolved) &
      " [defaults are provisional]"
    var code = if report.errors.len > 0: 1 else: 0
    if sweepHome:
      let home = if homeDir.len > 0: homeDir else: resolveCargoHome(envReader)
      if home.len == 0:
        stderr.writeLine "repro cargo gc: cannot locate CARGO_HOME"
        return 1
      let swept = sweepCargoHome(home, config.minAgeSeconds, dryRun)
      for entry in swept.removed:
        stdout.writeLine (if dryRun: "would delete " else: "deleted ") &
          humanBytes(entry.bytes) & "  " & entry.path & "  (extracted registry source)"
      for e in swept.errors:
        stderr.writeLine "error: " & e
        code = 1
      stdout.writeLine (if dryRun: "would free " else: "freed ") &
        humanBytes(swept.bytesFreed) & " in " & home
    return code
  except GcBusyError as err:
    stderr.writeLine "repro cargo gc: " & err.msg
    return ExitBusy
  except GcSetupError as err:
    stderr.writeLine "repro cargo gc: " & err.msg
    return 1
  except CatchableError as err:
    stderr.writeLine "repro cargo gc: " & err.msg
    return 1

proc runRecordLive(c: ReproCommandLineCargoRecordLive): int =
  let targetFlag = c.targetDir
  let fromFlag = c.fromFile
  let keepFlag = c.keepSets
  let tee = c.tee
  let resolved = resolveGcConfig(envReader, keepFlag, "")
  for problem in resolved.problems:
    stderr.writeLine "repro cargo record-live: warning: " & problem
  if keepFlag.len > 0 and resolved.keepSource != csFlag:
    stderr.writeLine "repro cargo record-live: invalid --keep-sets"
    return 2
  let target = targetDirFrom(targetFlag)
  try:
    var input = stdin
    var opened = false
    if fromFlag.len > 0 and fromFlag != "-":
      input = open(fromFlag, fmRead)
      opened = true
    defer:
      if opened: close(input)
    let report = recordLiveSetFromStream(target, input,
      (if tee: stdout else: nil), resolved.config.keepSets)
    # With --tee stdout carries cargo's stream, so the summary goes to stderr.
    let sink = if tee: stderr else: stdout
    if report.units == 0:
      sink.writeLine "repro cargo record-live: no unit under " & target &
        " in the stream; nothing recorded (" & $report.unresolved.len &
        " paths outside the target directory)"
      return 1
    sink.writeLine "recorded " & $report.units & " units across " &
      $report.profileDirs.len & " profile dir(s) into " & report.setFile
    return 0
  except CatchableError as err:
    stderr.writeLine "repro cargo record-live: " & err.msg
    return 1

proc runCargoCommand*(conf: ReproCommandLineCargo): int =
  ## `repro cargo <sub> ...`.
  case conf.command
  of ReproCommandLineCargoCommand.gc: runGc(conf.gc)
  of ReproCommandLineCargoCommand.recordLive: runRecordLive(conf.recordLive)
  of ReproCommandLineCargoCommand.run:
    let c = conf.run
    cargo_edge_cli.runCargoEdgeCommand(CargoEdgeOptions(width: c.width,
      productsFile: c.products, fragmentFile: c.fragment,
      actionId: c.actionId, relativeTo: c.relativeTo, includeRlibs: c.libs,
      cargo: c.cargo), "repro cargo run")
  of ReproCommandLineCargoCommand.help:
    # `repro cargo help [<word>...]` is `repro help cargo [<word>...]`.
    try:
      stdout.write(ReproCommandLine.helpText(@["cargo"] & conf.help.topic))
    except CliUsageError:
      stdout.write(ReproCommandLine.helpText(["cargo"]))
    0
