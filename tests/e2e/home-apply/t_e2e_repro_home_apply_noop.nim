## M63 gate 2: `e2e_repro_home_apply_noop`.
##
## Drives the public `repro home apply` CLI twice against the same
## profile and asserts the second invocation short-circuits to a
## no-op: same generation id, the stable "no-op: generation matches"
## log line, exit code 0.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

import ../scoop/scoop_sandbox

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply" / "fresh_install"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate
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

suite "M63 gate 2: e2e_repro_home_apply_noop":
  test "re-apply with no changes short-circuits to no-op":
    when not defined(windows):
      checkpoint "skipping on non-Windows"
      check true
      return
    let scoopBinary = resolveScoopBinary()
    doAssert scoopBinary.len > 0,
      "M63 gate 2 requires real scoop.exe"

    let tempRoot = createTempDir("repro-m63-noop-", "")
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
    let envVars = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate2-host"),
      (k: "REPRO_TEST_PACKAGE_SCOOP", v: scoopMap),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "fresh-install-fixture"),
      (k: "SCOOP", v: sandbox.root)]

    let first = runRepro(envVars, ["home", "apply"])
    check first.exitCode == 0
    check first.output.contains("applied generation")
    let firstId = readCurrentGenerationId(stateDir)
    check firstId.len > 0

    let second = runRepro(envVars, ["home", "apply"])
    check second.exitCode == 0
    check second.output.contains("no-op: generation matches; verified ")
    check second.output.contains(firstId)

    let secondId = readCurrentGenerationId(stateDir)
    check secondId == firstId

    # Still exactly one generation directory.
    let records = enumerateGenerations(stateDir)
    check records.len == 1
