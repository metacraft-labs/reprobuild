## GM4c: how a macOS application record is selected, routed and turned into
## an activation — platform-neutral, so it runs on every host.
##
## macOS bundle and installer-application records reach the shared tarball
## provisioning edge with their identity and installation fields intact.
## Unsupported vendor shapes, missing verification fields and unsafe product
## paths are refused during resolution, before downloads. The selected
## metadata still determines the macos.appBundle activation resource.
## Real package registration, selection and projection; no mocks or downloads.

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_home_apply
import repro_home_apply/builtin_adapter
import repro_home_apply/env_binding
import repro_home_resources

proc appRecord(installMethod: string; os = "macos"; cpu = "any";
               archiveType = "dmg"): TarballProvisioningDef =
  TarballProvisioningDef(url: "https://example.invalid/App-3.0." & archiveType,
    sha256: repeat('b', 64), archiveType: archiveType,
    executablePath: "App.app/Contents/MacOS/App",
    packageId: "gm4capprecord@3.0", lockIdentity: "fixture:gm4capprecord@3.0",
    cpu: cpu, os: os,
    detail: TarballArchiveDetail(version: "3.0", installMethod: installMethod,
      appBundle: "App.app", bundleId: "dev.reprobuild.record",
      teamId: "ABCDE12345"))

proc register(name: string; records: seq[TarballProvisioningDef]) =
  registerPackageDef(PackageDef(packageName: name,
    sourceFile: currentSourcePath(), sourceLine: 1,
    tarballProvisioning: records))

register("gm4capprecord", @[appRecord("app-bundle")])
register("gm4cpkginstall", @[appRecord("pkg-install")])
register("gm4cinstallerapp", @[block:
  # The OpenWebStart shape: an install4j installer on a disk image whose
  # product is a bundle inside a folder of the installed prefix.
  var r = appRecord("installer-silent")
  r.executablePath = "App/App.app/Contents/MacOS/App"
  r.detail.installerApp = "App Installer.app"
  r.detail.installerArgs = @["-q", "-dir", "${install_dir}/App"]
  r.detail.appBundle = "App/App.app"
  r])
register("gm4cinstallernoapp", @[appRecord("installer-silent")])
for field in ["appBundle", "bundleId", "teamId", "version"]:
  var r = appRecord("installer-silent")
  r.detail.installerApp = "App Installer.app"
  r.detail.installerArgs = @["-q"]
  case field
  of "appBundle": r.detail.appBundle = ""
  of "bundleId": r.detail.bundleId = ""
  of "teamId": r.detail.teamId = ""
  of "version": r.detail.version = ""
  register("gm4cinstallerno" & field.toLowerAscii(), @[r])
# Paths the realizer would walk that the spec rules out (§ Installer
# applications, "Declaring it"), each refused at resolution.
const BadInstallerShapes = [
  ("deepproduct", "appBundle", "App/Sub/App.app"),
  ("bundleinbundle", "appBundle", "App.app/Contents/Inner.app"),
  ("escapingproduct", "appBundle", "../App/App.app"),
  ("hiddenfolder", "appBundle", ".App/App.app"),
  ("notabundle", "appBundle", "App/App"),
  ("escapinginstaller", "installerApp", "../App Installer.app"),
  ("absoluteinstaller", "installerApp", "/Volumes/App/App Installer.app"),
  ("pkgarchive", "archiveType", "pkg")]
for (label, field, value) in BadInstallerShapes:
  var r = appRecord("installer-silent")
  r.detail.installerApp = "App Installer.app"
  r.detail.installerArgs = @["-q"]
  r.detail.appBundle = "App/App.app"
  case field
  of "appBundle": r.detail.appBundle = value
  of "installerApp": r.detail.installerApp = value
  of "archiveType": r.archiveType = value
  register("gm4cinstallerbad" & label, @[r])
register("gm4clinuxinstallerapp", @[block:
  var r = appRecord("installer-silent", os = "linux")
  r.detail.installerApp = "App Installer.app"
  r])
register("gm4clinuxapp", @[appRecord("app-bundle", os = "linux")])
register("gm4cnoteam", @[block:
  var r = appRecord("app-bundle")
  r.detail.teamId = ""
  r])

proc macos(arch = "arm64"): RealizationTarget =
  profileRealizationTarget("macos", arch, isHost = false)

