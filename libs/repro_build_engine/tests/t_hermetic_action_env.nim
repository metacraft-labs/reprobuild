## `BuildEngineConfig.hermeticEnv` — Hermetic-Builds-And-Path-Independence:
## "environment variables are allowlisted and normalized".
##
## An action is keyed on the variables it was observed reading. Launched over
## an inherited environment, a program that reads all of them (`node`, `npm`)
## reads every per-session variable of the shell that ran `repro build`, and
## two hosts building the same thing can never agree on a key. With the switch
## on, the child gets exactly what the engine composed: its declared entries,
## its passthrough names resolved from the host, and the host's OS-essential
## set — and nothing else.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_hash
import runquota_process

const LauncherIsolates = compiles(commandSpec(["x"], inheritEnv = false))
  ## A runquota older than 2c50aaf cannot start a child from nothing; there
  ## the engine degrades to layering (`repro_runquota.launchSpec`), and only
  ## the key half of the contract below is checkable.

const
  LeakVar = "REPRO_TEST_HERMETIC_LEAK"
  DeclaredVar = "REPRO_TEST_HERMETIC_DECLARED"
  PassthroughVar = "REPRO_TEST_HERMETIC_PASSTHROUGH"
  EssentialVar = when defined(windows): "SYSTEMROOT" else: "HOME"
    ## Upper case on Windows: an MSYS `sh` imports every name upper-cased
    ## (`SystemRoot` is `$SYSTEMROOT` to it), and Windows names match either.

proc report(sh, workRoot, id: string): BuildAction =
  ## Writes what the child can see of each variable, one per line.
  var script = ""
  for name in [LeakVar, DeclaredVar, PassthroughVar, EssentialVar]:
    script.add("printf '%s=%s\\n' " & name & " \"${" & name &
      "-<unset>}\" >> out/seen.txt; ")
  action(id, [sh, "-c", script],
    cwd = workRoot,
    inputs = [],
    outputs = ["out/seen.txt"],
    cacheable = false,
    weakFingerprint = weakFingerprintFromText("hermetic-env." & id),
    env = [DeclaredVar & "=declared"],
    envPassthrough = [PassthroughVar],
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc seenBy(hermetic: bool): string =
  let root = createTempDir("repro-hermetic-env-", "")
  defer: removeDir(root)
  createDir(root / "out")
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  config.hermeticEnv = hermetic
  let run = runBuild(graph([report(findExe("sh"), root, "hermetic/report")]),
    config)
  require run.results.len == 1
  require run.results[0].status == asSucceeded
  readFile(root / "out" / "seen.txt")

suite "an allowlisted action environment":
  putEnv(LeakVar, "from-the-invoking-shell")
  putEnv(PassthroughVar, "passed-through")

  test "control: without it, the invoking shell's variables reach the child":
    if findExe("sh").len == 0:
      skip("no `sh` on PATH; the probe action is a shell script")
    else:
      check (LeakVar & "=from-the-invoking-shell") in seenBy(false)

  test "with it, the child sees what it declared and nothing else":
    if findExe("sh").len == 0 or not LauncherIsolates:
      skip("needs `sh` on PATH and a launcher that isolates the environment on this platform")
    else:
      let seen = seenBy(true)
      check (LeakVar & "=<unset>") in seen
      check (DeclaredVar & "=declared") in seen
      check (PassthroughVar & "=passed-through") in seen
      if existsEnv(EssentialVar):
        check (EssentialVar & "=" & getEnv(EssentialVar)) in seen

  test "the key reads a host variable as unset and passes the essentials":
    let a = action("hermetic/key", ["tool"],
      env = [DeclaredVar & "=declared"],
      weakFingerprint = weakFingerprintFromText("hermetic-env.key"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var config = defaultBuildEngineConfig(getTempDir() / "unused")
    config.hermeticEnv = true
    let evidence = PathSetEvidence(
      monitorEnvReads: @[LeakVar, DeclaredVar, EssentialVar])
    var keyed: seq[string] = @[]
    for variable in a.cacheEnvInputs(evidence, addr config):
      keyed.add(variable.name & "|" & $variable.present & "|" &
        variable.value)
    # The leak is keyed as what the child saw -- unset -- so two hosts with
    # different values for it agree; the essential is keyed by name only
    # (not at all, here), like any passthrough.
    check keyed == @[DeclaredVar & "|true|declared", LeakVar & "|false|"]
    config.hermeticEnv = false
    var inherited: seq[string] = @[]
    for variable in a.cacheEnvInputs(evidence, addr config):
      inherited.add(variable.name)
    check EssentialVar in inherited or not existsEnv(EssentialVar)
