## Installer applications: realizing a macOS `installer-silent` record by
## running the verified installer confined, and placing what it produced
## (Store-And-Installation-Layout.md § macOS Application Bundles,
## "Installer applications"; issue
## `2026-10-14-macos-installer-applications-have-no-realizer`).
##
## Every case runs the real realizer (`realizeBuiltinPackage`, reached
## through `resolveProfilePackage` the way a home profile reaches it) on a
## real archive: the archive is downloaded from a `file://` URL and its
## sha256 checked, the installer is copied out of a disk image attached with
## `hdiutil` (or a zip expanded with `ditto`), verified with the real
## `codesign`, run under the real `/usr/bin/sandbox-exec`, and the product it
## wrote is verified and published to a real store. Placement uses the real
## `macos.appBundle` driver into a scratch Applications directory.
##
## FIXTURES, and why each is not a mock:
##
## * The installer application is built at test time
##   (`macos_app_fixtures.makeFixtureInstallerApp`): an ad-hoc signed bundle
##   whose main executable is a `/bin/sh` script implementing install4j's
##   unattended protocol (`-dir <d>`: copy the product there). A real
##   install4j installer cannot be built here (install4j is proprietary) and
##   a vendor installer cannot be made to misbehave on request; the script
##   lets each case make it do exactly one wrong thing. The realizer treats
##   it like any installer: it does not know it is a script. The genuine
##   OpenWebStart installer is realized for real by reprobuild-packages'
##   `verify-macos-apps` (strict policy).
## * The product folder it installs (`makeFixtureProductFolder`) holds real
##   compiled, signed bundles laid out as OpenWebStart's is.
## * TRUST POLICY: bundles built at test time cannot carry a Developer ID
##   signature or a notarization ticket, so these cases relax exactly checks
##   4 and 5 through the library API (`{atrUnanchoredTeamIdentifier,
##   atrSkipNotarization}`), as the GM4c tests do; checks 1 to 3 (Info.plist,
##   `codesign --verify --deep --strict`, team equality) run for real and are
##   what the refusals below trip. The sandbox is never relaxed.
##
## What the confinement cases prove, each against the real kernel sandbox:
## a write outside the prefix (to a directory outside the per-user temporary
## directory) is refused and leaves no file; a `defaults write` of a
## test-unique preference domain is refused and leaves the domain absent; a
## TCP connection to a listener in this process is refused -- each with a
## POSITIVE CONTROL showing the same operation succeeds unconfined, so the
## refusal is the sandbox's and not a broken probe. In each the realization
## still succeeds, because the product is complete.
##
## Never touches the real `~/Applications` or `/Applications`.
##
## Falsifying mutations: running the installer without `sandbox-exec` fails
## the three confinement cases (the leak file, the preference and the
## connection appear); dropping the prefix-contents check fails "a stray
## file in the prefix root"; dropping the product-exists check fails "an
## installer that installs nothing"; dropping the installer verification
## fails "an installer signed by another team is never run"; dropping the
## installer arguments from the prefix identity fails "the installer's
## arguments are part of the prefix identity".

