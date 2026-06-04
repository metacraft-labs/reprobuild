## M78 gate: `e2e_profile_declared_resources_apply`.
##
## Per the M78 milestone verification block:
##
##   A `home.nim` with a `resources:` block declaring an
##   `env.userPath` contribution and an `fs.managedBlock` /
##   `shell.integration` resource is applied by `repro home apply`:
##   the PATH entry is added (existing entries preserved), the
##   managed block is written with its sentinels, and the activation
##   manifest records a `ResourceBinding` per declared resource. A
##   no-op re-apply is a clean cache-hit. Deliberate drift on a
##   declared resource is detected as `EDrift`. `repro home plan`
##   lists the profile-declared resources. A resource declared inside
##   a `when windows:` block is materialized on a Windows host and
##   absent on others.
##
## The gate drives the REAL `repro` binary against a fixture profile
## whose `resources:` block declares the resources — no
## `REPRO_TEST_RESOURCES` seam is used (M78 makes the profile the
## production source). It runs in an isolated `$HOME` and snapshots /
## restores the real `HKCU\Environment\Path` so the live environment
## is never mutated (the M68 gate-4 pattern).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_home_resources
import repro_local_store

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m78" / "profile_declared_resources"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo m78-fixture 1.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 0\r\n")
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
  ## Read the activation manifest of the current generation and
  ## return its recorded `ResourceBinding` records.
  let activeId = readCurrentGenerationId(stateDir)
  doAssert activeId.len > 0, "no active generation after apply"
  let pointerFile = pointerPath(stateDir, activeId)
  doAssert fileExists(pointerFile), "no pointer file for " & activeId
  let env = readPointerFile(pointerFile)
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  var store = openStore(storeRoot)
  defer:
    try: store.close() except CatchableError: discard
  let manifest = decodeManifestBytes(readCasBlob(store, key))
  result = manifest.resourceBindings

proc bindingFor(bindings: seq[ResourceBinding];
                address: string): ResourceBinding =
  for b in bindings:
    if b.resourceAddress == address:
      return b
  doAssert false, "no ResourceBinding recorded for address '" &
    address & "'"

# The resources declared in the fixture's `resources:` block.
const
  PathEntry = "C:\\repro-m78-profile-bin"
  ProfileRcRel = ".m78-profile-rc"
  ProfileBlockId = "m78-profile-block"
  ProfileBlockBody = "export REPRO_M78_PROFILE=1"
  WindowsRcRel = ".m78-windows-only-rc"
  WindowsBlockId = "m78-windows-block"
  WindowsBlockBody = "windows-only profile resource"
  LinuxRcRel = ".m78-linux-only-rc"

