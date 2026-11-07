## `repro infra apply --keep-generations N --keep-days D` (ReproOS Add-On
## Mode §5.2): the full engine's apply takes the add-on host's generation
## retention policy, as the static add-on binary does. The flags parse as
## non-negative integers (0 keeps only what is always kept), are listed in
## the subcommand's help, and are refused on a host that is not an add-on
## host, where they would mean nothing.
##
## The add-on host leg itself (the policy reaching the retention after a
## commit) needs root, a store and systemd: the VM gate
## `e2e_addon_gc_keeps_current_and_previous` exercises it.
##
## *Mocking.* None: the real dispatcher in a child process, against a
## temporary state directory with a real (empty) system profile.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_cli_support/infra

type DispatchResult = object
  code: int
  output: string

proc dispatch(args: seq[string]; stateDir = ""): DispatchResult =
  var childEnv = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): childEnv[key] = value
  if stateDir.len > 0: childEnv["REPRO_INFRA_STATE_DIR"] = stateDir
  let child = startProcess(getAppFilename(),
    args = @["--dispatch-infra"] & args, env = childEnv,
    options = {poStdErrToStdOut})
  try:
    result.code = child.waitForExit(60_000)
    if result.code == -1:
      child.terminate()
      discard child.waitForExit()
      raise newException(IOError, "dispatcher did not return")
    result.output = child.outputStream.readAll()
  finally:
    child.close()

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--dispatch-infra":
    quit(runInfraCommand(if args.len > 1: args[1 .. ^1] else: @[]))

suite "repro infra apply: the add-on retention flags":
  test "the help lists them":
    let r = dispatch(@["apply", "--help"])
    check r.code == 0
    check "--keep-generations N" in r.output and "--keep-days D" in r.output

  test "a negative or non-numeric bound is a usage error":
    for bad in [@["--keep-generations", "-1"], @["--keep-days=x"],
                @["--keep-generations=two"]]:
      let r = dispatch(@["apply", "--no-preview"] & bad)
      check r.code == 2
      check "expects a non-negative integer" in r.output

  test "on a host that is not an add-on host they are refused":
    let dir = createTempDir("repro-infra-retention-", "")
    defer: removeDir(dir)
    let profile = dir / "system.profile"
    writeFile(profile, "")
    let r = dispatch(@["apply", "--no-preview", "--no-elevate",
                       "--state-dir", dir / "state", "--profile", profile,
                       "--host", "retention-test", "--keep-generations", "0"],
                     stateDir = dir / "state")
    check r.code == 2
    check "not an add-on host" in r.output
