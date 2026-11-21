## GM7: e2e_app_vendor_update_and_running_app.
##
## Store-And-Installation-Layout.md § macOS Application Bundles, "Vendor
## updates" and "Running applications", through a real `repro home apply`
## into the `~/Applications` of a SCRATCH home:
##
## * an application placed at v1 that updated itself to v2 (its placed copy
##   replaced by the vendor's newer, signed build) is KEPT by the next apply
##   while the profile still declares v1 -- no drift, nothing downgraded,
##   the generation keeps recording v1 and the apply reports the kept
##   update; when the catalog then declares v3, newer than the vendor
##   update, the apply replaces it with v3; a copy OLDER than the recorded
##   bundle is still drift (the apply fails, nothing is replaced);
## * an application with a process running from its placed bundle is not
##   replaced: the apply that would upgrade it defers the change (the placed
##   copy and its record stay, the record is marked so the next apply cannot
##   short-circuit past it, the outcome names it), an apply while it still
##   runs defers again, and the first apply after the process ends replaces
##   it.
##
## And the directory `repro home export` publishes as the profile bin
## (`concerns.profileBin`, Gradual-Nix-To-Reprobuild-Migration.md §The
## profile's commands), resolved against `$HOME`, is the one the default
## state directory's launchers are reached through, and an apply's launchers
## are in it.
##
## The pipeline runs for real (selection, the home archive realizer from
## `file://` disk images, the store, the `macos.appBundle` lifecycle, the
## generation manifest), as in `t_e2e_dmg_app_bundle_install_and_rollback`,
## whose header explains the fixtures and the one trust relaxation
## (`ApplyOptions.appTrust`: Developer ID chain and notarization, which a
## bundle built at test time cannot meet; no CLI path sets it). The vendor
## update is the fixture's v2 bundle copied over the placed v1 with `ditto`,
## as an updater does; the running application is a helper executable (a
## program compiled by the test that sleeps) inside the placed bundle,
## started detached by the test -- the process the apply must find through
## libproc. Nothing is mocked; nothing
## touches the real `~/Applications`.
##
## Vacuity guard: before the vendor update the placed bundle is v1 and the
## apply that places it is a fresh apply; the kept-update apply sees a v2
## copy on disk (read back from its Info.plist), and the running-process
## probe is shown to find the helper before the deferred apply runs.
##
## Negative control: the older copy (v1 over a recorded v3) fails the apply
## with `EDrift`, exactly as any changed bundle did before vendor updates
## were recognised.
##
## Falsifying mutations (performed for GM7): making `appBundleFacts` never
## set `vendorUpdate` turns the kept-update apply red (`EDrift`); making
## `decideAction` ignore `busy` turns the deferral red (the running bundle
## is replaced); dropping the deferred mark from the re-recorded binding
## turns "the first apply after it quits replaces it" red (the no-op
## short-circuit keeps v1 forever).

