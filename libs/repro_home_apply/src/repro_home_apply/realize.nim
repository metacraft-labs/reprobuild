## Realize planned packages.
##
## GM4b: every package reference is resolved by ``package_catalog.
## resolveProfilePackage`` — the canonical definition and its contributions,
## through ``realization_selection.selectRealization``, the selection a
## recipe's ``uses:`` makes (Provisioning-Contributions.md §"Profile Package
## References"). This module realizes the SELECTION with the realizer of its
## kind:
##
##   * ``tarball``, plain archive — the ``uses:`` provisioning edge
##     (``repro_tool_profiles.resolveTarballTool``), the realizer recipes use;
##   * ``tarball``, installer / MSYS2 / pre-install / launcher emission — the
##     home archive realizer (``builtin_adapter.realizeBuiltinPackage``);
##   * ``nix`` — ``repro_tool_profiles.resolveNixTool``, then a store prefix
##     recording the Nix store path;
##   * ``scoop`` — ``repro_tool_profiles.resolveScoopTool`` (Windows);
##   * ``path`` — the executable already on PATH, hardlinked or copied into a
##     store prefix.
##
## ``previewPackageResolutions`` (``--plan``) and ``realizePlannedPackages``
## (apply) resolve through the same ``ProfileResolutionContext``, so the plan
## and the apply cannot select differently.
##
## Test seams: ``$REPRO_TEST_PACKAGE_SOURCE`` (``<pkg>=<absolute-path>``) and
## ``$REPRO_TEST_PACKAGE_SCOOP`` (``<pkg>=<bucket>/<app>@<version>[#<exe>]``)
## bind a package to a fixture before resolution runs. They are TEST-ONLY:
## the actual realization still goes through the real store and the real
## realizer, only the binding comes from the environment.

import std/[options, os, strutils, tables]
from repro_core/paths import extendedPath

import blake3
import repro_local_store
import repro_home_generations
import repro_interface_artifacts
import repro_tool_profiles

import ./errors
import ./plan
import ./package_catalog
import ./builtin_adapter
import ./home_lock

const
  PackageSourceEnvVar* = "REPRO_TEST_PACKAGE_SOURCE"
  PackageScoopEnvVar* = "REPRO_TEST_PACKAGE_SCOOP"
  ScoopOverrideEnvVar* = "REPRO_TEST_SCOOP_OVERRIDE"

type
  AdapterKind* = enum
    akPath = "path"
    akScoop = "scoop"
    akTarball = "tarball"
    akBuiltin = "builtin"
      ## A ``tarball`` selection realized by the home archive realizer
      ## (``builtin_adapter.realizeBuiltinPackage``): installers, MSYS2
      ## packages, pre-install steps, launcher emission.
    akNix = "nix"
      ## GM4b: a ``nixPackage`` selection realized by
      ## ``repro_tool_profiles.resolveNixTool``.

  RealizedRecord* = object
    ## Per-package realization output: the prefix id + the resolved
    ## executable path, both fed into the manifest writer and the
    ## launch-plan synthesizer.
    packageId*: string
    adapter*: AdapterKind
    prefixId*: PrefixIdBytes
    prefixRelativePath*: string
    prefixAbsolutePath*: string
    resolvedExecutablePath*: string
    provenance*: seq[byte]
    fromProductionCatalog*: bool
      ## True when this record was resolved by ``resolveProfilePackage``
      ## (no `REPRO_TEST_PACKAGE_*` seam).
    cacheHit*: bool
      ## M72: true when the package was already installed at a
      ## version satisfying the profile — recorded as realized, NOT
      ## reinstalled. False for a genuine fresh realization.
    resolvedVersion*: string
      ## The selected realization's version, when it names one.
    # Archive fields: populated for a ``tarball`` selection.
    urlUsed*: string
    digestAlgorithm*: string
    digestValue*: string
    archiveFormat*: ArchiveFormat
    envBindings*: seq[tuple[name, value: string]]
      ## Per-tool environment variables (e.g. JAVA_HOME) with
      ## `${prefix}` already substituted. The apply pipeline merges
      ## these into the home generation's env export.
    selection*: RealizationSelection
      ## GM4b: what ``resolveProfilePackage`` selected — kind, contributor,
      ## version and lock identity. The home-profile lock is written from
      ## these. Default (and ``fromProductionCatalog = false``) for a
      ## test-seam binding.

