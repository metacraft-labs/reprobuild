## M63 gate 4: `e2e_repro_home_add_remove_immediate`.
##
## Drives the public `repro home add` / `repro home remove` CLI and
## verifies:
##
##   * `repro home add fd` runs apply inline → exit 0, intent edit
##     observed, new generation created, launcher present and
##     executes (`<launcher> --version` exits 0).
##   * `repro home remove fd` runs apply inline → exit 0, intent
##     edit observed, new generation created, launcher gone.
##   * `repro home remove fd --no-apply` skips apply → exit 0,
##     intent edit observed, no new generation. A subsequent
##     `repro home apply` produces a generation whose final state
##     matches the immediate form (same set of launchers).
##
## To avoid shipping a real `fd` we point the path-adapter at a
## fixture batch script that responds to `--version`.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply" / "add_remove_immediate"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate)
  candidate

proc writeFixtureFd(path: string) =
  ## A trivial Windows batch script imitating `fd --version`.
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo fd 0.0.0-fixture\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 1\r\n")
  else:
    writeFile(path,
      "#!/bin/sh\n" &
      "if [ \"$1\" = \"--version\" ]; then\n" &
      "  echo \"fd 0.0.0-fixture\"\n" &
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

proc launcherPath(stateDir, command: string): string =
  when defined(windows):
    let stableBin = stateDir / "bin"
    let cmdExe = stableBin / (command & ".exe")
    let cmdShim = stableBin / (command & ".cmd")
    if fileExists(cmdExe): cmdExe
    elif fileExists(cmdShim): cmdShim
    else: ""
  else:
    let activeId = readCurrentGenerationId(stateDir)
    let perGenBin = generationDir(stateDir, activeId) / "bin"
    let script = perGenBin / command
    if fileExists(script): script else: ""

suite "M63 gate 4: e2e_repro_home_add_remove_immediate":
  test "add fd produces a launcher; remove fd removes it; --no-apply defers":
    let tempRoot = createTempDir("repro-m63-immediate-", "")
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
    copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")
    let fdFixturePath = fixtureDir / (when defined(windows): "fd.cmd" else: "fd")
    let seedFixturePath = fixtureDir / (when defined(windows): "seed-package.cmd" else: "seed-package")
    writeFixtureFd(fdFixturePath)
    writeFixtureFd(seedFixturePath)

    let pkgSourceMap = "fd=" & fdFixturePath & ";seed-package=" & seedFixturePath
    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate4-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "fd,seed-package")]

    # Step A: `repro home add fd` → intent edit + apply.
    let addResult = runRepro(baseEnv, ["home", "add", "fd"])
    check addResult.exitCode == 0
    check addResult.output.contains("applied generation ")
    let profileBytes = readFile(profileDir / "home.nim")
    check profileBytes.contains("fd")
    let recordsAfterAdd = enumerateGenerations(stateDir)
    check recordsAfterAdd.len == 1
    let lp = launcherPath(stateDir, "fd")
    check lp.len > 0
    check fileExists(lp)

    # Run the launcher → it must exit 0 with the fixture's marker.
    let runRes = execCmdEx("\"" & lp & "\" --version")
    check runRes.exitCode == 0
    check runRes.output.contains("fd 0.0.0-fixture")

    # Step B: `repro home remove fd` → intent edit + apply.
    let removeResult = runRepro(baseEnv, ["home", "remove", "fd"])
    check removeResult.exitCode == 0
    check removeResult.output.contains("applied generation ")
    let profileAfterRemove = readFile(profileDir / "home.nim")
    check (not profileAfterRemove.contains("\n    fd\n"))
    let recordsAfterRemove = enumerateGenerations(stateDir)
    check recordsAfterRemove.len == 2
    # Launcher is gone.
    let lp2 = launcherPath(stateDir, "fd")
    check lp2.len == 0

    # Step C: `repro home remove seed-package --no-apply` → intent
    # edit ONLY.
    let removeNoApply = runRepro(baseEnv,
      ["home", "remove", "seed-package", "--no-apply"])
    check removeNoApply.exitCode == 0
    # Profile no longer mentions seed-package.
    let profileAfterNoApply = readFile(profileDir / "home.nim")
    check (not profileAfterNoApply.contains("seed-package"))
    # No new generation was produced.
    let recordsAfterNoApply = enumerateGenerations(stateDir)
    check recordsAfterNoApply.len == 2

    # Step D: `repro home apply` (no flags) catches up.
    let applyRes = runRepro(baseEnv, ["home", "apply"])
    check applyRes.exitCode == 0
    let recordsAfterApply = enumerateGenerations(stateDir)
    check recordsAfterApply.len == 3
    # Final state matches the immediate form: no fd launcher, no
    # seed-package launcher.
    let lpFd = launcherPath(stateDir, "fd")
    let lpSeed = launcherPath(stateDir, "seed-package")
    check lpFd.len == 0
    check lpSeed.len == 0
