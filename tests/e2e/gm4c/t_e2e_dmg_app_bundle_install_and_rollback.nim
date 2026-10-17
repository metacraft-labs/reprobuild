## GM4c: e2e_dmg_app_bundle_install_and_rollback.
##
## A package whose realization is a disk image delivering an application
## bundle is installed by a real `repro home apply` into `~/Applications`
## of a SCRATCH home, upgraded, rolled back to the previous version and
## rolled back out entirely — and a disk image whose bundle's signature does
## not verify is refused with nothing placed and no volume left attached
## (Store-And-Installation-Layout.md § macOS Application Bundles).
##
## The whole pipeline runs for real: selection (`resolveProfilePackage` →
## `selectRealization`), the home archive realizer (download from a
## `file://` URL, sha256 check, `hdiutil attach` / `ditto` / `hdiutil
## detach`, the trust checks with the real `codesign` and `spctl`), the
## store, the `macos.appBundle` resource lifecycle (`ditto --clone` copy,
## staged verification, rename), the generation manifest and
## `repro home rollback`'s executor. Nothing is mocked.
##
## The fixture package is registered in this test process, which stands in
## for the engine's linked definitions (as the GM4b e2e tests do); its
## archives are disk images this test builds with `hdiutil create` from
## bundles it compiles and signs (`repro_test_support/macos_app_fixtures`).
##
## TRUST POLICY — the one relaxation, and why it is not a mock. The
## fixture bundles are ad-hoc signed with a team identifier: a bundle built
## at test time cannot be signed by an Apple Developer ID certificate or
## notarized. `ApplyOptions.appTrust` therefore relaxes exactly those two
## checks (`atrUnanchoredTeamIdentifier`, `atrSkipNotarization`); the
## bundle identifier, version, signature integrity (`codesign --verify
## --deep --strict`) and team equality checks run for real and are what the
## negative control trips. The strict checks are proven to REFUSE these
## fixtures, with the real tools, in `t_macos_app_bundle_placement`, and to
## ACCEPT genuine vendor bundles in the GM4c contribution verification run.
## No CLI path sets `appTrust`.
##
## Vacuity guard: the bundle placed in the scratch `~/Applications` has the
## Info.plist identifier and version the contribution declares, and its
## code-directory hash is the one the realized store bundle carries (so the
## placed bundle IS the realized one); after the upgrade and the rollbacks
## the version on disk is the one each generation recorded.
##
## Negative control: a disk image whose bundle was modified after signing.
## The apply fails at the realize step naming the signature check; nothing
## is placed in `~/Applications`, no store prefix is published, `current`
## does not move, and `hdiutil info` lists no attachment of that image.
##
## Falsifying mutation (performed for GM4c): making `verifyAppBundle` skip
## its `codesign --verify --deep --strict` step lets the tampered bundle
## through realization into the store, and the negative control fails
## (measured: the apply then fails only at activation, where the pinned
## identity check runs its own `codesign --verify`, with `EAppBundleRefused`
## instead of the realize-step refusal, after publishing the prefix).
##
## Staged-copy refusal: the bundle in the STORE is changed after it was
## realized (a sealed resource rewritten, the way a damaged or tampered
## store looks), and a second home that shares the store applies the same
## profile. Realization is a cache hit (the prefix was verified when it was
## published), so the first check to see the change is the verification of
## the staged copy in `~/Applications`. The apply fails with the structured
## `EApplyAppBundleFailed` (step 9b) naming the package, the bundle, the
## target and the failed check -- not a bare `EAppBundleRefused` -- and
## leaves nothing behind: no bundle at the target, no staging directory,
## no Applications directory it created, no generation, and no disk image
## attached. A second home is used because re-applying in the first one
## would be a no-op of the placed bundle, never reaching placement.
##
## Rollback refusal: the earlier generation's bundle in the STORE is
## changed after that generation was superseded, and the rollback that would
## re-place it fails with the structured `ERollbackAppBundleFailed` naming
## the package, the resource address, the bundle, the target and the failed
## check -- not a bare `EAppBundleRefused` -- and changes nothing: the
## current generation's bundle is still placed (the user is never left with
## neither version), a file resource the rollback would have removed is still
## there (every re-placed bundle is staged and verified before ANY rollback
## operation runs), no staging directory is left, `current` does not move,
## and no disk image is attached.
##
## Command line (§ macOS Application Bundles, "Command line"): an
## application record that declares a command inside its bundle
## (`extraExecutable`, the way Visual Studio Code carries `code`) gets a
## launcher for it in the home profile's bin directory, and the launcher runs
## the PLACED copy in `~/Applications` -- the fixture command prints its own
## path, so the test sees which copy ran. Rolling back to a generation
## without the application removes the command with the bundle; rolling
## forward again restores both; narrowing the host's concerns to `packages`
## releases the bundle and drops the command. A declared command missing from
## the bundle fails realization (`EBuiltinBinaryMissing`, naming the package
## and the path) with nothing placed or published, and a
## profile `binaries` name (as a dotfiles `apps.toml` row declares it) the application does not provide is refused at
## plan time, before anything is downloaded.
##
## Falsifying mutations (performed): making `addApplicationCommands` skip the
## declared commands (the pre-fix behaviour, `extraExecutable` on an
## application silently ignored) turns the command test red at the first
## launcher check, and the `binaries` test red (the refusal then names
## `gm4ccli`, which is no longer provided). Dropping the `binaries` check
## alone (the pre-fix acceptance) turns the `binaries` test red: the apply
## succeeds and places the application.
##
## Never touches the real `~/Applications` or `/Applications`: the apply's
## home is a temporary directory.

