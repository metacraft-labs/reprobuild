## M55 Verification Gate: e2e_scoop_practical_hardening
##
## Verifies all four practical-hardening tiers and the cache-portability
## classification the build engine uses for them, plus the drift
## scenarios called out in the spec:
##
##   - Exact-version pin + declared manifestChecksum + default
##     requiresExecutionProfileChecksum produces
##     practicalHardening = pinned-and-profile-verified and
##     cachePortability = portable.
##   - Moving the sandboxed bucket head to a newer version does NOT
##     change the realized pointer prefix's junction target — the
##     adapter must still bind to the pinned <apps/<app>/<exact-
##     version>/>, not <current/>.
##   - Rewriting the bucket's manifest in place produces
##     EScoopManifestChecksumMismatch on the next plan.
##   - A corrupted post-install file produces
##     EScoopProfileChecksumMismatch on launch.
##   - The same package definition with preferredVersion range
##     produces practicalHardening = ranged-and-profile-verified and
##     cachePortability = local-only.
##   - With requiresExecutionProfileChecksum = false, the resolved
##     receipt's practicalHardening is pinned (exact) or ranged
##     (range), still cache-local.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] e2e_scoop_practical_hardening: " &
    "this gate requires Windows and a real Scoop install"
  quit(0)

import std/[json, os, tempfiles, unittest]

import repro_tool_profiles

import ./scoop_sandbox

