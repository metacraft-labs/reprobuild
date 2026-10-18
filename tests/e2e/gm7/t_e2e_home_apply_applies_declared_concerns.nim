## GM7: e2e_home_apply_applies_declared_concerns.
##
## A home profile whose `hosts:` entry for the applying host declares
## `applies: [applications]` (reprobuild-pm spec
## Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply) is applied
## by a real `repro home apply` pipeline into a SCRATCH home:
##
## * the application -- a package realized from a disk image -- is placed in
##   `~/Applications`;
## * nothing of the other concerns is written: no stow link (`files`), no
##   `fs.userFile` (`files`), no managed block (`environment`), and the plain
##   command-line package (`packages`) is not realized into the store;
## * a package with NO realization, in the `packages` concern the host does
##   not apply, does not fail the apply;
## * `--plan` shows every operation of the other concerns under `not
##   applied`, and none of them counts as drift;
## * the generation records the concern set (activation manifest schema 3,
##   `ownedConcerns == ["applications"]`), and the set is part of the
##   generation id;
## * narrowing -- a generation that applied everything, then the
##   declaration -- RELEASES what the other concerns placed: left in place,
##   not recorded, never removed; rollback to the full generation restores
##   the records, and rollback back to the narrowed generation releases them
##   again instead of removing them.
##
## Negative control: the SAME profile without the declaration fails at
## step 7 on the package with no realization, exactly as before; and
## without that package it applies every concern (stow link, user file,
## managed block, the command-line package realized, the application
## placed) -- today's behaviour, unchanged.
##
## Falsifying mutation (performed for GM7; see the milestone record):
## making `appliedConcernsFor` ignore the declaration (always every concern)
## turns the first test red at the step-7 failure on the package with no
## realization; with that package removed from the profile as well, the
## stow link and the user file are written -- the assertions below that
## they are absent are what catch it.
##
## Nothing is mocked. The profile is compiled the way `repro home apply`
## compiles it (the profile-compile edge driven through the built
## `build/bin/repro`, the RBPI envelope, `expandedHomeProfile`), so the
## declaration travels the production path.
## The pipeline runs for real: selection, the home
## archive realizer (`file://` download, sha256, `hdiutil attach`, the trust
## checks with the real `codesign`), the store, stow discovery, the resource
## lifecycle, the generation manifest and `repro home rollback`'s executor.
## The fixture packages are registered in this test process, standing in for
## the engine's linked definitions, as the GM4b / GM4c e2e tests do.
##
## TRUST POLICY -- the one relaxation, and why it is not a mock: identical to
## `t_e2e_dmg_app_bundle_install_and_rollback` (GM4c). The fixture bundle is
## built and ad-hoc signed at test time, so it cannot carry an Apple
## Developer ID chain or a notarization ticket; `ApplyOptions.appTrust`
## relaxes exactly those two checks. Bundle id, version, signature integrity
## and team equality run for real. No CLI path sets `appTrust`.
##
## Never touches the real home: every apply's home, state and store are
## temporary directories.

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
  import repro_profile_compile
  import repro_profile_intent
  from repro_test_support import reproBinaryPath, ReprobuildRepoRoot

  const
    AppName = "GM7Fixture"
    AppId = "dev.reprobuild.gm7.e2e"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}
    MissingPackage = "gm7nowhere"
      ## Defined by nothing: the plan reports it `missing`.

  let fixtureRoot = createTempDir("repro-gm7-e2e-fixture-", "")
  let host = currentHost()

  let app = makeFixtureApp(fixtureRoot / "v1", AppName, AppId, "1.0.0")
  let dmg = makeFixtureDmg(fixtureRoot, "gm7-1.0.0.dmg", [app])
  let appIdentity = appBundleCanonicalBytes(readAppBundleIdentity(app))

  let basePayload = fixtureRoot / "gm7base"
  writeFile(basePayload, "#!/bin/sh\necho gm7base\n")
  setFilePermissions(basePayload, {fpUserRead, fpUserWrite, fpUserExec})

  proc registerFixtures() =
    resetPackageRegistry()
    registerPackageDef(PackageDef(packageName: "gm7base",
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[TarballProvisioningDef(
        url: "file://" & basePayload, sha256: sha256Of(basePayload),
        archiveType: "raw", executablePath: "gm7base",
        packageId: "gm7base@1.0", lockIdentity: "fixture:gm7base@1.0",
        detail: TarballArchiveDetail(version: "1.0"))]))
    let sha = sha256Of(dmg)
    registerPackageDef(PackageDef(packageName: "gm7app",
      sourceFile: currentSourcePath(), sourceLine: 2,
      tarballProvisioning: @[TarballProvisioningDef(url: "file://" & dmg,
        sha256: sha, archiveType: "dmg",
        executablePath: AppName & ".app/Contents/MacOS/" & AppName,
        packageId: "gm7app@1.0.0",
        lockIdentity: "tarball:gm7app@1.0.0:macos-any:sha256:" & sha,
        cpu: "any", os: "macos",
        detail: TarballArchiveDetail(version: "1.0.0",
          installMethod: "app-bundle", appBundle: AppName & ".app",
          bundleId: AppId, teamId: FixtureTeamId))]))

  proc writeProfile(root: string; applies: string;
                    withMissing: bool) =
    ## The profile every test applies. `applies` is the `applies:` list of
    ## this host's entry ("" = no declaration: the one-line form).
    var text = "import repro_profile\n\nprofile \"gm7Concerns\":\n" &
      "  adapterPreference:\n    darwin: [tarball]\n\n" &
      "  activity default:\n    gm7base\n    gm7app\n"
    if withMissing:
      text.add("    " & MissingPackage & "\n")
    text.add("\n  activity desktop:\n    gm7base\n\n  hosts:\n")
    if applies.len > 0:
      text.add("    \"" & host & "\":\n      activities: [desktop]\n" &
        "      applies: [" & applies & "]\n")
    else:
      text.add("    \"" & host & "\": [desktop]\n")
    text.add("\n  resources:\n" &
      "    fsUserFile(hostFile = \"~/.gm7-marker\", content = \"gm7\\n\")\n" &
      "    fsManagedBlock(hostFile = \"~/.gm7rc\", blockId = \"gm7\",\n" &
      "      content = \"export GM7=1\")\n")
    writeFile(root / "profile" / "home.nim", text)

  proc newRoot(label: string): string =
    result = createTempDir("repro-gm7-e2e-" & label & "-", "")
    for d in ["profile", "state", "store", "home"]:
      createDir(result / d)
    # A GNU-stow package with one dotfile (`files` concern).
    createDir(result / "profile" / "stow" / "gm7dots")
    writeFile(result / "profile" / "stow" / "gm7dots" / ".gm7-dotfile",
      "dotfile\n")

  proc applyOptions(root: string; at: int64): ApplyOptions =
    ## The options `repro home apply` builds: the profile compiled through
    ## the profile-compile edge and adapted (`preLoadedProfile`).
    result.profileDir = root / "profile"
    result.profilePath = root / "profile" / "home.nim"
    result.stateDir = root / "state"
    result.storeRoot = root / "store"
    result.homeDir = root / "home"
    result.host = host
    result.activationTimestamp = at
    result.appTrust = Relaxed
    let artifact = compileProfileToRbpi(result.profilePath,
      ProfileCompileOptions(stateDir: result.stateDir,
        publicCliPath: reproBinaryPath(), repoRoot: ReprobuildRepoRoot))
    result.preLoadedProfile = expandedHomeProfile(
      decodeRbpi(artifact.rbpiBytes), result.profilePath)

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

  proc placedApp(root: string): string =
    root / "home" / "Applications" / (AppName & ".app")
  proc dotfile(root: string): string = root / "home" / ".gm7-dotfile"
  proc marker(root: string): string = root / "home" / ".gm7-marker"
  proc rcFile(root: string): string = root / "home" / ".gm7rc"

  proc hasBlock(root: string): bool =
    fileExists(rcFile(root)) and "export GM7=1" in readFile(rcFile(root))

  proc manifestOf(root, generationId: string): ActivationManifest =
    var store = openStore(root / "store")
    defer: store.close()
    let envelope = readPointerFile(pointerPath(root / "state", generationId))
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    let bytes = readCasBlob(store, key)
    result = decodeManifestBytes(bytes)

  proc manifestVersion(root, generationId: string): int =
    var store = openStore(root / "store")
    defer: store.close()
    let envelope = readPointerFile(pointerPath(root / "state", generationId))
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    let bytes = readCasBlob(store, key)
    int(bytes[4]) or (int(bytes[5]) shl 8)

  proc storeHasPackage(root, packageName: string): bool =
    var store = openStore(root / "store")
    defer: store.close()
    for row in listPrefixes(store):
      if row.packageName == packageName:
        return true

  proc addresses(m: ActivationManifest): seq[string] =
    for rb in m.resourceBindings:
      result.add rb.resourceAddress

  registerFixtures()

  suite "GM7: e2e_home_apply_applies_declared_concerns":

    test "applies: [applications] places the application and writes " &
        "nothing of the other concerns, a package with no realization " &
        "included":
      let root = newRoot("declared")
      withApplyEnv(root):
        writeProfile(root, "applications", withMissing = true)

        # --plan: the other concerns are shown, not applied, not drift.
        let preview = runApplyPlan(applyOptions(root, 1000))
        let rendered = renderPlanPreview(preview)
        checkpoint rendered
        check preview.applied.declared
        check preview.applied.concerns == {hcApplications}
        check preview.driftCount == 0
        check "concerns applied: applications (hosts." & host &
          ".applies)" in rendered
        check "[not applied on " & host & ": concern packages" in rendered
        check "[not applied on " & host & ": concern files" in rendered
        check "[not applied on " & host & ": concern environment" in
          rendered
        var sawMissing, sawStow, sawMarker, sawBlock, sawApp = false
        for item in preview.items:
          if item.category == "package" and item.name == MissingPackage:
            sawMissing = true
            check item.action == piaMissing
            check item.notApplied and item.concern == hcPackages
          if item.category == "stow":
            sawStow = true
            check item.notApplied and item.concern == hcFiles
          if item.category == "resource" and "gm7-marker" in item.name:
            sawMarker = true
            check item.notApplied and item.concern == hcFiles
          if item.category == "resource" and "gm7rc" in item.name:
            sawBlock = true
            check item.notApplied and item.concern == hcEnvironment
          if item.category == "app-bundle":
            sawApp = true
            check (not item.notApplied) and item.action == piaCreate
        check sawMissing and sawStow and sawMarker and sawBlock and sawApp
        check preview.notAppliedCount >= 5

        # The apply: succeeds although gm7nowhere has no realization.
        let gen = runApply(applyOptions(root, 2000))
        check gen.kind == aokFreshApplied
        check gen.applied.declared
        check gen.notAppliedCount >= 5
        check gen.released.len == 0
        # The application is placed, and it is the realized bundle.
        check dirExists(placedApp(root))
        check plistValue(placedApp(root), "CFBundleIdentifier") == AppId
        check appBundleCanonicalBytes(readAppBundleIdentity(
          placedApp(root))) == appIdentity
        # Nothing of the other concerns was written.
        check not fileExists(dotfile(root)) and not symlinkExists(dotfile(root))
        check not fileExists(marker(root))
        check not hasBlock(root)
        check storeHasPackage(root, "gm7app")
        check not storeHasPackage(root, "gm7base")
        # The generation records exactly the application, and its concerns.
        let m = manifestOf(root, gen.generationIdHex)
        check manifestVersion(root, gen.generationIdHex) == 3
        check m.concernsDeclared
        check m.ownedConcerns == @["applications"]
        check addresses(m) == @["home.package.gm7app.app"]
        check m.generatedFiles.len == 0
        check m.managedBlocks.len == 0
        # A re-apply is a verified no-op.
        let again = runApply(applyOptions(root, 2500))
        check again.kind == aokNoOpVerified
        check again.generationIdHex == gen.generationIdHex
      removeDir(root)

    test "applies: [applications] on a profile every package of which " &
        "realizes still writes no stow link, user file or block":
      # The direct form of the falsifying mutation's target: with nothing
      # to fail at step 7, a pipeline that ignored the declaration would
      # write the other concerns' objects; this one must not.
      let root = newRoot("declared-realizable")
      withApplyEnv(root):
        writeProfile(root, "applications", withMissing = false)
        let gen = runApply(applyOptions(root, 1000))
        check gen.kind == aokFreshApplied
        check dirExists(placedApp(root))
        check not symlinkExists(dotfile(root)) and not fileExists(dotfile(root))
        check not fileExists(marker(root))
        check not hasBlock(root)
        check not storeHasPackage(root, "gm7base")
        check manifestOf(root, gen.generationIdHex).ownedConcerns ==
          @["applications"]
      removeDir(root)

    test "negative control: without the declaration the same profile " &
        "fails at step 7, and applies every concern once it can":
      let root = newRoot("undeclared")
      withApplyEnv(root):
        writeProfile(root, "", withMissing = true)
        var refused = false
        try:
          discard runApply(applyOptions(root, 1000))
        except EApplyRealizeFailed as err:
          refused = true
          checkpoint err.msg
          check err.packageId == MissingPackage
        check refused
        check readCurrentGenerationId(root / "state").len == 0

        writeProfile(root, "", withMissing = false)
        let preview = runApplyPlan(applyOptions(root, 1500))
        check not preview.applied.declared
        check preview.notAppliedCount == 0
        check "not applied on" notin renderPlanPreview(preview)
        let gen = runApply(applyOptions(root, 2000))
        check gen.kind == aokFreshApplied
        check not gen.applied.declared
        check gen.notAppliedCount == 0
        check dirExists(placedApp(root))
        check symlinkExists(dotfile(root))
        check readFile(marker(root)) == "gm7\n"
        check hasBlock(root)
        check storeHasPackage(root, "gm7base")
        let m = manifestOf(root, gen.generationIdHex)
        # Undeclared: schema 2, byte-compatible with every earlier manifest.
        check manifestVersion(root, gen.generationIdHex) == 2
        check not m.concernsDeclared
        check ownedConcernsOf(m) == AllHomeConcerns
      removeDir(root)

    test "narrowing releases, rollback restores, and rolling back to the " &
        "narrowed generation releases instead of removing":
      let root = newRoot("narrowing")
      withApplyEnv(root):
        # Generation A: every concern.
        writeProfile(root, "", withMissing = false)
        let genA = runApply(applyOptions(root, 1000))
        check genA.kind == aokFreshApplied
        check symlinkExists(dotfile(root))
        check fileExists(marker(root)) and hasBlock(root)
        check dirExists(placedApp(root))

        # Generation B: the same profile, narrowed to the applications.
        writeProfile(root, "applications", withMissing = false)
        let preview = runApplyPlan(applyOptions(root, 1500))
        checkpoint renderPlanPreview(preview)
        check preview.releasedCount >= 3
        check "[released:" in renderPlanPreview(preview)
        let genB = runApply(applyOptions(root, 2000))
        check genB.kind == aokFreshApplied
        # The declaration alone is a new generation.
        check genB.generationIdHex != genA.generationIdHex
        checkpoint $genB.released
        var releasedText = genB.released.join("\n")
        check "generated-file " & dotfile(root) in releasedText
        check "gm7-marker" in releasedText
        check "gm7rc" in releasedText
        # Released, not removed: every object is still there ...
        check symlinkExists(dotfile(root))
        check readFile(marker(root)) == "gm7\n"
        check hasBlock(root)
        check dirExists(placedApp(root))
        # ... and no longer recorded.
        let mB = manifestOf(root, genB.generationIdHex)
        check mB.ownedConcerns == @["applications"]
        check addresses(mB) == @["home.package.gm7app.app"]
        check mB.generatedFiles.len == 0

        # A released object is no longer managed: editing it is not drift.
        writeFile(marker(root), "edited by the other tool\n")
        let preview2 = runApplyPlan(applyOptions(root, 2500))
        check preview2.driftCount == 0

        # Reclaiming by rollback never clobbers what the other tool now
        # holds: rolling back to A would restore A's marker over the edit,
        # so it is refused, and nothing changes.
        var reclaimRefused = false
        try:
          discard runRollback(RollbackOptions(stateDir: root / "state",
            storeRoot: root / "store", homeDir: root / "home",
            targetGenerationId: genA.generationIdHex,
            activationTimestamp: 2700))
        except EUserEditDetected as err:
          reclaimRefused = true
          checkpoint err.msg
          check "gm7-marker" in err.msg
        check reclaimRefused
        check readCurrentGenerationId(root / "state") == genB.generationIdHex
        check readFile(marker(root)) == "edited by the other tool\n"
        writeFile(marker(root), "gm7\n")

        # Rollback to A: A owns every concern and restores its records.
        let toA = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genA.generationIdHex,
          activationTimestamp: 3000))
        check toA.toGenerationIdHex == genA.generationIdHex
        check toA.released.len == 0
        check symlinkExists(dotfile(root))
        check fileExists(marker(root)) and hasBlock(root)

        # Rollback to B: B does not own files / environment, so A's records
        # of them are released -- left in place -- not removed.
        let toB = runRollback(RollbackOptions(stateDir: root / "state",
          storeRoot: root / "store", homeDir: root / "home",
          targetGenerationId: genB.generationIdHex,
          activationTimestamp: 4000))
        check toB.toGenerationIdHex == genB.generationIdHex
        checkpoint $toB.released
        releasedText = toB.released.join("\n")
        check "generated-file " & dotfile(root) in releasedText
        check "resource" in releasedText and "gm7-marker" in releasedText
        check symlinkExists(dotfile(root))
        check readFile(marker(root)) == "gm7\n"
        check hasBlock(root)
        check dirExists(placedApp(root))
      removeDir(root)

  removeDir(fixtureRoot)
