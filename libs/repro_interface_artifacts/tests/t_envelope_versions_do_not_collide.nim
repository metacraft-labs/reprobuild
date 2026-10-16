## The interface envelope's two version LANES do not collide.
##
## WHY THIS FILE EXISTS. `agents` and the shared-development-services
## branch each consumed envelope versions 21 and 22, independently, for
## DIFFERENT features:
##
##   * `agents` v21 -- `TarballArchiveDetail` (`detail`) on tarball
##     provisioning (GM4b), written after `os` and before `location`.
##   * `agents` v22 -- the macOS application fields `appBundle`,
##     `bundleId`, `teamId` INSIDE that detail (GM4c), after
##     `cpuFeatures`.
##   * ours v21 -- `publicServices` + `publicActivities` on
##     `ProjectInterface`, between `publicResources` and `toolUses`.
##   * ours v22/v23/v24 -- identity+scope, the compatibility major, and
##     the contribution points, each appended to the tail of a
##     `publicServices` ROW.
##
## A textual merge of the two branches produces `EnvelopeVersion = 24`
## with BOTH sides' gates firing at 21 and 22. That does not fail to
## compile and it does not raise: the decoder simply reads blocks that
## were never written. A v21 envelope from `agents` carries no services
## count, so `decodeInterfacePayload` would take the next four bytes --
## the `toolUses` count -- as one, then read that many service rows out
## of whatever follows. The cursor ends up somewhere the writer never
## put a boundary and every later field is garbage or a raise. SILENT
## ARTIFACT CORRUPTION, not a type error.
##
## The resolution renumbered OURS up (21->23, 22->24, 23->25, 24->26,
## `EnvelopeVersion = 26`) and left the published side's two alone,
## because v21/v22 artifacts written by `agents` already exist in other
## workspaces and in CI caches. THIS FILE IS THE MEASUREMENT THAT THE
## RENUMBER HOLDS. It is deliberately a CROSS-version matrix rather than
## a per-feature round-trip: the per-feature tests (L3's, L4's, L6's,
## D-SS11's) each encode at one version and would all stay green under
## the colliding numbering, because each only ever looks at its own
## block.
##
## WHAT MAKES IT FALSIFY THE COLLISION. Every case below encodes ONE
## fixture that carries BOTH sides' content at once, and asserts FIELD
## VALUES at each version rather than merely that the decode returned.
## Under the colliding numbering the v21 and v22 cases go red: either
## the service count read from `toolUses`' bytes is absurd and the
## decode raises, or it is small and the rows decode to rubbish. "It did
## not crash" is not the assertion; "the tarball detail says
## `Zed.app` and there are no service rows" is.
##
## MOCK POLICY -- NO MOCKS. The payloads come from the real
## `encodeInterfacePayload` at an explicit version and go back through
## the real `decodeInterfacePayload`, which is the same pairing every
## other codec test in this directory uses. A hand-typed byte string
## would be a guess about what v21 was.

import std/[options, strutils, unittest]

import repro_interface_artifacts
import repro_project_dsl

const
  AppBundle = "Zed.app"
  BundleId = "dev.zed.Zed"
  TeamId = "MQ55VZLNZQ"
  DetailVersion = "0.199.5"
  ClosureManifest = "closure.json"
  ServiceName = "zitadel"
  StableId = "com.example.sso"
  PointRelyingParties = "relyingParties"
  PointUsers = "fixtureUsers"

