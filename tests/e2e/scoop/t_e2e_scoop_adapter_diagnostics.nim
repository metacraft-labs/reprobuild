## M55 Verification Gate: e2e_scoop_adapter_diagnostics
##
## Verifies the adapter emits structured EScoop* exceptions in the
## failure modes the spec calls out:
##   - EScoopMissing       when scoop is removed from PATH
##   - EScoopBucketMissing when the named bucket isn't on disk
##   - EScoopVersionMismatch when the bucket head doesn't satisfy
##     the pin (both exact-version and preferredVersion forms)
##   - EScoopManifestUnreadable when the manifest JSON is malformed
##
## Each failure must be a CatchableError of the documented subtype,
## not a generic OSError or ValueError.

import std/[os, tempfiles, unittest]

import repro_tool_profiles

import ./scoop_sandbox

suite "e2e_scoop_adapter_diagnostics":
  test "e2e_scoop_adapter_diagnostics":
    let scoopBinary = resolveScoopBinary()
    if scoopBinary.len == 0:
      raise newException(OSError,
        "M55 gate requires a real scoop binary on PATH (none found).")

    let tempRoot = createTempDir("repro-m55-diag-", "")
    defer: safeRemoveTempRoot(tempRoot)

    let storeRoot = tempRoot / "tool-store"

    # --- EScoopMissing --------------------------------------------------
    # Force the adapter to see an empty PATH so no scoop binary
    # resolves. The adapter must raise EScoopMissing — not a generic
    # OSError — so callers can distinguish "scoop is not installed"
    # from every other failure mode.
    let savedPath = getEnv("PATH")
    putEnv("PATH", tempRoot / "definitely-not-a-path")
    let savedScoop = getEnv("SCOOP")
    putEnv("SCOOP", "")
    let savedReproOverride = getEnv("REPROBUILD_SCOOP_BINARY")
    putEnv("REPROBUILD_SCOOP_BINARY", "")
    try:
      let missingUseDef = fixtureUseDef(
        packageSelector = "diag-missing",
        executableName = "diag-cli",
        bucket = "main",
        app = "diag-missing-app",
        version = "1.0.0",
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "diag-cli.cmd")
      expect EScoopMissing:
        discard resolveScoopTool(missingUseDef, storeRoot)
    finally:
      putEnv("PATH", savedPath)
      if savedScoop.len > 0: putEnv("SCOOP", savedScoop)
      if savedReproOverride.len > 0:
        putEnv("REPROBUILD_SCOOP_BINARY", savedReproOverride)

    # --- EScoopBucketMissing -------------------------------------------
    # Sandboxed scoop root with no buckets at all. The adapter checks
    # <scoop-root>/buckets/<bucket> first and must surface a structured
    # EScoopBucketMissing.
    let sandbox = setupScoopSandbox(tempRoot, "main")
    # Remove the just-created bucket dir to exercise the missing
    # bucket failure.
    removeDir(sandbox.bucketDir)
    let bucketMissingUseDef = fixtureUseDef(
      packageSelector = "diag-bucket",
      executableName = "diag-cli",
      bucket = "main",
      app = "diag-bucket-app",
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = "",
      executablePath = "diag-cli.cmd")
    expect EScoopBucketMissing:
      discard resolveScoopTool(bucketMissingUseDef, storeRoot)

    # Restore the bucket dir for subsequent diagnostics.
    discard setupScoopSandbox(tempRoot, "main")

    # --- EScoopVersionMismatch (exact pin) -----------------------------
    # Bucket manifest version 2.0.0 but the package pins 1.0.0. The
    # adapter must refuse to follow the bucket head and raise
    # EScoopVersionMismatch.
    let fixtureV2 = populateScoopApp(sandbox, app = "diag-version-app",
      version = "2.0.0", executableName = "diag-cli.cmd",
      executablePayload = fixtureExecutablePayload("diag 2.0.0"))
    discard fixtureV2 # silence unused-var hint on Nim 2.2
    let exactPinUseDef = fixtureUseDef(
      packageSelector = "diag-version",
      executableName = "diag-cli",
      bucket = sandbox.bucketName,
      app = "diag-version-app",
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = "",
      executablePath = "diag-cli.cmd")
    expect EScoopVersionMismatch:
      discard resolveScoopTool(exactPinUseDef, storeRoot)

    # --- EScoopVersionMismatch (preferredVersion range) ----------------
    # Same fixture, but this time the package declares a range that
    # the bucket head 2.0.0 does NOT satisfy: ">=3.0".
    let rangeUseDef = fixtureUseDef(
      packageSelector = "diag-version",
      executableName = "diag-cli",
      bucket = sandbox.bucketName,
      app = "diag-version-app",
      version = "",
      preferredVersion = ">=3.0",
      manifestChecksum = "",
      executablePath = "diag-cli.cmd")
    expect EScoopVersionMismatch:
      discard resolveScoopTool(rangeUseDef, storeRoot)

    # --- EScoopManifestUnreadable --------------------------------------
    # Pre-position a perfectly fine install, then truncate the manifest
    # JSON to make it unparseable. The adapter reads the manifest from
    # the on-disk bucket before computing the manifest checksum, so it
    # must surface EScoopManifestUnreadable BEFORE any other check.
    let badFixture = populateScoopApp(sandbox, app = "diag-manifest-app",
      version = "1.0.0", executableName = "diag-cli.cmd",
      executablePayload = fixtureExecutablePayload("diag 1.0.0"))
    writeFile(badFixture.manifestPath, "{ this is not valid json")
    let manifestUseDef = fixtureUseDef(
      packageSelector = "diag-manifest",
      executableName = "diag-cli",
      bucket = sandbox.bucketName,
      app = "diag-manifest-app",
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = "",
      executablePath = "diag-cli.cmd")
    expect EScoopManifestUnreadable:
      discard resolveScoopTool(manifestUseDef, storeRoot)
