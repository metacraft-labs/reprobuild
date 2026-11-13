## Realization selection — the ONE implementation of "which realization of
## this package, for this target, under this policy".
##
## Provisioning-Contributions.md §"Resolution" and §"Profile Package
## References" (GM4b). A recipe's ``uses:`` (through ``nixAcquisitionPlan``,
## ``tarballAcquisitionPlan`` and ``scoopAcquisitionPlan`` in
## ``repro_tool_profiles``) and a home profile's ``package "<name>"`` (through
## ``repro_home_apply``'s resolver) both select here. Before GM4b the home
## side had its own adapter chain over a second copy of the archive
## realizations (``VersionedProvisioning`` catalog records), and the two
## copies drifted — the macOS ``just`` tarball existed in one and not the
## other. Core-Invariants.md §"One Implementation Per Concern" is why this
## module exists rather than a synchronisation test.
##
## The module is deliberately pure: it reads records and asks the caller's
## ``HostInventory`` callbacks about the host, and it never downloads,
## builds or installs anything. Realization stays with the realizers.

import std/[options, sequtils, strutils]

import repro_solver/version_constraints
import repro_interface_artifacts
import repro_dsl_stdlib/packages_schema

export packages_schema

type
  RealizationKind* = enum
    ## The realization kinds a selection policy orders. ``tarball``, ``nix``
    ## and ``scoop`` select DECLARED realizations (canonical-definition
    ## records and contributions); ``path`` selects from the host's
    ## inventory (the executable already on PATH).
    rkTarball = "tarball"
    rkNix = "nix"
    rkScoop = "scoop"
    rkPath = "path"

  SelectionPolicy* = seq[RealizationKind]

  RealizationTarget* = object
    ## The platform a realization is selected FOR. ``isHost`` says whether
    ## the host's inventory (PATH, Scoop) describes this target: it does only
    ## when the target is the machine running the selection.
    os*: PlatformOs
    platform*: PlatformTarget
    isHost*: bool

  ScoopInventoryHit* = object
    ## What a host's Scoop inventory knows about an app of a given name.
    found*: bool
    installed*: bool
    bucket*: string
    app*: string
    version*: string
    executableName*: string

  PathProbe* = proc(names: seq[string]): string {.closure.}
    ## Returns the absolute path of the first of ``names`` found on the
    ## host's PATH, or "".
  ScoopProbe* = proc(app: string): ScoopInventoryHit {.closure.}

  HostInventory* = object
    ## The host-local sources a caller lets selection consult. ``nil``
    ## callbacks mean "this caller has no such inventory". A recipe's
    ## ``uses:`` supplies PATH only; a profile on a Windows host supplies
    ## Scoop as well (Provisioning-Contributions.md §"Host inventory").
    probePath*: PathProbe
    probeScoop*: ScoopProbe

  SelectionRequest* = object
    packageName*: string
    target*: RealizationTarget
    policy*: SelectionPolicy
    version*: string
      ## Exact version pin, "" for none.
    contributor*: Option[string]
      ## Contributor pin (from a lock or an explicit curator policy; the
      ## ``REPRO_PROVISIONING_CONTRIBUTOR`` environment selector was removed
      ## by ReproOS M7 deliverable 3 and refuses while set). ``some("")`` pins
      ## the canonical package provider; ``none`` lets a unique contributor
      ## select.
    lockIdentity*: string
      ## Lock-identity pin, "" for none: the ``lockIdentity`` a previous
      ## selection recorded (``contributorLockIdentity`` form). When set, a
      ## declared record is eligible only when its own lock identity equals
      ## it, so a realization added to the definition later is never chosen
      ## over the locked one, and a withdrawn one is a miss rather than a
      ## silent re-selection. The host inventory (``path``, Scoop bucket
      ## discovery) is not consulted: an ambient selection is never pinned.
    availability*: PackageAvailability
      ## The package's declared ``platforms:`` (PMC-1).
    probeNames*: seq[string]
      ## Executable names the ``path`` kind probes for, in order.
    definitionKnown*: bool
      ## True when a package definition in scope has this name, so a miss is
      ## a missing realization rather than an unknown package.
    inventory*: HostInventory

  KindOutcome* = object
    ## One policy step: what this kind decided and why.
    kind*: RealizationKind
    selected*: bool
    reason*: string
    capabilityShortfall*: bool

  RealizationSelection* = object
    kind*: RealizationKind
    contributor*: string
      ## "" for the canonical package provider and for ambient selections.
    ambient*: bool
      ## Selected from the host inventory rather than a declaration. Never a
      ## reproducible pin.
    nix*: InterfaceNixProvisioning
    tarball*: InterfaceTarballProvisioning
    scoop*: InterfaceScoopProvisioning
    scoopInventory*: ScoopInventoryHit
    pathExecutable*: string
    version*: string
      ## The selected realization's version when it names one.
    realizationLockIdentity*: string
    lockIdentity*: string
      ## ``contributorLockIdentity(contributor, realizationLockIdentity)`` —
      ## the identity a lock records and an action identity carries.
    trace*: seq[KindOutcome]

  ERealizationSelection* = object of ValueError
    ## Base of the selection failures. ``steps`` carries every policy step
    ## consulted before the failure (``trace`` is taken: it is the inherited
    ## stack trace).
    packageName*: string
    target*: string
    steps*: seq[KindOutcome]

  EPlatformUnavailable* = object of ERealizationSelection
    ## PMC-1: the package's ``platforms:`` exclude the target. No kind is
    ## consulted, so nothing falls through to PATH.
    declaredPlatforms*: string
    authorMessage*: string

  EAmbiguousRealization* = object of ERealizationSelection
    ## More than one contributor offers an eligible realization of one kind
    ## and nothing pins one. Never resolved by import order.
    kind*: RealizationKind
    contributors*: seq[string]

  EMissingRealization* = object of ERealizationSelection
    ## No kind of the policy selected a realization for the target.
    definitionKnown*: bool

  EInvalidRealization* = object of ERealizationSelection
    ## A declared record cannot be read (an unknown cpu, os, floor or
    ## feature token). Refused, never skipped: skipping would turn a typo'd
    ## floor into "no record for this target" — or into a fall-through to the
    ## next kind — with nothing pointing at the typo.

  KindChoiceStatus* = enum
    kcSelected
    kcNoRecords          ## the package declares no realization of this kind
    kcNoneForTarget      ## records exist, none for the target platform
    kcVersionNotOffered  ## records exist for the target, not at the pin
    kcLockedIdentityNotOffered
      ## records of this kind exist, none carries the pinned lock identity
    kcContributorNotOffered
    kcAmbiguous
    kcCapabilityShortfall
    kcInvalidRecord      ## a record whose platform tokens do not parse

  KindChoice* = object
    ## The outcome of selecting within one kind.
    status*: KindChoiceStatus
    index*: int
    contributors*: seq[string]
    detail*: string

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

