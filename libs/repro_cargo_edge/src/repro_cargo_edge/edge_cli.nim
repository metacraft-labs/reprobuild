## The command line of the thin cargo edge: the standard provider's own
## helper entry (`--cargo-edge`), which a cargo convention's action runs so
## that it needs no `repro` binary on its argv. `repro cargo run` takes the
## same options from repro's own command-line description and calls
## `runCargoEdgeCommand` with them.
##
##   run [-j N] [--products FILE] [--fragment FILE --action-id ID]
##       [--relative-to DIR] [--libs] -- cargo ARGS...
##
## Exit codes: cargo's own when it ran, 2 usage, 1 any other failure.

import std/strutils
import ./[edge, wrapper_env]
export wrapper_env.EdgeHelperFlag

const
  EdgeUsage* =
    "usage: repro cargo run [-j N] [--products FILE] " &
    "[--fragment FILE --action-id ID] [--relative-to DIR] [--libs] " &
    "-- cargo ARGS...\n"

proc runCargoEdgeCommand*(options: CargoEdgeOptions; verb: string): int =
  ## Run the edge with options already read from a command line: cargo's
  ## exit status when it ran, 2 when no cargo command or a negative width
  ## was given, 1 on any other failure. `verb` names the command in
  ## messages.
  if options.width < 0:
    stderr.writeLine verb & ": -j takes a whole number"
    return 2
  if options.cargo.len == 0:
    stderr.writeLine verb & ": no cargo command after `--`"
    return 2
  try:
    let outcome = runCargoEdge(options)
    if outcome.exitCode == 0:
      stderr.writeLine verb & ": " & $outcome.products.len &
        " final product(s) from " & $outcome.units & " unit(s), " &
        $outcome.freshUnits & " fresh"
    return outcome.exitCode
  except CatchableError as err:
    stderr.writeLine verb & ": " & err.msg
    return 1

proc runEdge*(args: seq[string]; verb = "repro cargo run"): int =
  var options = CargoEdgeOptions()
  var i = 0
  proc takes(name: string; arg: string; into: var string): bool =
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
    var widthText = ""
    if a == "--":
      options.cargo = args[i + 1 .. ^1]
      break
    elif a == "--libs": options.includeRlibs = true
    elif a in ["-h", "--help"]:
      stdout.write EdgeUsage
      return 0
    elif takes("-j", a, widthText) or takes("--width", a, widthText):
      try:
        options.width = parseInt(widthText)
      except ValueError:
        options.width = -1
      if options.width < 0:
        stderr.writeLine verb & ": -j takes a whole number"
        return 2
    elif takes("--products", a, options.productsFile) or
        takes("--fragment", a, options.fragmentFile) or
        takes("--action-id", a, options.actionId) or
        takes("--relative-to", a, options.relativeTo):
      discard
    else:
      stderr.writeLine verb & ": unexpected argument '" & a & "'"
      stderr.write EdgeUsage
      return 2
    inc i
  if options.cargo.len == 0:
    stderr.writeLine verb & ": no cargo command after `--`"
    stderr.write EdgeUsage
    return 2
  runCargoEdgeCommand(options, verb)


func edgeCommand*(helper, productsFile: string; cargo: openArray[string];
                  relativeTo = ""): seq[string] =
  ## The argv of a delegated cargo action that goes through the edge. `-j 0` is
  ## the width flag the engine fills in with the grant (a width of 0 leaves
  ## cargo's own default, which is what an engine that did not size the action
  ## gets); the flag sits BEFORE `--` because the engine places a width only
  ## in the part of the command line that is the action's own.
  result = @[helper, EdgeHelperFlag, "-j", "0", "--products", productsFile]
  if relativeTo.len > 0:
    result.add ["--relative-to", relativeTo]
  result.add "--"
  result.add cargo
