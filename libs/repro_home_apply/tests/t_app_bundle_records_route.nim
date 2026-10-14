## GM4c: how a macOS application record is selected, routed and turned into
## an activation — platform-neutral, so it runs on every host.
##
## A `tarball` record with `installMethod = "app-bundle"` must reach the home
## archive realizer (never the `uses:` edge, which cannot unpack a disk image
## or place a bundle), carry its bundle / identifier / team into the
## realizer's input, and refuse at resolution when it cannot be realized:
## an application record for a non-macOS os, and the two declared-only vendor
## shapes (`pkg-install`, `installer-silent` on macOS), each naming the
## realizer it lacks. The realized record becomes one
## `macos.appBundle` resource in `~/Applications` at the reserved address.
## Store-And-Installation-Layout.md § macOS Application Bundles.
##
## Real selection, real projection, real records registered in this process
## (as the `package` macro registers them); nothing is downloaded. No mocks.
##
## Falsifying mutations: dropping `refuseUnrealizableMacosShape` from
## `archiveRouteFor` fails "declared-only vendor shapes are refused";
## removing `"dmg"` from `InstallerOnlyArchiveTypes` and the `appBundle`
## installer feature routes an application to the `uses:` edge and fails
## "an application routes to the home archive realizer".

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
register("gm4cinstallerapp", @[appRecord("installer-silent")])
register("gm4clinuxapp", @[appRecord("app-bundle", os = "linux")])
register("gm4cnoteam", @[block:
  var r = appRecord("app-bundle")
  r.detail.teamId = ""
  r])

proc macos(arch = "arm64"): RealizationTarget =
  profileRealizationTarget("macos", arch, isHost = false)

suite "GM4c: application records — selection, route, activation":

  test "an application routes to the home archive realizer with its " &
      "declarations":
    for arch in ["arm64", "x86_64"]:
      let resolution = resolveProfilePackage("gm4capprecord", macos(arch),
        @[rkTarball])
      check resolution.selection.kind == rkTarball
      check resolution.archiveRoute == arInstaller
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
    try:
      discard resolveProfilePackage("gm4cinstallerapp", macos(), @[rkTarball])
      check false
    except ValueError as err:
      check "installer application" in err.msg
      check MacosInstallerAppRefusal in err.msg

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

  test "a bundle name that is not one .app component fails validation":
    var bad = Resource(kind: rkMacosAppBundle, address: "home.package.x.app",
      appBundleSource: "/store/x/App.app", appBundleTargetDir: "/h/Applications",
      appBundleName: "../App.app", appBundleIdentity: @[1'u8])
    check "single '<Name>.app'" in resourceValidationError(bad)
    bad.appBundleName = "App"
    check resourceValidationError(bad).len > 0
    bad.appBundleName = "App.app"
    bad.appBundleTargetDir = "Applications"
    check "non-absolute" in resourceValidationError(bad)