proc hostRealizationTarget*(): RealizationTarget =
  ## The machine running the selection, at its DEFINITIONAL microarchitecture
  ## baseline (``x86-64-v1`` on amd64). Callers that honour a declared host
  ## level (``REPRO_HOST_MICROARCH_LEVEL``) build the target themselves.
  let family = detectHostCpu()
  RealizationTarget(os: detectHostOs(),
    platform: initPlatformTarget(family, baselineMicroarchLevel(family)),
    isHost: true)

proc realizationTargetFor*(cpu: PlatformCpu; os: PlatformOs;
                           level = mlNone; features: set[CpuFeature] = {};
                           isHost = false): RealizationTarget =
  RealizationTarget(os: os,
    platform: initPlatformTarget(cpu, level, features), isHost: isHost)

proc describeTarget*(target: RealizationTarget): string =
  ## ``aarch64-macos``, ``x86_64-windows`` — the spelling diagnostics and the
  ## home-profile lock use.
  $target.platform.family & "-" & $target.os

# ---------------------------------------------------------------------------
# Lock identities
# ---------------------------------------------------------------------------

proc contributorLabel*(value: string): string =
  if value.len > 0: value else: "canonical-package"

proc contributorLockIdentity*(contributor, realizationIdentity: string):
    string =
  ## The lock identity of a selected realization: the realization's own
  ## identity, prefixed by its contributor for an external contribution. An
  ## in-package realization (the canonical provider, contributor "") keeps
  ## the bare identity, which is what every lock written before
  ## contributions existed recorded.
  if contributor.len == 0:
    realizationIdentity
  else:
    "contributor:" & contributor & "\n" & realizationIdentity

proc normalizedHexDigest*(value, algorithm: string): string =
  result = value.strip().toLowerAscii()
  if result.startsWith(algorithm & ":"):
    result = result[algorithm.len + 1 .. ^1]

