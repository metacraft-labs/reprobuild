## Acquisition plans must select only realizations satisfying a recipe's range.
## No mocks: pure production planning over declared interface records; no
## download. The last suite drives path mode end to end against real
## executables on a temporary ``$PATH`` and a real archive realized through the
## realizer's own ``file://`` arm into a temporary store.
import std/[options, os, osproc, strutils, tempfiles, unittest]
import repro_interface_artifacts
import repro_tool_profiles

let macArm = realizationTargetFor(pcAArch64, poMacos)
let windows = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc fixture(constraint: string): InterfaceToolUse =
  result = InterfaceToolUse(packageSelector: "fixture", rawConstraint: constraint)
  for version in ["1.51.0", "2.2.0", ""]:
    result.tarballProvisioning.add(InterfaceTarballProvisioning(
      cpu: "aarch64", os: "macos", url: "https://example.invalid/" & version,
      sha256: repeat('a', 64), executablePath: "fixture"))
    result.tarballProvisioning[^1].detail.version = version
    result.scoopProvisioning.add(InterfaceScoopProvisioning(
      bucket: "main", app: "fixture", version: version,
      preferredVersion: ">=1.0", executablePath: "fixture.exe"))

suite "uses realization version ranges":
  test "tarball refuses the reported just >=2.0 mismatch":
    var useDef = fixture("fixture >=2.0")
    useDef.tarballProvisioning.setLen(1)
    try:
      discard tarballAcquisitionPlan(useDef, target = macArm)
      check false
    except ValueError as err:
      check "fixture >=2.0" in err.msg
      check "1.51.0" in err.msg
      check "offered" in err.msg

  test "scoop refuses incompatible offered version":
    var useDef = fixture("fixture >=2.0")
    useDef.scoopProvisioning.setLen(1)
    try:
      discard scoopAcquisitionPlan(useDef, windows)
      check false
    except ValueError as err:
      check "fixture >=2.0" in err.msg
      check "1.51.0" in err.msg
      check "offered" in err.msg

  test "range filters before declaration order for both plans":
    let useDef = fixture("fixture >=2.0 <3.0")
    check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("2.2.0")
    check scoopAcquisitionPlan(useDef, windows).version == "2.2.0"

  test "supported solver range operators apply to both plans":
    for constraint in ["^2.0", "~2.2", ">1.51.0, <=2.2.0", "=2.2.0"]:
      let useDef = fixture("fixture " & constraint)
      check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("2.2.0")
      check scoopAcquisitionPlan(useDef, windows).version == "2.2.0"

  test "unversioned records are admitted only without a range":
    var useDef = fixture("fixture >=2.0")
    useDef.tarballProvisioning = @[useDef.tarballProvisioning[2]]
    useDef.scoopProvisioning = @[useDef.scoopProvisioning[2]]
    expect ValueError:
      discard tarballAcquisitionPlan(useDef, target = macArm)
    expect ValueError:
      discard scoopAcquisitionPlan(useDef, windows)
    useDef.rawConstraint = "fixture"
    check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("/")
    check scoopAcquisitionPlan(useDef, windows).version == ""

  test "invalid ranges and versions cannot silently select":
    for constraint in ["fixture >=nope", "fixture >=3.0"]:
      let useDef = fixture(constraint)
      expect ValueError:
        discard tarballAcquisitionPlan(useDef, target = macArm)
      expect ValueError:
        discard scoopAcquisitionPlan(useDef, windows)
    var useDef = fixture("fixture >=2.0")
    useDef.tarballProvisioning[1].detail.version = "not-a-version"
    useDef.scoopProvisioning[1].version = "not-a-version"
    expect ValueError:
      discard tarballAcquisitionPlan(useDef, target = macArm)
    expect ValueError:
      discard scoopAcquisitionPlan(useDef, windows)

  test "whitespace separates the selector from its range":
    for constraint in ["  fixture\t>=2.0  ", "fixture   >=2.0", "fixture\n>=2.0"]:
      let useDef = fixture(constraint)
      check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("2.2.0")
      check scoopAcquisitionPlan(useDef, windows).version == "2.2.0"
    check scoopAcquisitionPlan(fixture("  fixture  "), windows).version == "1.51.0"

  test "ineligible contributors do not create ambiguity":
    var useDef = fixture("fixture >=2.0")
    useDef.tarballProvisioning[0].contributor = "other"
    useDef.scoopProvisioning[0].contributor = "other"
    check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("2.2.0")
    check scoopAcquisitionPlan(useDef, windows).version == "2.2.0"
    useDef.tarballProvisioning[0].detail.version = "2.3.0"
    useDef.scoopProvisioning[0].version = "2.3.0"
    expect ValueError:
      discard tarballAcquisitionPlan(useDef, target = macArm)
    expect ValueError:
      discard scoopAcquisitionPlan(useDef, windows)

  test "range filtering precedes coordinate specificity":
    var useDef = fixture("fixture >=2.0")
    useDef.tarballProvisioning[1].cpu = "any"
    useDef.tarballProvisioning[1].os = "any"
    check tarballAcquisitionPlan(useDef, target = macArm).url.endsWith("2.2.0")

  test "profile exact pins stay exact and contributor pins still filter":
    let useDef = fixture("fixture >=2.0")
    check selectTarballRecord(useDef.tarballProvisioning, macArm,
      version = "1.51.0").index == 0
    check selectScoopRecord(useDef.scoopProvisioning, windows,
      version = "1.51.0").index == 0
    check selectTarballRecord(useDef.tarballProvisioning, macArm,
      version = "1.51").status == kcVersionNotOffered
    check selectScoopRecord(useDef.scoopProvisioning, windows,
      version = "1.51").status == kcVersionNotOffered
    check selectTarballRecord(useDef.tarballProvisioning, macArm,
      contributor = some("missing")).status ==
      kcContributorNotOffered
    check selectScoopRecord(useDef.scoopProvisioning, windows,
      contributor = some("missing")).status ==
      kcContributorNotOffered