suite "M78 gate: e2e_profile_declared_resources_apply":
  when isNixSupported:
    test "a profile `resources:` block materializes through `repro home apply`":
      when not defined(windows):
        checkpoint "platform-skip: M78 gate exercises the Windows leg"
        skip()
      else:

        # Snapshot the real HKCU\Environment\Path so the gate never
        # mutates the dev host's environment (M68 gate-4 pattern).
        let preGate = readUserPathRaw()
        defer:
          when defined(windows):
            if preGate.present:
              writeRegistryValue("Environment", "Path", preGate.regType,
                encodeString(preGate.raw))
            else:
              try: deleteRegistryValue("Environment", "Path")
              except CatchableError: discard

        # Seed a user-only PATH entry that must survive the apply
        # (the env.userPath non-destructive invariant).
        let userOnlyEntry = "C:\\repro-m78-user-only-entry"
        var initialEntries: seq[string] = @[]
        if preGate.present:
          initialEntries = splitPathEntries(preGate.raw)
        initialEntries.add(userOnlyEntry)
        writeRegistryValue("Environment", "Path", 1'u32,
          encodeString(joinPathEntries(initialEntries)))

        let tempRoot = createTempDir("repro-m78-gate-", "")
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
        let exe = fixtureDir / "m78-fixture.cmd"
        writeFixtureExe(exe)

        # NOTE: REPRO_TEST_RESOURCES is deliberately NOT set — the
        # `resources:` block in the fixture profile is the sole source.
        let baseEnv = @[
          (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
          (k: "REPRO_HOME_STATE_DIR", v: stateDir),
          (k: "REPRO_STORE_ROOT", v: storeRoot),
          (k: "HOME", v: homeDir),
          (k: "USERPROFILE", v: homeDir),
          (k: "REPRO_HOST", v: "m78-gate-host"),
          (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m78-fixture"),
          (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m78-fixture=" & exe)]

        let profileRc = homeDir / ProfileRcRel
        let windowsRc = homeDir / WindowsRcRel
        let linuxRc = homeDir / LinuxRcRel

        # ---- `repro home plan` lists the profile-declared resources ----
        let plan = runRepro(baseEnv, ["home", "plan"])
        check plan.exitCode == 0
        check plan.output.contains("launcherDir")
        check plan.output.contains("env.userPath")
        check plan.output.contains("shellRc")
        check plan.output.contains("windowsOnly")
        check plan.output.contains("fs.managedBlock")
        # The `when linux:`-guarded resource is NOT planned on Windows.
        check not plan.output.contains("linuxOnly")

        # ---- Apply 1: materializes every reachable resource ----
        let r1 = runRepro(baseEnv, ["home", "apply"])
        check r1.exitCode == 0
        check r1.output.contains("applied generation ")

        # The managed block is written with its repro-managed sentinels.
        check fileExists(profileRc)
        let profileRcContent = readFile(profileRc)
        check profileRcContent.contains("repro-managed:" & ProfileBlockId)
        check profileRcContent.contains(ProfileBlockBody)

        # The `when windows:` resource materialized on this Windows host.
        check fileExists(windowsRc)
        let windowsRcContent = readFile(windowsRc)
        check windowsRcContent.contains("repro-managed:" & WindowsBlockId)
        check windowsRcContent.contains(WindowsBlockBody)

        # The `when linux:` resource is absent under the non-matching
        # predicate.
        check not fileExists(linuxRc)

        # The PATH entry was added; the pre-existing user entry survives
        # (the env.userPath non-destructive invariant).
        let pathAfterApply = readUserPathRaw()
        check pathAfterApply.present
        let entriesAfterApply = splitPathEntries(pathAfterApply.raw)
        check PathEntry in entriesAfterApply
        check userOnlyEntry in entriesAfterApply

        # The activation manifest records a ResourceBinding per declared,
        # reachable resource — and NOT for the unreachable `when linux:`
        # resource.
        let bindings1 = loadResourceBindings(stateDir, storeRoot)
        check bindings1.len == 3
        let pathBinding = bindingFor(bindings1, "launcherDir")
        check pathBinding.resourceKind == "env.userPath"
        # The PATH binding records the contribution bytes (the entry the
        # resource added), not the full variable — joined-entries form.
        check pathBinding.payloadKind == "joined-entries"
        check ($cast[string](pathBinding.payloadBytes)).contains(PathEntry)
        let rcBinding = bindingFor(bindings1, "shellRc")
        check rcBinding.resourceKind == "fs.managedBlock"
        let winBinding = bindingFor(bindings1, "windowsOnly")
        check winBinding.resourceKind == "fs.managedBlock"
        for b in bindings1:
          check b.resourceAddress != "linuxOnly"

        # ---- Apply 2: a no-op re-apply is a clean cache-hit ----
        let r2 = runRepro(baseEnv, ["home", "apply"])
        check r2.exitCode == 0
        check r2.output.contains("no-op")
        # Live state is unchanged.
        check readFile(profileRc).contains(ProfileBlockBody)
        check readFile(windowsRc).contains(WindowsBlockBody)
        check PathEntry in splitPathEntries(readUserPathRaw().raw)

        # ---- Deliberate drift on a declared resource -> EDrift ----
        # Edit the managed block BODY (between sentinels) out-of-band.
        let driftOrig = readFile(profileRc)
        let openS = "# >>> repro-managed:" & ProfileBlockId & " >>>"
        let closeS = "# <<< repro-managed:" & ProfileBlockId & " <<<"
        let openIdx = driftOrig.find(openS)
        let closeIdx = driftOrig.find(closeS)
        check openIdx >= 0
        check closeIdx > openIdx
        let lineEnd = driftOrig.find('\n', openIdx)
        let edited = driftOrig[0 .. lineEnd] &
          "USER MUTATED INSIDE BLOCK\n" & driftOrig[closeIdx .. ^1]
        writeFile(profileRc, edited)

        let r3 = runRepro(baseEnv, ["home", "apply"])
        check r3.exitCode != 0
        check (r3.output.contains("drift detected") or
               r3.output.contains("DRIFT") or
               r3.output.contains("drift"))

        # ---- `repro home plan` surfaces the drift ----
        let driftPlan = runRepro(baseEnv, ["home", "plan"])
        check driftPlan.exitCode != 0
        check driftPlan.output.contains("drift")

        # ---- --reconcile-drift collapses the drift back to managed state
        let r4 = runRepro(baseEnv & @[
          (k: "REPRO_HOME_APPLY_RECONCILE_DRIFT", v: "1")], ["home", "apply"])
        check r4.exitCode == 0
        check readFile(profileRc).contains(ProfileBlockBody)
        check not readFile(profileRc).contains("USER MUTATED INSIDE BLOCK")