proc tarballRealizationLockIdentity*(record: InterfaceTarballProvisioning):
    string =
  ## The record's declared ``lockIdentity``, else the digest that pins the
  ## archive in verification precedence (sha256, sha512, sha1).
  if record.lockIdentity.len > 0:
    record.lockIdentity
  elif record.sha256.len > 0:
    "sha256:" & normalizedHexDigest(record.sha256, "sha256")
  elif record.detail.sha512.len > 0:
    "sha512:" & normalizedHexDigest(record.detail.sha512, "sha512")
  elif record.detail.sha1.len > 0:
    "sha1:" & normalizedHexDigest(record.detail.sha1, "sha1")
  else:
    ""

proc lockedNixpkgsRef*(baseRef, narHash: string): string =
  result = baseRef
  if narHash.len > 0 and not result.contains("narHash="):
    if result.contains("?"):
      result.add("&narHash=")
    else:
      result.add("?narHash=")
    result.add(narHash)

proc effectiveNixSelector*(selected: InterfaceNixProvisioning): string =
  if selected.nixpkgsRef.len > 0 and selected.selector.startsWith("nixpkgs#"):
    return lockedNixpkgsRef(selected.nixpkgsRef,
      selected.nixpkgsNarHash) & "#" & selected.selector["nixpkgs#".len .. ^1]
  selected.selector

proc nixRealizationLockIdentity*(record: InterfaceNixProvisioning): string =
  if record.lockIdentity.len > 0:
    record.lockIdentity
  elif record.nixpkgsRef.len > 0:
    effectiveNixSelector(record)
  else:
    record.selector

proc scoopRealizationLockIdentity*(record: InterfaceScoopProvisioning):
    string =
  if record.lockIdentity.len > 0:
    record.lockIdentity
  else:
    "scoop:" & record.bucket & "/" & record.app

proc recordLockIdentity*(record: InterfaceTarballProvisioning): string =
  ## The lock identity selecting ``record`` produces — what a lock records
  ## for it and what a lock-identity pin is compared against.
  contributorLockIdentity(record.contributor,
    tarballRealizationLockIdentity(record))

proc recordLockIdentity*(record: InterfaceNixProvisioning): string =
  contributorLockIdentity(record.contributor,
    nixRealizationLockIdentity(record))

proc recordLockIdentity*(record: InterfaceScoopProvisioning): string =
  contributorLockIdentity(record.contributor,
    scoopRealizationLockIdentity(record))

proc displayLockIdentity*(identity: string): string =
  ## A lock identity on one line: the contributor form separates the
  ## contributor from the realization identity with a newline.
  identity.replace("\n", " ")

proc contributorAllowed(candidate: string; pin: Option[string]): bool =
  pin.isNone or pin.get == candidate

proc withLockedIdentity[T](records: seq[T]; identity: string;
                           contributor: Option[string]):
    tuple[kept: seq[T]; withheld: seq[string]] =
  ## ``records`` narrowed to those whose lock identity is ``identity``
  ## (unchanged when ``identity`` is ""). ``withheld`` lists the identities
  ## of the records the narrowing removed that the contributor pin would
  ## have admitted, for the diagnostic.
  if identity.len == 0:
    return (records, @[])
  for record in records:
    let own = recordLockIdentity(record)
    if own == identity:
      result.kept.add(record)
    elif contributorAllowed(record.contributor, contributor) and
        own notin result.withheld:
      result.withheld.add(own)

proc lockedIdentityMiss(kind: RealizationKind; identity: string;
                        withheld: seq[string]): KindChoice =
  KindChoice(status: kcLockedIdentityNotOffered, index: -1,
    detail: "the locked " & $kind & " realization " &
      displayLockIdentity(identity).escape() & " is no longer offered" &
      (if withheld.len > 0:
         " (offered: " & withheld.mapIt(displayLockIdentity(it)).join(", ") &
         ")"
       else: ""))

# ---------------------------------------------------------------------------
# Operations requested by a tarball record
# ---------------------------------------------------------------------------
#
# One provisioning edge consumes every ``tarball`` record for recipes and
# home profiles (``repro_tool_profiles.resolveTarballTool``). It downloads, verifies,
# extracts, installs and lays out a prefix for both recipes and profiles.
# The predicates below classify requested operations; they do not route
# records between different realizers.

