## Installer applications: the `macos.appBundle` driver placing a FOLDER --
## the placed item of an installer application whose product bundle lives
## in a folder of the installed prefix (`~/Applications/OpenWebStart`) --
## and the identity it records (Store-And-Installation-Layout.md § macOS
## Application Bundles, "Installer applications", "Activation").
##
## Real tools on real bundles built and ad-hoc signed at test time
## (`repro_test_support/macos_app_fixtures`), exactly as in
## `t_macos_app_bundle_placement`, which explains the fixtures and the one
## trust relaxation (checks 4 and 5 through `AppTrustPolicy`; checks 1 to 3
## run for real). No mocks.
##
## What is pinned:
## * the folder identity bytes: format line `macos.appFolder.v1`, then for
##   each `.app` directly in the folder in byte order of its name a
##   `bundle=<name>` line and that bundle's identity fields; a nested bundle
##   and plain files are not part of it; a SINGLE bundle's bytes are
##   unchanged (`macos.appBundle.v1`), so existing placements do not drift;
## * placement: the staged folder's product bundle passes checks 1 to 5 and
##   every other top-level bundle check 2; a refusal places nothing;
## * rollback-style re-placement (empty expectation, pinned bytes): check 2
##   on every top-level bundle and byte-equal folder identity;
## * observation and removal of a folder.
##
## Never touches the real `~/Applications`.
##
## Falsifying mutations: dropping the per-bundle `codesign --verify` from
## folder staging fails "a tampered second bundle refuses the folder";
## comparing only the main bundle's identity fails "a pinned folder refuses
## a folder with a different second bundle".

