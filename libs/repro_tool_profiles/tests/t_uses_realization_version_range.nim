## Acquisition plans must select only realizations satisfying a recipe's range.
## No mocks: pure production planning over declared interface records; no download.
import std/[options, strutils, unittest]
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