proc bothLanesInterface(): ProjectInterface =
  ## One interface carrying EVERY version-gated block of BOTH lanes.
  ##
  ## The two lanes live in disjoint parts of the byte stream -- ours in
  ## `ProjectInterface`/`InterfaceService`, upstream's inside a tarball
  ## provisioning record reached through `provisioningContributions`
  ## (itself a v13 block) -- which is WHY the renumber is sufficient and
  ## is exactly the property these cases check. A fixture that carried
  ## only one lane could not see a collision at all.
  result.projectName = "collision"
  result.packageName = "collision"
  result.location = SourceLocation(file: "repro.nim", line: 1)
  # --- ours: v23 block, with v24/v25/v26 fields on the row ---
  result.publicServices = @[InterfaceService(
    name: ServiceName,
    activityName: "sso",
    handleType: "SsoHandle",
    identityMode: isimStable,
    identityStableId: StableId,
    scope: issWorkspace,
    compatibilityMajor: 7'u32,
    contributionPoints: @[PointRelyingParties, PointUsers],
    location: SourceLocation(file: "repro.nim", line: 9))]
  result.publicActivities = @[InterfaceActivity(
    name: "sso",
    handleType: "SsoHandle",
    services: @[ServiceName],
    location: SourceLocation(file: "repro.nim", line: 11))]
  # --- upstream: v21 `detail`, carrying the v22 macOS fields ---
  result.provisioningContributions = @[InterfaceProvisioningContribution(
    targetPackage: "target",
    targetInterfaceFingerprint: "fp",
    contributor: "collision",
    location: SourceLocation(file: "repro.nim", line: 21),
    tarballProvisioning: @[InterfaceTarballProvisioning(
      packageName: "zed",
      contributor: "collision",
      url: "https://example.invalid/zed.tar.gz",
      sha256: "0" & repeat('a', 63),
      archiveType: "tar.gz",
      executablePath: "bin/zed",
      closureManifest: ClosureManifest,
      cpu: "aarch64",
      os: "macos",
      detail: TarballArchiveDetail(
        version: DetailVersion,
        installMethod: "dmg",
        cpuLevel: "v8",
        cpuFeatures: "neon",
        appBundle: AppBundle,
        bundleId: BundleId,
        teamId: TeamId),
      location: SourceLocation(file: "repro.nim", line: 22))],
    # --- GM5b: v27 Homebrew bridge records, after the Scoop records ---
    homebrewProvisioning: @[InterfaceHomebrewProvisioning(
      packageName: "target", contributor: "collision", kind: "cask",
      token: "zed", tap: "", location: SourceLocation(file: "repro.nim",
      line: 23))])]

proc atVersion(pi: ProjectInterface; version: uint16): ProjectInterface =
  ## Encode at `version` with the REAL encoder and read it back with the
  ## REAL decoder at the same version -- an honest image of what a build
  ## pinned at `version` would have written and would read.
  decodeInterfacePayload(encodeInterfacePayload(pi, version), version)

proc tarballOf(pi: ProjectInterface): InterfaceTarballProvisioning =
  doAssert pi.provisioningContributions.len == 1,
    "fixture drift: expected exactly one provisioning contribution"
  doAssert pi.provisioningContributions[0].tarballProvisioning.len == 1,
    "fixture drift: expected exactly one tarball provisioning row"
  pi.provisioningContributions[0].tarballProvisioning[0]