proc ownTarget(record: InterfaceTarballProvisioning): RealizationTarget =
  ## The target a record declares for itself; a record without coordinates
  ## (the Linux source archive) serves every host, so the host stands in.
  if record.cpu.len == 0 or record.os.len == 0:
    return hostRealizationTarget()
  let cpu = parseEnum[PlatformCpu](record.cpu)
  realizationTargetFor(cpu, parseEnum[PlatformOs](record.os),
    level = (if cpu == pcX86_64: mlX86_64_v1 else: mlNone))

suite "reprobuild's own Nim records satisfy the ranges it asks for":
  # The range check above holds every caller to its range, reprobuild's own
  # bootstrap included. The bootstrap asks for `nim >=2.2 <3.0` and the
  # source build for `nim ==<version>`; records built in code rather than
  # through the `tarball` DSL statement carried no version, so after the
  # range check every macOS and Windows host, and every Linux host without
  # Nix, could no longer provision the Nim that compiles recipes (measured on
  # m1 at reprobuild 9530a77f and 8554984c: "offered: unversioned").
  test "the bootstrap Nim plans on every target it declares":
    let useDef = bootstrapNimToolUse()
    for record in useDef.tarballProvisioning:
      checkpoint record.url
      check record.detail.version.len > 0
      var single = useDef
      single.tarballProvisioning = @[record]
      check tarballAcquisitionPlan(single, target = ownTarget(record)).url ==
        record.url

  test "the bootstrap Nim records' version is the one their ids name":
    # The version the range check reads and the version the lock identity
    # names must be the same release, or a lock written for one archive
    # would be satisfied by the range check for another.
    for record in bootstrapNimToolUse().tarballProvisioning:
      checkpoint record.url
      check record.detail.version == BootstrapNimVersion
      check record.packageId.endsWith("@" & BootstrapNimVersion)
      check ("@" & BootstrapNimVersion & ":") in record.lockIdentity
      check BootstrapNimVersion in record.url

  test "the bootstrap Nim plans on this host":
    let useDef = bootstrapNimToolUse()
    if useDef.tarballProvisioning.len > 0:
      check tarballAcquisitionPlan(useDef).url.len > 0
      check "of which" notin describeBootstrapNimRoute(bnrArchive)

  test "the Nim source archive satisfies its own exact constraint":
    let useDef = nimSourceToolUse("2.2.10", BootstrapNimSourceTarballUrl,
      BootstrapNimSourceTarballSha256)
    check tarballAcquisitionPlan(useDef).url == BootstrapNimSourceTarballUrl
    let other = nimSourceToolUse("2.2.9", BootstrapNimSourceTarballUrl,
      BootstrapNimSourceTarballSha256)
    check tarballAcquisitionPlan(other).url == BootstrapNimSourceTarballUrl

  test "a pinned binary Nim archive satisfies its own exact constraint":
    # `provisionPinnedNim`'s binary route (a lock-pinned official archive).
    let useDef = pinnedNimArchiveToolUse("2.2.10",
      "https://nim-lang.org/download/nim-2.2.10_x64.zip", repeat('a', 64),
      "zip")
    check useDef.tarballProvisioning[0].detail.version == "2.2.10"
    check tarballAcquisitionPlan(useDef).url ==
      "https://nim-lang.org/download/nim-2.2.10_x64.zip"