when defined(macosx):
  import std/[os, osproc, strutils, tempfiles, unittest]

  import repro_project_dsl
  import repro_local_store
  import repro_home_apply
  from repro_home_apply/builtin_adapter import EBuiltinBinaryMissing
  import repro_home_generations
  import repro_home_intent
  import repro_home_resources
  import repro_home_rollback
  import repro_test_support/macos_app_fixtures

  const
    AppName = "GM4cFixture"
    AppId = "dev.reprobuild.gm4c.e2e"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let fixtureRoot = createTempDir("repro-gm4c-e2e-fixture-", "")

  proc appRecord(dmg, version: string): TarballProvisioningDef =
    let sha = sha256Of(dmg)
    TarballProvisioningDef(url: "file://" & dmg, sha256: sha,
      archiveType: "dmg",
      executablePath: AppName & ".app/Contents/MacOS/" & AppName,
      packageId: "gm4capp@" & version,
      lockIdentity: "tarball:gm4capp@" & version & ":macos-any:sha256:" & sha,
      cpu: "any", os: "macos",
      detail: TarballArchiveDetail(version: version,
        installMethod: "app-bundle", appBundle: AppName & ".app",
        bundleId: AppId, teamId: FixtureTeamId))

  # The fixture archives: v1 and v2 of the application (different versions,
  # so different code-directory hashes), and a tampered v1.
  let appV1 = makeFixtureApp(fixtureRoot / "v1", AppName, AppId, "1.0.0")
  let appV2 = makeFixtureApp(fixtureRoot / "v2", AppName, AppId, "2.0.0")
  let appBad = makeFixtureApp(fixtureRoot / "bad", "GM4cBad", AppId, "1.0.0")
  tamperFixtureApp(appBad)
  let dmgV1 = makeFixtureDmg(fixtureRoot, "gm4c-1.0.0.dmg", [appV1])
  let dmgV2 = makeFixtureDmg(fixtureRoot, "gm4c-2.0.0.dmg", [appV2], "APFS")
  let dmgBad = makeFixtureDmg(fixtureRoot, "gm4c-bad.dmg", [appBad])
  # An application carrying a command-line tool inside its bundle, the way
  # Visual Studio Code carries `code`. The tool prints its own path, so the
  # test can tell which copy of the bundle a launcher ran.
  const
    CliAppName = "GM4cCli"
    CliAppId = "dev.reprobuild.gm4c.cli"
    CliCommandInBundle = "Contents/Resources/bin/gm4ccli"
    CliCommand = CliAppName & ".app/" & CliCommandInBundle
  let appCli = makeFixtureApp(fixtureRoot / "cli", CliAppName, CliAppId,
    "1.0.0", commands = [(path: CliCommandInBundle,
      body: "#!/bin/sh\necho \"gm4ccli 1.0.0 $0 $*\"\n")])
  let dmgCli = makeFixtureDmg(fixtureRoot, "gm4c-cli-1.0.0.dmg", [appCli])
  let identityV1 = appBundleCanonicalBytes(readAppBundleIdentity(appV1))
  let identityV2 = appBundleCanonicalBytes(readAppBundleIdentity(appV2))

  # A plain command-line package every profile below names, so the
  # application can be removed while the profile keeps realizing something.
  let basePayload = fixtureRoot / "gm4cbase"
  writeFile(basePayload, "#!/bin/sh\necho gm4cbase\n")
  setFilePermissions(basePayload, {fpUserRead, fpUserWrite, fpUserExec})

  proc registerFixtures(appVersion: string) =
    ## (Re)register the fixture definitions. ``appVersion`` selects which
    ## disk image ``gm4capp`` is realized from — a definition update, the
    ## way a contribution is bumped.
    resetPackageRegistry()
    registerPackageDef(PackageDef(packageName: "gm4cbase",
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[TarballProvisioningDef(
        url: "file://" & basePayload, sha256: sha256Of(basePayload),
        archiveType: "raw", executablePath: "gm4cbase",
        packageId: "gm4cbase@1.0", lockIdentity: "fixture:gm4cbase@1.0",
        detail: TarballArchiveDetail(version: "1.0"))]))
    registerPackageDef(PackageDef(packageName: "gm4capp",
      sourceFile: currentSourcePath(), sourceLine: 2,
      tarballProvisioning: @[
        if appVersion == "2.0.0": appRecord(dmgV2, "2.0.0")
        else: appRecord(dmgV1, "1.0.0")]))
    proc cliRecord(package: string; commands: seq[string]):
        TarballProvisioningDef =
      let sha = sha256Of(dmgCli)
      TarballProvisioningDef(url: "file://" & dmgCli, sha256: sha,
        archiveType: "dmg",
        executablePath: CliAppName & ".app/Contents/MacOS/" & CliAppName,
        packageId: package & "@1.0.0",
        lockIdentity: "tarball:" & package & "@1.0.0:macos-any:sha256:" & sha,
        cpu: "any", os: "macos",
        detail: TarballArchiveDetail(version: "1.0.0",
          installMethod: "app-bundle", appBundle: CliAppName & ".app",
          bundleId: CliAppId, teamId: FixtureTeamId,
          extraExecutables: commands))
    registerPackageDef(PackageDef(packageName: "gm4ccliapp",
      sourceFile: currentSourcePath(), sourceLine: 4,
      tarballProvisioning: @[cliRecord("gm4ccliapp", @[CliCommand])]))
    # The same bundle, declaring a command it does not carry.
    registerPackageDef(PackageDef(packageName: "gm4cclimissing",
      sourceFile: currentSourcePath(), sourceLine: 5,
      tarballProvisioning: @[cliRecord("gm4cclimissing",
        @[CliAppName & ".app/Contents/Resources/bin/absent"])]))
    var bad = appRecord(dmgBad, "1.0.0")
    bad.executablePath = "GM4cBad.app/Contents/MacOS/GM4cBad"
    bad.packageId = "gm4cbad@1.0.0"
    bad.lockIdentity = "tarball:gm4cbad@1.0.0"
    bad.detail.appBundle = "GM4cBad.app"
    registerPackageDef(PackageDef(packageName: "gm4cbad",
      sourceFile: currentSourcePath(), sourceLine: 3,
      tarballProvisioning: @[bad]))

  proc writeProfile(root: string; packages: openArray[string];
                    marker = ""; applies = "") =
    ## ``marker``, when set, adds an `fs.userFile` resource writing it to
    ## `~/.gm4c-marker`. ``applies``, when set, declares this host with that
    ## `applies:` list (GM7 concern-scoped apply).
    var text = "import repro/profile\n\nprofile \"gm4cApps\":\n" &
      "  adapterPreference:\n    darwin: [tarball]\n\n" &
      "  activity default:\n"
    for p in packages:
      text.add("    " & p & "\n")
    if applies.len > 0:
      text.add("\n  hosts:\n    \"" & currentHost() & "\":\n" &
        "      activities: [default]\n      applies: [" & applies & "]\n")
    if marker.len > 0:
      text.add("\n  resources:\n    fs.userFile marker:\n" &
        "      hostFile = \"~/.gm4c-marker\"\n" &
        "      content = \"" & marker & "\"\n")
    writeFile(root / "profile" / "home.nim", text)

  proc applyOptions(root: string; at: int64): ApplyOptions =
    result.profileDir = root / "profile"
    result.profilePath = root / "profile" / "home.nim"
    result.stateDir = root / "state"
    result.storeRoot = root / "store"
    result.homeDir = root / "home"
    result.host = currentHost()
    result.activationTimestamp = at
    result.appTrust = Relaxed

  proc newRoot(label: string): string =
    result = createTempDir("repro-gm4c-e2e-" & label & "-", "")
    for d in ["profile", "state", "store", "home"]:
      createDir(result / d)

  template withApplyEnv(root: string; body: untyped) =
    ## A real apply into ``root``: no shared binary cache, and the POSIX PATH
    ## rc file inside the scratch home.
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
    putEnv("REPRO_CACHE_DISABLE", "1")
    putEnv("REPRO_HOME_POSIX_PATH_RC", root / "home" / ".profile-path-rc")
    try:
      body
    finally:
      if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
      else: delEnv("REPRO_CACHE_DISABLE")
      if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
      else: delEnv("REPRO_HOME_POSIX_PATH_RC")

  proc placedApp(root: string): string =
    root / "home" / "Applications" / (AppName & ".app")

  proc appBindings(stateDir, storeRoot, generationId: string):
      seq[ResourceBinding] =
    ## The `macos.appBundle` bindings a generation's manifest records.
    var store = openStore(storeRoot)
    defer: store.close()
    let envelope = readPointerFile(pointerPath(stateDir, generationId))
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    let manifest = decodeManifestBytes(readCasBlob(store, key))
    for rb in manifest.resourceBindings:
      if rb.resourceKind == $rkMacosAppBundle:
        result.add(rb)

  proc storeHasPackage(storeRoot, packageName: string): bool =
    var store = openStore(storeRoot)
    defer: store.close()
    for row in listPrefixes(store):
      if row.packageName == packageName:
        return true

  proc withBinaries(opts: ApplyOptions; package: string;
                    binaries: seq[string]): ApplyOptions =
    ## ``opts`` with its profile pre-loaded and ``binaries`` declared on the
    ## reference to ``package`` -- what the compiled profile carries for
    ## `package(<id>, binaries = @[...])` or a data-file row's `binaries`
    ## (`adapter_home`). The text reader this test's applies otherwise use
    ## reads neither, so the declaration is set on the parsed reference.
    result = opts
    let profile = loadProfile(opts.profilePath)
    var found = false
    for activity in profile.root.children:
      if activity.kind != nkActivity:
        continue
      for child in activity.activityChildren:
        if child.kind == nkPackageRef and child.packageName == package:
          child.packageBinaries = binaries
          found = true
    doAssert found, "the profile names no package " & package
    result.preLoadedProfile = profile

  proc profileBin(root: string): string =
    ## The home profile's bin directory: the active generation's.
    root / "state" / "current" / "bin"

  proc runCommand(path: string; args: openArray[string] = []):
      tuple[output: string; exitCode: int] =
    execCmdEx(quoteShellCommand(@[path] & @args))

  suite "GM4c: e2e_dmg_app_bundle_install_and_rollback":

    test "an application's declared command runs from the profile bin " &
        "directory against the placed bundle, and leaves with it":
      let root = newRoot("command")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase"])
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied
        check not fileExists(profileBin(root) / "gm4ccli")

        writeProfile(root, ["gm4cbase", "gm4ccliapp"])
        let genB = runApply(applyOptions(root, 2000))
        check genB.kind == aokFreshApplied
        let placed = root / "home" / "Applications" / (CliAppName & ".app")
        check dirExists(placed)
        # The command is a launcher in the profile bin directory, and it runs
        # the copy in ~/Applications, not the store copy.
        let launcher = profileBin(root) / "gm4ccli"
        check fileExists(launcher)
        let ran = runCommand(launcher, ["--version"])
        checkpoint ran.output
        check ran.exitCode == 0
        check ran.output.strip() == "gm4ccli 1.0.0 " &
          (placed / CliCommandInBundle) & " --version"
        # The package's own launcher runs the placed copy too.
        check fileExists(profileBin(root) / "gm4ccliapp")
        let appLauncher = readFile(profileBin(root) / "gm4ccliapp")
        check (placed / "Contents" / "MacOS" / CliAppName) in appLauncher
        check (root / "store") notin appLauncher.splitLines()[^2]
        # `--plan` lists the command, so the preview shows what apply wrote.
        let preview = runApplyPlan(applyOptions(root, 2100))
        var plannedCommand = false
        for item in preview.items:
          if item.category == "launcher" and item.name == "gm4ccli":
            plannedCommand = true
        check plannedCommand
        check preview.isNoOp

        # Rollback to A removes the command with the bundle.
        discard runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genA.generationIdHex,
          activationTimestamp: 3000))
        check not dirExists(placed)
        check not fileExists(profileBin(root) / "gm4ccli")
        check not fileExists(profileBin(root) / "gm4ccliapp")
        # Rolling forward to B restores both.
        discard runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genB.generationIdHex,
          activationTimestamp: 4000))
        check dirExists(placed)
        let again = runCommand(profileBin(root) / "gm4ccli")
        check again.exitCode == 0
        check again.output.strip() == "gm4ccli 1.0.0 " &
          (placed / CliCommandInBundle)

        # Narrowing the host to `packages` releases the bundle (left in
        # place for the tool that now owns applications) and its commands
        # leave the profile bin directory with the concern.
        writeProfile(root, ["gm4cbase", "gm4ccliapp"], applies = "packages")
        let narrowed = runApply(applyOptions(root, 5000))
        check narrowed.kind == aokFreshApplied
        check dirExists(placed)
        check not fileExists(profileBin(root) / "gm4ccli")
        check fileExists(profileBin(root) / "gm4cbase")
      removeDir(root)

    test "a declared command the bundle does not carry is refused at " &
        "realization; nothing is placed or published":
      let root = newRoot("command-missing")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase"])
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied
        writeProfile(root, ["gm4cbase", "gm4cclimissing"])
        var refused = false
        try:
          discard runApply(applyOptions(root, 2000))
        except EBuiltinBinaryMissing as err:
          refused = true
          checkpoint err.msg
          check err.step == 7
          check err.packageId == "gm4cclimissing"
          check err.missingPath == CliAppName &
            ".app/Contents/Resources/bin/absent"
          check "is not in the bundle" in err.msg
        check refused
        check not dirExists(root / "home" / "Applications" /
          (CliAppName & ".app"))
        check not storeHasPackage(root / "store", "gm4cclimissing")
        check readCurrentGenerationId(root / "state") == genA.generationIdHex
        check attachedImagesOf(dmgCli).len == 0
      removeDir(root)

    test "a profile `binaries` name the application does not provide is " &
        "refused at plan time, before anything is realized":
      let root = newRoot("binaries")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase", "gm4ccliapp"])
        let declared = withBinaries(applyOptions(root, 1000), "gm4ccliapp",
          @["gm4ccli", "gm4cnope"])
        var refused = false
        try:
          discard runApply(declared)
        except EApplyPackageCommandRefused as err:
          refused = true
          checkpoint err.msg
          check err.packageId == "gm4ccliapp"
          check err.commandName == "gm4cnope"
          check err.reason == "undeclared-binary"
          check err.realization.startsWith("tarball:gm4ccliapp@1.0.0:")
          check "gm4ccliapp, gm4ccli" in err.msg
        check refused
        # `--plan` refuses the same way.
        expect EApplyPackageCommandRefused:
          discard runApplyPlan(declared)
        check not storeHasPackage(root / "store", "gm4ccliapp")
        check not dirExists(root / "home" / "Applications")
        check readCurrentGenerationId(root / "state").len == 0
        # A name the application does provide is accepted.
        check runApply(withBinaries(applyOptions(root, 2000), "gm4ccliapp",
          @["gm4ccli"])).kind == aokFreshApplied
        check fileExists(profileBin(root) / "gm4ccli")
      removeDir(root)

    test "a DMG-realized package installs its app bundle into " &
        "~/Applications, upgrades, and rollback restores then removes it":
      let root = newRoot("lifecycle")
      withApplyEnv(root):
        # Generation A: no application.
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase"])
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied
        check not dirExists(placedApp(root))

        # Generation B: the application, v1, from an HFS+ disk image.
        writeProfile(root, ["gm4cbase", "gm4capp"])
        let genB = runApply(applyOptions(root, 2000))
        check genB.kind == aokFreshApplied
        let app = placedApp(root)
        check dirExists(app)
        # Vacuity guard: the placed bundle is the contribution's bundle and
        # the realized one.
        check plistValue(app, "CFBundleIdentifier") == AppId
        check plistValue(app, "CFBundleShortVersionString") == "1.0.0"
        let placedV1 = appBundleCanonicalBytes(readAppBundleIdentity(app))
        check placedV1 == identityV1
        discard verifyAppBundle(app, AppBundleExpectation(bundleId: AppId,
          version: "1.0.0", teamId: FixtureTeamId), Relaxed)
        # Realized in the store: the prefix holds the bundle at its root.
        var realizedBundle = ""
        block:
          var store = openStore(root / "store")
          defer: store.close()
          for row in listPrefixes(store):
            if row.packageName == "gm4capp":
              realizedBundle = store.absolutePrefixPath(row.realizedPath) /
                (AppName & ".app")
        check realizedBundle.len > 0 and dirExists(realizedBundle)
        check appBundleCanonicalBytes(readAppBundleIdentity(
          realizedBundle)) == identityV1
        # The generation records the placement.
        let bindingsB = appBindings(root / "state", root / "store",
          genB.generationIdHex)
        check bindingsB.len == 1
        check bindingsB[0].resourceAddress == "home.package.gm4capp.app"
        check bindingsB[0].realWorldIdentity == app
        check bindingsB[0].payloadBytes == identityV1
        # The disk image is not left attached.
        check attachedImagesOf(dmgV1).len == 0

        # Re-applying the same profile is a verified no-op.
        let again = runApply(applyOptions(root, 2500))
        check again.kind == aokNoOpVerified
        check again.generationIdHex == genB.generationIdHex

        # Generation C: the definition is bumped to v2 (an APFS image); the
        # lock pins v1, so the upgrade is an explicit --relock.
        registerFixtures("2.0.0")
        var upgrade = applyOptions(root, 3000)
        upgrade.relock = true
        let genC = runApply(upgrade)
        check genC.kind == aokFreshApplied
        check plistValue(app, "CFBundleShortVersionString") == "2.0.0"
        check appBundleCanonicalBytes(readAppBundleIdentity(app)) ==
          identityV2
        check attachedImagesOf(dmgV2).len == 0

        # Rollback to B re-places v1 from B's store prefix.
        let back = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genB.generationIdHex,
          activationTimestamp: 4000))
        check back.toGenerationIdHex == genB.generationIdHex
        check back.resourceOpsApplied >= 1
        check plistValue(app, "CFBundleShortVersionString") == "1.0.0"
        check appBundleCanonicalBytes(readAppBundleIdentity(app)) ==
          identityV1

        # Rollback to A removes the application.
        let outRoll = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genA.generationIdHex,
          activationTimestamp: 5000))
        check outRoll.toGenerationIdHex == genA.generationIdHex
        check not dirExists(app)
        check not symlinkExists(app)
        # Nothing else was left in the Applications directory.
        var leftovers: seq[string] = @[]
        if dirExists(root / "home" / "Applications"):
          for kind, path in walkDir(root / "home" / "Applications",
              relative = true):
            leftovers.add(path)
        check leftovers.len == 0
      removeDir(root)

    test "negative control: a DMG whose bundle's signature does not " &
        "verify is refused, nothing is placed, nothing stays attached":
      let root = newRoot("tampered")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase"])
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied
        writeProfile(root, ["gm4cbase", "gm4cbad"])
        var refused = false
        try:
          discard runApply(applyOptions(root, 2000))
        except EApplyRealizeFailed as err:
          refused = true
          checkpoint err.msg
          check err.packageId == "gm4cbad"
          check "refused (signature)" in err.msg
          check "sealed resource" in err.msg
        check refused
        check not dirExists(root / "home" / "Applications" / "GM4cBad.app")
        check attachedImagesOf(dmgBad).len == 0
        check not storeHasPackage(root / "store", "gm4cbad")
        check readCurrentGenerationId(root / "state") == genA.generationIdHex
      removeDir(root)

    test "an app the user placed at the same path is never replaced":
      let root = newRoot("collision")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        let mine = placedApp(root)
        createDir(mine / "Contents")
        writeFile(mine / "Contents" / "user-owned", "mine")
        writeProfile(root, ["gm4cbase", "gm4capp"])
        var refused = false
        try:
          discard runApply(applyOptions(root, 1000))
        except EAppBundleCollision as err:
          refused = true
          checkpoint err.msg
          check err.targetPath == mine
          check "repro home adopt home.package.gm4capp.app" in err.msg
        check refused
        check readFile(mine / "Contents" / "user-owned") == "mine"
        check readCurrentGenerationId(root / "state").len == 0
      removeDir(root)

    test "a staged copy that fails verification fails the apply with a " &
        "structured error naming package, bundle and check; nothing is " &
        "placed and nothing is left behind":
      let first = newRoot("staged-source")
      let second = newRoot("staged-refused")
      withApplyEnv(first):
        registerFixtures("1.0.0")
        writeProfile(first, ["gm4cbase", "gm4capp"])
        let placed = runApply(applyOptions(first, 1000))
        check placed.kind == aokFreshApplied
        check dirExists(placedApp(first))
      # Change a sealed resource of the REALIZED bundle in the store, after
      # it passed every check and was published.
      var storeBundle = ""
      block:
        var store = openStore(first / "store")
        defer: store.close()
        for row in listPrefixes(store):
          if row.packageName == "gm4capp":
            storeBundle = store.absolutePrefixPath(row.realizedPath) /
              (AppName & ".app")
      check storeBundle.len > 0 and dirExists(storeBundle)
      let payload = storeBundle / "Contents" / "Resources" / "payload.txt"
      setFilePermissions(payload, {fpUserRead, fpUserWrite})
      setFilePermissions(payload.parentDir,
        {fpUserRead, fpUserWrite, fpUserExec})
      tamperFixtureApp(storeBundle)
      withApplyEnv(second):
        writeProfile(second, ["gm4cbase", "gm4capp"])
        var opts = applyOptions(second, 2000)
        opts.storeRoot = first / "store"
        var refused = false
        try:
          discard runApply(opts)
        except EApplyAppBundleFailed as err:
          refused = true
          checkpoint err.msg
          check err.step == 9
          check err.stepName == "place_app_bundle"
          check err.packageId == "gm4capp"
          check err.resourceAddress == "home.package.gm4capp.app"
          check err.bundleName == AppName & ".app"
          check err.targetPath == placedApp(second)
          check err.check == "signature"
          check "package gm4capp" in err.msg
          check AppName & ".app" in err.msg
          check "signature check" in err.msg
          check "sealed resource" in err.msg
        except CatchableError as err:
          checkpoint "unstructured failure: " & $err.name & ": " & err.msg
        check refused
        # Nothing placed, the staged copy gone, and the Applications
        # directory the placement created removed again.
        check not dirExists(placedApp(second))
        check not dirExists(second / "home" / "Applications")
        check readCurrentGenerationId(second / "state").len == 0
        check attachedImagesOf(dmgV1).len == 0
      # The first home's bundle is untouched by the refused placement.
      check dirExists(placedApp(first))
      check appBundleCanonicalBytes(readAppBundleIdentity(
        placedApp(first))) == identityV1
      removeDir(second)
      removeDir(first)

    test "a rollback whose earlier bundle fails verification fails with " &
        "a structured error and leaves the current generation intact":
      let root = newRoot("rollback-refused")
      withApplyEnv(root):
        # Generation B: v1. Generation C: v2 plus a file resource, which a
        # rollback to B would remove.
        registerFixtures("1.0.0")
        writeProfile(root, ["gm4cbase", "gm4capp"])
        let genB = runApply(applyOptions(root, 1000))
        check genB.kind == aokFreshApplied
        registerFixtures("2.0.0")
        writeProfile(root, ["gm4cbase", "gm4capp"], marker = "from C")
        var upgrade = applyOptions(root, 2000)
        upgrade.relock = true
        let genC = runApply(upgrade)
        check genC.kind == aokFreshApplied
        let app = placedApp(root)
        let marker = root / "home" / ".gm4c-marker"
        check appBundleCanonicalBytes(readAppBundleIdentity(app)) ==
          identityV2
        check readFile(marker) == "from C"
        # Change a sealed resource of B's bundle in the store (v1's prefix).
        var storeV1 = ""
        block:
          var store = openStore(root / "store")
          defer: store.close()
          for row in listPrefixes(store):
            let bundle = store.absolutePrefixPath(row.realizedPath) /
              (AppName & ".app")
            if row.packageName == "gm4capp" and
                plistValue(bundle, "CFBundleShortVersionString") == "1.0.0":
              storeV1 = bundle
        check storeV1.len > 0 and dirExists(storeV1)
        let payload = storeV1 / "Contents" / "Resources" / "payload.txt"
        setFilePermissions(payload, {fpUserRead, fpUserWrite})
        setFilePermissions(payload.parentDir,
          {fpUserRead, fpUserWrite, fpUserExec})
        tamperFixtureApp(storeV1)

        var refused = false
        try:
          discard runRollback(RollbackOptions(stateDir: root / "state",
            storeRoot: root / "store", homeDir: root / "home",
            targetGenerationId: genB.generationIdHex,
            activationTimestamp: 3000))
        except ERollbackAppBundleFailed as err:
          refused = true
          checkpoint err.msg
          check err.packageId == "gm4capp"
          check err.resourceAddress == "home.package.gm4capp.app"
          check err.bundleName == AppName & ".app"
          check err.targetPath == app
          check err.check == "signature"
          check err.targetGenerationIdHex == genB.generationIdHex
          check "package gm4capp" in err.msg
          check "signature check" in err.msg
          check "sealed resource" in err.msg
        except CatchableError as err:
          checkpoint "unstructured failure: " & $err.name & ": " & err.msg
        check refused
        # The current generation is intact: still active, its bundle (v2)
        # in place, its file resource not removed, nothing staged beside
        # the bundle, no disk image attached.
        check readCurrentGenerationId(root / "state") == genC.generationIdHex
        check dirExists(app)
        check appBundleCanonicalBytes(readAppBundleIdentity(app)) ==
          identityV2
        check fileExists(marker) and readFile(marker) == "from C"
        var entries: seq[string] = @[]
        for kind, path in walkDir(root / "home" / "Applications",
            relative = true):
          entries.add(path)
        check entries == @[AppName & ".app"]
        check attachedImagesOf(dmgV1).len == 0
        check attachedImagesOf(dmgV2).len == 0
      removeDir(root)

  removeDir(fixtureRoot)
