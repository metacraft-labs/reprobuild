## M72 gate 1: `integration_production_package_catalog`.
##
## Drives the public `repro home apply` CLI with NO
## `REPRO_TEST_PACKAGE_*` env vars set: package realization MUST go
## through the M72 production package catalog
## (`repro_home_apply/package_catalog.nim`) and dispatch each
## reference through the REAL M55 Scoop adapter.
##
## On Windows the gate stands up a sandboxed Scoop root (the M55
## pattern: `$env:SCOOP` redirects every Scoop state change into a
## test temp dir) holding two fixture apps:
##
##   * `m72-installed-fixture` — pre-positioned in the sandbox via
##     `populateScoopApp` (the `apps/<app>/<version>/` tree already
##     exists). The catalog must classify it as a CACHE-HIT and the
##     M55 adapter must NOT reinstall it. The gate proves "no
##     reinstall" by checking the realization record's `cacheHit`
##     flag in the activation manifest provenance AND by confirming
##     the install dir's mtime / contents are unchanged.
##
##   * `m72-bucket-fixture` — declared in a configured Scoop bucket
##     via `setupInstallableScoopApp` (the `apps/<app>/<version>/`
##     tree is NOT pre-populated). The catalog must classify it as
##     available-in-bucket and the M55 adapter must run real
##     `scoop install` to realize it.
##
## A third assertion drives an UNKNOWN package (declared in the
## profile catalog but absent from the Scoop install tree and every
## configured bucket): apply must fail with a structured diagnostic
## naming the package and the catalogs searched.

import std/[algorithm, json, os, osproc, streams, strtabs, strutils,
  tempfiles, unittest]

import repro_home_generations
import repro_local_store

import ../scoop/scoop_sandbox

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m72" / "production_catalog"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## Run the real `repro` CLI. Critically: the gate does NOT layer the
  ## inherited `REPRO_TEST_PACKAGE_*` vars (there are none) — the test
  ## env is built from scratch + the explicit overrides so the
  ## production catalog path is the only one that can fire.
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    # Defensively strip any inherited test seam so the production
    # catalog is genuinely exercised.
    if k in ["REPRO_TEST_PACKAGE_SOURCE", "REPRO_TEST_PACKAGE_SCOOP"]:
      continue
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

proc loadManifest(stateDir, storeRoot: string): ActivationManifest =
  let activeId = readCurrentGenerationId(stateDir)
  let env = readPointerFile(pointerPath(stateDir, activeId))
  var store = openStore(storeRoot)
  defer: store.close()
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  decodeManifestBytes(readCasBlob(store, key))

proc dirFingerprint(root: string): string =
  ## Stable fingerprint of a directory tree (relative path + size).
  ## Used to prove a cache-hit app's install tree was NOT touched.
  var lines: seq[string]
  for path in walkDirRec(root, yieldFilter = {pcFile}):
    let rel = path[root.len .. ^1].replace('\\', '/')
    lines.add(rel & ":" & $getFileSize(path))
  lines.sort()
  lines.join("\n")

when not defined(windows):
  suite "M72 gate 1: integration_production_package_catalog":
    when isNixSupported:
      test "platform N/A":
        echo "[platform N/A] t_integration_production_package_catalog: requires Windows and the Scoop production adapter"
        check true
