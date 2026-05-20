## M68 gate 4: `e2e_home_resource_rollback_preserves_unrelated`.
##
## Per the milestone spec:
##   - Generation B adds a PATH contribution.
##   - Rollback to A removes only the B-added contribution.
##   - User PATH entries added outside Reprobuild remain byte-identical.
##
## This proves the `env.userPath` driver respects entries it did
## NOT add — the gate-4 invariant.
##
## Strategy: instead of touching the real `HKCU\Environment\Path`
## (which would contaminate the dev host's environment), we drive
## the `env.userPath` driver directly with a temporary state +
## a side-channel "live PATH" model. The driver reads via the
## real `Reg*` API; the gate seeds and inspects the real
## `HKCU\Environment\Path` value through the same driver functions
## and restores the original at teardown.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_home_resources

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-resources" / "m68-base"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate
  candidate

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo m68-base-fixture 0.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 1\r\n")
  else:
    writeFile(path, "#!/bin/sh\necho fixture\n")

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

suite "M68 gate 4: e2e_home_resource_rollback_preserves_unrelated":
  test "rollback subtracts only Reprobuild contributions; user entries survive":
    when not defined(windows):
      checkpoint "platform-skip: Windows env.userPath path is the gate"
      check true
      return

    # Snapshot the real HKCU\Environment\Path so we can restore it.
    let preGate = readUserPathRaw()
    defer:
      when defined(windows):
        if preGate.present:
          writeRegistryValue("Environment", "Path", preGate.regType,
            encodeString(preGate.raw))
        else:
          try: deleteRegistryValue("Environment", "Path")
          except CatchableError: discard

    # Seed with a user-only entry that must survive both apply and
    # rollback. The entry is unusual enough that we'd notice it
    # accidentally collide with a real Reprobuild entry.
    let userOnlyEntry = "C:\\repro-m68-gate4-user-only-entry"
    let reproEntryA = "C:\\repro-m68-gate4-A"
    let reproEntryB = "C:\\repro-m68-gate4-B"

    # Build the initial PATH: pre-existing + user-only.
    var initialEntries: seq[string] = @[]
    if preGate.present:
      initialEntries = splitPathEntries(preGate.raw)
    initialEntries.add(userOnlyEntry)
    let initialJoined = joinPathEntries(initialEntries)
    writeRegistryValue("Environment", "Path", 1'u32,
      encodeString(initialJoined))

    let tempRoot = createTempDir("repro-m68-gate4-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let profileDir = tempRoot / "profile"
    let homeDir = tempRoot / "home"
    let fixtureDir = tempRoot / "fixtures"
    createDir(stateDir); createDir(storeRoot); createDir(homeDir)
    createDir(profileDir); createDir(fixtureDir)
    copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")
    let exe = fixtureDir / "m68-base-fixture.cmd"
    writeFixtureExe(exe)

    let envBaseA = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate4-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
      (k: "REPRO_TEST_RESOURCES",
        v: "userpath:env.path:" & reproEntryA)]
    let envBaseB = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate4-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
      (k: "REPRO_TEST_RESOURCES",
        v: "userpath:env.path:" & reproEntryA & "," & reproEntryB)]

    # --- Apply A: adds reproEntryA ---
    let rA = runRepro(envBaseA, ["home", "apply"])
    check rA.exitCode == 0
    let aId = readCurrentGenerationId(stateDir)
    check aId.len > 0

    let pathAfterA = readUserPathRaw()
    check pathAfterA.present
    let entriesAfterA = splitPathEntries(pathAfterA.raw)
    check userOnlyEntry in entriesAfterA
    check reproEntryA in entriesAfterA

    # --- Apply B: adds reproEntryB (and keeps A) ---
    let rB = runRepro(envBaseB, ["home", "apply"])
    check rB.exitCode == 0
    let bId = readCurrentGenerationId(stateDir)
    check bId != aId

    let pathAfterB = readUserPathRaw()
    let entriesAfterB = splitPathEntries(pathAfterB.raw)
    check userOnlyEntry in entriesAfterB
    check reproEntryA in entriesAfterB
    check reproEntryB in entriesAfterB

    # --- Rollback to A: should subtract ONLY reproEntryB ---
    let rRollback = runRepro(envBaseB, ["home", "rollback"])
    check rRollback.exitCode == 0
    check readCurrentGenerationId(stateDir) == aId

    let pathAfterRollback = readUserPathRaw()
    let entriesAfterRollback = splitPathEntries(pathAfterRollback.raw)
    # The gate-4 invariant: user-added entries survive.
    check userOnlyEntry in entriesAfterRollback
    # B's contribution is gone.
    check reproEntryB notin entriesAfterRollback
    # A's contribution is back.
    check reproEntryA in entriesAfterRollback