suite "e2e_scoop_practical_hardening":
  test "e2e_scoop_practical_hardening":
    let scoopBinary = resolveScoopBinary()
    if scoopBinary.len == 0:
      raise newException(OSError,
        "M55 gate requires a real scoop binary on PATH (none found).")

    let tempRoot = createTempDir("repro-m55-hardening-", "")
    defer: safeRemoveTempRoot(tempRoot)

    let sandbox = setupScoopSandbox(tempRoot, "main")
    let storeRoot = tempRoot / "tool-store"

    let fixture = populateScoopApp(sandbox, app = "hardening-app",
      version = "1.0.0", executableName = "hard-cli.cmd",
      executablePayload = fixtureExecutablePayload("hard 1.0.0"))

    # The declared manifestChecksum has to match what BLAKE3 of the
    # actual manifest bytes will be. Compute it the same way the
    # adapter does. This mirrors the package author flow: author runs a
    # one-time computation, pastes the digest into the package
    # definition.
    let declaredManifestChecksum = blake3HexFile(fixture.manifestPath)

    # ----------------------------------------------------------------
    # Tier 1: pinned-and-profile-verified (the recommended default)
    # ----------------------------------------------------------------
    let pinnedUseDef = fixtureUseDef(
      packageSelector = "hardening-pkg",
      executableName = "hard-cli",
      bucket = sandbox.bucketName,
      app = fixture.name,
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = declaredManifestChecksum,
      executablePath = fixture.executableName,
      requiresExecutionProfileChecksum = true)

    let pinnedProfile = resolveScoopTool(pinnedUseDef, storeRoot)
    check pinnedProfile.practicalHardening == phPinnedAndProfileVerified
    check pinnedProfile.cachePortability == cpPortable
    check pinnedProfile.scoopManifestChecksum == declaredManifestChecksum
    check pinnedProfile.scoopExecutionProfileChecksum.len == 64
    check pinnedProfile.scoopJunctionTarget == fixture.versionDir

    let pinnedReceipt = parseFile(
      pinnedProfile.selectedStorePath / ".repro-receipt.json")
    check pinnedReceipt{"practicalHardening"}.getStr() ==
      "pinned-and-profile-verified"

    # ----------------------------------------------------------------
    # Drift: bucket head moves to v2.0.0; pinned realization stays put.
    # ----------------------------------------------------------------
    let originalJunctionLive = readJunctionTarget(
      pinnedProfile.selectedStorePath / "bin")
    check originalJunctionLive.len > 0

    # Install a second version. `current/` swings to the newer dir —
    # exactly what `scoop update` does in production.
    let fixtureV2 = populateScoopApp(sandbox, app = "hardening-app",
      version = "2.0.0", executableName = "hard-cli.cmd",
      executablePayload = fixtureExecutablePayload("hard 2.0.0"))
    check readJunctionTarget(fixtureV2.currentDir) == fixtureV2.versionDir

    # But the manifest checksum changed (because the bucket head is
    # now 2.0.0). Reset the manifest to v1.0.0 so we can isolate the
    # "head moves but realization stays" assertion from the manifest-
    # rewrite assertion below.
    writeMinimalManifest(fixture.manifestPath, "1.0.0",
      fixture.executableName, fixture.executablePath)

    let pinnedAgain = resolveScoopTool(pinnedUseDef, storeRoot)
    check pinnedAgain.selectedStorePath == pinnedProfile.selectedStorePath
    let liveAfter = readJunctionTarget(pinnedAgain.selectedStorePath / "bin")
    check liveAfter.len > 0
    # Same realized prefix, same junction target — the v2.0.0 install
    # sitting next to v1.0.0 doesn't change which bytes the launch
    # plan reaches.
    check sameFile(liveAfter, fixture.versionDir)
    check liveAfter != fixtureV2.versionDir

    # ----------------------------------------------------------------
    # Manifest checksum mismatch: rewriting the bucket manifest in
    # place must be detected as EScoopManifestChecksumMismatch.
    # Use a valid JSON rewrite — same version, different homepage —
    # so the failure must come from the BLAKE3 checksum comparison,
    # not from the manifest-unreadable parse error.
    # ----------------------------------------------------------------
    let originalManifestText = readFile(fixture.manifestPath)
    let rewrittenManifestJson = parseJson(originalManifestText)
    rewrittenManifestJson["homepage"] =
      newJString("https://example.invalid/in-place-edit")
    writeFile(fixture.manifestPath, rewrittenManifestJson.pretty())
    expect EScoopManifestChecksumMismatch:
      discard resolveScoopTool(pinnedUseDef, storeRoot)
    # Restore for downstream subtests.
    writeMinimalManifest(fixture.manifestPath, "1.0.0",
      fixture.executableName, fixture.executablePath)

    # ----------------------------------------------------------------
    # Profile checksum mismatch: corrupt a post-install file under the
    # pinned version dir, then call the launch wrapper — must raise
    # EScoopProfileChecksumMismatch.
    # ----------------------------------------------------------------
    writeFile(fixture.versionDir / "extra-file.txt", "added after install")
    expect EScoopProfileChecksumMismatch:
      discard launchScoopExecutable(pinnedProfile.selectedStorePath,
        ["--version"])
    removeFile(fixture.versionDir / "extra-file.txt")

    # ----------------------------------------------------------------
    # Tier 2: ranged-and-profile-verified (preferredVersion). Build
    # engine treats this as cache-local even though the execution
    # profile is captured — the version isn't pinned, so cross-machine
    # cache portability isn't safe.
    # ----------------------------------------------------------------
    let rangedUseDef = fixtureUseDef(
      packageSelector = "hardening-pkg",
      executableName = "hard-cli",
      bucket = sandbox.bucketName,
      app = fixture.name,
      version = "",
      preferredVersion = ">=1.0",
      manifestChecksum = "",
      executablePath = fixture.executableName,
      requiresExecutionProfileChecksum = true)

    let rangedProfile = resolveScoopTool(rangedUseDef, storeRoot)
    check rangedProfile.practicalHardening == phRangedAndProfileVerified
    check rangedProfile.cachePortability == cpLocalOnly
    check rangedProfile.scoopResolvedVersion == "1.0.0"
    check rangedProfile.scoopExecutionProfileChecksum.len == 64
    let rangedReceipt = parseFile(
      rangedProfile.selectedStorePath / ".repro-receipt.json")
    check rangedReceipt{"practicalHardening"}.getStr() ==
      "ranged-and-profile-verified"

    # ----------------------------------------------------------------
    # Tier 3: pinned (no execution profile) — exact version,
    # requiresExecutionProfileChecksum = false. Cache-local.
    # ----------------------------------------------------------------
    let pinnedNoProfileUseDef = fixtureUseDef(
      packageSelector = "hardening-pkg",
      executableName = "hard-cli",
      bucket = sandbox.bucketName,
      app = fixture.name,
      version = "1.0.0",
      preferredVersion = "",
      manifestChecksum = declaredManifestChecksum,
      executablePath = fixture.executableName,
      requiresExecutionProfileChecksum = false)

    let pinnedNoProfile = resolveScoopTool(pinnedNoProfileUseDef, storeRoot)
    check pinnedNoProfile.practicalHardening == phPinned
    check pinnedNoProfile.cachePortability == cpLocalOnly
    check pinnedNoProfile.scoopExecutionProfileChecksum == ""

    # ----------------------------------------------------------------
    # Tier 4: ranged (no execution profile). Cache-local.
    # ----------------------------------------------------------------
    let rangedNoProfileUseDef = fixtureUseDef(
      packageSelector = "hardening-pkg",
      executableName = "hard-cli",
      bucket = sandbox.bucketName,
      app = fixture.name,
      version = "",
      preferredVersion = ">=1.0",
      manifestChecksum = "",
      executablePath = fixture.executableName,
      requiresExecutionProfileChecksum = false)

    let rangedNoProfile = resolveScoopTool(rangedNoProfileUseDef, storeRoot)
    check rangedNoProfile.practicalHardening == phRanged
    check rangedNoProfile.cachePortability == cpLocalOnly
    check rangedNoProfile.scoopExecutionProfileChecksum == ""
