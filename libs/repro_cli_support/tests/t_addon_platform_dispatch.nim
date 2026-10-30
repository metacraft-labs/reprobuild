## Exercise the production system/infra dispatchers without managing a host.
## The child is this real test executable calling those dispatchers, not a
## stand-in repro binary. Every command stops at usage or an explicit refusal;
## none plans, applies, probes the host, or starts a daemon. The Linux arm must
## still reach the real add-on usage while other platforms refuse that mode.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_cli_support/infra

type DispatchResult = object
  code: int
  output: string

proc dispatch(mode: string; args: seq[string] = @[];
              stateDir = ""): DispatchResult =
  var childEnv = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): childEnv[key] = value
  if stateDir.len > 0: childEnv["REPRO_INFRA_STATE_DIR"] = stateDir
  let child = startProcess(getAppFilename(),
    args = @["--dispatch-" & mode] & args, env = childEnv,
    options = {poStdErrToStdOut})
  try:
    result.code = child.waitForExit(10_000)
    if result.code == -1:
      child.terminate()
      discard child.waitForExit()
      raise newException(IOError, "usage-only dispatcher did not return")
    result.output = child.outputStream.readAll()
  finally:
    child.close()

when isMainModule:
  let args = commandLineParams()
  if args.len > 0:
    let rest = if args.len > 1: args[1 .. ^1] else: @[]
    case args[0]
    of "--dispatch-system": quit(runSystemCommand(rest))
    of "--dispatch-infra": quit(runInfraCommand(rest))
    else: discard # Leave test-runner protocol arguments to unittest.

suite "portable CLI keeps the Linux add-on boundary":
  test "system usage retains the ordinary command family":
    let actual = dispatch("system")
    check actual.code == 2
    check "usage: repro system" in actual.output
    check "rollback" in actual.output
    check "supported only on Linux" notin actual.output

  test "infra usage remains independent of add-on mode":
    let actual = dispatch("infra")
    check actual.code == 2
    check "usage: repro infra" in actual.output
    check "apply" in actual.output
    check "supported only on Linux" notin actual.output

  test "unknown system commands keep their own diagnostic":
    let actual = dispatch("system", @["unknown-dispatch-control"])
    check actual.code == 2
    check "unknown subcommand: unknown-dispatch-control" in actual.output
    check "supported only on Linux" notin actual.output

  test "add-on dispatch reaches Linux usage or explicitly refuses the platform":
    let actual = dispatch("system", @["addon"])
    check actual.code == 2
    when defined(linux):
      check "usage: repro system addon <command>" in actual.output
      check "supported only on Linux" notin actual.output
    else:
      check "repro system addon: supported only on Linux" in actual.output
      check "usage: repro system addon <command>" notin actual.output

  test "adoption reaches only the Linux ownership ledger":
    let stateDir = createTempDir("addon-dispatch-", "")
    defer: removeDir(stateDir)
    let actual = dispatch("system", @["adopt"], stateDir = stateDir)
    check actual.code == 2
    when defined(linux):
      check "only an add-on host has objects to adopt" in actual.output
      check "supported only on Linux" notin actual.output
    else:
      check "repro system adopt: supported only on Linux" in actual.output
      check "only an add-on host" notin actual.output
