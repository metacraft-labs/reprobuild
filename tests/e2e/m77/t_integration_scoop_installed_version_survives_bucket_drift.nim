## M77 Verification Gate: integration_scoop_installed_version_survives_bucket_drift
##
## `resolveScoopTool` used to raise `EScoopVersionMismatch` whenever a
## package's resolved version differed from the current bucket-head
## manifest version — EVEN when that version was already installed and
## would be used as a cache-hit, no install required. The M72 production
## package catalog resolves a bare `home.nim` package reference against
## the real environment and records the INSTALLED Scoop version as the
## acquisition plan's `version`; `resolveScoopTool` then demanded the
## bucket head equal it. When the Scoop bucket has since published a
## newer version, an already-installed, cache-hittable package failed the
## apply. Discovered when the M70 sandbox migration aborted at step 7
## realizing `claude-code`: installed `2.1.143`, `main` bucket head
## `2.1.145`.
##
## M77 relaxes ONLY the case where the wanted version is already on disk:
## the bucket-head equality check (pinned path) and the `preferredVersion`
## range check (unpinned path) apply only when an install FROM THE BUCKET
## is actually required.
##
## Per the M77 verification block, four cases against a sandboxed Scoop
## root (the M55 / M74 sandboxed-Scoop fixture pattern):
##
##   1. A fixture Scoop app INSTALLED at version X while its bucket
##      manifest head is a different, newer version Y (Y > X) resolves
##      through `resolveScoopTool` to the installed X as a cache-hit with
##      NO `EScoopVersionMismatch`. (The M70 `claude-code` case.)
##   2. Control: a plan pinned to a version that is NOT installed and not
##      equal to the bucket head still raises `EScoopVersionMismatch`
##      (install required, unsatisfiable).
##   3. Control: an unpinned plan whose `preferredVersion` range the
##      bucket head does not satisfy, with nothing installed, still
##      raises `EScoopVersionMismatch`.
##   4. The manifest-checksum mismatch path still raises
##      `EScoopManifestChecksumMismatch`.
##
## The adapter is exercised through the real `resolveScoopTool` entry
## point against a sandboxed Scoop root.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] integration_scoop_installed_version_survives_bucket_drift: " &
    "this gate requires Windows and a real Scoop install"
  quit(0)

import std/[json, os, strutils, tempfiles, unittest]

import repro_tool_profiles

import ../scoop/scoop_sandbox

# ---------------------------------------------------------------------------
# M77 fixture helpers. A Scoop app whose INSTALLED on-disk version and
# whose BUCKET-HEAD manifest version are chosen independently, so the gate
# can stage an installed-X / bucket-head-Y drift situation, and a plan
# pinned to a version that was never installed.
# ---------------------------------------------------------------------------

proc writeFixtureExe(path, marker: string) =
  ## A byte-stable Windows batch fixture; identical pattern to the M74
  ## fixtures. `.cmd` extension so the launch wrapper resolves it without
  ## a real PE.
  createDir(path.parentDir)
  writeFile(path,
    "@echo off\r\n" &
    "if /I \"%1\"==\"--version\" ( echo " & marker & " & exit /b 0 )\r\n" &
    "echo " & marker & " args=%*\r\n" &
    "exit /b 0\r\n")

proc writeAppManifestJson(version: string): JsonNode =
  ## The manifest body Scoop writes both into the bucket and (on install)
  ## into the version dir. A single `bin` entry at the version root.
  %*{
    "version": version,
    "description": "Reprobuild M77 bucket-drift fixture",
    "bin": "m77cli.cmd"}

proc installScoopAppAtVersion(sandbox: ScoopSandbox; app, version: string) =
  ## Pre-position an already-INSTALLED Scoop app at an exact version under
  ## the sandboxed root, mirroring what `scoop install` lays down: the
  ## version dir, `install.json`, and the version-dir copy of the
  ## manifest with a `bin` field.
  let versionDir = sandbox.appsDir / app / version
  createDir(versionDir)
  writeFixtureExe(versionDir / "m77cli.cmd", app & " " & version)
  writeFile(versionDir / "install.json",
    ($ %*{"architecture": "64bit", "bucket": sandbox.bucketName}))
  writeFile(versionDir / "manifest.json",
    writeAppManifestJson(version).pretty())