# ---------------------------------------------------------------------------
# A nixPackage arm carries no declared version: whatever the pinned nixpkgs
# builds is what the tool reports, so the range is held AFTER realization,
# against the version probe. Nothing is mocked: the refusal is a pure
# function of the recipe's constraint and the probe's recorded output, which
# is how `resolveNixTool` calls it (reprobuild-pm issue
# 2026-10-30-path-mode-realizes-a-nix-rustc-outside-the-declared-version-range).
# ---------------------------------------------------------------------------

proc nixProfile(versionOutput: string): PathOnlyToolProfile =
  result = PathOnlyToolProfile(installMethod: "nix", nixSelector: "nixpkgs#rustc",
    resolvedExecutablePath: "/nix/store/x-rustc-wrapper/bin/rustc")
  result.probes.add(ToolProbeResult(
    spec: ToolProbeSpec(kind: tpkVersion, name: "version", args: @["--version"]),
    exitCode: 0, output: versionOutput))

suite "a nix realization is held to the declared range":
  test "the version a tool reports is read from its probe output":
    check versionFromProbeOutput("rustc 1.91.1 (ed61e7d7e 2025-11-07) (built from a source tarball)\n") == "1.91.1"
    check versionFromProbeOutput("cargo 1.94.0 (f5fe2fd5e 2026-01-07)") == "1.94.0"
    check versionFromProbeOutput("This is perl 5, version 40, subversion 0 (v5.40.0)") == "5.40.0"
    check versionFromProbeOutput("v20.11.1") == "20.11.1"
    check versionFromProbeOutput("cmake version 3.31") == "3.31.0"
    check versionFromProbeOutput("GNU Make 4.4.1\nBuilt for x86_64") == "4.4.1"
    check versionFromProbeOutput("usage: thing [options]") == ""

  test "the nixpkgs rustc outside the recipe's range is refused by name":
    let useDef = InterfaceToolUse(packageSelector: "rustc",
      executableName: "rustc", rawConstraint: "rustc >=1.94 <1.95")
    let profile = nixProfile("rustc 1.91.1 (ed61e7d7e 2025-11-07) (built from a source tarball)")
    check realizedVersionOf(profile) == "1.91.1"
    try:
      enforceUsesVersionRange(profile, useDef)
      check false
    except OSError as err:
      check "rustc >=1.94 <1.95" in err.msg
      check "1.91.1" in err.msg
      check "nixpkgs#rustc" in err.msg

  test "a version in range, or no range at all, is accepted":
    let inRange = InterfaceToolUse(packageSelector: "rustc",
      executableName: "rustc", rawConstraint: "rustc >=1.94 <1.95")
    enforceUsesVersionRange(nixProfile("rustc 1.94.0 (abc 2026-01-07)"), inRange)
    let noRange = InterfaceToolUse(packageSelector: "rustc",
      executableName: "rustc", rawConstraint: "rustc")
    enforceUsesVersionRange(nixProfile("rustc 1.91.1 (x)"), noRange)
    check usesVersionRangeRefusal(noRange, "", "nix://x") == ""

  test "a range that cannot be verified is refused, not assumed":
    let useDef = InterfaceToolUse(packageSelector: "rustc",
      executableName: "rustc", rawConstraint: "rustc >=1.94 <1.95")
    expect OSError:
      enforceUsesVersionRange(nixProfile("usage: rustc [OPTIONS]"), useDef)
    try:
      enforceUsesVersionRange(nixProfile("usage: rustc [OPTIONS]"), useDef)
    except OSError as err:
      check "report no version" in err.msg

  test "a library's version is the one its nixpkgs store path names":
    check nixStorePathVersion("/nix/store/l7xwm1f6-zlib-1.3.1/lib/libz.so") == "1.3.1"
    check nixStorePathVersion("/nix/store/abc-zlib-1.3.1-dev") == "1.3.1"
    check nixStorePathVersion("/nix/store/abc-openssl-3.6.1-bin/bin/openssl") == "3.6.1"
    check nixStorePathVersion("/nix/store/abc-python3-3.12.8") == "3.12.8"
    check nixStorePathVersion("/nix/store/x-rustc-wrapper/bin/rustc") == ""
    check nixStorePathVersion("/usr/lib/libz.so") == ""
    # The version is the segment after the pname, not the first `-<digit>`:
    # a pname may hold one (`font-adobe-100dpi`) or several dashes.
    check nixStorePathVersion("/nix/store/abc-font-adobe-100dpi-1.0.4") == "1.0.4"
    check nixStorePathVersion("/nix/store/abc-zlib-ng-compat-2.2.4/lib/libz.so") == "2.2.4"
    check nixStorePathVersion("/nix/store/abc-zlib-ng-compat-2.2.4-dev") == "2.2.4"
    check nixStorePathVersion("/nix/store/abc-font-adobe-100dpi-1.0.4-man") == "1.0.4"
    # a nixpkgs unstable version is dashed itself; its last dash-digit
    # opens the day of the month, not the version.
    check nixStorePathVersion("/nix/store/abc-foo-0-unstable-2024-01-01") ==
      "0-unstable-2024-01-01"
    check nixStorePathVersion("/nix/store/abc-foo-0-unstable-2024-01-01-dev") ==
      "0-unstable-2024-01-01"
    check nixStorePathVersion("/nix/store/abc-openssh-9.6p1/bin/ssh") == "9.6p1"
    # no segment reads as a version: the last dash-digit still opens it.
    check nixStorePathVersion("/nix/store/abc-foo-1a") == "1a"
    check nixStorePathVersion("/nix/store/abc-foo-0-unstable-2024-01-15") ==
      "0-unstable-2024-01-15"
    # a word after the version is a name suffix, not part of it.
    check nixStorePathVersion("/nix/store/abc-perl-5.38.2-env") == "5.38.2"
    check nixStorePathNameVersion("/nix/store/abc-perl-5.38.2-env") ==
      ("perl", "5.38.2")
    check nixStorePathNameVersion("/nix/store/abc-zlib-ng-compat-2.2.4") ==
      ("zlib-ng-compat", "2.2.4")
    check nixStorePathNameVersion("/nix/store/abc-font-adobe-100dpi-1.0.4") ==
      ("font-adobe-100dpi", "1.0.4")
    check nixStorePathNameVersion("/nix/store/abc-foo-0-unstable-2024-01-15") ==
      ("foo", "0-unstable-2024-01-15")

  test "a library with no version probe is held to its store path's version":
    # zlib has no `--version`: before the store path was read, every nix
    # library with a declared range was refused as unverifiable, which
    # stopped `packages/source/openssl` (`uses "zlib >=1.2.11"`) in path mode.
    let zlib = InterfaceToolUse(packageSelector: "zlib",
      executableName: "zlib", rawConstraint: "zlib >=1.2.11")
    let lib = PathOnlyToolProfile(installMethod: "nix", nixSelector: "nixpkgs#zlib",
      resolvedExecutablePath: "/nix/store/l7xwm1f6-zlib-1.3.1/lib/libz.so",
      selectedStorePath: "/nix/store/l7xwm1f6-zlib-1.3.1")
    enforceUsesVersionRange(lib, zlib)
    let tooNew = InterfaceToolUse(packageSelector: "zlib",
      executableName: "zlib", rawConstraint: "zlib >=1.4")
    try:
      enforceUsesVersionRange(lib, tooNew)
      check false
    except OSError as err:
      check "1.3.1" in err.msg
      check "zlib >=1.4" in err.msg

  test "a store path naming another package is not that package's version":
    # nixpkgs' `zlib` attribute realized by `zlib-ng-compat`: 2.2.4 is
    # zlib-ng's numbering, not zlib's, so it is not held against zlib's range
    # (it would pass `zlib >=1.2.11` for the wrong reason). The realization
    # is refused as unverifiable instead.
    let zlib = InterfaceToolUse(packageSelector: "zlib",
      executableName: "zlib", rawConstraint: "zlib >=1.2.11")
    let ng = PathOnlyToolProfile(installMethod: "nix", nixSelector: "nixpkgs#zlib",
      resolvedExecutablePath: "/nix/store/abc-zlib-ng-compat-2.2.4/lib/libz.so",
      selectedStorePath: "/nix/store/abc-zlib-ng-compat-2.2.4")
    try:
      enforceUsesVersionRange(ng, zlib)
      check false
    except OSError as err:
      check "report no version" in err.msg
    # Realized through an attribute that IS the pname: its numbering holds.
    let viaAttr = PathOnlyToolProfile(installMethod: "nix",
      nixSelector: "nixpkgs#zlib-ng-compat",
      resolvedExecutablePath: "/nix/store/abc-zlib-ng-compat-2.2.4/lib/libz.so",
      selectedStorePath: "/nix/store/abc-zlib-ng-compat-2.2.4")
    let ngUse = InterfaceToolUse(packageSelector: "zlib",
      executableName: "zlib", rawConstraint: "zlib >=2.0")
    enforceUsesVersionRange(viaAttr, ngUse)

  test "an attribute's `^outputs` selector is not part of the package name":
    # `uses "zstd-dev >=0"` is realized through `#zstd^*` (Nix's installable
    # output selector) as `zstd-1.5.7-dev`. The attribute is `zstd`, the
    # store path's pname, so 1.5.7 holds; comparing against `zstd^*` refused
    # it as unverifiable (reprobuild-pm issue 2026-10-31-uses-version-check-
    # drops-a-dev-output-store-path-version-because-the-nix-attribute-keeps-
    # its-output-suffix).
    let dev = PathOnlyToolProfile(installMethod: "nix",
      nixSelector: "github:NixOS/nixpkgs/addf7cf5f383a3101ecfba091b98d0a1263dc9b8#zstd^*",
      resolvedExecutablePath: "/nix/store/abc-zstd-1.5.7-dev/include/zstd.h",
      selectedStorePath: "/nix/store/abc-zstd-1.5.7-dev/include/zstd.h")
    let zstdDev = InterfaceToolUse(packageSelector: "zstd-dev",
      executableName: "zstd-dev", rawConstraint: "zstd-dev >=0")
    enforceUsesVersionRange(dev, zstdDev)
    # The version is now read, not skipped: a range excluding 1.5.7 is
    # refused as out of range, naming the version, not as unverifiable.
    let tooNew = InterfaceToolUse(packageSelector: "zstd-dev",
      executableName: "zstd-dev", rawConstraint: "zstd-dev >=2")
    try:
      enforceUsesVersionRange(dev, tooNew)
      check false
    except OSError as err:
      check "reports version 1.5.7" in err.msg
      check "outside the declared range" in err.msg
      check "zstd-dev >=2" in err.msg

  test "the probe outranks the store path name":
    # A wrapper's store path names the wrapper's version, not the tool's.
    let useDef = InterfaceToolUse(packageSelector: "rustc",
      executableName: "rustc", rawConstraint: "rustc >=1.94 <1.95")
    var profile = nixProfile("rustc 1.91.1 (x)")
    profile.selectedStorePath = "/nix/store/abc-rustc-wrapper-1.94.0"
    expect OSError:
      enforceUsesVersionRange(profile, useDef)

