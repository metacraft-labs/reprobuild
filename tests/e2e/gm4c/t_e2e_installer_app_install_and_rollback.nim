## Installer applications: e2e_installer_app_install_and_rollback.
##
## A package whose macOS realization is an installer APPLICATION (the
## OpenWebStart shape: an installer `.app` on a disk image that installs a
## folder holding the product bundle) is installed by a real `repro home
## apply` into `~/Applications` of a SCRATCH home -- the installer runs
## confined under `sandbox-exec`, its product folder is verified, published
## and placed as a whole -- then upgraded, rolled back to the previous version
## (the folder re-placed from that generation's store prefix and verified
## against the folder identity it recorded) and rolled back out entirely
## (Store-And-Installation-Layout.md § macOS Application Bundles,
## "Installer applications").
##
## The whole pipeline runs for real, as in
## `t_e2e_dmg_app_bundle_install_and_rollback`: selection, the home archive
## realizer (download from `file://`, sha256, `hdiutil`, `codesign`,
## `sandbox-exec`), the store, the `macos.appBundle` resource lifecycle, the
## generation manifest and `repro home rollback`'s executor.
##
## FIXTURES. The installer application is built at test time
## (`macos_app_fixtures.makeFixtureInstallerApp`): an ad-hoc signed bundle
## whose main executable is a shell script implementing install4j's
## unattended `-dir` protocol, carrying a product folder of real compiled,
## signed bundles. A real install4j installer cannot be built here; the
## genuine one is realized by reprobuild-packages' `verify-macos-apps`.
## TRUST POLICY: `ApplyOptions.appTrust` relaxes exactly the Developer ID
## and notarization checks, which nothing built at test time can pass (the
## same justification as the GM4c e2e test); signature integrity, team and
## identity checks run for real.
##
## Vacuity guard: the folder placed in the scratch `~/Applications` holds the
## product bundle with the declared identifier and version, the generation
## records the folder identity (not the bundle's), and after the upgrade and
## the rollbacks the version on disk is the one each generation recorded.
##
## Never touches the real `~/Applications` or `/Applications`.

