## GM4c: the `macos.appBundle` driver — trust verification, placement scope,
## collision refusal, replacement, removal and identity
## (`drivers/app_bundle.nim`; Store-And-Installation-Layout.md § macOS
## Application Bundles).
##
## Every case runs the real system tools against real bundles: `codesign`,
## `spctl`, `ditto` and `plutil` from `/usr/bin` / `/usr/sbin`, on bundles
## built and signed at test time (`repro_test_support/macos_app_fixtures`).
##
## Why the fixtures are ad-hoc signed, and why two checks are relaxed in some
## cases. A bundle built at test time cannot carry an Apple Developer ID
## signature or a notarization ticket, and a self-signed certificate cannot
## record a team identifier (codesign sets one only for Apple-issued
## certificates). The fixtures are therefore signed ad-hoc with
## `--team-identifier`, which exercises the bundle-id, version, signature
## integrity and team-equality checks for real. The two checks that need
## Apple — the Developer ID chain (`codesign -R`) and Gatekeeper's
## notarization verdict (`spctl`) — are asserted here as REAL REFUSALS of
## those fixtures under the strict policy (so the checks are proven to run
## and to reject what they must), and are relaxed through `AppTrustPolicy`
## only in the cases that test something else. Their acceptance of a genuine
## Developer ID, notarized bundle is established against the real vendor
## applications (the GM4c contribution verification run). No mocks.
##
## Nothing here touches the real `~/Applications` or `/Applications`: every
## Applications directory is under a scratch root, and the system scope is
## re-rooted with `systemRoot`.
##
## Falsifying mutations: dropping the `codesign --verify` step from
## `verifyAppBundle` fails "a tampered bundle is refused and nothing is
## placed"; dropping the team comparison fails "a team-id mismatch is
## refused"; dropping the `managedPrior` check fails "an unmanaged bundle is
## never replaced".

