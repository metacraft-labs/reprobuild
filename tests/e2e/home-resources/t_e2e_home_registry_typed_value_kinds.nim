## M68 gate 2: `e2e_home_registry_typed_value_kinds` (Windows-only).
##
## Per the milestone spec:
##   - Apply writes one of each typed kind (`string`,
##     `expandString`, `dword`, `qword`, `binary`, `multiString`)
##     under a per-test subkey of `HKCU\Software\Reprobuild-Tests\`.
##   - Reads them back to verify exact byte-level match.
##   - Deliberate value drift produces `EDrift`.
##   - Rollback restores or deletes per the recorded `preWriteValue`.
##
## Uses real HKCU writes through the `windows.registryValue`
## driver's `Reg*` API path; mocking the registry is explicitly
## forbidden by the M68 anti-patterns list.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]

import repro_home_generations
import repro_home_resources

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-resources" / "m68-base"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `nim c apps/repro/repro.nim` first"
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

proc cleanupTestSubkey(subkey: string) =
  when defined(windows):
    # Delete the test subkey so re-runs start clean.
    for vname in ["v_string", "v_expand", "v_binary",
        "v_dword", "v_qword", "v_multi"]:
      try: deleteRegistryValue(subkey, vname) except CatchableError: discard

when not defined(windows):
  suite "M68 gate 2: e2e_home_registry_typed_value_kinds":
    test "platform N/A":
      echo "[platform N/A] t_e2e_home_registry_typed_value_kinds: requires Windows registry resources"
      check true
else:
  suite "M68 gate 2: e2e_home_registry_typed_value_kinds":
    test "all six typed kinds round-trip; drift detected; rollback":
      when not defined(windows):
        checkpoint "platform-skip: Windows-only gate"
        check true
        return
      # Per-test subkey: timestamp keeps parallel CI runs collision-free.
      let testSubkey = "Software\\Reprobuild-Tests\\m68-gate2-" &
        $epochTime()
      cleanupTestSubkey(testSubkey)
      defer: cleanupTestSubkey(testSubkey)

      let tempRoot = createTempDir("repro-m68-gate2-", "")
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
      let exe = fixtureDir / ("m68-base-fixture" &
        (when defined(windows): ".cmd" else: ""))
      writeFixtureExe(exe)

      # Compose the resources env-var: one of each typed kind.
      let resourcesEnv =
        "registry:reg.str:" & testSubkey & ";v_string;string;hello-world|" &
        "registry:reg.exp:" & testSubkey & ";v_expand;expandString;%USERPROFILE%\\bin|" &
        "registry:reg.bin:" & testSubkey & ";v_binary;binary;deadbeef|" &
        "registry:reg.dw:" & testSubkey & ";v_dword;dword;305419896|" &
        "registry:reg.qw:" & testSubkey & ";v_qword;qword;81985529216486895|" &
        "registry:reg.mul:" & testSubkey & ";v_multi;multiString;alpha,beta,gamma"

      let envBase = @[
        (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "gate2-host"),
        (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
        (k: "REPRO_TEST_RESOURCES", v: resourcesEnv)]

      # --- Apply ---
      let applyRes = runRepro(envBase, ["home", "apply"])
      check applyRes.exitCode == 0
      check applyRes.output.contains("applied generation ")

      # --- Verify each kind reads back exactly ---
      block:
        let r = readRegistryValue(testSubkey, "v_string")
        check r.present
        check r.regType == 1'u32  # REG_SZ
        let expected = encodeString("hello-world")
        check r.bytes == expected
      block:
        let r = readRegistryValue(testSubkey, "v_expand")
        check r.present
        check r.regType == 2'u32  # REG_EXPAND_SZ
        let expected = encodeString("%USERPROFILE%\\bin")
        check r.bytes == expected
      block:
        let r = readRegistryValue(testSubkey, "v_binary")
        check r.present
        check r.regType == 3'u32  # REG_BINARY
        check r.bytes == @[byte(0xDE), byte(0xAD), byte(0xBE), byte(0xEF)]
      block:
        let r = readRegistryValue(testSubkey, "v_dword")
        check r.present
        check r.regType == 4'u32  # REG_DWORD
        check r.bytes == encodeDword(305419896'u32)  # 0x12345678
      block:
        let r = readRegistryValue(testSubkey, "v_qword")
        check r.present
        check r.regType == 11'u32  # REG_QWORD
        check r.bytes == encodeQword(81985529216486895'u64)
      block:
        let r = readRegistryValue(testSubkey, "v_multi")
        check r.present
        check r.regType == 7'u32  # REG_MULTI_SZ
        let parsed = decodeMultiString(r.bytes)
        check parsed == @["alpha", "beta", "gamma"]

      # --- Deliberate drift on the dword; re-apply must raise EDrift ---
      writeRegistryValue(testSubkey, "v_dword", 4'u32,
        encodeDword(0xCAFEBABE'u32))
      let driftRes = runRepro(envBase, ["home", "apply"])
      check driftRes.exitCode != 0
      check driftRes.output.contains("drift detected") or
        driftRes.output.contains("DRIFT")

      # --- Reconcile drift: --reconcile-drift restores the value ---
      let reconcileEnv = envBase & @[
        (k: "REPRO_HOME_APPLY_RECONCILE_DRIFT", v: "1")]
      let reconcileRes = runRepro(reconcileEnv, ["home", "apply"])
      check reconcileRes.exitCode == 0
      let postReconcile = readRegistryValue(testSubkey, "v_dword")
      check postReconcile.present
      check postReconcile.bytes == encodeDword(305419896'u32)

      # --- Rollback: destroys the values per recorded preWriteValue ---
      # Apply a SECOND generation with NO resources (empty env) so
      # the destroy path fires.
      var envEmpty = envBase
      var found = -1
      for i, pair in envEmpty:
        if pair.k == "REPRO_TEST_RESOURCES":
          found = i
          break
      if found >= 0:
        envEmpty.delete(found)
      envEmpty.add((k: "REPRO_TEST_RESOURCES", v: ""))
      let secondApplyRes = runRepro(envEmpty, ["home", "apply"])
      check secondApplyRes.exitCode == 0
      # After the second apply, the values are gone.
      let goneR = readRegistryValue(testSubkey, "v_dword")
      check not goneR.present

      # Rollback to the first generation: values come back.
      let rollbackRes = runRepro(envBase, ["home", "rollback"])
      check rollbackRes.exitCode == 0
      let restoredR = readRegistryValue(testSubkey, "v_dword")
      check restoredR.present
      check restoredR.bytes == encodeDword(305419896'u32)