const InstallerOnlyArchiveTypes* = ["7z-sfx", "installer-nsis",
    "installer-msi", "dmg", "pkg"]
  ## Archive formats that require installation-aware staging.

proc archiveInstallerFeatures*(record: InterfaceTarballProvisioning):
    seq[string] =
  ## Installation operations the shared provisioning edge must stage in
  ## addition to its ordinary archive extraction. Empty for a plain archive.
  let detail = record.detail
  if detail.installMethod.len > 0 and detail.installMethod != "extract":
    result.add("installMethod " & detail.installMethod)
  if record.archiveType.toLowerAscii() in InstallerOnlyArchiveTypes:
    result.add("archiveType " & record.archiveType)
  if detail.extractPath.len > 0: result.add("extractPath")
  if detail.installerArgs.len > 0: result.add("installerArg")
  if detail.pacmanPackages.len > 0: result.add("pacmanPackage")
  if detail.bootstrapArgv.len > 0: result.add("bootstrapArg")
  if detail.preInstall.len > 0: result.add("preInstall")
  if detail.launcherEmit.len > 0: result.add("launcherEmit")
  if detail.nested7z: result.add("nested7z")
  if detail.msiAdminInstall: result.add("msiAdminInstall")
  if detail.appBundle.len > 0: result.add("appBundle")
  if detail.installerApp.len > 0: result.add("installerApp")
  if record.sha256.len == 0 and
      (detail.sha512.len > 0 or detail.sha1.len > 0):
    result.add("a digest other than sha256")

proc extractRealizerFeatures*(record: InterfaceTarballProvisioning):
    seq[string] =
  ## Compatibility classifier for the edge's layout operations. These may
  ## freely accompany installation operations in the same realization.
  if record.stripComponents > 0: result.add("stripComponents")
  if record.executableAlias.len > 0: result.add("executableAlias")
  if record.prunePaths.len > 0: result.add("prune")
  if record.launcher.len > 0: result.add("launcher")
  if record.closureManifest.len > 0: result.add("closureManifest")
  if record.archiveType.toLowerAscii() == "conda":
    result.add("archiveType conda")

# ---------------------------------------------------------------------------
# Per-kind selection
# ---------------------------------------------------------------------------

proc tarballArm*(record: InterfaceTarballProvisioning):
    tuple[ok: bool; arm: PlatformBinary; problem: string] =
  ## The ``PlatformBinary`` arm a tarball record presents to ``selectArm``:
  ## its (cpu, os) coordinate and its microarchitecture floor. A token that
  ## does not parse makes the record ineligible with a named problem — a
  ## typo'd floor must not silently become "no floor".
  let cpu = parsePlatformCpuToken(record.cpu)
  let os = parsePlatformOsToken(record.os)
  let level = parseMicroarchLevelToken(record.detail.cpuLevel)
  let features = parseCpuFeatureSet(record.detail.cpuFeatures)
  if not cpu.ok:
    return (false, PlatformBinary(), "unknown cpu '" & record.cpu & "'")
  if not os.ok:
    return (false, PlatformBinary(), "unknown os '" & record.os & "'")
  if not level.ok:
    return (false, PlatformBinary(), "unknown cpuLevel '" &
      record.detail.cpuLevel & "'")
  if not features.ok:
    return (false, PlatformBinary(), "unknown cpu feature '" &
      features.badToken & "'")
  (true, PlatformBinary(cpu: cpu.cpu, os: os.os, cpu_level: level.level,
    cpu_features: features.features), "")

proc describeCoverage(records: openArray[InterfaceTarballProvisioning]):
    string =
  var seen: seq[string] = @[]
  for record in records:
    let cpu = if record.cpu.len == 0: "any" else: record.cpu
    let os = if record.os.len == 0: "any" else: record.os
    let label = cpu & "-" & os &
      (if record.detail.version.len > 0: "@" & record.detail.version else: "")
    if label notin seen:
      seen.add(label)
  seen.join(", ")

proc requestedUsesVersionRange*(useDef: InterfaceToolUse): string =
  ## A uses constraint starts with its selector; only the following clause
  ## is a range. Accept all whitespace used by the DSL's tokenization.
  let constraint = useDef.rawConstraint.strip()
  for i, ch in constraint:
    if ch in Whitespace:
      return constraint[i + 1 .. ^1].strip()

proc parsedVersionRange*(range: string): Option[SemverRange] =
  if range.len == 0:
    return none(SemverRange)
  try:
    some(parseSemverRange(range))
  except ESemverParse as err:
    raise newException(ValueError, "invalid uses version range '" & range &
      "': " & err.msg)