when defined(macosx):
  import std/[os, strutils, tempfiles, unittest]

  import repro_project_dsl
  import repro_local_store
  import repro_home_apply
  import repro_home_generations
  import repro_home_intent
  import repro_home_resources
  import repro_home_rollback
  import repro_test_support/macos_app_fixtures

  const
    Item = "InstFixture"
    MainName = "InstFixture"
    AppId = "dev.reprobuild.installerapp.e2e"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let fixtureRoot = createTempDir("repro-installer-e2e-fixture-", "")

  proc installerDmg(version: string): string =
    let dir = fixtureRoot / version
    let product = makeFixtureProductFolder(dir / "product", Item, MainName,
      AppId, version)
    let installer = makeFixtureInstallerApp(dir / "installer",
      "InstFixture Installer", product)
    makeFixtureDmg(fixtureRoot, "installer-" & version & ".dmg", [installer])

  let dmgV1 = installerDmg("1.0.0")
  let dmgV2 = installerDmg("2.0.0")

  proc appRecord(dmg, version: string): TarballProvisioningDef =
    let sha = sha256Of(dmg)
    TarballProvisioningDef(url: "file://" & dmg, sha256: sha,
      archiveType: "dmg",
      executablePath: Item & "/" & MainName & ".app/Contents/MacOS/" &
        MainName,
      packageId: "instapp@" & version,
      lockIdentity: "tarball:instapp@" & version & ":macos-any:sha256:" & sha,
      cpu: "any", os: "macos",
      detail: TarballArchiveDetail(version: version,
        installMethod: "installer-silent",
        installerApp: "InstFixture Installer.app",
        installerArgs: @["-q", "-dir", "${install_dir}/" & Item],
        appBundle: Item & "/" & MainName & ".app", bundleId: AppId,
        teamId: FixtureTeamId))

  let basePayload = fixtureRoot / "instbase"
  writeFile(basePayload, "#!/bin/sh\necho instbase\n")
  setFilePermissions(basePayload, {fpUserRead, fpUserWrite, fpUserExec})

  proc registerFixtures(appVersion: string) =
    resetPackageRegistry()
    registerPackageDef(PackageDef(packageName: "instbase",
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[TarballProvisioningDef(
        url: "file://" & basePayload, sha256: sha256Of(basePayload),
        archiveType: "raw", executablePath: "instbase",
        packageId: "instbase@1.0", lockIdentity: "fixture:instbase@1.0",
        detail: TarballArchiveDetail(version: "1.0"))]))
    registerPackageDef(PackageDef(packageName: "instapp",
      sourceFile: currentSourcePath(), sourceLine: 2,
      tarballProvisioning: @[
        if appVersion == "2.0.0": appRecord(dmgV2, "2.0.0")
        else: appRecord(dmgV1, "1.0.0")]))

  proc writeProfile(root: string; packages: openArray[string]) =
    var text = "import repro/profile\n\nprofile \"instApps\":\n" &
      "  adapterPreference:\n    darwin: [tarball]\n\n" &
      "  activity default:\n"
    for p in packages:
      text.add("    " & p & "\n")
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
    result = createTempDir("repro-installer-e2e-" & label & "-", "")
    for d in ["profile", "state", "store", "home"]:
      createDir(result / d)

  template withApplyEnv(root: string; body: untyped) =
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

  proc appBindings(stateDir, storeRoot, generationId: string):
      seq[ResourceBinding] =
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

  proc mainVersion(folder: string): string =
    plistValue(folder / (MainName & ".app"), "CFBundleShortVersionString")

  suite "installer applications: e2e_installer_app_install_and_rollback":

    test "an installer application's product folder is installed into " &
        "~/Applications, upgraded, and rollback restores then removes it":
      let root = newRoot("lifecycle")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["instbase"])
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied

        writeProfile(root, ["instbase", "instapp"])
        let genB = runApply(applyOptions(root, 2000))
        check genB.kind == aokFreshApplied
        let placed = root / "home" / "Applications" / Item
        check dirExists(placed / (MainName & ".app"))
        check dirExists(placed / (Item & " Helper.app"))
        check fileExists(placed / "readme.txt")
        check plistValue(placed / (MainName & ".app"),
          "CFBundleIdentifier") == AppId
        check mainVersion(placed) == "1.0.0"
        let identityV1 = readPlacedItemIdentityBytes(placed)
        var folderText = ""
        for b in identityV1: folderText.add(char(b))
        check folderText.startsWith(AppFolderIdentityFormat & "\n")
        let bindingsB = appBindings(root / "state", root / "store",
          genB.generationIdHex)
        check bindingsB.len == 1
        check bindingsB[0].resourceAddress == "home.package.instapp.app"
        check bindingsB[0].realWorldIdentity == placed
        check bindingsB[0].payloadBytes == identityV1
        check attachedImagesOf(dmgV1).len == 0

        # Re-applying is a verified no-op (the folder identity re-observes
        # equal).
        let again = runApply(applyOptions(root, 2500))
        check again.kind == aokNoOpVerified

        registerFixtures("2.0.0")
        var upgrade = applyOptions(root, 3000)
        upgrade.relock = true
        let genC = runApply(upgrade)
        check genC.kind == aokFreshApplied
        check mainVersion(placed) == "2.0.0"
        check readPlacedItemIdentityBytes(placed) != identityV1

        let back = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genB.generationIdHex,
          activationTimestamp: 4000))
        check back.toGenerationIdHex == genB.generationIdHex
        check mainVersion(placed) == "1.0.0"
        check readPlacedItemIdentityBytes(placed) == identityV1

        let outRoll = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genA.generationIdHex,
          activationTimestamp: 5000))
        check outRoll.toGenerationIdHex == genA.generationIdHex
        check not dirExists(placed)
        var leftovers: seq[string] = @[]
        if dirExists(root / "home" / "Applications"):
          for _, path in walkDir(root / "home" / "Applications",
              relative = true):
            leftovers.add(path)
        check leftovers.len == 0
      removeDir(root)

    test "the plan names the folder an installer application places":
      let root = newRoot("plan")
      withApplyEnv(root):
        registerFixtures("1.0.0")
        writeProfile(root, ["instbase", "instapp"])
        let plan = runApplyPlan(applyOptions(root, 1000))
        var found = false
        for item in plan.items:
          if item.category == "app-bundle":
            check item.name == root / "home" / "Applications" / Item
            check item.action == piaCreate
            found = true
        check found
      removeDir(root)

  removeDir(fixtureRoot)
