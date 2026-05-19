## M64 gate 2: `e2e_repro_home_rollback_user_edit_protection`.
##
## Verifies the digest-check / `EUserEditDetected` contract from
## `Home-Profile-Generations-And-State.md` "Rollback":
##
##   1. Apply A then apply B (so we have two generations).
##   2. Hand-edit a B-managed file in `$HOME`.
##   3. `repro home rollback` (target = A): exits non-zero with the
##      `user edit detected` diagnostic naming the path and digest
##      prefixes. The drifted file is NOT modified.
##   4. `repro home rollback --accept-overwrite`: exits 0; the
##      drifted file is clobbered (rolled back to A's content) and
##      the drift is logged.

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
  doAssert fileExists(candidate)
  candidate

proc writeFixtureExe(path: string) =
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

const
  # NB: no trailing newline — see comments in the round-trip gate.
  AConfigContent = "[foo]\nfrom=a"
  BConfigContent = "[bar]\nfrom=b"
  ABlockContent = "export FOO=a"
  BBlockContent = "export FOO=b"
  UserEditSuffix = "\n# user-added by hand on 2026-05-20\n"

suite "M64 gate 2: e2e_repro_home_rollback_user_edit_protection":
  test "user edit blocks rollback; --accept-overwrite clobbers":
    let tempRoot = createTempDir("repro-m64-userprotect-", "")
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

    # --- Apply A ---
    copyFile(ProfileASrc / "home.nim", profileDir / "home.nim")
    let envA = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate2-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
        v: "pkg-x=.fooconfig:" & AConfigContent),
      (k: "REPRO_TEST_PACKAGE_MANAGED_BLOCKS",
        v: "pkg-y=.bashrc#repro.gate2:" & ABlockContent),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "pkg-x,pkg-y,pkg-z")]
    let aRes = runRepro(envA, ["home", "apply"])
    check aRes.exitCode == 0
    let aId = readCurrentGenerationId(stateDir)
    check aId.len > 0

    # --- Apply B ---
    copyFile(ProfileBSrc / "home.nim", profileDir / "home.nim")
    let envB = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate2-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
        v: "pkg-x=.barconfig:" & BConfigContent),
      (k: "REPRO_TEST_PACKAGE_MANAGED_BLOCKS",
        v: "pkg-z=.bashrc#repro.gate2:" & BBlockContent),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "pkg-x,pkg-y,pkg-z")]
    let bRes = runRepro(envB, ["home", "apply"])
    check bRes.exitCode == 0
    let bId = readCurrentGenerationId(stateDir)
    check bId.len > 0
    check bId != aId

    # --- Hand-edit a B-managed file ---
    let barPath = homeDir / ".barconfig"
    check fileExists(barPath)
    let originalB = readFile(barPath)
    writeFile(barPath, originalB & UserEditSuffix)
    let driftedContent = readFile(barPath)
    check driftedContent != originalB
    check driftedContent.contains("user-added by hand")

    # --- Rollback without --accept-overwrite -> exits non-zero ---
    let rbRefuse = runRepro(envB, ["home", "rollback"])
    check rbRefuse.exitCode != 0
    check rbRefuse.output.contains("user edit detected")
    check rbRefuse.output.contains(".barconfig")
    check rbRefuse.output.contains("--accept-overwrite")
    # The barconfig file MUST NOT be modified.
    check readFile(barPath) == driftedContent
    # current still points at B (rollback refused).
    check readCurrentGenerationId(stateDir) == bId

    # --- Rollback WITH --accept-overwrite -> exits 0, clobbers ---
    let rbAccept = runRepro(envB, ["home", "rollback", "--accept-overwrite"])
    check rbAccept.exitCode == 0
    check rbAccept.output.contains("drift detected at " & barPath) or
      rbAccept.output.contains("clobbered under --accept-overwrite")
    # current now at A.
    check readCurrentGenerationId(stateDir) == aId
    # The .barconfig file is gone (A doesn't have it).
    check (not fileExists(barPath))
    # A's fooconfig is restored.
    check fileExists(homeDir / ".fooconfig")
    check readFile(homeDir / ".fooconfig") == AConfigContent