when defined(macosx):
  import std/[os, osproc, posix, strutils, tempfiles, unittest]

  import repro_project_dsl
  import repro_local_store
  import repro_home_apply
  import repro_home_generations
  import repro_home_intent
  import repro_home_resources
  import repro_test_support/macos_app_fixtures

  const
    AppName = "GM7Vendor"
    AppId = "dev.reprobuild.gm7.vendorupdate"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let fixtureRoot = createTempDir("repro-gm7-vendor-e2e-fixture-", "")
  let apps = [
    makeFixtureApp(fixtureRoot / "v1", AppName, AppId, "1.0.0"),
    makeFixtureApp(fixtureRoot / "v2", AppName, AppId, "2.0.0"),
    makeFixtureApp(fixtureRoot / "v3", AppName, AppId, "3.0.0")]
  let dmgs = [
    makeFixtureDmg(fixtureRoot, "gm7-1.0.0.dmg", [apps[0]]),
    makeFixtureDmg(fixtureRoot, "gm7-2.0.0.dmg", [apps[1]]),
    makeFixtureDmg(fixtureRoot, "gm7-3.0.0.dmg", [apps[2]])]
  let identityV1 = appBundleCanonicalBytes(readAppBundleIdentity(apps[0]))
  let basePayload = fixtureRoot / "gm7base"
  writeFile(basePayload, "#!/bin/sh\necho gm7base\n")
  setFilePermissions(basePayload, {fpUserRead, fpUserWrite, fpUserExec})

  proc registerFixtures(version: int) =
    ## The catalog as it stands: ``gm7app`` at ``version`` (1, 2 or 3).
    resetPackageRegistry()
    registerPackageDef(PackageDef(packageName: "gm7base",
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[TarballProvisioningDef(
        url: "file://" & basePayload, sha256: sha256Of(basePayload),
        archiveType: "raw", executablePath: "gm7base",
        packageId: "gm7base@1.0", lockIdentity: "fixture:gm7base@1.0",
        detail: TarballArchiveDetail(version: "1.0"))]))
    let v = $version & ".0.0"
    let dmg = dmgs[version - 1]
    let sha = sha256Of(dmg)
    registerPackageDef(PackageDef(packageName: "gm7app",
      sourceFile: currentSourcePath(), sourceLine: 2,
      tarballProvisioning: @[TarballProvisioningDef(url: "file://" & dmg,
        sha256: sha, archiveType: "dmg",
        executablePath: AppName & ".app/Contents/MacOS/" & AppName,
        packageId: "gm7app@" & v,
        lockIdentity: "tarball:gm7app@" & v & ":macos-any:sha256:" & sha,
        cpu: "any", os: "macos",
        detail: TarballArchiveDetail(version: v,
          installMethod: "app-bundle", appBundle: AppName & ".app",
          bundleId: AppId, teamId: FixtureTeamId))]))

  proc newRoot(label: string): string =
    result = createTempDir("repro-gm7-vendor-e2e-" & label & "-", "")
    for d in ["profile", "state", "store", "home"]:
      createDir(result / d)
    writeFile(result / "profile" / "home.nim",
      "import repro/profile\n\nprofile \"gm7Vendor\":\n" &
      "  adapterPreference:\n    darwin: [tarball]\n\n" &
      "  activity default:\n    gm7base\n    gm7app\n")

  proc applyOptions(root: string; at: int64): ApplyOptions =
    result.profileDir = root / "profile"
    result.profilePath = root / "profile" / "home.nim"
    result.stateDir = root / "state"
    result.storeRoot = root / "store"
    result.homeDir = root / "home"
    result.host = currentHost()
    result.activationTimestamp = at
    result.appTrust = Relaxed
    # Every catalog bump below is an intended upgrade.
    result.relock = true

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

  proc placed(root: string): string =
    root / "home" / "Applications" / (AppName & ".app")

  proc placedVersion(root: string): string =
    plistValue(placed(root), "CFBundleShortVersionString")

  proc spawnDetached(exe: string): int =
    ## Start ``exe`` in a new session whose parent is launchd, and return
    ## its pid (sent back over a pipe by the intermediate child).
    var fds: array[2, cint]
    doAssert posix.pipe(fds) == 0
    let first = posix.fork()
    doAssert first >= 0
    if first == 0:
      discard posix.close(fds[0])
      discard posix.setsid()
      let second = posix.fork()
      if second == 0:
        discard posix.close(fds[1])
        let devnull = posix.open("/dev/null", O_RDWR)
        discard posix.dup2(devnull, 0)
        discard posix.dup2(devnull, 1)
        discard posix.dup2(devnull, 2)
        var argv = allocCStringArray([exe])
        discard posix.execv(exe.cstring, argv)
        posix.exitnow(127)
      var p = int32(second)
      discard posix.write(fds[1], addr p, sizeof(p))
      posix.exitnow(0)
    discard posix.close(fds[1])
    var p: int32
    doAssert posix.read(fds[0], addr p, sizeof(p)) == sizeof(p)
    discard posix.close(fds[0])
    var status: cint
    discard posix.waitpid(first, status, 0)
    int(p)

  proc vendorUpdates(root, app: string) =
    ## What an in-place updater does: the vendor's build replaces the
    ## placed bundle at the same path.
    removeDir(placed(root))
    let res = execCmdEx(quoteShellCommand(["/usr/bin/ditto", app,
      placed(root)]))
    doAssert res.exitCode == 0, res.output

  proc appBinding(root, generationId: string): ResourceBinding =
    var store = openStore(root / "store")
    defer: store.close()
    let envelope = readPointerFile(pointerPath(root / "state", generationId))
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    let manifest = decodeManifestBytes(readCasBlob(store, key))
    for rb in manifest.resourceBindings:
      if rb.resourceKind == $rkMacosAppBundle:
        return rb
    doAssert false, "no macos.appBundle binding in " & generationId

  suite "GM7: the profile bin directory the export publishes":
    test "is the directory the apply writes launchers into":
      # Gradual-Nix-To-Reprobuild-Migration.md §The profile's commands: the
      # location `repro home export` publishes for this platform
      # (`defaultProfileBinLocation`), resolved against $HOME, is
      # `profileBinDir` of the default state directory, and an apply's
      # launchers are there.
      let location = defaultProfileBinLocation(HostStatePlatform)
      check location.base == sdbHome
      check location.components.join("/") ==
        "Library/Application Support/repro/home/current/bin"
      let savedState = getEnv("REPRO_HOME_STATE_DIR")
      delEnv("REPRO_HOME_STATE_DIR")
      try:
        var resolved = getHomeDir()
        for c in location.components:
          resolved = resolved / c
        check resolved == profileBinDir(osDefaultStateDir())
      finally:
        if savedState.len > 0: putEnv("REPRO_HOME_STATE_DIR", savedState)
      let root = newRoot("bin")
      withApplyEnv(root):
        registerFixtures(1)
        check runApply(applyOptions(root, 1000)).kind == aokFreshApplied
        check fileExists(profileBinDir(root / "state") / "gm7app")
        check profileBinDir(root / "state") == root / "state" / "current" / "bin"
      removeDir(root)

  suite "GM7: e2e_app_vendor_update_and_running_app":

    test "a vendor update is kept, replaced by a newer declared " &
        "version, and an older copy is still drift":
      let root = newRoot("vendor")
      withApplyEnv(root):
        registerFixtures(1)
        let first = runApply(applyOptions(root, 1000))
        check first.kind == aokFreshApplied
        check placedVersion(root) == "1.0.0"

        # The application updates itself to v2.
        vendorUpdates(root, apps[1])
        check placedVersion(root) == "2.0.0"
        let kept = runApply(applyOptions(root, 2000))
        check placedVersion(root) == "2.0.0"
        check kept.keptVendorUpdates.len == 1
        check "home.package.gm7app.app" in kept.keptVendorUpdates[0]
        check "2.0.0" in kept.keptVendorUpdates[0]
        # The generation keeps recording what it placed.
        check appBinding(root, kept.generationIdHex).payloadBytes ==
          identityV1
        # ...and keeps accepting the update on the next apply.
        let again = runApply(applyOptions(root, 2500))
        check placedVersion(root) == "2.0.0"
        check again.keptVendorUpdates.len == 1

        # The catalog moves past the vendor update: replaced with v3.
        registerFixtures(3)
        let bumped = runApply(applyOptions(root, 3000))
        check bumped.kind == aokFreshApplied
        check placedVersion(root) == "3.0.0"
        check bumped.keptVendorUpdates.len == 0

        # Negative control: an OLDER copy than the recorded v3 is drift.
        vendorUpdates(root, apps[0])
        var drift = false
        try:
          discard runApply(applyOptions(root, 4000))
        except EDrift:
          drift = true
        check drift
        check placedVersion(root) == "1.0.0"
      removeDir(root)

    test "a running application is not replaced until it quits":
      let root = newRoot("running")
      withApplyEnv(root):
        registerFixtures(1)
        check runApply(applyOptions(root, 1000)).kind == aokFreshApplied
        check placedVersion(root) == "1.0.0"
        # A process of the application: a helper executable inside the
        # placed bundle (outside its signature's main executable, so the
        # placed identity is unchanged).
        let helper = placed(root) / "Contents" / "MacOS" / "helper"
        writeFile(root / "helper.c",
          "#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n")
        let cc = execCmdEx(quoteShellCommand(["/usr/bin/cc", "-o", helper,
          root / "helper.c"]))
        doAssert cc.exitCode == 0, cc.output
        # Started DETACHED -- double fork, its own session, re-parented to
        # launchd -- as an application the user launched is: process
        # helpers in this test process clean up children they started, and
        # a child of the test would be taken for one of those.
        let pid = spawnDetached(helper)
        var running = true
        proc stopHelper() =
          discard posix.kill(Pid(pid), SIGTERM)
          for _ in 0 ..< 100:
            if processesRunningFrom(placed(root)).len == 0: break
            sleep(20)
        try:
          var seen: seq[int]
          for _ in 0 ..< 50:
            seen = processesRunningFrom(placed(root))
            if seen.len > 0: break
            sleep(20)
          check seen == @[pid]

          registerFixtures(2)
          let deferred = runApply(applyOptions(root, 2000))
          check deferred.kind == aokFreshApplied
          check placedVersion(root) == "1.0.0"
          check deferred.deferred.len == 1
          check "home.package.gm7app.app" in deferred.deferred[0]
          check $pid in deferred.deferred[0]
          let rb = appBinding(root, deferred.generationIdHex)
          check rb.payloadBytes == identityV1
          check rb.payloadKind.endsWith("+deferred")

          # Still running: deferred again, nothing replaced.
          let stillDeferred = runApply(applyOptions(root, 2500))
          check placedVersion(root) == "1.0.0"
          check stillDeferred.deferred.len == 1

          stopHelper()
          running = false
          check processesRunningFrom(placed(root)).len == 0

          # The first apply after it quits replaces it.
          let replaced = runApply(applyOptions(root, 3000))
          check placedVersion(root) == "2.0.0"
          check replaced.deferred.len == 0
          check not appBinding(root, replaced.generationIdHex).payloadKind.
            endsWith("+deferred")
          # ...and the generation after that is a plain no-op.
          let noop = runApply(applyOptions(root, 4000))
          check noop.kind == aokNoOpVerified
        finally:
          if running:
            stopHelper()
      removeDir(root)

  removeDir(fixtureRoot)