# ---------------------------------------------------------------------------
# Env-driven catalog
# ---------------------------------------------------------------------------

type
  PathPackageSpec = object
    sourcePath: string
  ScoopPackageSpec = object
    bucket: string
    app: string
    version: string
    executableName: string

proc parsePathCatalog(): Table[string, PathPackageSpec] =
  let raw = getEnv(PackageSourceEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    let src = trimmed[eq + 1 .. ^1].strip()
    if pkg.len == 0 or src.len == 0:
      continue
    result[pkg] = PathPackageSpec(sourcePath: src)

proc parseScoopCatalog(): Table[string, ScoopPackageSpec] =
  let raw = getEnv(PackageScoopEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    var rest = trimmed[eq + 1 .. ^1].strip()
    if pkg.len == 0 or rest.len == 0:
      continue
    var execName = ""
    let hash = rest.find('#')
    if hash >= 0:
      execName = rest[hash + 1 .. ^1].strip()
      rest = rest[0 ..< hash]
    let slash = rest.find('/')
    if slash <= 0:
      continue
    let bucket = rest[0 ..< slash].strip()
    var afterSlash = rest[slash + 1 .. ^1]
    var version = ""
    let at = afterSlash.find('@')
    var app = afterSlash
    if at >= 0:
      app = afterSlash[0 ..< at].strip()
      version = afterSlash[at + 1 .. ^1].strip()
    if execName.len == 0:
      execName = app
    result[pkg] = ScoopPackageSpec(bucket: bucket, app: app,
      version: version, executableName: execName)

# ---------------------------------------------------------------------------
# Path-adapter realization
# ---------------------------------------------------------------------------

proc realizePathAdapter(store: var Store; packageId, sourcePath: string):
    RealizedRecord =
  ## Hardlink-or-copy `sourcePath` (an absolute path on the host) into
  ## a freshly realized `prefixes/...` directory inside the M56 store.
  ## The realization-hash is derived deterministically from
  ## `(packageId, sourcePath)` so two applies of the same intent
  ## produce the same prefix id (no-op short-circuit relies on this).
  if not fileExists(extendedPath(sourcePath)):
    raiseRealizeFailed(packageId, "path",
      "source executable not found at '" & sourcePath & "' (" &
      PackageSourceEnvVar & ")")
  let leafName = extractFilename(sourcePath)
  let hint = StoreReceiptHint(
    adapter: "path",
    packageName: packageId,
    version: "fixture",
    declaredExecutablePath: leafName,
    exportedExecutables: @[leafName],
    lockIdentity: "path:" & sourcePath,
    provenanceUrl: "file:///" & sourcePath.replace('\\', '/'),
    provenanceChecksum: "",
    materializationMechanism: "")
  let prefixId = computeRealizationHash(packageId, "fixture", "path",
    "path:" & sourcePath, leafName,
    "file:///" & sourcePath.replace('\\', '/'), "", [packageId])
  let outcome = realizePrefix(store, prefixId, hint,
    proc(stagingDir: string; mechanism: var string) =
      let dst = stagingDir / leafName
      try:
        createHardlink(sourcePath, dst)
        mechanism = "hardlink"
      except OSError, IOError:
        copyFile(extendedPath(sourcePath), extendedPath(dst))
        mechanism = "copy")
  result.packageId = packageId
  result.adapter = akPath
  result.prefixId = prefixId
  result.prefixRelativePath = outcome.relativePath
  result.prefixAbsolutePath = outcome.absolutePath
  result.resolvedExecutablePath = outcome.absolutePath / leafName
  # Pack the provenance: a single typed line of "path:<sourcePath>".
  let prov = "path:" & sourcePath
  result.provenance = newSeq[byte](prov.len)
  for i, ch in prov:
    result.provenance[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Store-prefix records for the realizers that register their own prefix
# ---------------------------------------------------------------------------

proc bytesOfText(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc recordFromStorePrefix(store: Store; packageId: string;
                           adapter: AdapterKind; adapterLabel: string;
                           absPath, resolvedExecutable,
                           provenance: string): RealizedRecord =
  ## The ``RealizedRecord`` view of a prefix a ``repro_tool_profiles``
  ## realizer laid out and registered in the unified store itself
  ## (``registerInUnifiedStore`` seals ``.repro-receipt`` at its root, whose
  ## realization hash is the prefix id the generation holds).
  let receiptPath = absPath / ".repro-receipt"
  if not fileExists(extendedPath(receiptPath)):
    raiseRealizeFailed(packageId, adapterLabel,
      "no receipt at expected path " & receiptPath)
  let receipt = readReceiptFile(receiptPath)
  var rel = absPath
  let prefix = store.root & DirSep
  if rel.startsWith(prefix):
    rel = rel[prefix.len .. ^1]
  result.packageId = packageId
  result.adapter = adapter
  result.prefixId = receipt.realizationHash
  result.prefixRelativePath = rel.replace('\\', '/')
  result.prefixAbsolutePath = absPath
  result.resolvedExecutablePath = resolvedExecutable
  result.provenance = bytesOfText(provenance)

# ---------------------------------------------------------------------------
# Scoop realization
# ---------------------------------------------------------------------------

proc scoopSpecUse(packageId: string; spec: ScoopPackageSpec):
    InterfaceToolUse =
  ## A ``uses:``-shaped Scoop record for a binding that has no declared
  ## ``scoopApp`` (a test seam, or the host's Scoop inventory).
  result = InterfaceToolUse(
    rawConstraint: packageId,
    packageSelector: packageId,
    executableName: spec.executableName,
    location: SourceLocation(file: "home-apply", line: 1))
  result.scoopProvisioning = @[InterfaceScoopProvisioning(
    packageName: packageId,
    bucket: spec.bucket,
    app: spec.app,
    version: spec.version,
    preferredVersion: "",
    manifestChecksum: "",
    executablePath: spec.executableName,
    requiresExecutionProfileChecksum: false,
    packageId: spec.bucket & "/" & spec.app,
    lockIdentity: "scoop:" & spec.bucket & "/" & spec.app,
    location: SourceLocation(file: "home-apply", line: 2))]

proc realizeScoopUse(store: var Store; packageId: string;
                     useDef: InterfaceToolUse): RealizedRecord =
  ## Realize a Scoop record through the M55 adapter
  ## (``resolveScoopTool``), which creates and registers the prefix itself.
  when defined(windows):
    let scoopOverride = getEnv(ScoopOverrideEnvVar)
    let profile =
      try:
        resolveScoopTool(useDef, store.root, scoopOverride)
      except CatchableError as err:
        raiseRealizeFailed(packageId, "scoop", err.msg)
    let record = useDef.scoopProvisioning[0]
    recordFromStorePrefix(store, packageId, akScoop, "scoop",
      profile.selectedStorePath, profile.resolvedExecutablePath,
      "scoop:" & record.bucket & "/" & record.app & "@" & record.version)
  else:
    discard useDef
    raiseRealizeFailed(packageId, "scoop",
      "the scoop adapter is Windows-only; this build runs on a " &
      "non-Windows platform")

proc realizeScoopAdapter(store: var Store; packageId: string;
                         spec: ScoopPackageSpec): RealizedRecord =
  realizeScoopUse(store, packageId, scoopSpecUse(packageId, spec))

# ---------------------------------------------------------------------------
# Home archive realizer (installers, MSYS2, pre-install, launcher emit)
# ---------------------------------------------------------------------------

proc realizeBuiltinAdapter(store: var Store;
                           resolution: ArchiveRealization): RealizedRecord =
  ## Run the home archive realizer on a projected ``tarball`` selection and
  ## pack the result into the ``RealizedRecord`` the pipeline consumes.
  let outcome = realizeBuiltinPackage(store, resolution)
  result.packageId = resolution.packageId
  result.adapter = akBuiltin
  result.prefixId = outcome.prefixId
  result.prefixRelativePath = outcome.prefixRelativePath
  result.prefixAbsolutePath = outcome.prefixAbsolutePath
  result.resolvedExecutablePath = outcome.resolvedExecutablePath
  result.cacheHit = outcome.cacheHit
  result.resolvedVersion = resolution.builtinVersion
  result.urlUsed = outcome.urlUsed
  result.digestAlgorithm = outcome.digestAlgorithm
  result.digestValue = outcome.digestValue
  result.archiveFormat = outcome.archiveFormat
  result.envBindings = outcome.envBindings
  # Provenance: a typed `builtin:<algorithm>:<digest>` blob so cross-
  # adapter callers can identify which adapter realized the prefix.
  result.provenance = bytesOfText("builtin:" & outcome.digestAlgorithm & ":" &
    outcome.digestValue)


# ---------------------------------------------------------------------------
# Extract-route tarball and Nix realization
# ---------------------------------------------------------------------------

proc substitutedEnv(record: InterfaceTarballProvisioning;
                    prefixAbs: string): seq[tuple[name, value: string]] =
  ## A plain archive's ``env`` bindings with ``${prefix}`` substituted —
  ## what the home archive realizer computes for its own records, so an
  ## env-declaring package binds the same variables whichever realizer ran.
  var raw: seq[tuple[name, value: string]] = @[]
  for binding in record.detail.env:
    let eq = binding.find('=')
    if eq > 0:
      raw.add((name: binding[0 ..< eq], value: binding[eq + 1 .. ^1]))
  for i in 0 ..< raw.len:
    for j in i + 1 ..< raw.len:
      if raw[j].name < raw[i].name:
        swap(raw[i], raw[j])
  substituteEnv(raw, prefixAbs)

proc realizeExtractTarball(store: var Store;
                           resolution: ProfilePackageResolution):
    RealizedRecord =
  ## A plain archive: realized by the ``uses:`` provisioning edge
  ## (``resolveTarballTool``), the realizer a recipe's ``uses:`` of the same
  ## package runs. ``resolution.useDef`` carries only the selected record,
  ## so the edge cannot select a different one.
  let packageId = resolution.packageId
  let record = resolution.selection.tarball
  let profile =
    try:
      resolveTarballTool(resolution.useDef, store.root)
    except CatchableError as err:
      raiseRealizeFailed(packageId, "tarball", err.msg)
  result = recordFromStorePrefix(store, packageId, akTarball, "tarball",
    profile.selectedStorePath, profile.resolvedExecutablePath,
    "tarball:" & resolution.selection.lockIdentity)
  result.resolvedVersion = record.detail.version
  result.urlUsed = profile.tarballSelectedUrl
  result.digestAlgorithm = "sha256"
  result.digestValue = profile.tarballSha256
  let format = parseArchiveFormatToken(record.archiveType)
  if format.ok:
    result.archiveFormat = format.format
  result.envBindings = substitutedEnv(record, profile.selectedStorePath)

proc realizeNixSelection(store: var Store;
                         resolution: ProfilePackageResolution):
    RealizedRecord =
  ## A ``nixPackage`` selection: realized by ``resolveNixTool``, the
  ## realizer a recipe's ``uses:`` in nix mode runs. With a store root it
  ## records a pointer prefix for the Nix store path in the unified store,
  ## which is the prefix the generation holds.
  let packageId = resolution.packageId
  when defined(windows):
    raiseRealizeFailed(packageId, "nix",
      "nix realizations are not realized on Windows (selection should " &
      "never choose one for a Windows target)")
  else:
    let profile =
      try:
        resolveNixTool(resolution.useDef, store.root)
      except CatchableError as err:
        raiseRealizeFailed(packageId, "nix", err.msg)
    var pointerPrefix = ""
    let storePrefix = store.root & DirSep
    for path in profile.realizedStorePaths:
      if path.startsWith(storePrefix):
        pointerPrefix = path
    if pointerPrefix.len == 0:
      raiseRealizeFailed(packageId, "nix",
        "resolveNixTool registered no prefix under the store root " &
        store.root & " for " & profile.nixSelector)
    result = recordFromStorePrefix(store, packageId, akNix, "nix",
      pointerPrefix, profile.resolvedExecutablePath,
      "nix:" & resolution.selection.lockIdentity)
    # The runtime prefix is the Nix store path itself; the pointer prefix
    # only records it.
    result.prefixAbsolutePath = profile.selectedStorePath

# ---------------------------------------------------------------------------
# Resolution context — shared by --plan and apply
# ---------------------------------------------------------------------------

type
  ProfileResolutionContext* = object
    ## Everything a profile reference resolves against, fixed once per apply
    ## so the plan and the apply select identically.
    target*: RealizationTarget
    policy*: SelectionPolicy
    policySource*: string
      ## ``adapterPreference.<os>`` or ``default`` — recorded in the lock.
    inventory*: HostInventory
    scoop*: ScoopHostInventory
    lockTarget*: Option[HomeLockTarget]
      ## The home-profile lock's record for this target, when one exists.
    relock*: bool
      ## Ignore the lock's pins (``repro home apply --relock``).

proc profileResolutionContext*(
    adapterPreference: OrderedTable[string, seq[string]];
    platform, arch: string; isHost: bool;
    lock = none(HomeProfileLock); relock = false):
    ProfileResolutionContext =
  ## Build the context for a profile evaluated for ``platform`` / ``arch``
  ## (``HostContext`` spellings). The host inventory is consulted only when
  ## the target is the host.
  result.target = profileRealizationTarget(platform, arch, isHost)
  let policy = selectionPolicyFor(adapterPreference, result.target.os)
  result.policy = policy.policy
  result.policySource = policy.source
  if isHost:
    when defined(windows):
      result.scoop = openScoopHostInventory()
    result.inventory = profileHostInventory(result.scoop)
  if lock.isSome:
    result.lockTarget = lockedTarget(lock.get, describeTarget(result.target))
  result.relock = relock

proc hostProfileResolutionContext*(
    adapterPreference = initOrderedTable[string, seq[string]]();
    lock = none(HomeProfileLock); relock = false): ProfileResolutionContext =
  ## The context for the machine running the apply.
  let host = profileRealizationTarget(
    case detectHostOs()
    of poWindows: "windows"
    of poMacos: "macos"
    else: "linux",
    if detectHostCpu() == pcAArch64: "arm64" else: "x86_64", true)
  result = profileResolutionContext(adapterPreference,
    $host.os, $host.platform.family, true, lock, relock)

proc resolveInContext*(ctx: ProfileResolutionContext;
                       p: PlannedPackage): ProfilePackageResolution =
  ## Resolve one planned package in ``ctx``. A lock pin (a non-ambient
  ## selection recorded under the current policy) narrows the policy to the
  ## pinned kind and pins the contributor and the lock identity, so exactly
  ## the recorded realization is eligible; when it is no longer offered, the
  ## failure names the lock and ``--relock`` instead of silently re-selecting
  ## (Provisioning-Contributions.md §"The home-profile lock").
  let pin =
    if ctx.relock: none(HomeLockPin)
    else: lockedPin(ctx.lockTarget, p.packageId, ctx.policy,
      p.requestedVersion)
  if pin.isNone:
    return resolveProfilePackage(p.packageId, ctx.target, ctx.policy,
      requestedVersion = p.requestedVersion, binaries = p.binaries,
      inventory = ctx.inventory, scoop = ctx.scoop)
  try:
    resolveProfilePackage(p.packageId, ctx.target, @[pin.get.kind],
      requestedVersion = p.requestedVersion, binaries = p.binaries,
      contributor = some(pin.get.contributor), inventory = ctx.inventory,
      scoop = ctx.scoop, lockIdentity = pin.get.lockIdentity)
  except EMissingRealization as err:
    let locked =
      (if pin.get.version.len > 0: " at version " & pin.get.version
       else: "") &
      (if pin.get.lockIdentity.len > 0:
         " (lock identity " &
           displayLockIdentity(pin.get.lockIdentity).escape() & ")"
       else: "")
    var e = newException(EMissingRealization,
      "the home-profile lock pins " & p.packageId & " for " &
      describeTarget(ctx.target) & " to its " & $pin.get.kind &
      " realization from " & contributorLabel(pin.get.contributor) & locked &
      ", which is no longer offered (" & err.msg & "). Re-select with " &
      "`repro home apply --relock`.")
    e.packageName = err.packageName
    e.target = err.target
    e.steps = err.steps
    e.definitionKnown = err.definitionKnown
    raise e

proc realizeResolution*(store: var Store;
                        resolution: ProfilePackageResolution):
    RealizedRecord =
  ## Realize one resolved reference with the realizer of its selected kind.
  let selection = resolution.selection
  case selection.kind
  of rkTarball:
    case resolution.archiveRoute
    of arExtract:
      result = realizeExtractTarball(store, resolution)
    of arInstaller:
      result = realizeBuiltinAdapter(store, resolution.archive)
  of rkNix:
    result = realizeNixSelection(store, resolution)
  of rkScoop:
    if selection.ambient:
      let hit = selection.scoopInventory
      result = realizeScoopAdapter(store, resolution.packageId,
        ScoopPackageSpec(bucket: hit.bucket, app: hit.app,
          version: hit.version, executableName: hit.executableName))
    else:
      result = realizeScoopUse(store, resolution.packageId, resolution.useDef)
    result.cacheHit = resolution.cacheHit
  of rkPath:
    result = realizePathAdapter(store, resolution.packageId,
      selection.pathExecutable)
    result.cacheHit = true
  result.fromProductionCatalog = true
  result.selection = selection
  if result.resolvedVersion.len == 0:
    result.resolvedVersion = selection.version

# ---------------------------------------------------------------------------
# Read-only package preview for `--plan`
# ---------------------------------------------------------------------------

type
  PackagePreviewKind* = enum
    ppkRealize = "realize"            ## genuine fresh realization
    ppkCacheHit = "cache-hit"         ## already installed & satisfying
    ppkMissing = "missing"            ## no realization for the target

  PackagePreview* = object
    ## Read-only verdict for one `PlannedPackage` — what a real apply
    ## WOULD do, computed without realizing anything.
    packageId*: string
    kind*: PackagePreviewKind
    detail*: string
    resolved*: bool
      ## True when ``resolveProfilePackage`` selected a realization (false
      ## for a test-seam binding and for a missing package).
    resolution*: ProfilePackageResolution
      ## The selection, when ``resolved``.
    steps*: seq[KindOutcome]
      ## The policy steps consulted — the selection's trace, or the failed
      ## selection's ``steps``.
    resolvedVersion*: string

proc contributorSuffix(selection: RealizationSelection): string =
  if selection.contributor.len > 0:
    " [contributor " & selection.contributor & "]"
  else:
    ""

proc describeResolution*(resolution: ProfilePackageResolution):
    tuple[kind: PackagePreviewKind; detail: string] =
  ## The ``--plan`` line for a resolved reference.
  let selection = resolution.selection
  case selection.kind
  of rkTarball:
    let record = selection.tarball
    let digest =
      if record.sha256.len > 0: "sha256"
      elif record.detail.sha512.len > 0: "sha512"
      else: "sha1"
    let route =
      if resolution.archiveRoute == arInstaller:
        ", " & (if record.detail.installMethod.len > 0:
                  record.detail.installMethod else: "extract")
      else: ""
    (ppkRealize, "tarball " & record.url &
      (if selection.version.len > 0: " @" & selection.version else: "") &
      " (" & digest & route & ")" & contributorSuffix(selection))
  of rkNix:
    (ppkRealize, "nix " & effectiveNixSelector(selection.nix) &
      contributorSuffix(selection))
  of rkScoop:
    let bucketApp =
      if selection.ambient:
        selection.scoopInventory.bucket & "/" & selection.scoopInventory.app
      else:
        selection.scoop.bucket & "/" & selection.scoop.app
    if resolution.cacheHit:
      (ppkCacheHit, "scoop " & bucketApp & "@" & resolution.installedVersion &
        " already installed (no reinstall)" & contributorSuffix(selection))
    else:
      (ppkRealize, "scoop " & bucketApp &
        (if selection.version.len > 0: "@" & selection.version else: "") &
        " would be installed" & contributorSuffix(selection))
  of rkPath:
    (ppkCacheHit, "path " & selection.pathExecutable & " already available")

proc previewResolutionFailure(err: ref CatchableError):
    tuple[detail: string; steps: seq[KindOutcome]] =
  if err of EPlatformUnavailable:
    ("platform-unavailable: " & err.msg,
     (ref ERealizationSelection)(err).steps)
  elif err of EAmbiguousRealization:
    ("ambiguous-realization: " & err.msg,
     (ref ERealizationSelection)(err).steps)
  elif err of EInvalidRealization:
    ("invalid-realization: " & err.msg,
     (ref ERealizationSelection)(err).steps)
  elif err of EMissingRealization:
    let missing = (ref EMissingRealization)(err)
    ((if missing.definitionKnown: "missing-realization: "
      else: "unknown-package: ") & err.msg, missing.steps)
  else:
    ("unrealizable: " & err.msg, @[])

proc previewPackageResolutions*(packages: seq[PlannedPackage];
                                ctx: ProfileResolutionContext):
    seq[PackagePreview] =
  ## Classify each planned package WITHOUT realizing it. The selection is
  ## static metadata plus the host inventory (PATH, `scoop list`, bucket
  ## manifests) — reads only; no download, build or `scoop install` runs.
  ## Resolution precedence matches ``realizePlannedPackages``: test seams
  ## first, then ``resolveInContext``.
  let pathCatalog = parsePathCatalog()
  let scoopCatalog = parseScoopCatalog()
  for p in packages:
    var preview = PackagePreview(packageId: p.packageId)
    if p.packageId in pathCatalog:
      let src = pathCatalog[p.packageId].sourcePath
      if fileExists(extendedPath(src)):
        preview.kind = ppkRealize
        preview.detail = "path adapter (test seam) -> " & src
      else:
        preview.kind = ppkMissing
        preview.detail = "path-adapter source missing: " & src
    elif p.packageId in scoopCatalog:
      preview.kind = ppkRealize
      let s = scoopCatalog[p.packageId]
      preview.detail = "scoop adapter (test seam) -> " & s.bucket & "/" & s.app
    else:
      try:
        let resolution = resolveInContext(ctx, p)
        let described = describeResolution(resolution)
        preview.kind = described.kind
        preview.detail = described.detail
        preview.resolved = true
        preview.resolution = resolution
        preview.steps = resolution.selection.trace
        preview.resolvedVersion = resolution.selection.version
      except CatchableError as err:
        let failure = previewResolutionFailure(err)
        preview.kind = ppkMissing
        preview.detail = failure.detail
        preview.steps = failure.steps
    result.add(preview)

# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------

proc realizePlannedPackages*(store: var Store;
                             packages: seq[PlannedPackage];
                             ctx: ProfileResolutionContext):
    seq[RealizedRecord] =
  ## Realize every planned package. The `REPRO_TEST_PACKAGE_*` seams are
  ## TEST-ONLY bindings and win; every other package is resolved in ``ctx``
  ## (the same context the ``--plan`` preview used) and realized by the
  ## realizer of its selected kind. A package that cannot be resolved fails
  ## the apply with ``EApplyRealizeFailed`` naming the reason.
  let pathCatalog = parsePathCatalog()
  let scoopCatalog = parseScoopCatalog()
  for p in packages:
    if p.packageId in pathCatalog:
      result.add(realizePathAdapter(store, p.packageId,
        pathCatalog[p.packageId].sourcePath))
    elif p.packageId in scoopCatalog:
      result.add(realizeScoopAdapter(store, p.packageId,
        scoopCatalog[p.packageId]))
    else:
      let resolution =
        try:
          resolveInContext(ctx, p)
        except EPlatformUnavailable as err:
          raiseRealizeFailed(p.packageId, "<platform>", err.msg)
        except ERealizationSelection as err:
          raiseRealizeFailed(p.packageId, "<selection>", err.msg)
        except ValueError as err:
          raiseRealizeFailed(p.packageId, "<selection>", err.msg)
      result.add(realizeResolution(store, resolution))