suite "GM4c: application records — selection, route, activation":

  test "an application routes to the shared provisioning edge with its " &
      "declarations":
    for arch in ["arm64", "x86_64"]:
      let resolution = resolveProfilePackage("gm4capprecord", macos(arch),
        @[rkTarball])
      check resolution.selection.kind == rkTarball
      check resolution.archiveRoute == arExtract
      let archive = resolution.archive
      check archive.installMethod == imAppBundle
      check archive.archiveFormat == afDmg
      check archive.appBundle == "App.app"
      check archive.bundleId == "dev.reprobuild.record"
      check archive.teamId == "ABCDE12345"
      check archive.builtinVersion == "3.0"
      check appBundleLeaf(archive) == "App.app"
      let expectation = appBundleExpectationOf(archive)
      check expectation.bundleId == "dev.reprobuild.record"
      check expectation.version == "3.0"
      check expectation.teamId == "ABCDE12345"

  test "disk images and packages are installer-only archive types":
    for t in ["dmg", "pkg"]:
      check t in InstallerOnlyArchiveTypes
    let zipped = toProjectInterface(PackageDef(packageName: "probe",
      toolUses: @[PackageUseDef(rawConstraint: "gm4capprecord",
        packageSelector: "gm4capprecord", executableName: "gm4capprecord")]),
      registeredPackages())
    let record = zipped.toolUses[0].tarballProvisioning[0]
    check "appBundle" in archiveInstallerFeatures(record)
    check "installMethod app-bundle" in archiveInstallerFeatures(record)

  test "declared-only vendor shapes are refused, naming why":
    try:
      discard resolveProfilePackage("gm4cpkginstall", macos(), @[rkTarball])
      check false
    except ValueError as err:
      check "pkg-install" in err.msg
      check "system scope" in err.msg
      check MacosPkgInstallRefusal in err.msg

  test "an installer application routes to the shared provisioning edge " &
      "with its declarations":
    for arch in ["arm64", "x86_64"]:
      let resolution = resolveProfilePackage("gm4cinstallerapp", macos(arch),
        @[rkTarball])
      check resolution.selection.kind == rkTarball
      check resolution.archiveRoute == arExtract
      let archive = resolution.archive
      check archive.installMethod == imInstallerSilent
      check archive.archiveFormat == afDmg
      check archive.installerApp == "App Installer.app"
      check archive.installerArgs == @["-q", "-dir", "${install_dir}/App"]
      check archive.appBundle == "App/App.app"
      check archive.bundleId == "dev.reprobuild.record"
      check archive.teamId == "ABCDE12345"
      check archive.builtinVersion == "3.0"
      check archive.digestAlgorithm == "sha256"
      check isMacosInstallerApp(archive)
      # The placed item is the folder the product bundle lives in.
      check appPlacedItem(archive) == (item: "App", mainBundle: "App.app")
      let expectation = appBundleExpectationOf(archive)
      check expectation.bundleId == "dev.reprobuild.record"
      check expectation.version == "3.0"
      check expectation.teamId == "ABCDE12345"
    # An app-bundle record's placed item is the bundle itself.
    let plain = resolveProfilePackage("gm4capprecord", macos(), @[rkTarball])
    check not isMacosInstallerApp(plain.archive)
    check appPlacedItem(plain.archive) == (item: "App.app", mainBundle: "")

  test "an installer application record missing a field it is verified " &
      "against is refused, naming the field":
    try:
      discard resolveProfilePackage("gm4cinstallernoapp", macos(),
        @[rkTarball])
      check false
    except ValueError as err:
      checkpoint err.msg
      check "installer application" in err.msg
      check "installerApp" in err.msg
    for field in ["appBundle", "bundleId", "teamId", "version"]:
      checkpoint field
      try:
        discard resolveProfilePackage("gm4cinstallerno" & field.toLowerAscii(),
          macos(), @[rkTarball])
        check false
      except ValueError as err:
        checkpoint err.msg
        check field in err.msg
    try:
      discard resolveProfilePackage("gm4clinuxinstallerapp",
        profileRealizationTarget("linux", "x86_64", isHost = false),
        @[rkTarball])
      check false
    except ValueError as err:
      check "macOS realization" in err.msg

  test "an installer application whose product or installer path the " &
      "realizer would not accept is refused at resolution":
    for (label, field, value) in BadInstallerShapes:
      checkpoint label & ": " & field & " = " & value
      try:
        discard resolveProfilePackage("gm4cinstallerbad" & label, macos(),
          @[rkTarball])
        check false
      except ValueError as err:
        checkpoint err.msg
        check field in err.msg or
          (field == "archiveType" and "pkg-install" in err.msg)

  test "an application record for another os is refused":
    try:
      discard resolveProfilePackage("gm4clinuxapp",
        profileRealizationTarget("linux", "x86_64", isHost = false),
        @[rkTarball])
      check false
    except ValueError as err:
      check "macOS realization" in err.msg

  test "an application record without a team cannot be realized":
    try:
      discard resolveProfilePackage("gm4cnoteam", macos(), @[rkTarball])
      check false
    except ValueError as err:
      check "teamId" in err.msg

  test "a realized bundle becomes one ~/Applications resource at the " &
      "reserved address":
    var app = RealizedRecord(packageId: "gm4capprecord")
    app.appBundle = AppBundleRealization(
      storeBundlePath: "/store/prefixes/gm4capprecord/3.0-x/App.app",
      bundleName: "App.app",
      expectation: AppBundleExpectation(bundleId: "dev.reprobuild.record",
        version: "3.0", teamId: "ABCDE12345"),
      identity: @[1'u8, 2, 3])
    let cli = RealizedRecord(packageId: "plaintool",
      resolvedExecutablePath: "/store/prefixes/plaintool/bin/plaintool",
      prefixAbsolutePath: "/store/prefixes/plaintool")
    let resources = planAppBundleActivations(@[cli, app], "/Users/someone")
    check resources.len == 1
    let res = resources[0]
    check res.kind == rkMacosAppBundle
    check res.address == "home.package.gm4capprecord.app"
    check packageIdOfAppBundleAddress(res.address) == "gm4capprecord"
    check packageIdOfAppBundleAddress("home.package.x.bin") == ""
    check res.appBundleTargetDir == "/Users/someone/Applications"
    check realWorldIdentity(res) == "/Users/someone/Applications/App.app"
    check res.appBundleIdentity == @[1'u8, 2, 3]
    check resourceValidationError(res) == ""
    check digestOfResource(res) == digestOfBytes([1'u8, 2, 3])
    # An application bundle contributes no PATH entry; a CLI package does.
    check prefixBinDirs(app).len == 0
    check prefixBinDirs(cli) == @["/store/prefixes/plaintool/bin"]

  test "a realized installer application places its product's folder":
    var app = RealizedRecord(packageId: "gm4cinstallerapp")
    app.appBundle = AppBundleRealization(
      storeBundlePath: "/store/prefixes/gm4cinstallerapp/3.0-x/App",
      bundleName: "App", mainBundlePath: "App.app",
      expectation: AppBundleExpectation(bundleId: "dev.reprobuild.record",
        version: "3.0", teamId: "ABCDE12345"),
      identity: @[4'u8, 5, 6])
    let resources = planAppBundleActivations(@[app], "/Users/someone")
    check resources.len == 1
    let res = resources[0]
    check res.address == "home.package.gm4cinstallerapp.app"
    check res.appBundleName == "App"
    check res.appBundleMainPath == "App.app"
    check realWorldIdentity(res) == "/Users/someone/Applications/App"
    check resourceValidationError(res) == ""
    check digestOfResource(res) == digestOfBytes([4'u8, 5, 6])

  test "a placed-item name that is not one component fails validation":
    var bad = Resource(kind: rkMacosAppBundle, address: "home.package.x.app",
      appBundleSource: "/store/x/App.app", appBundleTargetDir: "/h/Applications",
      appBundleName: "../App.app", appBundleIdentity: @[1'u8])
    check "single component" in resourceValidationError(bad)
    for name in ["", "..", ".", "a/b", ".hidden"]:
      bad.appBundleName = name
      check resourceValidationError(bad).len > 0
    # A folder (an installer application's product) must name the bundle
    # inside it that the trust checks run on; a bundle must not.
    bad.appBundleName = "App"
    check "main bundle" in resourceValidationError(bad)
    bad.appBundleMainPath = "App.app"
    check resourceValidationError(bad) == ""
    bad.appBundleMainPath = "../App.app"
    check resourceValidationError(bad).len > 0
    # The main bundle lies DIRECTLY in the folder: the folder identity pins
    # only those bundles.
    bad.appBundleMainPath = "Sub/App.app"
    check "directly inside" in resourceValidationError(bad)
    bad.appBundleName = "App.app"
    bad.appBundleMainPath = "Inner.app"
    check resourceValidationError(bad).len > 0
    bad.appBundleMainPath = ""
    check resourceValidationError(bad) == ""
    bad.appBundleTargetDir = "Applications"
    check "non-absolute" in resourceValidationError(bad)
