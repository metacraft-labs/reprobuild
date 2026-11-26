## A cached application prefix is verified before it is reused, repaired when
## it no longer verifies, sealed read-only and kept out of Launch Services
## (Store-And-Installation-Layout.md § macOS Application Bundles,
## "Cached prefixes").
##
## Every case runs the real realizer (`realizeBuiltinPackage`, reached
## through `resolveProfilePackage` the way a home profile reaches it) on a
## real zip archive downloaded from a `file://` URL: the real `ditto`,
## `codesign` and `spctl` check the bundle, the store is a real store, and
## "Launch Services" is the real registration database (`lsregister`).
##
## FIXTURES, and why none is a mock:
##
## * The application is built at test time
##   (`macos_app_fixtures.makeFixtureApp`): a compiled, ad-hoc signed bundle.
##   A bundle built here cannot carry a Developer ID signature or a
##   notarization ticket, so these cases relax exactly checks 4 and 5
##   (`{atrUnanchoredTeamIdentifier, atrSkipNotarization}`), as the GM4c
##   tests do; checks 1 to 3 (Info.plist, `codesign --verify --deep
##   --strict`, team equality) run for real and are what the drift trips.
## * "An updater rewrote the prefix" is a second, validly signed version of
##   the same application copied over the cached bundle: the very shape
##   an Electron updater (Squirrel) leaves behind (126.9.13 becoming
##   126.11.11), which only the version check can tell from the pinned
##   bundle.
## * "A process runs from the prefix" is a signed copy of `/bin/sleep` started from
##   inside the cached bundle, found by the real libproc scan.
## * Nothing here touches the real `~/Applications`, the real store or the
##   real Launch Services entries of any installed application: every path
##   is inside a temporary directory.
##
## Vacuity guards: the registration is made first (positive control), so the
## "unregistered" check sees a registration disappear; the drifted bundle is
## shown to fail the very check the repair answers; and the repaired bundle
## is compared byte-for-byte against the pinned archive's.
##
## Falsifying mutations (performed): dropping the receipt seal from
## `settleAppPrefix` fails "a prefix without a receipt is verified and
## sealed"; dropping the discard from the existing-prefix branch fails "a
## prefix an updater rewrote is repaired"; dropping the in-use guard from
## `discardCachedPrefix` fails "a repair is deferred while a process runs
## from the prefix"; dropping `settleVerifiedPrefix` fails the read-only and
## Launch Services cases.

