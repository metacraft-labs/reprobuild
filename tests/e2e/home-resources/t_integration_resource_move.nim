## M68 Phase B: `repro home resource move` integration test.
##
## `resource move` renames a resource record WITHOUT re-applying.
## The underlying real-world state (here a Windows registry value)
## is untouched; only the resource's IDENTITY in the manifest moves
## from `<old>` to `<new>`. No driver apply / destroy runs.
##
## Real assertions:
##   - move carries the binding forward: the new generation's
##     manifest has a `ResourceBinding` whose `resourceAddress` is
##     the NEW id, with the SAME `realWorldIdentity`, payload bytes,
##     and post-write digest as the old binding.
##   - the underlying registry value is byte-identical before and
##     after the move (no driver write happened).
##   - moving an unknown `<old>` fails with `EUnknownResource`.
##   - moving onto an existing `<new>` fails with `EResourceConflict`.
##
## Windows-focused: registry resources are testable on the dev host.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
  unittest]

import repro_home_generations
import repro_home_resources
import repro_local_store

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

proc loadResourceBindings(stateDir, storeRoot: string):
    seq[ResourceBinding] =
  ## Read the active generation's activation manifest and return its
  ## resource bindings.
  let activeId = readCurrentGenerationId(stateDir)
  doAssert activeId.len > 0
  let pointerFile = pointerPath(stateDir, activeId)
  let env = readPointerFile(pointerFile)
  var manifestKey: PrefixIdBytes
  for i in 0 ..< 32:
    manifestKey[i] = env.activationManifestDigest[i]
  var store = openStore(storeRoot)
  defer:
    try: store.close() except CatchableError: discard
  let manifestBytes = readCasBlob(store, manifestKey)
  let manifest = decodeManifestBytes(manifestBytes)
  result = manifest.resourceBindings

suite "M68 Phase B: integration_resource_move":
  test "resource move carries the binding forward; no driver runs":
    when not defined(windows):
      checkpoint "platform-skip: Windows registry resource is the subject"
      check true
      return

    let testSubkey = "Software\\Reprobuild-Tests\\m68-move-" &
      $epochTime()
    defer:
      when defined(windows):
        try: deleteRegistryValue(testSubkey, "Marker")
        except CatchableError: discard

    let tempRoot = createTempDir("repro-m68-move-", "")
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

    # Apply a registry resource addressed `reg.old`.
    let envBase = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "move-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
      (k: "REPRO_TEST_RESOURCES",
        v: "registry:reg.old:" & testSubkey & ";Marker;string;move-me")]

    let rApply = runRepro(envBase, ["home", "apply"])
    check rApply.exitCode == 0
    let genA = readCurrentGenerationId(stateDir)
    check genA.len > 0

    # The registry value is live and the binding is recorded.
    let valBefore = readRegistryValue(testSubkey, "Marker")
    check valBefore.present
    let bindingsA = loadResourceBindings(stateDir, storeRoot)
    var oldBinding: ResourceBinding
    var foundOld = false
    for rb in bindingsA:
      if rb.resourceAddress == "reg.old":
        oldBinding = rb
        foundOld = true
    check foundOld

    # --- resource move reg.old -> reg.new ---
    let rMove = runRepro(envBase,
      ["home", "resource", "move", "reg.old", "reg.new"])
    check rMove.exitCode == 0
    check rMove.output.contains("renamed reg.old -> reg.new")
    let genB = readCurrentGenerationId(stateDir)
    check genB.len > 0
    check genB != genA  # a new generation reflects the rename

    # The new generation's manifest carries the binding forward
    # under the NEW address — same identity, same payload, same
    # digest. The OLD address is gone.
    let bindingsB = loadResourceBindings(stateDir, storeRoot)
    var newBinding: ResourceBinding
    var foundNew = false
    var foundOldStill = false
    for rb in bindingsB:
      if rb.resourceAddress == "reg.new":
        newBinding = rb
        foundNew = true
      if rb.resourceAddress == "reg.old":
        foundOldStill = true
    check foundNew
    check not foundOldStill
    # Identity / payload / digest are preserved verbatim — the move
    # is metadata-only.
    check newBinding.realWorldIdentity == oldBinding.realWorldIdentity
    check newBinding.payloadBytes == oldBinding.payloadBytes
    check newBinding.postWriteDigest == oldBinding.postWriteDigest
    check newBinding.resourceKind == oldBinding.resourceKind

    # The underlying registry value is byte-identical: NO driver
    # apply / destroy ran during the move.
    let valAfter = readRegistryValue(testSubkey, "Marker")
    check valAfter.present
    check valAfter.bytes == valBefore.bytes

  test "resource move rejects unknown <old> and conflicting <new>":
    when not defined(windows):
      checkpoint "platform-skip"
      check true
      return

    let testSubkey = "Software\\Reprobuild-Tests\\m68-move-err-" &
      $epochTime()
    defer:
      when defined(windows):
        try: deleteRegistryValue(testSubkey, "A")
        except CatchableError: discard
        try: deleteRegistryValue(testSubkey, "B")
        except CatchableError: discard

    let tempRoot = createTempDir("repro-m68-move-err-", "")
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

    # Apply two registry resources: `reg.a` and `reg.b`.
    let envBase = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "move-err-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m68-base-fixture=" & exe),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m68-base-fixture"),
      (k: "REPRO_TEST_RESOURCES",
        v: "registry:reg.a:" & testSubkey & ";A;string;val-a" & "|" &
           "registry:reg.b:" & testSubkey & ";B;string;val-b")]
    let rApply = runRepro(envBase, ["home", "apply"])
    check rApply.exitCode == 0

    # Unknown <old> -> EUnknownResource.
    let rUnknown = runRepro(envBase,
      ["home", "resource", "move", "reg.does-not-exist", "reg.c"])
    check rUnknown.exitCode != 0
    check rUnknown.output.contains("not a known resource")

    # <new> already exists -> EResourceConflict.
    let rConflict = runRepro(envBase,
      ["home", "resource", "move", "reg.a", "reg.b"])
    check rConflict.exitCode != 0
    check rConflict.output.contains("already exists")
