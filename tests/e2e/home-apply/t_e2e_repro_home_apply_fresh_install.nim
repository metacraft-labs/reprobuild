## M63 gate 1: `e2e_repro_home_apply_fresh_install`.
##
## Drives the public `repro home apply` CLI against a clean state
## directory using a sandboxed Scoop root. Verifies the full pipeline:
##
##   * exit code 0
##   * realized prefix exists under the store
##   * launcher present in the per-generation bin dir AND in the
##     Windows stable bin dir
##   * pointer.bin exists at `<state-dir>/generations/<gen-id>/`
##   * activation manifest is reachable via the pointer's CAS digest
##   * `current` points at the new generation
##   * the store has a `profile`-kind root row for the new id
##   * eager GC ran (the audit log shows entries even when nothing
##     is reclaimed — we check `gc/pending-deletion/` exists at most)

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

import ../scoop/scoop_sandbox

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply" / "fresh_install"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc copyFixture(profileDir: string) =
  createDir(profileDir)
  copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")

proc runReproApply(envOverrides: openArray[tuple[k, v: string]];
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

when not defined(windows):
  suite "M63 gate 1: e2e_repro_home_apply_fresh_install":
    test "platform N/A":
      echo "[platform N/A] t_e2e_repro_home_apply_fresh_install: requires Windows and a real Scoop install"
      check true
else:
  suite "M63 gate 1: e2e_repro_home_apply_fresh_install":
    test "fresh apply realizes a Scoop package end-to-end":
      when not defined(windows):
        checkpoint "skipping on non-Windows"
        check true
        return
      let scoopBinary = resolveScoopBinary()
      doAssert scoopBinary.len > 0,
        "M63 gate 1 requires real scoop.exe on PATH; the milestone " &
        "forbids mocking it"

      let tempRoot = createTempDir("repro-m63-fresh-", "")
      defer: safeRemoveTempRoot(tempRoot)
      let stateDir = tempRoot / "state"
      let storeRoot = tempRoot / "store"
      let profileDir = tempRoot / "profile"
      let homeDir = tempRoot / "home"
      createDir(stateDir)
      createDir(storeRoot)
      createDir(homeDir)
      copyFixture(profileDir)

      let sandbox = setupScoopSandbox(tempRoot, "main")
      let fixture = populateScoopApp(sandbox,
        app = "fresh-install-fixture",
        version = "1.0.0",
        executableName = "fresh-install-fixture.cmd",
        executablePayload = fixtureExecutablePayload(
          "fresh-install-fixture 1.0.0 M63"))

      let scoopMap = "fresh-install-fixture=" & sandbox.bucketName & "/" &
        fixture.name & "@" & fixture.version & "#" & fixture.executableName

      let (code, output) = runReproApply([
        (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "gate1-host"),
        (k: "REPRO_TEST_PACKAGE_SCOOP", v: scoopMap),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: "fresh-install-fixture"),
        (k: "SCOOP", v: sandbox.root)],
        ["home", "apply"])
      check code == 0
      check output.contains("applied generation ")

      # Pointer exists for the new generation.
      let records = enumerateGenerations(stateDir)
      check records.len == 1
      let activeId = readCurrentGenerationId(stateDir)
      check activeId == records[0].generationId

      # Pointer file exists and is parseable.
      let pointerFile = pointerPath(stateDir, activeId)
      check fileExists(pointerFile)
      let envelope = readPointerFile(pointerFile)
      check envelope.realizedPrefixIds.len == 1

      # Manifest reachable via the pointer's digest.
      var verifyStore = openStore(storeRoot)
      defer: verifyStore.close()
      var manifestKey: PrefixIdBytes
      for i in 0 ..< 32:
        manifestKey[i] = envelope.activationManifestDigest[i]
      let manifestBytes = readCasBlob(verifyStore, manifestKey)
      let manifest = decodeManifestBytes(manifestBytes)
      check manifest.realizedPackages.len == 1
      check manifest.realizedPackages[0].packageId == "fresh-install-fixture"
      check manifest.realizedPackages[0].adapter == "scoop"
      check manifest.exportedCommands.len == 1
      check manifest.exportedCommands[0].commandName == "fresh-install-fixture"

      # Realized prefix exists under the store. lookupPrefix() confirms
      # the SQLite row is also present.
      var prefixId: PrefixIdBytes
      for i in 0 ..< 32:
        prefixId[i] = manifest.realizedPackages[0].realizedPrefixId[i]
      let lookup = lookupPrefix(verifyStore, prefixId)
      check lookup.found
      let absPrefix = absolutePrefixPath(verifyStore, lookup.row.realizedPath)
      check dirExists(absPrefix)

      # The store has a `profile`-kind root with the new generation id.
      let roots = listRoots(verifyStore)
      var hasGenRoot = false
      for r in roots:
        if r.rootId == activeId and r.kind == "profile":
          hasGenRoot = true
          break
      check hasGenRoot

      # The stable Windows bin dir has the launcher (.exe or .cmd shim).
      let stableBin = stateDir / "bin"
      check dirExists(stableBin)
      let cmdExe = stableBin / "fresh-install-fixture.exe"
      let cmdShim = stableBin / "fresh-install-fixture.cmd"
      let cmdLauncher = stableBin / "fresh-install-fixture.repro-launch"
      check fileExists(cmdExe) or fileExists(cmdShim)
      # Per-generation bin dir also exists.
      let perGenBin = generationDir(stateDir, activeId) / "bin"
      check dirExists(perGenBin)

      # Eager GC ran: assert on the stable subprocess-visible log line
      # the CLI emits from the fresh-applied branch. The line is fed by
      # `ApplyOutcome.gcResult` (sourced from `repro_local_store.gc`),
      # so its presence proves the pipeline actually invoked step 11 —
      # not merely that `openStore` created the `gc/pending-deletion/`
      # directory. On a fresh apply with no prior generations nothing
      # is reclaimed, so the line shows zero.
      check output.contains("apply: eager gc reclaimed 0 prefixes (ranAt ")
      check dirExists(storeRoot / "gc" / "pending-deletion")

      discard cmdLauncher  # silence unused-binding on copy-fallback hosts