proc matchesVersionRange*(version: string; range: Option[SemverRange]): bool =
  ## Unknown or malformed versions cannot prove a versioned request.
  if range.isNone: return true
  if version.len == 0: return false
  try:
    satisfies(parseSemver(version), range.get)
  except ESemverParse:
    false

proc selectTarballRecord*(records: openArray[InterfaceTarballProvisioning];
                          target: RealizationTarget; version = "";
                          contributor = none(string); versionRange = ""): KindChoice =
  ## Select among ``tarball`` records: filter by contributor pin, target
  ## platform and version pin; refuse an ambiguous contributor set; then
  ## ``selectArm`` (most specific coordinate, highest satisfied floor,
  ## declaration order).
  result.index = -1
  if records.len == 0:
    result.status = kcNoRecords
    result.detail = "no tarball realization declared"
    return
  let range = parsedVersionRange(versionRange)
  var arms: seq[PlatformBinary] = @[]
  var armRecord: seq[int] = @[]
  var platformMatched = false
  var versions: seq[string] = @[]
  var contributorFiltered = false
  for i, record in records:
    if not contributorAllowed(record.contributor, contributor):
      contributorFiltered = true
      continue
    let arm = tarballArm(record)
    if not arm.ok:
      result.status = kcInvalidRecord
      result.detail = "unreadable tarball realization " & record.url & ": " &
        arm.problem
      return
    # Coordinate applicability is ``selectArm``'s rule (tier >= 0); asking it
    # about a single arm keeps one definition of "applies to this target".
    let single = selectArm([PlatformBinary(cpu: arm.arm.cpu, os: arm.arm.os)],
      initPlatformTarget(target.platform.family), target.os)
    if single.index < 0:
      continue
    platformMatched = true
    let offered = if record.detail.version.len > 0: record.detail.version
                  else: "unversioned"
    if offered notin versions: versions.add(offered)
    if not matchesVersionRange(record.detail.version, range): continue
    if version.len > 0 and record.detail.version != version:
      continue
    arms.add(arm.arm)
    armRecord.add(i)
    if record.contributor notin result.contributors:
      result.contributors.add(record.contributor)
  if arms.len == 0:
    if platformMatched and (version.len > 0 or range.isSome):
      result.status = kcVersionNotOffered
      result.detail = "no tarball realization satisfies " &
        (if range.isSome: "range '" & versionRange else: "version '" & version) &
        "' for " & describeTarget(target) & " (offered: " &
        (if versions.len > 0: versions.join(", ") else: "unversioned") & ")"
    elif contributorFiltered and contributor.isSome:
      result.status = kcContributorNotOffered
      result.detail = "contributor " & contributorLabel(contributor.get) &
        " offers no tarball realization for " & describeTarget(target)
    else:
      result.status = kcNoneForTarget
      result.detail = "no tarball realization for " & describeTarget(target) &
        " (records cover " & describeCoverage(records) & ")"
    return
  if contributor.isNone and result.contributors.len > 1:
    result.status = kcAmbiguous
    result.detail = "eligible tarball contributors: " &
      result.contributors.mapIt(contributorLabel(it)).join(", ")
    return
  let picked = selectArm(arms, target.platform, target.os)
  if picked.index < 0:
    if picked.selection.refusedForLevel:
      result.status = kcCapabilityShortfall
      var refusedVersions: seq[string] = @[]
      for i in armRecord:
        let v = records[i].detail.version
        if v.len > 0 and v notin refusedVersions:
          refusedVersions.add(v)
      result.detail = "a tarball realization" &
        (if refusedVersions.len > 0:
           " (version " & refusedVersions.join(", ") & ")" else: "") &
        " exists for " &
        describeTarget(target) & " but the target cannot run it: " &
        describeCapabilityShortfall(picked.selection)
    else:
      result.status = kcNoneForTarget
      result.detail = "no tarball realization for " & describeTarget(target)
    return
  result.status = kcSelected
  result.index = armRecord[picked.index]

proc nixServesTarget*(target: RealizationTarget): bool =
  ## A ``nixPackage`` realizes on the OSes Nix runs on.
  target.os in {poLinux, poMacos}

