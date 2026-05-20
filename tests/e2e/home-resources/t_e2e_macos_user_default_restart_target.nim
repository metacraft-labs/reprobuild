## M68 gate 3: `e2e_macos_user_default_restart_target`.
##
## macOS-only. Per the milestone spec:
##   - Apply writes a typed value to a TEST domain under
##     `~/Library/Preferences/` (NOT `com.apple.dock`) with
##     `restartTarget` set to a benign placeholder daemon.
##   - The daemon is killed ONLY when the value actually changed.
##   - A cache-hit re-apply does NOT invoke `killall`.
##
## On the Windows dev host this gate is platform-skipped (the
## `when not defined(macosx)` guard returns early) — the milestone
## verification block records `status: skipped`, `skip_reason:
## platform-e2e: macOS-only`. The test below is written honestly:
## when run on a macOS host it really exercises `defaults` +
## `killall` against an isolated test domain.
##
## ## How the "killall fired?" assertion is made without a real
## ##  daemon
##
## A benign placeholder process is started by the test itself —
## `/bin/sleep` running for a long interval. Its process name is
## `sleep`; `restartTarget = "sleep"` means the driver runs
## `killall sleep` after a value-changing write. The test then
## checks whether the placeholder process is still alive:
##   - value changed  -> the placeholder was killed (killall fired)
##   - cache-hit       -> the placeholder is still alive (no killall)
## This keeps the gate self-contained and never touches a real
## system daemon.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
  unittest]

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
    writeFile(path,
      "#!/bin/sh\n" &
      "if [ \"$1\" = \"--version\" ]; then\n" &
      "  echo 'm68-base-fixture 0.0.0'\n" &
      "  exit 0\n" &
      "fi\n" &
      "exit 1\n")

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

when defined(macosx):
  proc placeholderAlive(pidStr: string): bool =
    ## True while the benign placeholder process is still running.
    execCmd("kill -0 " & pidStr & " 2>/dev/null") == 0

  proc runGate3() =
    # The test domain lives under ~/Library/Preferences/ — NOT
    # com.apple.dock — so the gate never disturbs a real system
    # preference. `defaults` resolves a bare reverse-DNS domain to
    # ~/Library/Preferences/<domain>.plist.
    let testDomain = "com.reprobuild.m68-gate3-" & $int(epochTime())
    defer:
      discard execCmd("defaults delete " & testDomain & " 2>/dev/null")

    let tempRoot = createTempDir("repro-m68-gate3-", "")
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
    let exe = fixtureDir / "m68-base-fixture.sh"
    writeFixtureExe(exe)
    discard execCmd("chmod +x " & exe)

    proc envFor(resources: string): seq[tuple[k, v: string]] =
      @[(k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "REPRO_HOST", v: "gate3-host"),
        (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
        (k: "REPRO_TEST_RESOURCES", v: resources)]

    # --- Apply 1: writes the value; placeholder should be killed ---
    # Start a benign placeholder `sleep` and use its process name as
    # the restartTarget. A long sleep keeps it alive long enough to
    # observe whether the driver's `killall` reached it.
    let ph1 = startProcess("/bin/sleep", args = @["600"],
      options = {poUsePath})
    let ph1Pid = $ph1.processID
    let resources1 = "userdefault:macos.theme:" & testDomain &
      ";AppleInterfaceStyle;'Dark';sleep"
    let r1 = runRepro(envFor(resources1), ["home", "apply"])
    check r1.exitCode == 0
    # The value was created (a real change) -> killall sleep fired
    # -> the placeholder process is gone.
    sleep(500)
    check not placeholderAlive(ph1Pid)
    try: ph1.close() except CatchableError: discard
    # The value really landed in the test domain.
    let (readOut, readCode) = execCmdEx(
      "defaults read " & testDomain & " AppleInterfaceStyle")
    check readCode == 0
    check readOut.strip() == "Dark"

    # --- Apply 2: identical value -> cache-hit -> NO killall ---
    let ph2 = startProcess("/bin/sleep", args = @["600"],
      options = {poUsePath})
    let ph2Pid = $ph2.processID
    let r2 = runRepro(envFor(resources1), ["home", "apply"])
    check r2.exitCode == 0
    # The lifecycle algorithm sees observed.digest == desired.digest
    # -> rakNoOp -> the driver's apply (and therefore killall) is
    # never reached. The placeholder must STILL be alive.
    sleep(500)
    check placeholderAlive(ph2Pid)
    try:
      discard execCmd("kill " & ph2Pid)
      ph2.close()
    except CatchableError: discard

suite "M68 gate 3: e2e_macos_user_default_restart_target":
  test "restartTarget killall fires on change, not on a cache-hit":
    when defined(macosx):
      runGate3()
    else:
      checkpoint "platform-skip: macos.userDefault is the gate; " &
        "macOS-only"
      skip()