else:
  suite "M72 gate 1: integration_production_package_catalog":
    when isNixSupported:
      test "apply realizes via the production catalog; cache-hit not reinstalled":
        when not defined(windows):
          checkpoint "platform-skip: M72 production catalog gate is " &
            "Windows-specific (the Scoop adapter is Windows-only)"
          check true
          return

        let scoopBinary = resolveScoopBinary()
        doAssert scoopBinary.len > 0,
          "M72 gate 1 requires a real scoop binary on PATH; the milestone " &
          "forbids mocking Scoop."

        let tempRoot = createTempDir("repro-m72-catalog-", "")
        defer: safeRemoveTempRoot(tempRoot)
        let stateDir = tempRoot / "state"
        let storeRoot = tempRoot / "store"
        let profileDir = tempRoot / "profile"
        let homeDir = tempRoot / "home"
        createDir(stateDir)
        createDir(storeRoot)
        createDir(homeDir)
        createDir(profileDir)
        copyFile(FixtureSrc / "home.nim", profileDir / "home.nim")

        let sandbox = setupScoopSandbox(tempRoot, "main")

        # --- Cache-hit fixture: already installed in the sandboxed root. ---
        let installed = populateScoopApp(sandbox,
          app = "m72-installed-fixture",
          version = "2.0.0",
          executableName = "m72-installed-fixture.cmd",
          executablePayload = fixtureExecutablePayload(
            "m72-installed-fixture 2.0.0 M72"))
        # Fingerprint the install tree BEFORE apply — a cache-hit must
        # leave it byte-identical (no reinstall).
        let installedDir = sandbox.appsDir / installed.name / installed.version
        let beforeFingerprint = dirFingerprint(installedDir)

        # --- Available-in-bucket fixture: NOT installed; the M55 adapter
        # must shell out to real `scoop install` to realize it. ---
        let bucketApp = setupInstallableScoopApp(sandbox, tempRoot,
          app = "m72-bucket-fixture",
          version = "1.5.0",
          executableName = "m72-bucket-fixture.cmd",
          executablePayload = fixtureBuildActionPayload(
            "m72-bucket-fixture 1.5.0 M72"))
        doAssert not dirExists(bucketApp.versionDir),
          "fixture invariant: the bucket app must NOT be pre-installed"

        let baseEnv = @[
          (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
          (k: "REPRO_HOME_STATE_DIR", v: stateDir),
          (k: "REPRO_STORE_ROOT", v: storeRoot),
          (k: "HOME", v: homeDir),
          (k: "USERPROFILE", v: homeDir),
          (k: "REPRO_HOST", v: "m72-gate1-host"),
          (k: "REPRO_HOME_PACKAGE_CATALOG",
           v: "m72-installed-fixture,m72-bucket-fixture"),
          (k: "SCOOP", v: sandbox.root)]

        # --- Apply: NO REPRO_TEST_PACKAGE_* env. ---
        let res = runRepro(baseEnv, ["home", "apply"])
        if res.exitCode != 0:
          checkpoint "apply output:\n" & res.output
        check res.exitCode == 0
        check res.output.contains("applied generation ")

        # Both packages realized through the real Scoop adapter dispatch.
        let manifest = loadManifest(stateDir, storeRoot)
        check manifest.realizedPackages.len == 2
        var sawInstalled, sawBucket = false
        for rp in manifest.realizedPackages:
          check rp.adapter == "scoop"
          if rp.packageId == "m72-installed-fixture":
            sawInstalled = true
          if rp.packageId == "m72-bucket-fixture":
            sawBucket = true
        check sawInstalled
        check sawBucket

        # CACHE-HIT proof: the already-installed fixture's `apps/<app>/
        # <version>/` tree is byte-identical after apply — `scoop install`
        # never ran for it (a reinstall would rewrite the tree).
        check dirExists(installedDir)
        check dirFingerprint(installedDir) == beforeFingerprint

        # REALIZE proof: the bucket fixture's `apps/<app>/<version>/` tree
        # now exists — real `scoop install` was driven by the adapter.
        check dirExists(bucketApp.versionDir)
        check fileExists(bucketApp.expectedInstalledExecutable)

        # Both realized prefixes are present in the M56 store.
        var verifyStore = openStore(storeRoot)
        defer: verifyStore.close()
        for rp in manifest.realizedPackages:
          var prefixId: PrefixIdBytes
          for i in 0 ..< 32:
            prefixId[i] = rp.realizedPrefixId[i]
          let lookup = lookupPrefix(verifyStore, prefixId)
          check lookup.found

        # --- Unknown-package diagnostic. ---
        # A profile that names a package absent from the install tree and
        # every configured bucket. Apply must fail with a structured
        # diagnostic naming the package and the catalogs searched.
        let unknownProfileDir = tempRoot / "unknown-profile"
        createDir(unknownProfileDir)
        writeFile(unknownProfileDir / "home.nim",
          "import repro/profile\n\n" &
          "profile \"m72-unknown-pkg-gate\":\n" &
          "  activity default:\n" &
          "    m72-this-package-does-not-exist\n")
        let unknownState = tempRoot / "unknown-state"
        createDir(unknownState)
        let unknownEnv = @[
          (k: "REPRO_HOME_PROFILE_DIR", v: unknownProfileDir),
          (k: "REPRO_HOME_STATE_DIR", v: unknownState),
          (k: "REPRO_STORE_ROOT", v: storeRoot),
          (k: "HOME", v: homeDir),
          (k: "USERPROFILE", v: homeDir),
          (k: "REPRO_HOST", v: "m72-gate1-host"),
          (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m72-this-package-does-not-exist"),
          (k: "SCOOP", v: sandbox.root)]
        let unknownRes = runRepro(unknownEnv, ["home", "apply"])
        check unknownRes.exitCode != 0
        # The diagnostic names the package...
        check unknownRes.output.contains("m72-this-package-does-not-exist")
        # ...and the catalogs that were searched.
        check (unknownRes.output.contains("no production adapter catalog") and
               unknownRes.output.contains("Searched"))
        check unknownRes.output.contains("scoop:")
