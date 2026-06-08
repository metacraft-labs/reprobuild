## M80 Verification Gate: integration_plan_classifier_bucket_drift_is_cache_hit
##
## M77 fixed the APPLY-time Scoop adapter (`resolveScoopTool`) to treat
## an already-installed package version as a cache-hit even when the
## Scoop bucket head has drifted ahead of it — no reinstall. But M77
## did NOT update the PLAN-time classifier: the M72 package catalog's
## `resolvePackage` / `previewPackageResolutions`
## (`repro_home_apply/package_catalog.nim`) decided cache-hit by
## requiring the installed version to EQUAL the bucket-head version. So
## `repro home apply --plan` reported an installed-but-bucket-drifted
## package as `realize` ("would be installed"), while the actual
## `repro home apply` correctly cache-hit it and installed nothing —
## the plan contradicted the apply. Discovered when the M70
## extended-profile real-host re-apply dry-run flagged 5 installed apps
## (`claude-code`, `codex`, `firefox`, `googlechrome`, `vscode`) as
## `realize` because their bucket manifests had advanced since install.
##
## M80 makes the plan classifier agree with the M77 apply path by
## sharing ONE installed-version cache-hit predicate
## (`repro_tool_profiles.installedVersionSatisfies`) between the plan
## classifier and `resolveScoopTool`.
##
## Per the M80 verification block, this gate stands up a sandboxed
## Scoop root (the M55 / M77 fixture pattern) and drives the REAL
## `repro home apply --plan` CLI:
##
##   1. A fixture Scoop app INSTALLED at version X while its bucket
##      manifest head is a newer version Y (Y > X), declared in the
##      profile as a bare (unpinned) package reference: `--plan`
##      classifies it as `cache-hit`, NOT `realize`. (This is the case
##      that genuinely FAILS on the unfixed classifier — it reported
##      `realize`.)
##   2. A genuinely NOT-installed package available only in the bucket
##      is still previewed as `realize`.
##   3. An UNKNOWN package (absent from the Scoop tree and every
##      configured bucket) is still previewed as `missing`.
##   4. Plan/apply agreement: applying the same bucket-drifted fixture
##      installs NOTHING for that package — its `apps/<app>/<version>/`
##      install tree is byte-identical after apply, the bucket-head
##      version dir was never created, and the realization record is
##      marked `cacheHit`. The not-installed bucket package IS realized
##      by a real `scoop install` on apply.
##
## The classifier is exercised through the real `repro` binary; the
## Scoop adapter is the real M55 `resolveScoopTool`. No `skip`.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] t_integration_plan_classifier_bucket_drift_is_cache_hit: " &
    "requires Windows and a real Scoop install"
  quit(0)

import std/[algorithm, json, os, osproc, streams, strtabs, strutils,
  tempfiles, unittest]

import repro_home_generations
import repro_local_store
import repro_test_support

import ../scoop/scoop_sandbox

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m80"

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
  ## Run the real `repro` CLI with the `REPRO_TEST_PACKAGE_*` test seams
  ## defensively stripped: the production package catalog
  ## (`package_catalog.resolvePackage` / `previewPackageResolutions`)
  ## MUST be the only resolution path, so the gate exercises the M80
  ## classifier and not a test seam.
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k in ["REPRO_TEST_PACKAGE_SOURCE", "REPRO_TEST_PACKAGE_SCOOP",
             "REPRO_TEST_PACKAGE_GENERATES",
             "REPRO_TEST_PACKAGE_MANAGED_BLOCKS"]:
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

proc packageSectionLines(planOutput: string): seq[string] =
  ## Extract only the per-package preview lines from the `[package]`
  ## section of a `repro home apply --plan` render. The render groups
  ## items under `  [<category>]` headers; a package line is rendered as
  ## `    <action>  <name>  (<detail>)`. Scoping to this section is
  ## required because the `[launcher]` section ALSO contains one line
  ## per package name (`write  <pkg>  (launcher ...)`) — a bare
  ## name-substring match would misclassify those.
  var inPackages = false
  for raw in planOutput.splitLines():
    let stripped = raw.strip()
    if stripped == "[package]":
      inPackages = true
      continue
    if stripped.startsWith("[") and stripped.endsWith("]"):
      inPackages = false
      continue
    if inPackages and stripped.len > 0:
      result.add(stripped)

proc dirFingerprint(root: string): string =
  ## Stable fingerprint of a directory tree (relative path + size).
  ## A byte-identical fingerprint before vs after apply proves a
  ## cache-hit app's install tree was NOT touched (no `scoop install`).
  var lines: seq[string]
  for path in walkDirRec(root, yieldFilter = {pcFile}):
    let rel = path[root.len .. ^1].replace('\\', '/')
    lines.add(rel & ":" & $getFileSize(path))
  lines.sort()
  lines.join("\n")

