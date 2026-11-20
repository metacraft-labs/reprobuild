## Exercise the production system/infra dispatchers without managing a host.
## The child is this real test executable calling those dispatchers, not a
## stand-in repro binary. Every command stops at usage or an explicit refusal;
## none plans, applies, probes the host, or starts a daemon. The Linux arm must
## still reach the real add-on usage while other platforms refuse that mode.
##
## The rollback cases tell the two rollback paths apart by how each refuses
## an empty `--host=`, before either takes a lock or reads the host: on an
## add-on host the full engine refuses every whole-system rollback flag (the
## add-on's rollback takes a generation and `--reconcile-drift` only); the
## ordinary rollback's host resolver refuses the empty name. The add-on
## state directory is a scratch directory holding only the ledger copy
## `isAddonHost` tests for. (Both paths parse the command line with repro's
## generated parser first, so an unknown flag no longer tells them apart.)

from repro_core/process_streams import drainStream
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
    result.output = drainStream(child.outputStream)
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
    # repro's parser: a bare namespace names the subcommands it expects.
    check "needs a subcommand" in actual.output
    check "rollback" in actual.output
    check "supported only on Linux" notin actual.output

  test "infra usage remains independent of add-on mode":
    let actual = dispatch("infra")
    check actual.code == 2
    check "needs a subcommand" in actual.output
    check "apply" in actual.output
    check "supported only on Linux" notin actual.output

  test "unknown system commands keep their own diagnostic":
    let actual = dispatch("system", @["unknown-dispatch-control"])
    check actual.code == 2
    check "unknown subcommand 'unknown-dispatch-control'" in actual.output
    check "supported only on Linux" notin actual.output

  test "add-on dispatch reaches Linux usage or explicitly refuses the platform":
    # The add-on's command line is mounted in repro's description on every
    # platform, so a bare `system addon` is the parser's usage error
    # everywhere; a verb reaches the handler, which refuses the platform.
    let actual = dispatch("system", @["addon"])
    check actual.code == 2
    check "'repro system addon' needs a subcommand" in actual.output
    check "supported only on Linux" notin actual.output
    when not defined(linux):
      let verb = dispatch("system", @["addon", "status"])
      check verb.code == 2
      check "repro system addon: supported only on Linux" in verb.output

  test "adoption reaches only the Linux ownership ledger":
    let stateDir = createTempDir("addon-dispatch-", "")
    defer: removeDir(stateDir)
    let actual = dispatch("system", @["adopt", "unit:x", "--profile", "p"],
      stateDir = stateDir)
    check actual.code == 2
    when defined(linux):
      check "only an add-on host has objects to adopt" in actual.output
      check "supported only on Linux" notin actual.output
    else:
      check "repro system adopt: supported only on Linux" in actual.output
      check "only an add-on host" notin actual.output

  test "rollback on an add-on host takes the add-on switch only on Linux":
    let stateDir = createTempDir("addon-dispatch-", "")
    defer: removeDir(stateDir)
    writeFile(stateDir / "addon-ledger", "")
    let actual = dispatch("system", @["rollback", "--host="],
      stateDir = stateDir)
    check actual.code == 2
    when defined(linux):
      check ("on an add-on host only a generation and --reconcile-drift " &
        "apply") in actual.output
      # The add-on path refused it, not the ordinary host resolver.
      check actual.output.count("repro system rollback:") == 1
    else:
      check "repro system rollback:" in actual.output
      check "on an add-on host" notin actual.output

  test "rollback elsewhere keeps the ordinary system rollback":
    let stateDir = createTempDir("addon-dispatch-", "")
    defer: removeDir(stateDir)
    let actual = dispatch("system", @["rollback", "--host="],
      stateDir = stateDir)
    check actual.code == 2
    check "repro system rollback:" in actual.output
    check "on an add-on host" notin actual.output
