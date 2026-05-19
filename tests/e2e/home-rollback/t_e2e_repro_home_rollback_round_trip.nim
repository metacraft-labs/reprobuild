## M64 gate 1: `e2e_repro_home_rollback_round_trip`.
##
## Drives the public `repro home apply` and `repro home rollback`
## CLIs end-to-end:
##
##   1. Apply profile A (packages X, Y; generated `~/.fooconfig`;
##      managed block in `~/.bashrc`).
##   2. Swap to profile B (packages X, Z; generated `~/.barconfig`;
##      different managed block content).
##   3. Apply B.
##   4. Roll back (no arg -> targets A's id).
##   5. Verify A's state is restored.
##   6. Roll back forward to B by explicit id.
##   7. Verify B's state is restored.
##
## Uses the universal `path` adapter via `REPRO_TEST_PACKAGE_SOURCE`
## for package realization (no Scoop required), and the
## `REPRO_TEST_PACKAGE_GENERATES` / `REPRO_TEST_PACKAGE_MANAGED_BLOCKS`
## test hooks for the generated file and managed block. Packages X, Y,
## Z stay installed throughout — rollback does NOT uninstall.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-rollback"
const ProfileASrc = FixtureRoot / "profile-a"
const ProfileBSrc = FixtureRoot / "profile-b"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path: string) =
  ## Trivial executable that responds to --version. Used as the
  ## `path` adapter's source for each fixture package.
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo fixture-pkg 0.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 1\r\n")
  else:
    writeFile(path,
      "#!/bin/sh\n" &
      "if [ \"$1\" = \"--version\" ]; then\n" &
      "  echo fixture-pkg 0.0.0\n" &
      "  exit 0\n" &
      "fi\n" &
      "exit 1\n")
    setFilePermissions(path, {fpUserExec, fpUserWrite, fpUserRead,
      fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

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

proc launcherPresent(stateDir, command: string): bool =
  when defined(windows):
    let stable = stateDir / "bin"
    fileExists(stable / (command & ".exe")) or
      fileExists(stable / (command & ".cmd"))
  else:
    let active = readCurrentGenerationId(stateDir)
    if active.len == 0: return false
    fileExists(generationDir(stateDir, active) / "bin" / command)

const
  # NB: no trailing newline — the env-var seam's `parseSynthetic*`
  # parsers strip surrounding whitespace, so a trailing `\n` would be
  # dropped on the way through.
  AConfigContent = "[foo]\nfrom=a"
  BConfigContent = "[bar]\nfrom=b"
  ABlockContent = "export FOO=a"
  BBlockContent = "export FOO=b"

suite "M64 gate 1: e2e_repro_home_rollback_round_trip":
  test "apply A, apply B, rollback to A, rollback forward to B":
    let tempRoot = createTempDir("repro-m64-roundtrip-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let profileDir = tempRoot / "profile"
    let homeDir = tempRoot / "home"
    let fixtureDir = tempRoot / "fixtures"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(homeDir)
    createDir(profileDir)
    createDir(fixtureDir)

    let exeExt = when defined(windows): ".cmd" else: ""
    let xExe = fixtureDir / ("pkg-x" & exeExt)
    let yExe = fixtureDir / ("pkg-y" & exeExt)
    let zExe = fixtureDir / ("pkg-z" & exeExt)
    writeFixtureExe(xExe)
    writeFixtureExe(yExe)
    writeFixtureExe(zExe)

    let pkgSourceMap = "pkg-x=" & xExe & ";pkg-y=" & yExe & ";pkg-z=" & zExe

    # --- Step 1: apply A ---
    copyFile(ProfileASrc / "home.nim", profileDir / "home.nim")
    let envA = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate1-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
        v: "pkg-x=.fooconfig:" & AConfigContent),
      (k: "REPRO_TEST_PACKAGE_MANAGED_BLOCKS",
        v: "pkg-y=.bashrc#repro.gate1:" & ABlockContent),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "pkg-x,pkg-y,pkg-z")]
    let aRes = runRepro(envA, ["home", "apply"])
    check aRes.exitCode == 0
    check aRes.output.contains("applied generation ")
    let aId = readCurrentGenerationId(stateDir)
    check aId.len > 0

    # Sanity: A's state on disk.
    check readFile(homeDir / ".fooconfig") == AConfigContent
    let bashrcA = readFile(homeDir / ".bashrc")
    check bashrcA.contains("repro-managed:repro.gate1")
    check bashrcA.contains(ABlockContent.strip)
    check launcherPresent(stateDir, "pkg-x")
    check launcherPresent(stateDir, "pkg-y")
    check not launcherPresent(stateDir, "pkg-z")

    # --- Step 2-3: swap to B and apply ---
    copyFile(ProfileBSrc / "home.nim", profileDir / "home.nim")
    let envB = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate1-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
        v: "pkg-x=.barconfig:" & BConfigContent),
      (k: "REPRO_TEST_PACKAGE_MANAGED_BLOCKS",
        v: "pkg-z=.bashrc#repro.gate1:" & BBlockContent),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "pkg-x,pkg-y,pkg-z")]
    let bRes = runRepro(envB, ["home", "apply"])
    check bRes.exitCode == 0
    check bRes.output.contains("applied generation ")
    let bId = readCurrentGenerationId(stateDir)
    check bId.len > 0
    check bId != aId

    # Sanity: B's state.
    check readFile(homeDir / ".barconfig") == BConfigContent
    check not fileExists(homeDir / ".fooconfig")
    let bashrcB = readFile(homeDir / ".bashrc")
    check bashrcB.contains(BBlockContent.strip)
    check (not bashrcB.contains(ABlockContent.strip))
    check launcherPresent(stateDir, "pkg-x")
    check launcherPresent(stateDir, "pkg-z")
    check (not launcherPresent(stateDir, "pkg-y"))

    # --- Step 4: rollback to A (no arg = previous) ---
    let rbA = runRepro(envB, ["home", "rollback"])
    check rbA.exitCode == 0
    check rbA.output.contains("rolled back from " & bId & " to " & aId)

    # A's state must be restored.
    check readCurrentGenerationId(stateDir) == aId
    check fileExists(homeDir / ".fooconfig")
    check readFile(homeDir / ".fooconfig") == AConfigContent
    check not fileExists(homeDir / ".barconfig")
    let bashrcAfterRollback = readFile(homeDir / ".bashrc")
    check bashrcAfterRollback.contains(ABlockContent.strip)
    check (not bashrcAfterRollback.contains(BBlockContent.strip))
    check launcherPresent(stateDir, "pkg-x")
    check launcherPresent(stateDir, "pkg-y")
    check not launcherPresent(stateDir, "pkg-z")

    # Packages X, Y, Z must all still be installed.
    let storePrefixes = storeRoot / "prefixes"
    var prefixCount = 0
    for kind, entry in walkDir(storePrefixes, relative = false):
      if kind in {pcDir, pcLinkToDir}:
        for k2, e2 in walkDir(entry, relative = false):
          if k2 in {pcDir, pcLinkToDir}: inc prefixCount
    # X, Y, Z each realized a prefix. Rollback does NOT uninstall.
    check prefixCount >= 3

    # --- Step 5: rollback forward to B ---
    let rbB = runRepro(envB, ["home", "rollback", bId])
    check rbB.exitCode == 0
    check rbB.output.contains("rolled back from " & aId & " to " & bId)

    check readCurrentGenerationId(stateDir) == bId
    check fileExists(homeDir / ".barconfig")
    check readFile(homeDir / ".barconfig") == BConfigContent
    check not fileExists(homeDir / ".fooconfig")
    let bashrcFinal = readFile(homeDir / ".bashrc")
    check bashrcFinal.contains(BBlockContent.strip)
    check (not bashrcFinal.contains(ABlockContent.strip))
    check launcherPresent(stateDir, "pkg-z")
    check (not launcherPresent(stateDir, "pkg-y"))
