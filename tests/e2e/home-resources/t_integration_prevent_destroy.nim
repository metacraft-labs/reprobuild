## M68 Phase B: `lifecyclePolicy = preventDestroy` integration test.
##
## `preventDestroy` is ABSOLUTE at home scope: when the lifecycle
## algorithm would produce a `destroy` action for a resource that
## carries `lifecyclePolicy = preventDestroy`, it raises
## `EPreventDestroy` instead — and that refusal is NOT bypassable
## by `--reconcile-drift` or `--accept-overwrite`.
##
## Real assertions:
##   - a `preventDestroy` registry resource removed from the desired
##     set makes the next apply fail with `EPreventDestroy`; the
##     registry value is STILL present afterwards (not destroyed).
##   - the same removal under `--accept-overwrite`
##     (REPRO_HOME_APPLY_ACCEPT_OVERWRITE=1) STILL fails — absolute.
##   - a plain (`lpDefault`) registry resource removed from the
##     desired set IS destroyed on the next apply (the control case
##     proving the test harness really exercises the destroy path).
##
## Windows-focused: registry resources are testable on the dev host.

when not defined(windows):
  {.warning[UnreachableCode]: off.}

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
  unittest]

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

suite "M68 Phase B: integration_prevent_destroy":
  test "preventDestroy blocks the destroy; --accept-overwrite cannot bypass":
    when not defined(windows):
      checkpoint "platform-skip: Windows registry resource is the subject"
      check true
      quit(0)

    let testSubkey = "Software\\Reprobuild-Tests\\m68-pd-" &
      $epochTime()
    defer:
      when defined(windows):
        try: deleteRegistryValue(testSubkey, "Guarded")
        except CatchableError: discard

    let tempRoot = createTempDir("repro-m68-pd-", "")
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

    proc envWith(resources: string;
                 extra: openArray[tuple[k, v: string]] = []):
        seq[tuple[k, v: string]] =
      result = @[
        (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "pd-host"),
        (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
        (k: "REPRO_TEST_RESOURCES", v: resources)]
      for kv in extra:
        result.add (k: kv.k, v: kv.v)

    # --- Apply 1: create a registry resource carrying preventDestroy.
    # The `@preventDestroy` suffix on the address sets the resource's
    # lifecyclePolicy; it is persisted in the manifest binding.
    let withResource = "registry:reg.guarded@preventDestroy:" &
      testSubkey & ";Guarded;string;protected-value"
    let r1 = runRepro(envWith(withResource), ["home", "apply"])
    check r1.exitCode == 0
    let liveAfterCreate = readRegistryValue(testSubkey, "Guarded")
    check liveAfterCreate.present

    # --- Apply 2: the resource is GONE from the desired set. The
    # lifecycle would produce a `destroy` — but the recorded
    # binding carries lifecyclePolicy=preventDestroy, so apply
    # fails with EPreventDestroy.
    let r2 = runRepro(envWith(""), ["home", "apply"])
    check r2.exitCode != 0
    check r2.output.contains("preventDestroy")
    check r2.output.contains("reg.guarded")
    # The value was NOT destroyed.
    let liveAfterBlock = readRegistryValue(testSubkey, "Guarded")
    check liveAfterBlock.present
    check liveAfterBlock.bytes == liveAfterCreate.bytes

    # --- Apply 3: same removal, but with --accept-overwrite
    # (the REPRO_HOME_APPLY_ACCEPT_OVERWRITE=1 seam). preventDestroy
    # is ABSOLUTE — the destroy is STILL refused.
    let r3 = runRepro(
      envWith("", [(k: "REPRO_HOME_APPLY_ACCEPT_OVERWRITE", v: "1")]),
      ["home", "apply"])
    check r3.exitCode != 0
    check r3.output.contains("preventDestroy")
    let liveAfterAccept = readRegistryValue(testSubkey, "Guarded")
    check liveAfterAccept.present
    check liveAfterAccept.bytes == liveAfterCreate.bytes

  test "control: a plain (lpDefault) resource IS destroyed on removal":
    when not defined(windows):
      checkpoint "platform-skip"
      check true
      quit(0)

    let testSubkey = "Software\\Reprobuild-Tests\\m68-pd-ctl-" &
      $epochTime()
    defer:
      when defined(windows):
        try: deleteRegistryValue(testSubkey, "Plain")
        except CatchableError: discard

    let tempRoot = createTempDir("repro-m68-pd-ctl-", "")
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

    let envBase = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "pd-ctl-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture")]

    # Apply 1: create a PLAIN registry resource (no preventDestroy).
    let r1 = runRepro(envBase & @[(k: "REPRO_TEST_RESOURCES",
      v: "registry:reg.plain:" & testSubkey & ";Plain;string;disposable")],
      ["home", "apply"])
    check r1.exitCode == 0
    check readRegistryValue(testSubkey, "Plain").present

    # Apply 2: removed from the desired set -> destroyed cleanly.
    let r2 = runRepro(envBase & @[(k: "REPRO_TEST_RESOURCES", v: "")],
      ["home", "apply"])
    check r2.exitCode == 0
    check not readRegistryValue(testSubkey, "Plain").present