proc writeBucketManifest(sandbox: ScoopSandbox; app, headVersion: string):
    string =
  ## Write the bucket-head manifest for `app` declaring `headVersion`.
  ## Returns the BLAKE3 hex of the manifest bytes.
  let bucketManifestPath = sandbox.bucketManifestDir / (app & ".json")
  createDir(bucketManifestPath.parentDir)
  writeFile(bucketManifestPath, writeAppManifestJson(headVersion).pretty())
  blake3HexFile(bucketManifestPath)

suite "integration_scoop_installed_version_survives_bucket_drift":
  test "integration_scoop_installed_version_survives_bucket_drift":
    let scoopBinary = resolveScoopBinary()
    if scoopBinary.len == 0:
      raise newException(OSError,
        "M77 gate requires a real scoop binary on PATH (none found). " &
        "Install Scoop from https://scoop.sh/ before running this test.")

    let tempRoot = createTempDir("repro-m77-bucket-drift-", "")
    defer: safeRemoveTempRoot(tempRoot)
    let sandbox = setupScoopSandbox(tempRoot, "main")
    let storeRoot = tempRoot / "tool-store"

    # -----------------------------------------------------------------
    # Case 1: installed X, bucket head Y (Y > X), pinned to X. The
    # already-installed version X is resolved as a CACHE-HIT — NO
    # `EScoopVersionMismatch`, NO install. This is the M70 `claude-code`
    # case (installed 2.1.143, bucket head 2.1.145).
    # -----------------------------------------------------------------
    block installedSurvivesBucketDrift:
      let app = "m77-drift-app"
      let installedX = "2.1.143"
      let bucketHeadY = "2.1.145"
      installScoopAppAtVersion(sandbox, app, installedX)
      discard writeBucketManifest(sandbox, app, bucketHeadY)
      # Sanity: the bucket head and the installed version genuinely
      # differ, and only X is installed.
      check installedX != bucketHeadY
      check dirExists(sandbox.appsDir / app / installedX)
      check not dirExists(sandbox.appsDir / app / bucketHeadY)

      let useDef = fixtureUseDef(
        packageSelector = "m77-drift",
        executableName = "m77cli",
        bucket = sandbox.bucketName,
        app = app,
        # The acquisition plan pins the INSTALLED version (what the M72
        # catalog records for a bare `home.nim` reference).
        version = installedX,
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "m77cli.cmd",
        requiresExecutionProfileChecksum = true)

      # The pre-M77 behavior raised `EScoopVersionMismatch` here; M77
      # resolves to the installed X with no exception.
      let profile = resolveScoopTool(useDef, storeRoot)
      # Resolved to the INSTALLED version X, not the bucket head Y.
      check profile.scoopResolvedVersion == installedX
      check profile.scoopResolvedVersion != bucketHeadY
      # The realized executable resolves through the junction to the
      # real installed `<versionDir>/m77cli.cmd`.
      check fileExists(profile.resolvedExecutablePath)
      check sameFile(profile.resolvedExecutablePath,
        sandbox.appsDir / app / installedX / "m77cli.cmd")
      # No install was performed: the bucket-head version dir was never
      # created.
      check not dirExists(sandbox.appsDir / app / bucketHeadY)
      # The executable actually runs and reports the INSTALLED version.
      let launched = launchScoopExecutable(profile.selectedStorePath,
        ["--version"])
      check launched.exitCode == 0
      check launched.output.contains(app & " " & installedX)
      check not launched.output.contains(bucketHeadY)

    # -----------------------------------------------------------------
    # Control 2: a plan pinned to a version that is NOT installed and
    # NOT equal to the bucket head. An install IS required and the
    # bucket cannot supply it → still raises `EScoopVersionMismatch`.
    # -----------------------------------------------------------------
    block pinnedNotInstalledStillRaises:
      let app = "m77-uninstallable-app"
      let bucketHead = "5.0.0"
      # Bucket head exists; NO version is installed at all.
      discard writeBucketManifest(sandbox, app, bucketHead)
      check not dirExists(sandbox.appsDir / app)

      let useDef = fixtureUseDef(
        packageSelector = "m77-uninstallable",
        executableName = "m77cli",
        bucket = sandbox.bucketName,
        app = app,
        # Pin a version that is neither installed nor the bucket head.
        version = "4.2.0",
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "m77cli.cmd",
        requiresExecutionProfileChecksum = true)

      var raised = false
      try:
        discard resolveScoopTool(useDef, storeRoot)
      except EScoopVersionMismatch as err:
        raised = true
        check err.msg.contains("EScoopVersionMismatch")
        check err.msg.contains("package pinned 4.2.0")
        check err.msg.contains("bucket head is 5.0.0")
      check raised

    # -----------------------------------------------------------------
    # Control 3: an UNPINNED plan whose `preferredVersion` range the
    # bucket head does not satisfy, with NOTHING installed. An install
    # is required and the bucket cannot satisfy the range → still
    # raises `EScoopVersionMismatch`.
    # -----------------------------------------------------------------
    block unpinnedRangeUnsatisfiedStillRaises:
      let app = "m77-range-app"
      let bucketHead = "1.0.0"
      discard writeBucketManifest(sandbox, app, bucketHead)
      check not dirExists(sandbox.appsDir / app)

      let useDef = fixtureUseDef(
        packageSelector = "m77-range",
        executableName = "m77cli",
        bucket = sandbox.bucketName,
        app = app,
        version = "",
        # Bucket head 1.0.0 does NOT satisfy `>=2.0`.
        preferredVersion = ">=2.0",
        manifestChecksum = "",
        executablePath = "m77cli.cmd",
        requiresExecutionProfileChecksum = true)

      var raised = false
      try:
        discard resolveScoopTool(useDef, storeRoot)
      except EScoopVersionMismatch as err:
        raised = true
        check err.msg.contains("EScoopVersionMismatch")
        check err.msg.contains("bucket head 1.0.0")
        check err.msg.contains("does not satisfy preferredVersion >=2.0")
      check raised

    # -----------------------------------------------------------------
    # Control 3b (symmetry check): an UNPINNED plan whose range the
    # bucket head does NOT satisfy, but an INSTALLED version DOES — the
    # installed version is resolved as a cache-hit, NO exception. This
    # proves the M77 relaxation is implemented symmetrically for the
    # unpinned path, not just the pinned path.
    # -----------------------------------------------------------------
    block unpinnedRangeInstalledIsCacheHit:
      let app = "m77-range-installed-app"
      let installedX = "3.4.0"
      let bucketHeadY = "1.9.0"
      installScoopAppAtVersion(sandbox, app, installedX)
      discard writeBucketManifest(sandbox, app, bucketHeadY)
      check dirExists(sandbox.appsDir / app / installedX)

      let useDef = fixtureUseDef(
        packageSelector = "m77-range-installed",
        executableName = "m77cli",
        bucket = sandbox.bucketName,
        app = app,
        version = "",
        # Installed 3.4.0 satisfies `>=3.0`; bucket head 1.9.0 does not.
        preferredVersion = ">=3.0",
        manifestChecksum = "",
        executablePath = "m77cli.cmd",
        requiresExecutionProfileChecksum = true)

      let profile = resolveScoopTool(useDef, storeRoot)
      check profile.scoopResolvedVersion == installedX
      check not dirExists(sandbox.appsDir / app / bucketHeadY)
      check fileExists(profile.resolvedExecutablePath)

    # -----------------------------------------------------------------
    # Case 4: the manifest-checksum mismatch path is UNCHANGED — a
    # declared `manifestChecksum` that does not match the bucket
    # manifest's actual checksum still raises
    # `EScoopManifestChecksumMismatch`, even when the wanted version is
    # installed. M77 must not weaken this check.
    # -----------------------------------------------------------------
    block manifestChecksumMismatchStillRaises:
      let app = "m77-checksum-app"
      let installedX = "7.0.0"
      installScoopAppAtVersion(sandbox, app, installedX)
      # The real bucket manifest checksum — the plan will declare a
      # DIFFERENT one.
      let realChecksum = writeBucketManifest(sandbox, app, installedX)
      check realChecksum.len > 0
      let wrongChecksum =
        if realChecksum.startsWith("0"): "f" & realChecksum[1 .. ^1]
        else: "0" & realChecksum[1 .. ^1]
      check wrongChecksum != realChecksum

      let useDef = fixtureUseDef(
        packageSelector = "m77-checksum",
        executableName = "m77cli",
        bucket = sandbox.bucketName,
        app = app,
        version = installedX,
        preferredVersion = "",
        # Declared checksum deliberately does not match the manifest.
        manifestChecksum = wrongChecksum,
        executablePath = "m77cli.cmd",
        requiresExecutionProfileChecksum = true)

      var raised = false
      try:
        discard resolveScoopTool(useDef, storeRoot)
      except EScoopManifestChecksumMismatch as err:
        raised = true
        check err.msg.contains("EScoopManifestChecksumMismatch")
        check err.msg.contains(wrongChecksum)
      check raised