proc selectNixRecord*(records: openArray[InterfaceNixProvisioning];
                      target: RealizationTarget; version = "";
                      contributor = none(string)): KindChoice =
  result.index = -1
  if records.len == 0:
    result.status = kcNoRecords
    result.detail = "no nixPackage realization declared"
    return
  if not nixServesTarget(target):
    result.status = kcNoneForTarget
    result.detail = "nix does not realize packages for " &
      describeTarget(target)
    return
  if version.len > 0:
    # A ``nixPackage`` record names an attribute of a pinned nixpkgs, not a
    # version; it cannot be shown to satisfy an exact pin.
    result.status = kcVersionNotOffered
    result.detail = "nixPackage realizations name no version, so none " &
      "satisfies the pin '" & version & "'"
    return
  for i, record in records:
    if not contributorAllowed(record.contributor, contributor):
      continue
    if record.contributor notin result.contributors:
      result.contributors.add(record.contributor)
    if result.index < 0:
      result.index = i
  if result.index < 0:
    result.status = kcContributorNotOffered
    result.detail = "contributor " & contributorLabel(contributor.get) &
      " offers no nix realization"
    return
  if contributor.isNone and result.contributors.len > 1:
    result.status = kcAmbiguous
    result.index = -1
    result.detail = "eligible nix contributors: " &
      result.contributors.mapIt(contributorLabel(it)).join(", ")
    return
  result.status = kcSelected

proc scoopServesTarget*(target: RealizationTarget): bool =
  target.os == poWindows

proc selectScoopRecord*(records: openArray[InterfaceScoopProvisioning];
                        target: RealizationTarget; version = "";
                        contributor = none(string); versionRange = ""): KindChoice =
  result.index = -1
  if records.len == 0:
    result.status = kcNoRecords
    result.detail = "no scoopApp realization declared"
    return
  if not scoopServesTarget(target):
    result.status = kcNoneForTarget
    result.detail = "scoop does not realize packages for " &
      describeTarget(target)
    return
  let range = parsedVersionRange(versionRange)
  var versions: seq[string] = @[]
  var versionMatched = false
  for i, record in records:
    if not contributorAllowed(record.contributor, contributor):
      continue
    let offered = if record.version.len > 0: record.version else: "unversioned"
    if offered notin versions: versions.add(offered)
    if not matchesVersionRange(record.version, range): continue
    if version.len > 0 and record.version != version:
      continue
    versionMatched = true
    if record.contributor notin result.contributors:
      result.contributors.add(record.contributor)
    if result.index < 0:
      result.index = i
  if result.index < 0:
    if (version.len > 0 or range.isSome) and not versionMatched and
        versions.len > 0:
      result.status = kcVersionNotOffered
      result.detail = "no scoopApp realization satisfies " &
        (if range.isSome: "range '" & versionRange else: "version '" & version) &
        "' (offered: " & versions.join(", ") & ")"
    else:
      result.status = kcContributorNotOffered
      result.detail = "contributor " & contributorLabel(contributor.get) &
        " offers no scoop realization"
    return
  if contributor.isNone and result.contributors.len > 1:
    result.status = kcAmbiguous
    result.index = -1
    result.detail = "eligible scoop contributors: " &
      result.contributors.mapIt(contributorLabel(it)).join(", ")
    return
  result.status = kcSelected

# ---------------------------------------------------------------------------
# Selection over a policy
# ---------------------------------------------------------------------------

proc parseRealizationKind*(token: string):
    tuple[ok: bool; kind: RealizationKind] =
  ## A selection-policy token. ``builtin`` is the pre-GM4b spelling of
  ## ``tarball`` (the adapter that read the retired catalog records) and is
  ## accepted so an existing ``adapterPreference:`` block keeps its meaning.
  case token.strip().toLowerAscii()
  of "tarball", "builtin": (true, rkTarball)
  of "nix": (true, rkNix)
  of "scoop": (true, rkScoop)
  of "path": (true, rkPath)
  else: (false, rkPath)

const DefaultSelectionPolicy*: SelectionPolicy =
  @[rkTarball, rkNix, rkScoop, rkPath]
  ## The policy when a profile names none for the target OS — the same on
  ## every platform (Provisioning-Contributions.md §"Selection policy"). Kinds
  ## a platform cannot use are not removed per platform: their records are
  ## simply not eligible there.

proc describePolicy*(policy: SelectionPolicy): string =
  policy.mapIt($it).join(", ")

proc renderTrace*(trace: openArray[KindOutcome]): string =
  var parts: seq[string] = @[]
  for step in trace:
    parts.add($step.kind & ": " & step.reason)
  parts.join("; ")