# ---------------------------------------------------------------------------
# M80 fixture helpers. A Scoop app whose INSTALLED on-disk version and
# whose BUCKET-HEAD manifest version are chosen independently, so the
# gate can stage an installed-X / bucket-head-Y drift situation that the
# plan classifier must treat as a cache-hit.
# ---------------------------------------------------------------------------

proc fixtureBatch(marker: string): string =
  ## A byte-stable Windows batch fixture (`.cmd`), identical pattern to
  ## the M74 / M77 fixtures.
  "@echo off\r\n" &
  "if /I \"%1\"==\"--version\" ( echo " & marker & " & exit /b 0 )\r\n" &
  "echo " & marker & " args=%*\r\n" &
  "exit /b 0\r\n"

proc installScoopAppAtVersion(sandbox: ScoopSandbox; app, version,
                              executableName: string) =
  ## Pre-position an already-INSTALLED Scoop app at an exact version
  ## under the sandboxed root, mirroring what `scoop install` lays down:
  ## the version dir, `install.json`, and the version-dir copy of the
  ## manifest with a `bin` field. The bucket manifest is written
  ## SEPARATELY so the gate can give it a drifted head version.
  let versionDir = sandbox.appsDir / app / version
  createDir(versionDir)
  writeFile(versionDir / executableName,
    fixtureBatch(app & " " & version))
  writeFile(versionDir / "install.json",
    ($ %*{"architecture": "64bit", "bucket": sandbox.bucketName}))
  writeFile(versionDir / "manifest.json",
    ( %*{"version": version,
         "description": "Reprobuild M80 bucket-drift fixture",
         "bin": executableName}).pretty())

proc writeBucketManifest(sandbox: ScoopSandbox; app, headVersion,
                         executableName: string) =
  ## Write the bucket-head manifest for `app` declaring `headVersion` —
  ## the version the bucket head currently publishes.
  let bucketManifestPath = sandbox.bucketManifestDir / (app & ".json")
  createDir(bucketManifestPath.parentDir)
  writeFile(bucketManifestPath,
    ( %*{"version": headVersion,
         "description": "Reprobuild M80 bucket-drift fixture",
         "bin": executableName}).pretty())