when defined(macosx):
  import std/[os, strutils, tempfiles, unittest]

  import repro_home_resources/drivers/app_bundle
  import repro_test_support/macos_app_fixtures

  const
    FixtureId = "dev.reprobuild.gm4c.placement"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  proc expectation(version = "1.0.0"; team = FixtureTeamId;
                   bundleId = FixtureId): AppBundleExpectation =
    AppBundleExpectation(bundleId: bundleId, version: version, teamId: team)

  proc entries(dir: string): seq[string] =
    if not dirExists(dir):
      return
    for kind, path in walkDir(dir, relative = true):
      result.add(path)

  suite "GM4c: macos.appBundle trust verification":
    let root = createTempDir("repro-gm4c-verify-", "")
    let app = makeFixtureApp(root, "Fixture", FixtureId, "1.0.0")

    test "a bundle matching its declarations passes the relaxed policy":
      let identity = verifyAppBundle(app, expectation(), Relaxed)
      check identity.bundleId == FixtureId
      check identity.shortVersion == "1.0.0"
      check identity.teamId == FixtureTeamId
      check identity.adhoc
      check identity.cdhash.len == 40

    test "the strict policy refuses an ad-hoc team id (real codesign -R)":
      try:
        discard verifyAppBundle(app, expectation(), {atrSkipNotarization})
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "developer-id"

    test "the strict policy refuses an un-notarized bundle (real spctl)":
      try:
        discard verifyAppBundle(app, expectation(),
          {atrUnanchoredTeamIdentifier})
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "notarization"
        check "rejected" in err.msg

    test "a team-id mismatch is refused":
      try:
        discard verifyAppBundle(app, expectation(team = "ABCDE12345"),
          Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "team-id"
        check FixtureTeamId in err.msg
        check "ABCDE12345" in err.msg

    test "a declared team id that is not a team id is refused":
      try:
        discard verifyAppBundle(app, expectation(team = "not-a-team"),
          Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "team-id"

    test "bundle identifier and version mismatches are refused":
      try:
        discard verifyAppBundle(app, expectation(bundleId = "com.other"),
          Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "bundle-id"
      try:
        discard verifyAppBundle(app, expectation(version = "9.9.9"), Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "version"

    test "an unsigned bundle is refused at the signature check":
      let unsigned = makeFixtureApp(root / "unsigned", "Unsigned", FixtureId,
        "1.0.0", sign = false)
      try:
        discard verifyAppBundle(unsigned, expectation(), Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "signature"

    removeDir(root)

  suite "GM4c: macos.appBundle placement":
    let root = createTempDir("repro-gm4c-place-", "")
    let app = makeFixtureApp(root / "store", "Fixture", FixtureId, "1.0.0")
    let appV2 = makeFixtureApp(root / "store2", "Fixture", FixtureId,
      "2.0.0")
    let pinnedV1 = appBundleCanonicalBytes(readAppBundleIdentity(app))

    test "home scope is ~/Applications and system scope is /Applications":
      let home = root / "home"
      check applicationsDir(apsHome, home) == home / "Applications"
      check applicationsDir(apsSystem, home) == "/Applications"
      check applicationsDir(apsSystem, home, root / "sysroot") ==
        root / "sysroot" / "Applications"

    test "a bundle placed at home scope lands in the scratch home only":
      let dir = applicationsDir(apsHome, root / "home")
      let placed = placeAppBundle(app, dir, "Fixture.app", expectation(),
        Relaxed, pinned = pinnedV1)
      check dirExists(dir / "Fixture.app")
      check plistValue(dir / "Fixture.app", "CFBundleIdentifier") == FixtureId
      check appBundleCanonicalBytes(placed) == pinnedV1
      # Only the bundle: no staging or retired copy is left beside it.
      check entries(dir) == @["Fixture.app"]

    test "a bundle placed at system scope lands under the system root":
      let dir = applicationsDir(apsSystem, root / "home", root / "sysroot")
      discard placeAppBundle(app, dir, "Fixture.app", expectation(), Relaxed)
      check dirExists(root / "sysroot" / "Applications" / "Fixture.app")

    test "an unmanaged bundle at the target path is never replaced":
      let dir = root / "collide" / "Applications"
      createDir(dir / "Fixture.app" / "Contents")
      writeFile(dir / "Fixture.app" / "Contents" / "user-owned", "mine")
      try:
        discard placeAppBundle(app, dir, "Fixture.app", expectation(),
          Relaxed)
        check false
      except EAppBundleCollision as err:
        check err.targetPath == dir / "Fixture.app"
        check "not placed by Reprobuild" in err.msg
      check readFile(dir / "Fixture.app" / "Contents" / "user-owned") ==
        "mine"
      check entries(dir) == @["Fixture.app"]

    test "a managed bundle is replaced by a new version":
      let dir = root / "update" / "Applications"
      discard placeAppBundle(app, dir, "Fixture.app", expectation(), Relaxed)
      let v2 = placeAppBundle(appV2, dir, "Fixture.app",
        expectation("2.0.0"), Relaxed, managedPrior = true)
      check v2.shortVersion == "2.0.0"
      check plistValue(dir / "Fixture.app", "CFBundleShortVersionString") ==
        "2.0.0"
      check entries(dir) == @["Fixture.app"]

    test "a tampered bundle is refused and nothing is placed":
      let tampered = makeFixtureApp(root / "tampered", "Fixture", FixtureId,
        "1.0.0")
      tamperFixtureApp(tampered)
      let dir = root / "tamper-home" / "Applications"
      try:
        discard placeAppBundle(tampered, dir, "Fixture.app", expectation(),
          Relaxed)
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "signature"
      # The Applications directory this call would have created is gone too.
      check not dirExists(dir)

    test "a refused replacement leaves the managed bundle in place":
      let dir = root / "keep" / "Applications"
      discard placeAppBundle(app, dir, "Fixture.app", expectation(), Relaxed)
      try:
        discard placeAppBundle(appV2, dir, "Fixture.app",
          expectation("2.0.0", team = "ABCDE12345"), Relaxed,
          managedPrior = true)
        check false
      except EAppBundleRefused as err:
        check err.check == "team-id"
      check plistValue(dir / "Fixture.app", "CFBundleShortVersionString") ==
        "1.0.0"
      check entries(dir) == @["Fixture.app"]

    test "a pinned identity refuses a different bundle":
      let dir = root / "pinned" / "Applications"
      try:
        discard placeAppBundle(appV2, dir, "Fixture.app",
          AppBundleExpectation(), {}, pinned = pinnedV1)
        check false
      except EAppBundleRefused as err:
        check err.check == "identity"
      check not dirExists(dir / "Fixture.app")
      let placed = placeAppBundle(app, dir, "Fixture.app",
        AppBundleExpectation(), {}, pinned = pinnedV1)
      check appBundleCanonicalBytes(placed) == pinnedV1

    test "a bundle whose executable is named by its directory survives " &
        "staging":
      # DB Browser for SQLite ships an empty CFBundleExecutable; codesign
      # then locates the main executable from the bundle's name, so staging
      # under any other name would make it "not signed at all".
      let nameless = makeFixtureApp(root / "nameless", "Fixture", FixtureId,
        "1.0.0", declareExecutable = false)
      check plistValue(nameless, "CFBundleExecutable") == ""
      let dir = root / "nameless-home" / "Applications"
      discard placeAppBundle(nameless, dir, "Fixture.app", expectation(),
        Relaxed)
      check dirExists(dir / "Fixture.app")
      check entries(dir) == @["Fixture.app"]

    test "bundles staged together are committed or discarded without " &
        "touching their targets until committed":
      # Rollback stages every bundle it re-places before it renames any of
      # them into place, so one refusal changes none.
      let otherId = FixtureId & ".other"
      let other = makeFixtureApp(root / "other", "Other", otherId, "1.0.0")
      let dir = root / "staged" / "Applications"
      discard placeAppBundle(app, dir, "Fixture.app", expectation(), Relaxed)
      let v2 = stageAppBundle(appV2, dir, "Fixture.app",
        expectation("2.0.0"), Relaxed, managedPrior = true)
      let o = stageAppBundle(other, dir, "Other.app",
        expectation(bundleId = otherId), Relaxed)
      check v2.identity.shortVersion == "2.0.0"
      # Staged, not placed: the target still holds v1, the other target is
      # empty.
      check plistValue(dir / "Fixture.app", "CFBundleShortVersionString") ==
        "1.0.0"
      check not dirExists(dir / "Other.app")
      discard commitStagedAppBundle(v2)
      discardStagedAppBundle(o)
      check plistValue(dir / "Fixture.app", "CFBundleShortVersionString") ==
        "2.0.0"
      check entries(dir) == @["Fixture.app"]
      # Discarding everything staged into an Applications directory the
      # staging created removes that directory again.
      let fresh = root / "staged-fresh" / "Applications"
      let a = stageAppBundle(app, fresh, "Fixture.app", expectation(),
        Relaxed)
      let b = stageAppBundle(other, fresh, "Other.app",
        expectation(bundleId = otherId), Relaxed)
      discardStagedAppBundle(b)
      discardStagedAppBundle(a)
      check not dirExists(fresh)

    test "removal removes only the bundle":
      let dir = root / "remove" / "Applications"
      discard placeAppBundle(app, dir, "Fixture.app", expectation(), Relaxed)
      writeFile(dir / "neighbour.txt", "x")
      removeAppBundle(dir / "Fixture.app")
      check not dirExists(dir / "Fixture.app")
      check entries(dir) == @["neighbour.txt"]

    test "the identity distinguishes versions and survives a copy":
      let idV1 = readAppBundleIdentity(app)
      let idV2 = readAppBundleIdentity(appV2)
      check idV1.cdhash != idV2.cdhash
      check appBundleCanonicalBytes(idV1) != appBundleCanonicalBytes(idV2)
      let copy = root / "copy" / "Fixture.app"
      createDir(copy.parentDir)
      copyBundle(app, copy)
      check appBundleCanonicalBytes(readAppBundleIdentity(copy)) == pinnedV1

    removeDir(root)