suite "envelope lanes -- the PUBLISHED side's versions keep their meaning":

  test "v21 carries upstream's detail and NONE of our blocks":
    # The case the collision would break. v21 is upstream's
    # `TarballArchiveDetail`; under the colliding numbering it was also
    # our services block, so this decode would read a service count out
    # of `toolUses`' bytes.
    let back = atVersion(bothLanesInterface(), 21'u16)
    # Upstream's v21 field decoded to its real value...
    let tarball = tarballOf(back)
    check tarball.detail.version == DetailVersion
    check tarball.detail.installMethod == "dmg"
    check tarball.detail.cpuFeatures == "neon"
    # ...the v22 fields inside it are absent at v21, as upstream says...
    check tarball.detail.appBundle == ""
    check tarball.detail.bundleId == ""
    check tarball.detail.teamId == ""
    # ...the surrounding v20 field is intact, so the cursor is where the
    # writer left it and not merely plausible...
    check tarball.closureManifest == ClosureManifest
    check tarball.cpu == "aarch64"
    check tarball.os == "macos"
    # ...and NOTHING of ours decoded, because v21 is not our gate.
    check back.publicServices.len == 0
    check back.publicActivities.len == 0

  test "v22 adds upstream's macOS fields and still NONE of our blocks":
    let back = atVersion(bothLanesInterface(), 22'u16)
    let tarball = tarballOf(back)
    check tarball.detail.appBundle == AppBundle
    check tarball.detail.bundleId == BundleId
    check tarball.detail.teamId == TeamId
    check tarball.detail.version == DetailVersion
    check tarball.closureManifest == ClosureManifest
    check back.publicServices.len == 0
    check back.publicActivities.len == 0

suite "envelope lanes -- OUR blocks begin at v23, one at a time":

  test "v23 adds our service rows, with the v24+ fields at §4's defaults":
    let back = atVersion(bothLanesInterface(), 23'u16)
    check back.publicServices.len == 1
    check back.publicActivities.len == 1
    let svc = back.publicServices[0]
    check svc.name == ServiceName
    check svc.activityName == "sso"
    check svc.handleType == "SsoHandle"
    # v<24: identity and scope are §4's own defaults, not an invented
    # "unset" -- the same assertion L4's own file makes, here beside the
    # upstream lane so the two cannot drift apart.
    check svc.identityMode == isimDerived
    check svc.identityStableId == ""
    check svc.scope == issProject
    check svc.compatibilityMajor == 0'u32
    check svc.contributionPoints.len == 0
    # Upstream's lane is unaffected by ours arriving.
    check tarballOf(back).detail.appBundle == AppBundle
    check tarballOf(back).detail.version == DetailVersion

  test "v24 adds identity and scope; the major and points stay absent":
    let svc = atVersion(bothLanesInterface(), 24'u16).publicServices[0]
    check svc.identityMode == isimStable
    check svc.identityStableId == StableId
    check svc.scope == issWorkspace
    check svc.compatibilityMajor == 0'u32
    check svc.contributionPoints.len == 0

  test "v25 adds the compatibility major; the points stay absent":
    let svc = atVersion(bothLanesInterface(), 25'u16).publicServices[0]
    check svc.identityStableId == StableId
    check svc.compatibilityMajor == 7'u32
    check svc.contributionPoints.len == 0

  test "v26 carries EVERYTHING, both lanes at once":
    let back = atVersion(bothLanesInterface(), 26'u16)
    let svc = back.publicServices[0]
    check svc.identityMode == isimStable
    check svc.identityStableId == StableId
    check svc.scope == issWorkspace
    check svc.compatibilityMajor == 7'u32
    check svc.contributionPoints == @[PointRelyingParties, PointUsers]
    let tarball = tarballOf(back)
    check tarball.detail.appBundle == AppBundle
    check tarball.detail.bundleId == BundleId
    check tarball.detail.teamId == TeamId
    check tarball.detail.version == DetailVersion
    check tarball.closureManifest == ClosureManifest
    # v26 is what the build writes by default, so the explicit-version
    # path above and the default path must agree. If they ever disagree,
    # `EnvelopeVersion` moved and a gate did not.
    let dflt = decodeInterfacePayload(
      encodeInterfacePayload(bothLanesInterface()))
    check dflt.publicServices == back.publicServices
    check dflt.publicActivities == back.publicActivities
    check tarballOf(dflt).detail == tarball.detail

suite "envelope lanes -- the Homebrew block begins at v27":

  test "v27 adds the Homebrew records; v21..v26 decode without them":
    # GM5b was developed as v23 against an older tip, when v23 was still
    # free; that number is the services lane's here. Every earlier version
    # must decode with no Homebrew record and with both other lanes intact,
    # and v27 (the default) must carry it beside everything else.
    let pi = bothLanesInterface()
    for v in 21'u16 .. 26'u16:
      let back = atVersion(pi, v)
      check back.provisioningContributions[0].homebrewProvisioning.len == 0
      check tarballOf(back).closureManifest == ClosureManifest
    let back = atVersion(pi, 27'u16)
    let brew = back.provisioningContributions[0].homebrewProvisioning
    check brew.len == 1
    check brew[0].token == "zed"
    check brew[0].kind == "cask"
    check back.publicServices[0].contributionPoints ==
      @[PointRelyingParties, PointUsers]
    check tarballOf(back).detail.appBundle == AppBundle
    let dflt = decodeInterfacePayload(encodeInterfacePayload(pi))
    check dflt.provisioningContributions[0].homebrewProvisioning == brew

suite "envelope lanes -- the installer application begins at v28":

  test "v28 adds installerApp inside the detail; v21..v27 decode without " &
      "it and with every other block intact":
    # The macOS installer-application field (Store-And-Installation-
    # Layout.md § Installer applications) was developed as v23 against an
    # older tip, where v23 was free; here v23 is the services lane's. A gate
    # left at 23 would make a v23..v27 reader take the next string of the
    # stream as `installerApp` and desynchronize every later field.
    var pi = bothLanesInterface()
    pi.provisioningContributions[0].tarballProvisioning[0].detail
      .installerApp = "Zed Installer.app"
    for v in 21'u16 .. 27'u16:
      checkpoint "v" & $v
      let back = atVersion(pi, v)
      check tarballOf(back).detail.installerApp == ""
      check tarballOf(back).closureManifest == ClosureManifest
      check tarballOf(back).location.line == 22
      if v >= 22'u16:
        check tarballOf(back).detail.teamId == TeamId
      if v >= 27'u16:
        check back.provisioningContributions[0].homebrewProvisioning.len == 1
    let back = atVersion(pi, 28'u16)
    check tarballOf(back).detail.installerApp == "Zed Installer.app"
    check tarballOf(back).detail.teamId == TeamId
    check back.provisioningContributions[0].homebrewProvisioning[0].token ==
      "zed"
    check back.publicServices[0].contributionPoints ==
      @[PointRelyingParties, PointUsers]
    # v28 is the default.
    # version-literal-ok: a pin that must fail when the envelope moves past v28, so this matrix is extended
    check interfaceEnvelopeVersion() == 28'u16
    let dflt = decodeInterfacePayload(encodeInterfacePayload(pi))
    check tarballOf(dflt).detail == tarballOf(back).detail

suite "envelope lanes -- the version is the ONLY thing that varies":

  test "each of our four blocks appears at exactly its own version":
    # The matrix, as one monotone statement. Encoding the SAME fixture at
    # 21..26 must turn each block on at one version and never off again.
    # A gate that fired two versions early -- which is precisely what the
    # collision was -- breaks a row of this table.
    let pi = bothLanesInterface()
    var services: seq[int] = @[]
    var identities: seq[bool] = @[]
    var majors: seq[uint32] = @[]
    var points: seq[int] = @[]
    var appBundles: seq[string] = @[]
    for v in 21'u16 .. 26'u16:
      let back = atVersion(pi, v)
      services.add(back.publicServices.len)
      identities.add(back.publicServices.len > 0 and
        back.publicServices[0].identityMode == isimStable)
      majors.add(if back.publicServices.len > 0:
        back.publicServices[0].compatibilityMajor else: 0'u32)
      points.add(if back.publicServices.len > 0:
        back.publicServices[0].contributionPoints.len else: 0)
      appBundles.add(tarballOf(back).detail.appBundle)
    #                      v21 v22 v23 v24 v25 v26
    check services   == @[    0,  0,  1,  1,  1,  1]
    check identities == @[false, false, false, true, true, true]
    check majors     == @[0'u32, 0'u32, 0'u32, 0'u32, 7'u32, 7'u32]
    check points     == @[    0,  0,  0,  0,  0,  2]
    # And upstream's lane, on the same fixture, switches at ITS version
    # and not at ours -- the two columns that would merge into one if the
    # numbering ever collided again.
    check appBundles == @["", AppBundle, AppBundle, AppBundle, AppBundle,
                          AppBundle]