when defined(macosx):
  import std/[os, osproc, strutils, tempfiles, unittest]

  import repro_project_dsl
  import repro_local_store
  import repro_home_apply
  import repro_home_apply/builtin_adapter
  import repro_home_resources
  import repro_tool_profiles/cached_prefix
  import repro_test_support/macos_app_fixtures

  const
    AppName = "CachedApp"
    AppId = "dev.reprobuild.cachedprefix.fixture"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let root = createTempDir("repro-cached-prefix-", "")
  var counter = 0

  proc macos(): RealizationTarget =
    profileRealizationTarget("macos", "arm64", isHost = false)

  proc record(archive, name, version: string): TarballProvisioningDef =
    let sha = sha256Of(archive)
    TarballProvisioningDef(url: "file://" & archive, sha256: sha,
      archiveType: "zip",
      executablePath: AppName & ".app/Contents/MacOS/" & AppName,
      packageId: name & "@" & version,
      lockIdentity: "tarball:" & name & "@" & version & ":sha256:" & sha,
      cpu: "any", os: "macos",
      detail: TarballArchiveDetail(version: version,
        installMethod: "app-bundle", appBundle: AppName & ".app",
        bundleId: AppId, teamId: FixtureTeamId))

  proc newPackage(version = "1.0.0"): tuple[name: string;
                                           archive: ArchiveRealization] =
    ## A fresh package (its own archive, name and store) so cases do not
    ## share prefixes.
    inc counter
    let name = "cachedprefix" & $counter
    let dir = root / ("fixture-" & $counter)
    let app = makeFixtureApp(dir, AppName, AppId, version)
    let zip = makeFixtureZip(dir, name & ".zip", app)
    registerPackageDef(PackageDef(packageName: name,
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[record(zip, name, version)]))
    result = (name, resolveProfilePackage(name, macos(), @[rkTarball]).archive)

  proc bundleOf(r: RealizeBuiltinResult): string =
    r.prefixAbsolutePath / (AppName & ".app")

  proc userWritable(path: string): bool =
    fpUserWrite in getFilePermissions(path)

  proc makeTreeWritable(path: string) =
    doAssert execCmdEx("/bin/chmod -R u+w " & quoteShell(path)).exitCode == 0

  proc payloadOf(bundle: string): string =
    readFile(bundle / "Contents" / "Resources" / "payload.txt")

  proc registerWithLaunchServices(bundle: string) =
    doAssert execCmdEx(quoteShell(LsRegisterPath) & " -f " &
      quoteShell(bundle)).exitCode == 0

  proc unregisterFromLaunchServices(bundle: string) =
    discard execCmdEx(quoteShell(LsRegisterPath) & " -u " & quoteShell(bundle))

  proc updaterRewrites(bundle: string; version: string) =
    ## What a vendor updater does: replaces the bundle by the next, validly
    ## signed release of the same application.
    inc counter
    let next = makeFixtureApp(root / ("updater-" & $counter), AppName, AppId,
      version)
    makeTreeWritable(bundle)
    removeDir(bundle)
    doAssert execCmdEx("/usr/bin/ditto " & quoteShell(next) & " " &
      quoteShell(bundle)).exitCode == 0

  suite "a cached application prefix":

    test "a fresh realization is receipted, read-only and out of Launch " &
        "Services":
      var store = openStore(root / "store-fresh")
      defer: store.close()
      let pkg = newPackage()
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      let bundle = bundleOf(realized)
      check fileExists(realized.prefixAbsolutePath / ".repro-receipt")
      check not realized.cacheHit
      # Read-only: the bundle, its directories and its files.
      check not userWritable(bundle)
      check not userWritable(bundle / "Contents")
      check not userWritable(bundle / "Contents" / "Resources" / "payload.txt")
      check not userWritable(bundle / "Contents" / "Info.plist")
      # The prefix directory itself stays writable (the receipt lives there,
      # and a discard restores directory write bits as for any prefix).
      check userWritable(realized.prefixAbsolutePath)
      # Launch Services: positive control first -- an explicit registration
      # of this very bundle is visible -- then a reuse of the prefix
      # unregisters it.
      registerWithLaunchServices(bundle)
      check cachedBundleRegisteredWithLaunchServices(bundle)
      let again = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      check again.prefixId == realized.prefixId
      check not cachedBundleRegisteredWithLaunchServices(bundle)

    test "a prefix without a receipt is verified and sealed, not refused":
      var store = openStore(root / "store-receiptless")
      defer: store.close()
      let pkg = newPackage()
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      let receipt = realized.prefixAbsolutePath / ".repro-receipt"
      let payloadBefore = payloadOf(bundleOf(realized))
      # The state a substituted or interrupted realization leaves: bundle complete, no receipt,
      # and writable (as an older engine left every prefix).
      removeFile(receipt)
      makeTreeWritable(bundleOf(realized))
      check not fileExists(receipt)
      check userWritable(bundleOf(realized))
      let again = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      check fileExists(receipt)
      check again.prefixId == realized.prefixId
      check again.prefixAbsolutePath == realized.prefixAbsolutePath
      check payloadOf(bundleOf(again)) == payloadBefore
      check not userWritable(bundleOf(again))

    test "a prefix an updater rewrote is repaired from the pinned archive":
      var store = openStore(root / "store-drift")
      defer: store.close()
      let pkg = newPackage("1.0.0")
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      let bundle = bundleOf(realized)
      let pinnedPayload = payloadOf(bundle)
      updaterRewrites(bundle, "2.0.0")
      # The rewritten bundle is intact and validly signed: only the version
      # check refuses it, which is the check the repair answers.
      let verdict = cachedBundleVerdict(pkg.archive, realized.prefixAbsolutePath,
        Relaxed)
      check not verdict.verified
      check verdict.check == "version"
      check payloadOf(bundle).contains("2.0.0")
      # The apply that follows does not fail: it realizes the pinned archive
      # again at the same prefix.
      let repaired = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      check repaired.prefixAbsolutePath == realized.prefixAbsolutePath
      check payloadOf(bundleOf(repaired)) == pinnedPayload
      check cachedBundleVerdict(pkg.archive, repaired.prefixAbsolutePath,
        Relaxed).verified
      check fileExists(repaired.prefixAbsolutePath / ".repro-receipt")
      check not userWritable(bundleOf(repaired))

    test "a prefix whose signature no longer verifies is repaired too":
      var store = openStore(root / "store-tampered")
      defer: store.close()
      let pkg = newPackage()
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      let bundle = bundleOf(realized)
      let pinnedPayload = payloadOf(bundle)
      makeTreeWritable(bundle)
      tamperFixtureApp(bundle)
      let verdict = cachedBundleVerdict(pkg.archive, realized.prefixAbsolutePath,
        Relaxed)
      check not verdict.verified
      check verdict.check == "signature"
      let repaired = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      check payloadOf(bundleOf(repaired)) == pinnedPayload

    test "a repair is deferred while a process runs from the prefix":
      var store = openStore(root / "store-running")
      defer: store.close()
      let pkg = newPackage("1.0.0")
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      let bundle = bundleOf(realized)
      # No receipt either (as for a substituted prefix): the apply must
      # still go on, so the realizer seals the receipt, which carries the
      # prefix id; it does not make the prefix trusted.
      removeFile(realized.prefixAbsolutePath / ".repro-receipt")
      updaterRewrites(bundle, "2.0.0")
      # A program that runs from inside the cached bundle, as an application
      # launched from its prefix would.
      let sleeper = bundle / "Contents" / "MacOS" / "sleeper"
      makeFixtureSleeper(sleeper)
      let running = startProcess(sleeper, args = @["120"])
      try:
        var visible = false
        for _ in 0 ..< 100:
          if processesRunningFromPrefix(realized.prefixAbsolutePath).len == 1:
            visible = true
            break
          sleep(100)
        check visible
        # The apply goes on and does not fail; the prefix is left as it is.
        let during = realizeBuiltinPackage(store, pkg.archive, Relaxed)
        check during.prefixAbsolutePath == realized.prefixAbsolutePath
        check payloadOf(bundle).contains("2.0.0")
        check fileExists(sleeper)
        check not cachedBundleVerdict(pkg.archive, realized.prefixAbsolutePath,
          Relaxed).verified
        # A deferred prefix is not treated as verified: not sealed, and
        # still failing the checks on every resolution.
        check fileExists(realized.prefixAbsolutePath / ".repro-receipt")
        check userWritable(bundle)
      finally:
        running.terminate()
        discard running.waitForExit()
        running.close()
      # The next apply, after the application quit, repairs it.
      let after = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      check payloadOf(bundleOf(after)).contains("1.0.0")
      check not fileExists(bundleOf(after) / "Contents" / "MacOS" / "sleeper")
      check cachedBundleVerdict(pkg.archive, after.prefixAbsolutePath,
        Relaxed).verified

    test "a prefix that holds no application is left exactly as it was":
      var store = openStore(root / "store-plain")
      defer: store.close()
      inc counter
      let name = "plaincached" & $counter
      let dir = root / ("fixture-" & $counter)
      createDir(dir / "tool")
      writeFile(dir / "tool" / "run.sh", "#!/bin/sh\nexit 0\n")
      setFilePermissions(dir / "tool" / "run.sh",
        {fpUserRead, fpUserWrite, fpUserExec})
      let zip = makeFixtureZip(dir, name & ".zip", dir / "tool")
      let sha = sha256Of(zip)
      registerPackageDef(PackageDef(packageName: name,
        sourceFile: currentSourcePath(), sourceLine: 1,
        tarballProvisioning: @[TarballProvisioningDef(url: "file://" & zip,
          sha256: sha, archiveType: "zip", executablePath: "tool/run.sh",
          packageId: name & "@1", cpu: "any", os: "macos",
          lockIdentity: "tarball:" & name & "@1:sha256:" & sha,
          detail: TarballArchiveDetail(version: "1"))]))
      let archive = resolveProfilePackage(name, macos(), @[rkTarball]).archive
      let realized = realizeBuiltinPackage(store, archive, Relaxed)
      let again = realizeBuiltinPackage(store, archive, Relaxed)
      check again.prefixAbsolutePath == realized.prefixAbsolutePath
      check fileExists(realized.prefixAbsolutePath / ".repro-receipt")
      # Not an application: still writable, and the adapter receipt declares
      # no application bundle.
      check userWritable(realized.prefixAbsolutePath)
      check userWritable(realized.prefixAbsolutePath / "tool")
      check userWritable(realized.prefixAbsolutePath / "tool" / "run.sh")
      check "appBundle" notin readFile(realized.prefixAbsolutePath /
        ".reprobuild-tarball-receipt.json")

    test "a prefix that cannot be repaired still refuses, naming the check":
      var store = openStore(root / "store-unrepairable")
      defer: store.close()
      let pkg = newPackage()
      let realized = realizeBuiltinPackage(store, pkg.archive, Relaxed)
      # Strict trust: the fixture bundle is not Developer ID signed, so no
      # re-realization can make it verify. The apply fails at the check,
      # exactly as it did before cached prefixes were repaired, and the
      # prefix that failed was discarded on the way (it was not kept).
      var refused = false
      try:
        discard realizeBuiltinPackage(store, pkg.archive, {})
      except CatchableError as err:
        refused = true
        checkpoint err.msg
        check "developer-id" in err.msg or "team-id" in err.msg
      check refused

  # The sealed prefixes are read-only; make them removable, as the store does.
  discard execCmdEx("/bin/chmod -R u+w " & quoteShell(root))
  removeDir(root)