suite "tool-provisioning=nix falls back to an in-range archive":
  # The pinned nixpkgs builds one version of each package. A recipe whose
  # range excludes it is served by an archive the catalog pins inside the
  # range, which is what the refusal tells the author to add; the predicate
  # below is the whole of the decision `toolProfileFor`'s `tpmNix` arm makes.
  let linuxX86 = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)

  proc goUse(constraint: string): InterfaceToolUse =
    result = InterfaceToolUse(packageSelector: "go", executableName: "go",
      rawConstraint: constraint)
    for (cpu, os, version) in [("x86_64", "linux", "1.23.4"),
                               ("x86_64", "linux", "1.26.10"),
                               ("aarch64", "linux", "1.26.10")]:
      result.tarballProvisioning.add(InterfaceTarballProvisioning(
        cpu: cpu, os: os, url: "https://example.invalid/go" & version,
        sha256: repeat('a', 64), executablePath: "bin/go"))
      result.tarballProvisioning[^1].detail.version = version

  test "the out-of-range refusal is a distinct, still-OSError, type":
    let useDef = InterfaceToolUse(packageSelector: "go",
      executableName: "go", rawConstraint: "go >=1.26.5")
    expect UsesVersionOutOfRange:
      enforceUsesVersionRange(nixProfile("go version go1.25.4 linux/amd64"),
        useDef)
    expect OSError:
      enforceUsesVersionRange(nixProfile("go version go1.25.4 linux/amd64"),
        useDef)

  test "an archive inside the range is the fallback":
    let useDef = goUse("go >=1.26.5")
    check nixRangeRefusalFallsBackToTarball(useDef, linuxX86)
    check tarballAcquisitionPlan(useDef, target = linuxX86).url.endsWith(
      "go1.26.10")

  test "no range, no archive in range, or none for the host: it stands":
    check not nixRangeRefusalFallsBackToTarball(goUse("go"), linuxX86)
    check not nixRangeRefusalFallsBackToTarball(goUse("go >=1.27"), linuxX86)
    check not nixRangeRefusalFallsBackToTarball(goUse("go >=1.26.5"),
      realizationTargetFor(pcAArch64, poMacos))
    var noArchives = goUse("go >=1.26.5")
    noArchives.tarballProvisioning = @[]
    check not nixRangeRefusalFallsBackToTarball(noArchives, linuxX86)

  test "a tool with no nixPackage arm is realized from its archive":
    # zig: the catalog pins release archives only. Under nix mode that is
    # the realization, as it is in path mode; a tool with a nix arm, or
    # with no archive for the host, is not redirected.
    let zigUse = goUse("go >=1.26.5")
    check nixModeTakesTarballArm(zigUse, linuxX86)
    check not nixModeTakesTarballArm(zigUse,
      realizationTargetFor(pcAArch64, poMacos))
    var withNix = zigUse
    withNix.nixProvisioning.add(InterfaceNixProvisioning(
      selector: "nixpkgs#go", executablePath: "bin/go"))
    check not nixModeTakesTarballArm(withNix, linuxX86)

