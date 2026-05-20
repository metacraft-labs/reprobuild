## M63 gate 3: `e2e_repro_home_apply_partial_recovery`.
##
## Drives the public `repro home apply` CLI with the test injection
## env var `REPRO_TEST_APPLY_KILL_AFTER_STEP=8`, which causes the
## pipeline to write the partial-apply marker and raise after step 8.
## Then re-runs apply WITHOUT the env var and asserts:
##
##   1. The aborted generation has been quarantined under
##      `<state-dir>/generations/.aborted/<id>-<reason>-<ts>/`.
##   2. A new generation has been produced.
##   3. `current` points at the new generation.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

import ../scoop/scoop_sandbox

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply" / "fresh_install"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate)
  candidate

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

when not defined(windows):
  suite "M63 gate 3: e2e_repro_home_apply_partial_recovery":
    test "platform N/A":
      echo "[platform N/A] t_e2e_repro_home_apply_partial_recovery: requires Windows and a real Scoop install"
      check true
else:
  suite "M63 gate 3: e2e_repro_home_apply_partial_recovery":
    test "killed apply quarantines on next run; current stays intact":
      when not defined(windows):
        checkpoint "skipping on non-Windows"
        check true
        return
      let scoopBinary = resolveScoopBinary()
      doAssert scoopBinary.len > 0

      let tempRoot = createTempDir("repro-m63-recovery-", "")
      defer: safeRemoveTempRoot(tempRoot)
      let stateDir = tempRoot / "state"
      let storeRoot = tempRoot / "store"
      let profileDir = tempRoot / "profile"
      let homeDir = tempRoot / "home"
      createDir(stateDir)
      createDir(storeRoot)
      createDir(homeDir)
      createDir(profileDir)
      copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")

      let sandbox = setupScoopSandbox(tempRoot, "main")
      let fixture = populateScoopApp(sandbox,
        app = "fresh-install-fixture",
        version = "1.0.0",
        executableName = "fresh-install-fixture.cmd",
        executablePayload = fixtureExecutablePayload(
          "fresh-install-fixture 1.0.0 M63"))

      let scoopMap = "fresh-install-fixture=" & sandbox.bucketName & "/" &
        fixture.name & "@" & fixture.version & "#" & fixture.executableName
      let baseEnv = @[
        (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "gate3-host"),
        (k: "REPRO_TEST_PACKAGE_SCOOP", v: scoopMap),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "fresh-install-fixture"),
        (k: "SCOOP", v: sandbox.root)]
      let killEnv = baseEnv & @[
        (k: "REPRO_TEST_APPLY_KILL_AFTER_STEP", v: "8")]

      let killed = runRepro(killEnv, ["home", "apply"])
      check killed.exitCode != 0
      check killed.output.contains("aborted after step 8")

      # `current` was never advanced.
      let currentAfterKill = readCurrentGenerationId(stateDir)
      check currentAfterKill.len == 0

      # The marker file exists.
      check fileExists(stateDir / "apply.in-progress")

      let recovered = runRepro(baseEnv, ["home", "apply"])
      check recovered.exitCode == 0
      check recovered.output.contains("applied generation ")
      check recovered.output.contains(
        "recovered partial generation at ")
      check recovered.output.contains(".aborted")

      # The marker was cleared.
      check (not fileExists(stateDir / "apply.in-progress"))

      # A new generation exists and `current` points at it.
      let activeId = readCurrentGenerationId(stateDir)
      check activeId.len > 0
      check dirExists(generationDir(stateDir, activeId))
      check fileExists(pointerPath(stateDir, activeId))

      # The aborted directory has at least one quarantined entry.
      let abortedRoot = generationsRoot(stateDir) / ".aborted"
      check dirExists(abortedRoot)
      var abortedEntries = 0
      for kind, entry in walkDir(abortedRoot, relative = false):
        if kind in {pcDir, pcLinkToDir}:
          inc abortedEntries
      check abortedEntries >= 1
