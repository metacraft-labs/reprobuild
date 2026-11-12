## `repro cargo`: the cargo target-directory janitor's command line.
##
## Surface:
##
##   repro cargo gc [--target-dir DIR] [--keep-sets N] [--min-age DURATION]
##                  [--dry-run] [--cargo-home [DIR]]
##   repro cargo record-live [--target-dir DIR] [--from FILE|-] [--tee]
##                           [--keep-sets N]
##
## Arguments are parsed here; everything else is `repro_cargo_gc`.
##
## Exit codes: 0 success, 1 failure, 2 usage, 75 (EX_TEMPFAIL) a cargo build
## or another janitor holds a lock, so nothing was touched and the caller may
## simply try again later.

import std/[os, strutils]
import repro_cargo_gc

const
  CargoUsage* =
    "usage: repro cargo gc [--target-dir DIR] [--keep-sets N] " &
    "[--min-age DURATION] [--dry-run] [--cargo-home[=DIR]]\n" &
    "       repro cargo record-live [--target-dir DIR] [--from FILE|-] " &
    "[--tee] [--keep-sets N]\n"
  ExitBusy* = 75

proc cargoHelp(): string =
  CargoUsage & """

gc            Delete cargo build units that no recent cargo invocation used.
              A unit goes when it is in none of the last N live sets of its
              profile directory AND nothing in it was written for DURATION,
              or when it was built by a toolchain none of those live sets
              used. Only the cargo-owned parts of profile directories are
              touched (deps/, .fingerprint/, build/, incremental/ and the
              final artifacts hard-linked from deps/); test-logs/, nextest/,
              flycheck*/ and every other name are left alone. Refuses, with
              exit code 75, while cargo holds the target directory's lock.
              A target directory with no recorded live set is left alone.
record-live   Read `cargo ... --message-format=json` output (stdin, or the
              file given to --from) and store which units the invocation
              used. Run it after every cargo invocation of a target
              directory, e.g.
                cargo build --message-format=json | repro cargo record-live --tee
              --tee copies the stream to stdout so the pipe stays usable.

--target-dir  the target directory (default: $CARGO_TARGET_DIR, else ./target).
              Under `build.build-dir` split layouts pass the build directory.
--keep-sets   N >= 1 recent live sets protect their units.
              Default 3. [PROVISIONAL: not yet tuned.]
              Also $REPRO_CARGO_GC_KEEP_SETS, `keep_sets` under [cargo_gc]
              in $XDG_CONFIG_HOME/reprobuild/config.toml.
--min-age     DURATION such as 30m, 36h, 14d, 2w or 0.
              Default 14d. [PROVISIONAL: not yet tuned.]
              Also $REPRO_CARGO_GC_MIN_AGE, `min_age` under [cargo_gc].
--dry-run     Print what would be deleted, with byte counts; delete nothing.
--cargo-home  Also sweep CARGO_HOME/registry/src (extracted crates whose
              .crate download is still cached), older than --min-age.
"""

proc envReader(name: string): string = getEnv(name)

proc targetDirFrom(flag: string): string =
  if flag.len > 0: flag
  elif getEnv("CARGO_TARGET_DIR").len > 0: getEnv("CARGO_TARGET_DIR")
  else: "target"

proc humanBytes(n: int64): string = $n & " B"

proc runGc(args: seq[string]): int =
  var targetFlag, keepFlag, ageFlag: string
  var dryRun = false
  var sweepHome = false
  var homeDir = ""
  var i = 0
  proc value(name: string; arg: string; into: var string): bool =
    ## `--name=v` or `--name v`.
    if arg == name:
      if i + 1 >= args.len: return false
      inc i
      into = args[i]
      return true
    if arg.startsWith(name & "="):
      into = arg[name.len + 1 .. ^1]
      return true
    false
  while i < args.len:
    let a = args[i]
    if a == "--dry-run": dryRun = true
    elif a == "--cargo-home": sweepHome = true
    elif a.startsWith("--cargo-home="):
      sweepHome = true
      homeDir = a["--cargo-home=".len .. ^1]
    elif a in ["-h", "--help"]:
      stdout.write cargoHelp()
      return 0
    elif value("--target-dir", a, targetFlag) or
        value("--keep-sets", a, keepFlag) or value("--min-age", a, ageFlag):
      discard
    else:
      stderr.writeLine "repro cargo gc: unexpected argument '" & a & "'"
      stderr.write CargoUsage
      return 2
    inc i
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

proc runRecordLive(args: seq[string]): int =
  var targetFlag, fromFlag, keepFlag: string
  var tee = false
  var i = 0
  proc value(name: string; arg: string; into: var string): bool =
    if arg == name:
      if i + 1 >= args.len: return false
      inc i
      into = args[i]
      return true
    if arg.startsWith(name & "="):
      into = arg[name.len + 1 .. ^1]
      return true
    false
  while i < args.len:
    let a = args[i]
    if a == "--tee": tee = true
    elif a in ["-h", "--help"]:
      stdout.write cargoHelp()
      return 0
    elif value("--target-dir", a, targetFlag) or value("--from", a, fromFlag) or
        value("--keep-sets", a, keepFlag):
      discard
    else:
      stderr.writeLine "repro cargo record-live: unexpected argument '" & a & "'"
      stderr.write CargoUsage
      return 2
    inc i
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

proc runCargoCommand*(args: seq[string]): int =
  ## `repro cargo <sub> ...`.
  if args.len == 0:
    stderr.write CargoUsage
    return 2
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  case args[0]
  of "gc": runGc(rest)
  of "record-live": runRecordLive(rest)
  of "-h", "--help", "help":
    stdout.write cargoHelp()
    0
  else:
    stderr.writeLine "repro cargo: unknown subcommand: " & args[0]
    stderr.write CargoUsage
    2