# ---------------------------------------------------------------------------
# Path mode holds the first match on $PATH to the declared range (reprobuild-pm
# issue 2026-10-27-path-provisioned-gcc-is-not-probed-so-fpc-gcc-2-95-fails-c-
# builds-cryptically). On a Windows CI runner Free Pascal's bundled gcc 2.95
# sat on PATH ahead of every usable gcc, and `uses "gcc >=12"` recipes were
# compiled with it. The fixture below is that host in miniature: a tool on
# PATH whose `--version` prints `2.95`, against `>=12`.
#
# No mocks: the tool is a real executable run by the real version probe, the
# resolution goes through `toolBuildIdentity` -- the entry point the build
# uses -- and the in-range archive is a real tar.gz this test builds, realized
# through the `file://` arm into a temporary store with the shared cache
# switched off, so nothing is downloaded or published.
# ---------------------------------------------------------------------------

const PathFixtureTool = "pathrange-fixture-cc"
  ## Not `gcc`: a real `gcc` name would let a sibling source recipe or the
  ## stdlib's own `gcc` provisioning answer, and the point is to see which
  ## arm path mode takes for exactly the arms this fixture declares.

proc toolFileName(name: string): string =
  when defined(windows): name & ".cmd" else: name

proc writeTool(dir, name, versionOutput: string) =
  ## A tool whose version probe prints ``versionOutput``.
  createDir(dir)
  let path = dir / toolFileName(name)
  when defined(windows):
    writeFile(path, "@echo off\r\necho " & versionOutput & "\r\n")
  else:
    writeFile(path, "#!/bin/sh\necho '" & versionOutput & "'\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc pathFixtureUse(constraint: string): InterfaceToolUse =
  InterfaceToolUse(packageSelector: PathFixtureTool,
    executableName: PathFixtureTool,
    rawConstraint: PathFixtureTool & " " & constraint)

proc withArchive(useDef: InterfaceToolUse; archive, version: string):
    InterfaceToolUse =
  ## ``useDef`` with one host-agnostic archive arm declaring ``version``.
  result = useDef
  result.tarballProvisioning.add(InterfaceTarballProvisioning(
    url: "file://" & archive, sha256: fileSha256Hex(archive),
    archiveType: "tar.gz",
    executablePath: "bin/" & toolFileName(PathFixtureTool),
    packageId: PathFixtureTool & "@" & version, cpu: "any", os: "any",
    lockIdentity: "fixture:" & PathFixtureTool & "@" & version))
  result.tarballProvisioning[^1].detail.version = version

proc pathModeProfile(useDef: InterfaceToolUse;
                     pathValue, store: string): PathOnlyToolProfile =
  let artifact = ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "pathrange-fixture", packageName: "pathrange-fixture",
    toolUses: @[useDef]))
  let identity = toolBuildIdentity(artifact, tpmPathOnly,
    pathValue = pathValue, storeRoot = store)
  require identity.profiles.len == 1
  identity.profiles[0]

