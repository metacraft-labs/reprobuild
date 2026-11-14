## What a rustc command line says about the unit it compiles.
##
## Cargo invokes `$RUSTC_WRAPPER rustc <args>` once per compiled unit (and a
## few times per build for probes: `-vV`, `--print ...`). The wrapper needs to
## tell the two apart and to name a unit stably, so that the totals of one
## crate's compile land under one statistics key from build to build. It reads
## the arguments and never rewrites them.
##
## The flags are rustc's own and are documented at
## https://doc.rust-lang.org/rustc/command-line-arguments.html.

import std/strutils

type
  RustcUnit* = object
    crateName*: string
    kind*: string
      ## The crate types joined with `+` (`lib`, `bin`, `proc-macro`,
      ## `cdylib+rlib`), or `test` for a `--test` harness, or `bin` when rustc
      ## was given no crate type (its default).
    optLevel*: string
      ## `0`..`3`, `s`, `z`; `0` when the line names none (rustc's default).

func valueOf(args: openArray[string]; i: int; flag: string;
             value: var string; consumed: var int): bool =
  ## `--flag value` or `--flag=value` at `args[i]`.
  let arg = args[i]
  if arg == flag:
    if i + 1 < args.len:
      value = args[i + 1]
      consumed = 2
      return true
    return false
  if arg.startsWith(flag & "="):
    value = arg[flag.len + 1 .. ^1]
    consumed = 1
    return true
  false

func rustcUnitOf*(args: openArray[string]): tuple[isUnit: bool,
                                                  unit: RustcUnit] =
  ## `args` are rustc's arguments (without the rustc path). A line is a unit
  ## when it names a crate (`--crate-name`), is not asking rustc a question
  ## (`--print`, `--version`, `-vV`, `--explain`; cargo's target-info probe
  ## passes `--crate-name ___ --print=file-names`, which compiles nothing) and
  ## was issued by cargo itself, which always has rustc report in JSON
  ## (`--error-format=json`). A build script that compiles a probe of its own
  ## (proc-macro2 and thiserror test for compiler features this way, through
  ## the wrapper cargo hands them in `RUSTC_WRAPPER`) names the crate it
  ## belongs to and reads rustc's plain diagnostics: it is a compile, not a
  ## unit, and recording it under the crate's key would mix a 50 ms probe
  ## into the totals of a multi-second compile.
  var crateName = ""
  var crateTypes: seq[string]
  var isTest = false
  var optLevel = ""
  var optimized = false
  var jsonErrors = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    var value = ""
    var consumed = 0
    if arg in ["--print", "--version", "-V", "-vV", "--explain"] or
        arg.startsWith("--print=") or arg.startsWith("--explain="):
      return (false, RustcUnit())
    elif valueOf(args, i, "--crate-name", value, consumed):
      crateName = value
      i += consumed
    elif valueOf(args, i, "--crate-type", value, consumed):
      for part in value.split(','):
        if part.len > 0 and part notin crateTypes: crateTypes.add part
      i += consumed
    elif arg == "--test":
      isTest = true
      inc i
    elif arg == "-":
      # Source from standard input: a probe, never a unit of the graph.
      return (false, RustcUnit())
    elif valueOf(args, i, "--error-format", value, consumed):
      if value.startsWith("json"): jsonErrors = true
      i += consumed
    elif arg == "-O":
      optimized = true
      inc i
    elif arg == "-C" and i + 1 < args.len and
        args[i + 1].startsWith("opt-level="):
      optLevel = args[i + 1]["opt-level=".len .. ^1]
      i += 2
    elif arg.startsWith("-Copt-level="):
      optLevel = arg["-Copt-level=".len .. ^1]
      inc i
    else:
      inc i
  if crateName.len == 0 or crateName == "___" or not jsonErrors:
    return (false, RustcUnit())
  if optLevel.len == 0:
    optLevel = if optimized: "2" else: "0"
  let kind =
    if isTest: "test"
    elif crateTypes.len == 0: "bin"
    else: crateTypes.join("+")
  (true, RustcUnit(crateName: crateName, kind: kind, optLevel: optLevel))

func statsKeyOf*(unit: RustcUnit): string =
  ## The key one unit's totals are recorded under. The same crate compiled as
  ## a library, as a test harness or as a build script is a different unit
  ## with a different cost, and a dev and a release compile of it differ again,
  ## so the key carries the crate type and the optimisation level.
  "rustc/" & unit.crateName & "/" & unit.kind & "/o" & unit.optLevel