when defined(macosx):
  import std/[algorithm, os, strutils, tempfiles, unittest]

  import repro_home_resources
  import repro_home_resources/drivers/app_bundle
  import repro_test_support/macos_app_fixtures

  const
    ProductId = "dev.reprobuild.folder.product"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}
    Item = "Prod"

  proc expectation(version = "1.0.0"): AppBundleExpectation =
    AppBundleExpectation(bundleId: ProductId, version: version,
      teamId: FixtureTeamId)

  proc text(bytes: seq[byte]): string =
    for b in bytes: result.add(char(b))

  proc entries(dir: string): seq[string] =
    if dirExists(dir):
      for _, path in walkDir(dir, relative = true):
        result.add(path)
    result.sort()

  suite "installer applications: folder identity and placement":
    let root = createTempDir("repro-folder-placement-", "")
    let v1 = makeFixtureProductFolder(root / "v1", Item, "Prod", ProductId,
      "1.0.0")
    let v2 = makeFixtureProductFolder(root / "v2", Item, "Prod", ProductId,
      "2.0.0")
    var counter = 0
    proc freshApps(): string =
      inc counter
      root / ("home-" & $counter) / "Applications"

    test "the folder identity lists the top-level bundles in byte order":
      # "Prod Helper.app" sorts before "Prod.app" (' ' < '.').
      let bytes = readPlacedItemIdentityBytes(v1)
      let main = readAppBundleIdentity(v1 / "Prod.app")
      let helper = readAppBundleIdentity(v1 / "Prod Helper.app")
      let expected = AppFolderIdentityFormat & "\n" &
        "bundle=Prod Helper.app\n" &
        "bundleId=" & helper.bundleId & "\n" &
        "shortVersion=1.0.0\nbundleVersion=1.0.0\n" &
        "teamId=" & FixtureTeamId & "\n" &
        "cdhash=" & helper.cdhash & "\n" &
        "bundle=Prod.app\n" &
        "bundleId=" & ProductId & "\n" &
        "shortVersion=1.0.0\nbundleVersion=1.0.0\n" &
        "teamId=" & FixtureTeamId & "\n" &
        "cdhash=" & main.cdhash & "\n"
      check text(bytes) == expected
      # A bundle's bytes are exactly the v1 bundle identity.
      check readPlacedItemIdentityBytes(v1 / "Prod.app") ==
        appBundleCanonicalBytes(main)
      check text(appBundleCanonicalBytes(main)).startsWith(
        AppBundleIdentityFormat & "\n")
      check readPlacedItemIdentityBytes(v2) != bytes

    test "a folder is placed whole and observed with its folder identity":
      let apps = freshApps()
      let pinned = readPlacedItemIdentityBytes(v1)
      let placed = placeAppBundle(v1, apps, Item, expectation(), Relaxed,
        pinned = pinned, mainBundle = "Prod.app")
      check placed.bundleId == ProductId
      let target = apps / Item
      check entries(target) == entries(v1)
      check dirExists(target / ".support" / (Item & " Update.app"))
      check entries(apps) == @[Item]
      let observed = observeAppBundleAt(target)
      check observed.present
      check observed.rawBytes == pinned
      removeAppBundle(target)
      check not dirExists(target)
      check entries(apps).len == 0

    test "a staged folder whose product bundle mismatches is refused and " &
        "nothing is placed":
      let apps = freshApps()
      try:
        discard placeAppBundle(v1, apps, Item, expectation("9.9"), Relaxed,
          mainBundle = "Prod.app")
        check false
      except EAppBundleRefused as err:
        check err.check == "version"
      check not dirExists(apps / Item)
      check not dirExists(apps)

    test "a tampered second bundle refuses the folder":
      let bad = makeFixtureProductFolder(root / "bad", Item, "Prod", ProductId,
        "1.0.0")
      tamperFixtureApp(bad / "Prod Helper.app")
      let apps = freshApps()
      try:
        discard placeAppBundle(bad, apps, Item, expectation(), Relaxed,
          mainBundle = "Prod.app")
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "signature"
        check "Prod Helper.app" in err.bundlePath
      check not dirExists(apps / Item)

    test "a folder without its product bundle is refused":
      let apps = freshApps()
      try:
        discard placeAppBundle(v1, apps, Item, expectation(), Relaxed,
          mainBundle = "Missing.app")
        check false
      except EAppBundleRefused as err:
        check err.check == "info-plist"
      check not dirExists(apps / Item)

    test "a product bundle not directly in the folder is refused":
      # The folder identity pins only the bundles directly in the folder,
      # so a product nested deeper (here the updater in `.support/`) would
      # be launched from bytes no recorded identity covers.
      let apps = freshApps()
      for main in [".support/Prod Update.app", "../Prod.app", "Prod"]:
        checkpoint main
        try:
          discard placeAppBundle(v1, apps, Item, expectation(), Relaxed,
            mainBundle = main)
          check false
        except EAppBundlePlacement as err:
          checkpoint err.msg
          check "directly in it" in err.msg
        check not dirExists(apps / Item)

    test "a pinned folder is re-placed against its recorded identity " &
        "(rollback) and replaces the managed one":
      let apps = freshApps()
      let pinnedV1 = readPlacedItemIdentityBytes(v1)
      let pinnedV2 = readPlacedItemIdentityBytes(v2)
      discard placeAppBundle(v2, apps, Item, expectation("2.0.0"), Relaxed,
        pinned = pinnedV2, mainBundle = "Prod.app")
      # Rollback stages with an empty expectation and the recorded bytes,
      # and no main-bundle path: it re-places what the generation recorded.
      let staged = stageAppBundle(v1, apps, Item, AppBundleExpectation(), {},
        managedPrior = true, pinned = pinnedV1)
      check staged.itemIdentity == pinnedV1
      discard commitStagedAppBundle(staged)
      check observeAppBundleAt(apps / Item).rawBytes == pinnedV1
      check entries(apps) == @[Item]

    test "a pinned folder refuses a folder with a different second bundle":
      let other = makeFixtureProductFolder(root / "other", Item, "Prod",
        ProductId, "1.0.0")
      # Replace only the helper with another build of it: the main bundle's
      # identity is unchanged, the folder's is not.
      removeDir(other / "Prod Helper.app")
      discard makeFixtureApp(other, "Prod Helper", ProductId & ".helper",
        "1.0.1")
      let apps = freshApps()
      try:
        discard stageAppBundle(other, apps, Item, AppBundleExpectation(), {},
          pinned = readPlacedItemIdentityBytes(v1))
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "identity"
      check not dirExists(apps / Item)

    test "a pinned folder whose bundle was tampered with is refused":
      let bad = makeFixtureProductFolder(root / "bad2", Item, "Prod",
        ProductId, "1.0.0")
      let pinned = readPlacedItemIdentityBytes(bad)
      tamperFixtureApp(bad / "Prod.app")
      let apps = freshApps()
      try:
        discard stageAppBundle(bad, apps, Item, AppBundleExpectation(), {},
          pinned = pinned)
        check false
      except EAppBundleRefused as err:
        check err.check == "signature"
      check not dirExists(apps / Item)

    test "an unmanaged folder at the target is never replaced":
      let apps = freshApps()
      createDir(apps / Item)
      writeFile(apps / Item / "mine.txt", "user data")
      try:
        discard placeAppBundle(v1, apps, Item, expectation(), Relaxed,
          mainBundle = "Prod.app")
        check false
      except EAppBundleCollision:
        discard
      check readFile(apps / Item / "mine.txt") == "user data"

    test "the installer check needs Contents/Info.plist and the team":
      let installer = makeFixtureInstallerApp(root / "inst", "Inst", "")
      let identity = verifyAppBundleTeam(installer, FixtureTeamId, Relaxed)
      check identity.teamId == FixtureTeamId
      try:
        discard verifyAppBundleTeam(installer, "OTHERTEAM1", Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "team-id"
      # The strict policy refuses an ad-hoc signature (real codesign -R).
      try:
        discard verifyAppBundleTeam(installer, FixtureTeamId,
          {atrSkipNotarization})
        check false
      except EAppBundleRefused as err:
        check err.check == "developer-id"
      let notBundle = root / "inst" / "NotABundle.app"
      createDir(notBundle / "Contents")
      try:
        discard verifyAppBundleTeam(notBundle, FixtureTeamId, Relaxed)
        check false
      except EAppBundleRefused as err:
        check err.check == "info-plist"

    removeDir(root)