suite "integration_plan_classifier_bucket_drift_is_cache_hit":
  test "integration_plan_classifier_bucket_drift_is_cache_hit":
    let scoopBinary = resolveScoopBinary()
    doAssert scoopBinary.len > 0,
      "M80 gate requires a real scoop binary on PATH (none found). " &
      "Install Scoop from https://scoop.sh/ before running this test."

    let tempRoot = createTempDir("repro-m80-plan-drift-", "")
    defer: safeRemoveTempRoot(tempRoot)
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let homeDir = tempRoot / "home"
    let profileDir = tempRoot / "profile"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(homeDir)
    createDir(profileDir)
    copyFile(FixtureSrc / "drift_and_realize_home.nim",
      profileDir / "home.nim")

    let sandbox = setupScoopSandbox(tempRoot, "main")

    # -----------------------------------------------------------------
    # Fixture 1: `m80-drift-app` — INSTALLED at version X while the
    # bucket manifest head is a newer version Y. Declared in the
    # profile as a bare (unpinned) package reference. The plan
    # classifier must treat the installed X as a cache-hit and NOT
    # `realize` it, because the apply (M77 `resolveScoopTool`) would
    # cache-hit it and install nothing.
    # -----------------------------------------------------------------
    let driftApp = "m80-drift-app"
    let driftExe = "m80-drift-app.cmd"
    let installedX = "2.1.143"
    let bucketHeadY = "2.1.145"
    installScoopAppAtVersion(sandbox, driftApp, installedX, driftExe)
    writeBucketManifest(sandbox, driftApp, bucketHeadY, driftExe)
    let driftInstalledDir = sandbox.appsDir / driftApp / installedX
    # Fixture invariants: only X is installed; bucket head genuinely
    # differs.
    check installedX != bucketHeadY
    check dirExists(driftInstalledDir)
    check not dirExists(sandbox.appsDir / driftApp / bucketHeadY)
    let driftFingerprintBefore = dirFingerprint(driftInstalledDir)

    # -----------------------------------------------------------------
    # Fixture 2: `m80-realize-app` — NOT installed, available only in
    # the bucket. The plan classifier must preview it as `realize`, and
    # a real apply must drive `scoop install`. `setupInstallableScoopApp`
    # writes an installable bucket manifest (a `file://` zip) but does
    # NOT create `apps/<app>/<version>/`.
    # -----------------------------------------------------------------
    let realizeApp = "m80-realize-app"
    let realizeExe = "m80-realize-app.cmd"
    let bucketApp = setupInstallableScoopApp(sandbox, tempRoot,
      app = realizeApp,
      version = "1.5.0",
      executableName = realizeExe,
      executablePayload = fixtureExecutablePayload(
        realizeApp & " 1.5.0 M80"))
    check not dirExists(bucketApp.versionDir)

    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "m80-gate-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: driftApp & "," & realizeApp),
      (k: "SCOOP", v: sandbox.root),
      registryRootEnv(tempRoot)]

    # =================================================================
    # Part 1: `repro home apply --plan` classification.
    # =================================================================
    let plan = runRepro(baseEnv, ["home", "apply", "--plan"])
    checkpoint "plan output:\n" & plan.output
    check plan.output.contains("[package]")

    # ---- Exact per-package classification --------------------------
    # The plan renders one line per package as
    #   `    <action>  <name>  (<detail>)`.
    # The bucket-drifted, already-installed `m80-drift-app` is a
    # CACHE-HIT — NOT `realize`. This is the assertion that genuinely
    # FAILS on the unfixed classifier (it emitted `realize`).
    var sawDriftCacheHit = false
    var sawRealize = false
    var sawMissing = false
    for s in packageSectionLines(plan.output):
      if s.contains(driftApp):
        check s.startsWith("cache-hit")
        check not s.startsWith("realize")
        # The detail names the installed version, not the bucket head.
        check s.contains(installedX)
        check not s.contains(bucketHeadY)
        sawDriftCacheHit = true
      elif s.contains(realizeApp):
        check s.startsWith("realize")
        check not s.startsWith("cache-hit")
        sawRealize = true
    check sawDriftCacheHit
    check sawRealize

    # ---- Unknown package is still `missing` ------------------------
    let unknownProfileDir = tempRoot / "unknown-profile"
    let unknownState = tempRoot / "unknown-state"
    createDir(unknownProfileDir)
    createDir(unknownState)
    copyFile(FixtureSrc / "unknown_home.nim",
      unknownProfileDir / "home.nim")
    let unknownEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: unknownProfileDir),
      (k: "REPRO_HOME_STATE_DIR", v: unknownState),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "m80-gate-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m80-this-package-does-not-exist"),
      (k: "SCOOP", v: sandbox.root)]
    let unknownPlan = runRepro(unknownEnv, ["home", "apply", "--plan"])
    checkpoint "unknown plan output:\n" & unknownPlan.output
    for s in packageSectionLines(unknownPlan.output):
      if s.contains("m80-this-package-does-not-exist"):
        check s.startsWith("missing")
        sawMissing = true
    check sawMissing

    # =================================================================
    # Part 2: plan/apply agreement. Apply the SAME bucket-drifted
    # fixture profile; the apply must install NOTHING for the
    # bucket-drifted package (its install tree is byte-identical and the
    # bucket-head version dir is never created) and must realize the
    # genuinely-not-installed bucket package.
    # =================================================================
    let apply = runRepro(baseEnv, ["home", "apply"])
    checkpoint "apply output:\n" & apply.output
    check apply.exitCode == 0
    check apply.output.contains("applied generation ")

    # CACHE-HIT proof — the plan said `cache-hit`, the apply agrees:
    # `m80-drift-app`'s install tree is byte-identical after apply, and
    # the drifted bucket-head version dir was never created. No
    # `scoop install` ran for it.
    check dirExists(driftInstalledDir)
    check dirFingerprint(driftInstalledDir) == driftFingerprintBefore
    check not dirExists(sandbox.appsDir / driftApp / bucketHeadY)

    # REALIZE proof — the plan said `realize`, the apply agrees: the
    # bucket fixture's `apps/<app>/<version>/` tree now exists; a real
    # `scoop install` was driven by the adapter.
    check dirExists(bucketApp.versionDir)
    check fileExists(bucketApp.expectedInstalledExecutable)

    # The activation manifest records both packages realized through
    # the real Scoop adapter dispatch.
    let manifest = loadManifest(stateDir, storeRoot)
    check manifest.realizedPackages.len == 2
    var sawDriftRecord, sawRealizeRecord = false
    for rp in manifest.realizedPackages:
      check rp.adapter == "scoop"
      if rp.packageId == driftApp:
        sawDriftRecord = true
      if rp.packageId == realizeApp:
        sawRealizeRecord = true
    check sawDriftRecord
    check sawRealizeRecord

    # A re-plan after the apply is a no-op: both packages now resolve as
    # cache-hits (the realize app is installed, the drift app still
    # cache-hits its drifted-bucket install). The plan and apply
    # continue to agree.
    let replan = runRepro(baseEnv, ["home", "apply", "--plan"])
    checkpoint "re-plan output:\n" & replan.output
    var replanCacheHits = 0
    for s in packageSectionLines(replan.output):
      if s.contains(driftApp) or s.contains(realizeApp):
        check s.startsWith("cache-hit")
        check not s.startsWith("realize")
        inc replanCacheHits
    check replanCacheHits == 2