when defined(macosx):
  import std/[nativesockets, net, os, osproc, strutils, tempfiles, times,
    unittest]

  import repro_project_dsl
  import repro_local_store
  import repro_home_apply
  import repro_home_apply/builtin_adapter
  import repro_home_apply/macos_archives
  import repro_home_apply/macos_installer
  import repro_home_resources
  import repro_test_support/macos_app_fixtures

  const
    ProductId = "dev.reprobuild.installerapp.product"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}
    Item = "Prod"
    MainName = "Prod"

  let root = createTempDir("repro-installer-app-realize-", "")
  # A directory OUTSIDE everything the sandbox lets the installer write: not
  # the staging prefix, not its scratch, not the per-user temporary
  # directory (where `root` lives).
  let outsideRoot = createTempDir("repro-installer-outside-", "",
    "/private/tmp")
  # The per-user temporary directory IS writable by the installer (spec:
  # install4j unpacks its runtime there), so reports from inside the sandbox
  # are written there.
  let userTemp = darwinUserTempDir()
  var counter = 0

  proc macos(): RealizationTarget =
    profileRealizationTarget("macos", "arm64", isHost = false)

  proc installerRecord(archive, name: string; archiveType = "dmg";
                       args: seq[string] = @[];
                       appBundle = Item & "/" & MainName & ".app";
                       bundleId = ProductId; version = "1.0.0";
                       installerApp = "Prod Installer.app"):
      TarballProvisioningDef =
    let sha = sha256Of(archive)
    TarballProvisioningDef(url: "file://" & archive, sha256: sha,
      archiveType: archiveType,
      executablePath: appBundle & "/Contents/MacOS/" & MainName,
      packageId: name & "@" & version,
      lockIdentity: "tarball:" & name & "@" & version & ":sha256:" & sha,
      cpu: "any", os: "macos",
      detail: TarballArchiveDetail(version: version,
        installMethod: "installer-silent", installerApp: installerApp,
        installerArgs: @["-q", "-dir", "${install_dir}/" & Item] & args,
        appBundle: appBundle, bundleId: bundleId, teamId: FixtureTeamId))

  proc register(name: string; record: TarballProvisioningDef) =
    registerPackageDef(PackageDef(packageName: name,
      sourceFile: currentSourcePath(), sourceLine: 1,
      tarballProvisioning: @[record]))

  proc fixtureInstaller(label: string; extraScript = ""; install = true;
                        teamId = FixtureTeamId; helperTeamId = "";
                        version = "1.0.0"; archive = "dmg";
                        payload = ""): string =
    ## A fresh installer application in an archive of its own; returns the
    ## archive path.
    inc counter
    let dir = root / ("fixture-" & label & "-" & $counter)
    createDir(dir)
    let product =
      if payload.len > 0: payload
      else: makeFixtureProductFolder(dir / "product", Item, MainName,
        ProductId, version, helperTeamId = helperTeamId)
    let installer = makeFixtureInstallerApp(dir / "installer",
      "Prod Installer", product, teamId = teamId, extraScript = extraScript,
      install = install)
    case archive
    of "zip": makeFixtureZip(dir, "installer.zip", installer)
    else: makeFixtureDmg(dir, "installer.dmg", [installer])

  proc resolve(name: string; record: TarballProvisioningDef):
      ArchiveRealization =
    register(name, record)
    resolveProfilePackage(name, macos(), @[rkTarball]).archive

  proc realize(name: string; record: TarballProvisioningDef;
               store: var Store): RealizeBuiltinResult =
    realizeBuiltinPackage(store, resolve(name, record), Relaxed)

  proc text(bytes: seq[byte]): string =
    for b in bytes: result.add(char(b))

  proc storeHas(store: var Store; name: string): bool =
    for row in listPrefixes(store):
      if row.packageName == name:
        return true

  proc entries(dir: string): seq[string] =
    if dirExists(dir):
      for _, path in walkDir(dir, relative = true):
        result.add(path)

  proc defaultsDomainExists(domain: string): bool =
    execCmdEx("/usr/bin/defaults read " & quoteShell(domain)).exitCode == 0

  suite "installer applications: confined realization":
    var store = openStore(root / "store")

    test "the installer's product is realized as a folder, verified, " &
        "placed, re-observed and removed":
      let dmg = fixtureInstaller("lifecycle")
      let archive = resolve("instlifecycle", installerRecord(dmg,
        "instlifecycle"))
      check isMacosInstallerApp(archive)
      let realized = realizeBuiltinPackage(store, archive, Relaxed)
      let prefix = realized.prefixAbsolutePath
      # The prefix holds the placed item (the folder) and the receipt only.
      check realized.appBundlePath == prefix / Item
      check realized.appBundleMainPath == MainName & ".app"
      check dirExists(prefix / Item / (MainName & ".app"))
      check dirExists(prefix / Item / (Item & " Helper.app"))
      check dirExists(prefix / Item / ".support" / (Item & " Update.app"))
      check fileExists(prefix / Item / "readme.txt")
      for entry in entries(prefix):
        check entry in [Item, ".repro-receipt"]
      check realized.resolvedExecutablePath ==
        prefix / Item / (MainName & ".app") / "Contents" / "MacOS" / MainName
      # The recorded identity is the folder identity.
      check realized.appBundleIdentity ==
        readPlacedItemIdentityBytes(prefix / Item)
      let identity = text(realized.appBundleIdentity)
      checkpoint identity
      check identity.startsWith(AppFolderIdentityFormat & "\n")
      check ("bundle=" & MainName & ".app\n") in identity
      check ("bundle=" & Item & " Helper.app\n") in identity
      check "Update.app" notin identity   # not directly in the folder
      check attachedImagesOf(dmg).len == 0
      # The installer ran from scratch outside the prefix, which is gone.
      check not dirExists(prefix / ".repro-download")

      # Placement into a scratch Applications directory.
      let apps = root / "home-lifecycle" / "Applications"
      discard placeAppBundle(realized.appBundlePath, apps, Item,
        AppBundleExpectation(bundleId: ProductId, version: "1.0.0",
          teamId: FixtureTeamId), Relaxed,
        pinned = realized.appBundleIdentity,
        mainBundle = realized.appBundleMainPath)
      let target = apps / Item
      check dirExists(target / (MainName & ".app"))
      check fileExists(target / "readme.txt")
      check entries(apps) == @[Item]
      let observed = observeAppBundleAt(target)
      check observed.present
      check observed.rawBytes == realized.appBundleIdentity
      # A second realization is a cache hit with the same identity.
      let again = realizeBuiltinPackage(store, archive, Relaxed)
      check again.cacheHit
      check again.appBundlePath == realized.appBundlePath
      check again.appBundleMainPath == realized.appBundleMainPath
      check again.appBundleIdentity == realized.appBundleIdentity
      removeAppBundle(target)
      check not dirExists(target)
      check entries(apps).len == 0

    test "the installer's arguments are part of the prefix identity":
      # They decide what the installer installs and where, so a record that
      # changes them is never served the prefix the old arguments produced.
      let dmg = fixtureInstaller("args")
      var archive = resolve("instargs", installerRecord(dmg, "instargs"))
      let first = realizeBuiltinPackage(store, archive, Relaxed)
      archive.installerArgs.add("-unattendedExtra")
      let second = realizeBuiltinPackage(store, archive, Relaxed)
      check not second.cacheHit
      check second.prefixAbsolutePath != first.prefixAbsolutePath
      check dirExists(second.appBundlePath / (MainName & ".app"))

    test "a zip-delivered installer is realized the same way":
      let zip = fixtureInstaller("zip", archive = "zip")
      let realized = realize("instzip", installerRecord(zip, "instzip",
        archiveType = "zip"), store)
      check dirExists(realized.appBundlePath / (MainName & ".app"))

    test "writes outside the prefix and preference writes are refused by " &
        "the sandbox, and the realization still succeeds":
      let domain = "dev.reprobuild.test.installerapp." &
        $getCurrentProcessId() & "." & $epochTime().int64
      let outside = outsideRoot / "outside-write"
      createDir(outside)
      let report = userTemp / ("repro-installer-report-" &
        $getCurrentProcessId() & ".txt")
      removeFile(report)
      defer:
        removeFile(report)
        discard execCmdEx("/usr/bin/defaults delete " & quoteShell(domain))
      # Positive controls: unconfined, the same operations succeed.
      writeFile(outside / "control.txt", "x")
      check fileExists(outside / "control.txt")
      check execCmdEx("/usr/bin/defaults write " & quoteShell(domain) &
        " control -string yes").exitCode == 0
      check defaultsDomainExists(domain)
      check execCmdEx("/usr/bin/defaults delete " &
        quoteShell(domain)).exitCode == 0
      check not defaultsDomainExists(domain)
      let dmg = fixtureInstaller("confined", extraScript =
        "if echo leak > \"$outside/leak.txt\"; then w=written; " &
          "else w=refused; fi\n" &
        "if /usr/bin/defaults write " & domain & " leaked -string yes; " &
          "then d=written; else d=refused; fi\n" &
        "echo \"write=$w defaults=$d\" > \"$report\"\n")
      let realized = realize("instconfined", installerRecord(dmg,
        "instconfined", args = @["-outside", outside, "-report", report]),
        store)
      check dirExists(realized.appBundlePath / (MainName & ".app"))
      check fileExists(report)
      let said = readFile(report)
      checkpoint said
      check "write=refused" in said
      check "defaults=refused" in said
      check not fileExists(outside / "leak.txt")
      check not defaultsDomainExists(domain)

    test "network access is refused by the sandbox":
      let server = newSocket()
      defer: server.close()
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(0), "127.0.0.1")
      server.listen()
      let port = $server.getLocalAddr()[1].int
      # Positive control: unconfined, the probe connects.
      check execCmdEx("/usr/bin/nc -z -G 3 127.0.0.1 " & port).exitCode == 0
      var accepted: Socket
      server.accept(accepted)
      accepted.close()
      let report = userTemp / ("repro-installer-net-" &
        $getCurrentProcessId() & ".txt")
      removeFile(report)
      defer: removeFile(report)
      let dmg = fixtureInstaller("network", extraScript =
        "if /usr/bin/nc -z -G 3 127.0.0.1 " & port &
          "; then n=connected; else n=refused; fi\n" &
        "echo \"net=$n\" > \"$report\"\n")
      let realized = realize("instnetwork", installerRecord(dmg,
        "instnetwork", args = @["-report", report]), store)
      check dirExists(realized.appBundlePath)
      let said = readFile(report)
      checkpoint said
      check "net=refused" in said
      # Nothing connected: a pending connection would be accepted here.
      server.getFd().setBlocking(false)
      var pending: Socket
      var connected = true
      try:
        server.accept(pending)
        pending.close()
      except OSError:
        connected = false
      check not connected

    test "an installer that exits 0 without installing the product is " &
        "refused and nothing is published":
      let dmg = fixtureInstaller("nothing", install = false)
      try:
        discard realize("instnothing", installerRecord(dmg, "instnothing"),
          store)
        check false
      except EInstallerApp as err:
        checkpoint err.msg
        check err.check == "product"
        check (Item & "/" & MainName & ".app") in err.msg
        check "installing nothing" in err.msg   # the installer's output
      check not storeHas(store, "instnothing")
      check attachedImagesOf(dmg).len == 0

    test "an installer that exits non-zero is refused, quoting its output":
      let dmg = fixtureInstaller("exit", extraScript =
        "echo 'fixture installer: disk full'; exit 3")
      try:
        discard realize("instexit", installerRecord(dmg, "instexit"), store)
        check false
      except EInstallerApp as err:
        checkpoint err.msg
        check err.check == "exit-status"
        check "exited 3" in err.msg
        check "disk full" in err.msg
      check not storeHas(store, "instexit")

    test "a stray file in the prefix root is refused":
      let dmg = fixtureInstaller("stray", extraScript =
        "echo stray > \"$(dirname \"$dest\")/stray.txt\"")
      try:
        discard realize("inststray", installerRecord(dmg, "inststray"), store)
        check false
      except EInstallerApp as err:
        checkpoint err.msg
        check err.check == "prefix-contents"
        check "stray.txt" in err.msg
      check not storeHas(store, "inststray")

    test "an installer signed by another team is never run":
      let marker = userTemp / ("repro-installer-ran-" &
        $getCurrentProcessId() & ".txt")
      removeFile(marker)
      defer: removeFile(marker)
      let dmg = fixtureInstaller("team", teamId = "OTHERTEAM1",
        extraScript = "echo ran > \"$report\"")
      try:
        discard realize("instteam", installerRecord(dmg, "instteam",
          args = @["-report", marker]), store)
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "team-id"
        check "Prod Installer.app" in err.bundlePath
      check not fileExists(marker)
      check not storeHas(store, "instteam")
      check attachedImagesOf(dmg).len == 0

    test "a product whose bundle identifier differs from the record is " &
        "refused and nothing is published":
      let dmg = fixtureInstaller("bundleid")
      try:
        discard realize("instbundleid", installerRecord(dmg, "instbundleid",
          bundleId = "dev.reprobuild.someoneelse"), store)
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "bundle-id"
      check not storeHas(store, "instbundleid")

    test "another bundle in the product signed by another team is refused":
      let dmg = fixtureInstaller("helperteam", helperTeamId = "OTHERTEAM1")
      try:
        discard realize("insthelper", installerRecord(dmg, "insthelper"),
          store)
        check false
      except EAppBundleRefused as err:
        checkpoint err.msg
        check err.check == "team-id"
        check "Helper.app" in err.bundlePath
      check not storeHas(store, "insthelper")

    test "an installer whose product is a single bundle places the bundle":
      let dir = root / "single"
      createDir(dir)
      let product = makeFixtureApp(dir, MainName, ProductId, "1.0.0")
      inc counter
      let installer = makeFixtureInstallerApp(dir / "installer",
        "Prod Installer", product)
      let dmg = makeFixtureDmg(dir, "single.dmg", [installer])
      var record = installerRecord(dmg, "instsingle",
        appBundle = MainName & ".app")
      record.detail.installerArgs = @["-q", "-dir",
        "${install_dir}/" & MainName & ".app"]
      let realized = realize("instsingle", record, store)
      check realized.appBundlePath ==
        realized.prefixAbsolutePath / (MainName & ".app")
      check realized.appBundleMainPath == ""
      # A single bundle's identity is exactly an app-bundle realization's.
      check realized.appBundleIdentity == appBundleCanonicalBytes(
        readAppBundleIdentity(realized.appBundlePath))

    store.close()

  suite "installer applications: the confined runner":

    test "an installer still running at the timeout is killed and fails":
      let dir = root / "timeout"
      createDir(dir / "prefix")
      createDir(dir / "scratch")
      # The installer starts a child that would outlive it (install4j's
      # launcher starts a Java runtime); the child must be killed too.
      let marker = dir / "prefix" / "child-survived"
      let installer = makeFixtureInstallerApp(dir, "Slow Installer", "",
        extraScript = "(sleep 4; echo survived > \"$dest/child-survived\") &\n" &
          "sleep 60")
      let started = epochTime()
      try:
        discard runConfinedInstaller(installer, @["-dir", dir / "prefix"],
          dir / "prefix", dir / "scratch", timeout = initDuration(seconds = 2))
        check false
      except EInstallerApp as err:
        checkpoint err.msg
        check err.check == "timeout"
        check "fixture installer: installed" notin err.msg
      check epochTime() - started < 30.0
      sleep(6000)
      check not fileExists(marker)

    test "a host without sandbox-exec refuses to run the installer":
      let dir = root / "nosandbox"
      createDir(dir / "prefix")
      createDir(dir / "scratch")
      let marker = userTemp / ("repro-installer-unconfined-" &
        $getCurrentProcessId() & ".txt")
      removeFile(marker)
      defer: removeFile(marker)
      let installer = makeFixtureInstallerApp(dir, "Any Installer", "",
        extraScript = "echo ran > \"$report\"")
      try:
        discard runConfinedInstaller(installer, @["-dir", dir / "prefix",
          "-report", marker], dir / "prefix", dir / "scratch",
          sandboxExe = dir / "no-such-sandbox-exec")
        check false
      except EInstallerApp as err:
        checkpoint err.msg
        check err.check == "sandbox"
      check not fileExists(marker)

    test "the policy names every writable path resolved and escaped":
      let profile = installerSandboxProfile(["/private/tmp/a \"q\"\\b"])
      check "(deny file-write* (require-not (require-any" in profile
      check "(subpath \"/private/tmp/a \\\"q\\\"\\\\b\")" in profile
      check "(deny user-preference-write)" in profile
      check "(deny network*)" in profile
      check "(literal \"/dev/null\")" in profile
      check darwinUserTempDir().startsWith("/private/var/")

  removeDir(root)
  removeDir(outsideRoot)