proc raiseSelectionError[T: ERealizationSelection](
    e: ref T; request: SelectionRequest; trace: seq[KindOutcome])
    {.noreturn.} =
  e.packageName = request.packageName
  e.target = describeTarget(request.target)
  e.steps = trace
  raise e

proc selectRealization*(useDef: InterfaceToolUse;
                        request: SelectionRequest): RealizationSelection =
  ## Select the realization of ``useDef`` (its declared nix / tarball /
  ## scoop records) for ``request.target`` under ``request.policy``.
  ##
  ## Raises ``EPlatformUnavailable`` (declared ``platforms:`` exclude the
  ## target), ``EAmbiguousRealization`` (an unpinned kind with more than one
  ## eligible contributor) or ``EMissingRealization`` (no kind selected). The
  ## steps are Provisioning-Contributions.md §"Profile Package References"
  ## → Selection, in order.
  let target = request.target
  if not request.availability.isAvailableOn(target.platform.family,
      target.os):
    var e = newException(EPlatformUnavailable,
      request.packageName & " is declared for " &
      request.availability.describeDeclaredPlatforms() & "; the target is " &
      request.availability.describeHostTarget(target.platform.family,
        target.os) & "." &
      (if request.availability.message.len > 0:
         " " & request.availability.message else: "") &
      " This is a declared platform constraint (`platforms:` on the " &
      "package), not a missing realization: no realization kind can supply " &
      "it here.")
    e.declaredPlatforms = request.availability.describeDeclaredPlatforms()
    e.authorMessage = request.availability.message
    raiseSelectionError(e, request, @[])
  var trace: seq[KindOutcome] = @[]
  var capabilityRefusal = ""
  for kind in request.policy:
    var step = KindOutcome(kind: kind)
    var choice: KindChoice
    case kind
    of rkTarball:
      let records = withLockedIdentity(useDef.tarballProvisioning,
        request.lockIdentity, request.contributor)
      choice =
        if records.kept.len == 0 and request.lockIdentity.len > 0 and
            useDef.tarballProvisioning.len > 0:
          lockedIdentityMiss(kind, request.lockIdentity, records.withheld)
        else:
          selectTarballRecord(records.kept, target, request.version,
            request.contributor)
      if choice.status == kcSelected:
        let record = records.kept[choice.index]
        result.kind = rkTarball
        result.contributor = record.contributor
        result.tarball = record
        result.version = record.detail.version
        result.realizationLockIdentity =
          tarballRealizationLockIdentity(record)
    of rkNix:
      let records = withLockedIdentity(useDef.nixProvisioning,
        request.lockIdentity, request.contributor)
      choice =
        if records.kept.len == 0 and request.lockIdentity.len > 0 and
            useDef.nixProvisioning.len > 0:
          lockedIdentityMiss(kind, request.lockIdentity, records.withheld)
        else:
          selectNixRecord(records.kept, target, request.version,
            request.contributor)
      if choice.status == kcSelected:
        let record = records.kept[choice.index]
        result.kind = rkNix
        result.contributor = record.contributor
        result.nix = record
        result.realizationLockIdentity = nixRealizationLockIdentity(record)
    of rkScoop:
      let records = withLockedIdentity(useDef.scoopProvisioning,
        request.lockIdentity, request.contributor)
      choice =
        if records.kept.len == 0 and request.lockIdentity.len > 0 and
            useDef.scoopProvisioning.len > 0:
          lockedIdentityMiss(kind, request.lockIdentity, records.withheld)
        else:
          selectScoopRecord(records.kept, target, request.version,
            request.contributor)
      if choice.status == kcSelected:
        let record = records.kept[choice.index]
        result.kind = rkScoop
        result.contributor = record.contributor
        result.scoop = record
        result.version = record.version
        result.realizationLockIdentity = scoopRealizationLockIdentity(record)
      elif choice.status == kcNoRecords and scoopServesTarget(target) and
          target.isHost and request.inventory.probeScoop != nil and
          request.contributor.isNone and request.lockIdentity.len == 0:
        # Host inventory: a Scoop app of the package's name, installed or
        # offered by a configured bucket, when the definition declares no
        # scoop realization. Ambient — recorded, never pinned.
        let hit = request.inventory.probeScoop(request.packageName)
        if hit.found and (request.version.len == 0 or
            hit.version == request.version):
          choice.status = kcSelected
          result.kind = rkScoop
          result.ambient = true
          result.scoopInventory = hit
          result.version = hit.version
          result.realizationLockIdentity = "scoop:" & hit.bucket & "/" &
            hit.app
        else:
          choice.detail = "no scoopApp realization declared, and the host's " &
            "Scoop inventory has no app '" & request.packageName & "'" &
            (if hit.found: " at version '" & request.version & "'" else: "")
    of rkPath:
      choice.index = -1
      if capabilityRefusal.len > 0:
        # PMC-4: an archive exists for the target and the target cannot run
        # it. A same-named executable on PATH is not that artifact.
        choice.status = kcCapabilityShortfall
        choice.detail = "refused: an archive realization exists for " &
          describeTarget(target) & " but the target cannot run it, and a " &
          "same-named executable from PATH would substitute an undeclared " &
          "binary for it (" & capabilityRefusal & ")"
      elif not target.isHost:
        choice.status = kcNoneForTarget
        choice.detail = "PATH describes the host only, not " &
          describeTarget(target)
      elif request.inventory.probePath == nil:
        choice.status = kcNoRecords
        choice.detail = "this caller consults no PATH inventory"
      elif request.contributor.isSome:
        choice.status = kcContributorNotOffered
        choice.detail = "a contributor is pinned; PATH has no contributor"
      elif request.lockIdentity.len > 0:
        choice.status = kcLockedIdentityNotOffered
        choice.detail = "a lock identity is pinned; an executable on PATH " &
          "has none"
      elif request.version.len > 0:
        choice.status = kcVersionNotOffered
        choice.detail = "an executable on PATH names no version, so none " &
          "satisfies the pin '" & request.version & "'"
      else:
        let names =
          if request.probeNames.len > 0: request.probeNames
          else: @[request.packageName]
        let found = request.inventory.probePath(names)
        if found.len > 0:
          choice.status = kcSelected
          result.kind = rkPath
          result.ambient = true
          result.pathExecutable = found
          result.realizationLockIdentity = "path:" & found
        else:
          choice.status = kcNoneForTarget
          choice.detail =
            if names.len == 1: "'" & names[0] & "' not found on PATH"
            else: "none of [" & names.join(", ") & "] found on PATH"
    step.selected = choice.status == kcSelected
    step.capabilityShortfall = choice.status == kcCapabilityShortfall
    if step.selected:
      step.reason = "selected" &
        (if result.ambient: " from the host inventory" else: "") &
        (if result.contributor.len > 0:
           " (contributor " & result.contributor & ")" else: "")
      trace.add(step)
      result.lockIdentity =
        if result.ambient: result.realizationLockIdentity
        else: contributorLockIdentity(result.contributor,
          result.realizationLockIdentity)
      result.trace = trace
      return
    step.reason = choice.detail
    trace.add(step)
    if choice.status == kcCapabilityShortfall and kind == rkTarball and
        capabilityRefusal.len == 0:
      capabilityRefusal = choice.detail
    if choice.status == kcInvalidRecord:
      var e = newException(EInvalidRealization,
        "package '" & request.packageName & "' declares " & choice.detail)
      raiseSelectionError(e, request, trace)
    if choice.status == kcAmbiguous:
      var e = newException(EAmbiguousRealization,
        "ambiguous " & $kind & " realization of package '" &
        request.packageName & "' for " & describeTarget(target) & "; " &
        choice.detail & "; select one through the lock or a contributor pin")
      e.kind = kind
      e.contributors = choice.contributors
      raiseSelectionError(e, request, trace)
  let definitionKnown = request.definitionKnown or
    useDef.nixProvisioning.len > 0 or useDef.tarballProvisioning.len > 0 or
    useDef.scoopProvisioning.len > 0
  let message =
    if definitionKnown:
      "no realization of package '" & request.packageName & "' for " &
        describeTarget(target) & " under the selection policy [" &
        describePolicy(request.policy) & "]" &
        (if request.version.len > 0: " at version '" & request.version & "'"
         else: "") & ": " & renderTrace(trace)
    else:
      "unknown package '" & request.packageName & "': no package " &
        "definition in scope names it, and no host inventory realizes it " &
        "for " & describeTarget(target) & " (" & renderTrace(trace) & ")"
  var e = newException(EMissingRealization, message)
  e.definitionKnown = definitionKnown
  raiseSelectionError(e, request, trace)