suite "path mode holds the tool on PATH to the declared range":
  setup:
    let root = createTempDir("repro-path-range-", "")
    let savedCacheDisable = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
    let store = root / "store"
    let oldBin = root / "fpc" / "bin"         # gcc 2.95, first on PATH
    writeTool(oldBin, PathFixtureTool, "2.95")
    let unversionedBin = root / "plain" / "bin"
    writeTool(unversionedBin, PathFixtureTool, "usage: tool [options]")
    let currentBin = root / "current" / "bin"
    writeTool(currentBin, PathFixtureTool,
      PathFixtureTool & " (GCC) 13.2.0")
    # The in-range archive: the same tool, reporting 13.2.0.
    let tree = root / "tree"
    writeTool(tree / "bin", PathFixtureTool, PathFixtureTool & " 13.2.0")
    let archive = root / "fixture-13.2.0.tar.gz"
    # `tar` is one of the host tools the realizer itself requires
    # (Dependency-Provisioning-In-Build-Graph.md §4.1).
    let packed = execCmdEx("tar -czf " & quoteShell(archive) &
      " -C " & quoteShell(tree) & " bin")

  teardown:
    if savedCacheDisable.len > 0:
      putEnv("REPRO_CACHE_DISABLE", savedCacheDisable)
    else:
      delEnv("REPRO_CACHE_DISABLE")
    removeDir(root)

  test "an out-of-range version on PATH is refused by name":
    let useDef = pathFixtureUse(">=12")
    var message = ""
    try:
      discard resolvePathOnlyTool(useDef, oldBin)
      checkpoint("expected a refusal, got a realization")
      check false
    except UsesVersionOutOfRange as err:
      message = err.msg
    checkpoint("message: " & message)
    check (PathFixtureTool & " >=12") in message          # selector + range
    check "'>=12'" in message                              # the range
    check (oldBin / toolFileName(PathFixtureTool)) in message  # the path
    check "reports version 2.95" in message                # what it said
    check "ahead of it on PATH" in message                 # the PATH remedy
    check "nixpkgs" notin message

  test "with no archive declared, path mode's answer is the refusal":
    var message = ""
    try:
      discard pathModeProfile(pathFixtureUse(">=12"), oldBin, store)
      checkpoint("expected a refusal, got a realization")
      check false
    except UsesVersionOutOfRange as err:
      message = err.msg
    checkpoint("message: " & message)
    check "reports version 2.95" in message
    check (oldBin / toolFileName(PathFixtureTool)) in message

  test "with an in-range archive declared, path mode realizes the archive":
    require packed.exitCode == 0
    let useDef = pathFixtureUse(">=12").withArchive(archive, "13.2.0")
    let profile = pathModeProfile(useDef, oldBin, store)
    checkpoint("realized: " & profile.resolvedExecutablePath)
    check profile.installMethod == "tarball"
    check profile.resolvedExecutablePath.startsWith(absolutePath(store))
    check not profile.resolvedExecutablePath.startsWith(oldBin)
    check realizedVersionOf(profile) == "13.2.0"

  test "an archive outside the range does not replace it: the refusal stands":
    require packed.exitCode == 0
    # The archive is declared at 11.0.0 (its bytes do not matter: the range
    # filter refuses the record before acquisition).
    let useDef = pathFixtureUse(">=12").withArchive(archive, "11.0.0")
    var message = ""
    try:
      discard pathModeProfile(useDef, oldBin, store)
      checkpoint("expected a refusal, got a realization")
      check false
    except UsesVersionOutOfRange as err:
      message = err.msg
    checkpoint("message: " & message)
    check "reports version 2.95" in message
    check "No other realization inside the range" in message

  test "controls: an in-range PATH tool, no range, and no reported version":
    # In range on PATH: taken from PATH, as before.
    let inRange = pathModeProfile(pathFixtureUse(">=12"), currentBin, store)
    check inRange.installMethod == "path"
    check inRange.resolvedExecutablePath ==
      currentBin / toolFileName(PathFixtureTool)
    # No declared range: 2.95 is accepted, as before.
    let noRange = InterfaceToolUse(packageSelector: PathFixtureTool,
      executableName: PathFixtureTool, rawConstraint: PathFixtureTool)
    check pathModeProfile(noRange, oldBin, store).resolvedExecutablePath ==
      oldBin / toolFileName(PathFixtureTool)
    # A probe that reports no version keeps today's weak acceptance (the
    # nix arm refuses it; path mode does not).
    let unversioned = pathModeProfile(pathFixtureUse(">=12"), unversionedBin,
      store)
    check unversioned.installMethod == "path"
    check unversioned.resolvedExecutablePath ==
      unversionedBin / toolFileName(PathFixtureTool)
    # Later PATH entries are not tried: the first match is the one refused.
    expect UsesVersionOutOfRange:
      discard pathModeProfile(pathFixtureUse(">=12"),
        oldBin & $PathSep & currentBin, store)
