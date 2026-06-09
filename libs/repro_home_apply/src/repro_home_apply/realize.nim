## Realize planned packages through the appropriate M55/M56 adapter.
##
## The M63 pipeline supports three adapters at the apply layer:
##
##   * `scoop`  — Windows-only; binds through `repro_tool_profiles.resolveScoopTool`
##                with a sandboxed `$SCOOP` root.
##   * `tarball` — cross-platform fallback for verified-source packages
##                (not exercised by Phase A gates, present for symmetry).
##   * `path`    — universal "the executable already lives at an
##                absolute path" adapter. Used by gate 4 to install
##                `fd` from a fixture stub executable without forcing
##                a real Scoop install. Records a real `prefixes/...`
##                row in the M56 store with a hardlink-or-copy of the
##                source executable.
##
## The picker is driven by:
##
##   1. `$REPRO_TEST_PACKAGE_SOURCE` (semicolon-separated
##      `<pkg>=<absolute-path>` entries) — exercised by the Phase A
##      gates to declare path-adapter packages without going through
##      Scoop.
##   2. `$REPRO_TEST_PACKAGE_SCOOP` (semicolon-separated
##      `<pkg>=<bucket>/<app>@<version>[#<execName>]`) — exercised by
##      the fresh-install gate to route a package through the Scoop
##      adapter against the sandboxed root.
##
## The env-driven indirection is the same shape as the M61 catalog
## lookup seam (`REPRO_HOME_PACKAGE_CATALOG`) and keeps the gates'
## "no fake apply" rule intact: the actual realization still goes
## through the real store + the real Scoop adapter; the env vars
## only carry per-package binding instructions a future package
## catalog (M65+) will provide.
##
## M72 Deliverable 1 — production package catalog:
##   When a package has NO `REPRO_TEST_PACKAGE_*` seam binding, the
##   dispatcher falls back to `package_catalog.resolvePackage`, which
##   resolves the reference against the REAL host adapter catalog (on
##   Windows: installed Scoop apps + configured Scoop buckets) and
##   dispatches the package to the M55 Scoop adapter. An app already
##   installed at a satisfying version is recorded as a CACHE-HIT and
##   is NOT reinstalled. An unknown package raises `EUnknownPackage`
##   (a structured diagnostic naming the package + the catalogs
##   searched), surfaced by the pipeline as `EApplyRealizeFailed`.
##   Resolution precedence: the test seams win over the production
##   catalog so the M63/M68/M70 gates do not regress.

import std/[os, strutils, tables]
from repro_core/paths import extendedPath

import blake3
import repro_local_store
import repro_home_generations
when defined(windows):
  import repro_interface_artifacts
  import repro_tool_profiles

import ./errors
import ./plan
import ./package_catalog
import ./builtin_adapter
import ./catalog_lookup
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry

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
      ## M64: a realized cakBuiltin package — bytes fetched from the
      ## catalog's recorded URL, verified against the catalog's
      ## recorded SHA, and materialized into the M56 store via
      ## `realizeBuiltinPackage`.

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
      ## M72: true when this record was resolved by the production
      ## catalog (no `REPRO_TEST_PACKAGE_*` seam). Used by the apply
      ## log and `--plan` preview to distinguish a real catalog
      ## dispatch from a test-seam binding.
    cacheHit*: bool
      ## M72: true when the package was already installed at a
      ## version satisfying the profile — recorded as realized, NOT
      ## reinstalled. False for a genuine fresh realization.
    resolvedVersion*: string
      ## M72: the version the catalog resolved (Scoop app version).
    # M64 fields: populated when `adapter == akBuiltin`.
    urlUsed*: string
    digestAlgorithm*: string
    digestValue*: string
    archiveFormat*: ArchiveFormat
    envBindings*: seq[tuple[name, value: string]]
      ## Per-tool environment variables (e.g. JAVA_HOME) with
      ## `${prefix}` already substituted. The apply pipeline merges
      ## these into the home generation's env export.
    chainTrace*: seq[ChainStep]
      ## M1 (Realize-Layer-Plumbing-Closures): per-resolution chain trace
      ## populated by the chain-routed branch of
      ## `realizeViaProductionCatalog` so the realize side reports the
      ## same per-adapter trace `PackagePreview.chainTrace` exposes.
      ## Empty for the legacy `resolvePackage` branch and for test-seam
      ## bindings (path / scoop env-driven catalogs).

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
# Scoop-adapter realization
# ---------------------------------------------------------------------------

when defined(windows):
  proc realizeScoopAdapter(store: var Store; packageId: string;
                           spec: ScoopPackageSpec): RealizedRecord =
    ## Bind the package through the M55 Scoop adapter.
    ## `resolveScoopTool` itself creates the realized prefix under the
    ## store via `registerInUnifiedStore`; we synthesize the
    ## `RealizedRecord` view of that result for the manifest writer.
    let useDef = InterfaceToolUse(
      rawConstraint: packageId,
      packageSelector: packageId,
      executableName: spec.executableName,
      location: SourceLocation(file: "home-apply", line: 1))
    var provisioning = InterfaceScoopProvisioning(
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
      location: SourceLocation(file: "home-apply", line: 2))
    var withScoop = useDef
    withScoop.scoopProvisioning = @[provisioning]
    let scoopOverride = getEnv(ScoopOverrideEnvVar)
    let profile =
      try:
        resolveScoopTool(withScoop, store.root, scoopOverride)
      except CatchableError as err:
        raiseRealizeFailed(packageId, "scoop", err.msg)
    # `resolveScoopTool` populated `selectedStorePath` with the
    # realized prefix. Reverse-compute the relative path under the
    # store + read the receipt to obtain the canonical prefix id.
    let absPath = profile.selectedStorePath
    let relPath = block:
      var rel = absPath
      let prefix = store.root & DirSep
      if rel.startsWith(prefix):
        rel = rel[prefix.len .. ^1]
      rel.replace('\\', '/')
    # The receipt path under the prefix encodes the realization hash.
    let receiptPath = absPath / ".repro-receipt"
    if not fileExists(extendedPath(receiptPath)):
      raiseRealizeFailed(packageId, "scoop",
        "no receipt at expected path " & receiptPath)
    let recipt = readReceiptFile(receiptPath)
    result.packageId = packageId
    result.adapter = akScoop
    result.prefixId = recipt.realizationHash
    result.prefixRelativePath = relPath
    result.prefixAbsolutePath = absPath
    result.resolvedExecutablePath = profile.resolvedExecutablePath
    let prov = "scoop:" & spec.bucket & "/" & spec.app & "@" & spec.version
    result.provenance = newSeq[byte](prov.len)
    for i, ch in prov:
      result.provenance[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# M64 cakBuiltin-adapter realization
# ---------------------------------------------------------------------------

proc realizeBuiltinAdapter(store: var Store;
                           resolution: CatalogResolution): RealizedRecord =
  ## Bridge the `CatalogResolution` shape onto the `realizeBuiltinPackage`
  ## entry point in `./builtin_adapter.nim` and pack the result into a
  ## `RealizedRecord` the apply pipeline downstream consumes.
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
  let prov = "builtin:" & outcome.digestAlgorithm & ":" & outcome.digestValue
  result.provenance = newSeq[byte](prov.len)
  for i, ch in prov:
    result.provenance[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# M2.5 adapter-preference helpers
# ---------------------------------------------------------------------------
#
# `resolveAdapterChainFor` picks the per-host chain to feed into M65's
# `chainResolvePackage`. The rule (per M2.5 spec):
#
#   1. If the profile carries an `adapterPreference:` block AND the
#      block has an entry for the current host's OS → use it.
#   2. If the block is present but the current OS key is unspecified →
#      fall back to the M65 platform default for that OS (NOT the
#      empty chain).
#   3. If the block is absent → fall back to the M65 platform default.
#
# Adapter-name → CatalogAdapterKind mapping is the closed set the M2.5
# DSL parser already enforces; an unknown name here is a defensive
# bug-check (the parsers reject unknown entries at parse time).

proc currentHostOsKey*(): string =
  ## Canonical OS key for the current host. Matches the DSL parser's
  ## canonicalization (`macos` aliases to `darwin`).
  when defined(windows):
    "windows"
  elif defined(linux):
    "linux"
  elif defined(macosx) or defined(osx):
    "darwin"
  else:
    ""

proc adapterNameToKind(name: string): CatalogAdapterKind =
  ## Defensive: the parser already restricts the closed set.
  case name
  of "builtin": cakBuiltin
  of "scoop":   cakScoop
  of "nix":     cakNix
  of "path":    cakPath
  else:
    raise newException(ValueError,
      "internal: unknown adapter name '" & name &
      "' reached resolveAdapterChainFor; the DSL parser must reject " &
      "this earlier (closed set: builtin, scoop, nix, path)")

proc resolveAdapterChainFor*(
    adapterPreference: OrderedTable[string, seq[string]];
    osKey: string): seq[CatalogAdapterKind] =
  ## M2.5: pick the chain to feed into `chainResolvePackage` for a
  ## given host OS. An empty preference table → the M65 platform
  ## default chain. A present table that lacks the current OS key →
  ## the M65 platform default chain for that OS (NOT the empty chain).
  ## A present + matching entry → that entry's chain (an empty list
  ## also falls back to the platform default for that OS).
  if osKey in adapterPreference:
    let names = adapterPreference[osKey]
    if names.len > 0:
      for n in names:
        result.add adapterNameToKind(n)
      return
  # Fallback: M65 platform default for the named OS. Note this is
  # keyed on the requested OS, NOT the host's OS — for tests this lets
  # us assert "a Windows-only preference uses the Windows default on
  # a non-Windows host" if we ever wire that up (today the helper is
  # always called with the host's OS key so the distinction is moot,
  # but the keying is correct).
  case osKey
  of "windows": result = WindowsDefaultChain
  of "linux":   result = LinuxDefaultChain
  of "darwin":  result = MacosDefaultChain
  else:
    # An unknown osKey (e.g. running on an OS the M65 chain doesn't
    # know about) — defensive fallback to the path adapter.
    result = @[cakPath]

# ---------------------------------------------------------------------------
# M1 (Realize-Layer-Plumbing-Closures) — chain-resolver test seam
# ---------------------------------------------------------------------------
#
# Production callers leave ``chainResolveOverride`` nil; the realize-side
# dispatcher then calls ``chainResolvePackage`` directly. Hermetic tests
# in ``t_realize_honors_adapter_preference.nim`` and
# ``t_realize_honors_requested_version.nim`` install a stub here to
# (a) observe the ``chain`` + ``version`` args the realize side passes
# through (so the M1 plumbing contract is testable without downloading
# bytes), and (b) substitute a synthetic ``CatalogResolution`` that
# points the dispatcher at a fixture path adapter — letting the realize
# side run end-to-end on hermetic inputs.

type
  ChainResolveCallback* = proc (cat: var ProductionCatalog;
                                packageId: string;
                                chain: seq[CatalogAdapterKind];
                                version: string;
                                hostCpu: PlatformCpu;
                                hostOs: PlatformOs): CatalogResolution
    {.closure.}

var chainResolveOverride*: ChainResolveCallback = nil
  ## M1 test seam. Set to a non-nil closure to intercept the realize-side
  ## ``chainResolvePackage`` call. NEVER set in production; the helpers
  ## in `tests/t_realize_honors_*` set + reset around their test bodies.

proc callChainResolve(cat: var ProductionCatalog;
                      packageId: string;
                      chain: seq[CatalogAdapterKind];
                      version: string): CatalogResolution =
  if chainResolveOverride != nil:
    return chainResolveOverride(cat, packageId, chain, version,
      detectHostCpu(), detectHostOs())
  return chainResolvePackage(cat, packageId, chain = chain, version = version)

# ---------------------------------------------------------------------------
# M72 production catalog dispatch
# ---------------------------------------------------------------------------

proc realizeViaProductionCatalog(store: var Store;
                                 cat: var ProductionCatalog;
                                 packageId: string;
                                 requestedVersion = "";
                                 chain: seq[CatalogAdapterKind] = @[]):
    RealizedRecord =
  ## M72+ production dispatch. Windows prefers Scoop; macOS/Linux can
  ## realize PATH-discovered tools through the universal path adapter.
  ##
  ## M69: when ``requestedVersion`` is non-empty OR the package is in
  ## the built-in catalog registry, the dispatcher MUST use
  ## ``chainResolvePackage`` so the version threads into
  ## ``resolveBuiltinPackage``. The catalog-lookup helper validates
  ## that the slice exists before the chain runs, so a miss surfaces
  ## as a structured ``EVersionNotInCatalog`` rather than a generic
  ## ``EAdapterChainExhausted``.
  let useChain = requestedVersion.len > 0 or isRegistered(packageId)
  if useChain:
    if isRegistered(packageId):
      try:
        # The lookup raises a structured error for a missing version
        # OR an unknown id — fail-closed per M69's contract.
        discard lookupCatalogSlice(packageId, requestedVersion)
      except EVersionNotInCatalog as err:
        raiseRealizeFailed(packageId, "builtin", err.msg)
      except EUnknownPackageId as err:
        raiseRealizeFailed(packageId, "builtin", err.msg)
    let resolutionChain =
      try:
        callChainResolve(cat, packageId, chain, requestedVersion)
      except EAdapterChainExhausted as err:
        raiseRealizeFailed(packageId, "<chain>", err.msg)
      except EUnknownPackage as err:
        raiseRealizeFailed(packageId, "<none>", err.msg)
    case resolutionChain.adapter
    of cakBuiltin:
      result = realizeBuiltinAdapter(store, resolutionChain)
    of cakPath:
      result = realizePathAdapter(store, packageId, resolutionChain.sourcePath)
    of cakScoop:
      when defined(windows):
        let spec = ScoopPackageSpec(
          bucket: resolutionChain.bucket,
          app: resolutionChain.app,
          version: resolutionChain.resolvedVersion,
          executableName: resolutionChain.executableName)
        result = realizeScoopAdapter(store, packageId, spec)
      else:
        raiseRealizeFailed(packageId, "scoop",
          "the scoop adapter is Windows-only; this build runs on a " &
          "non-Windows platform")
    of cakNix:
      raiseRealizeFailed(packageId, "nix",
        "cakNix realize branch is not yet wired into the production " &
        "dispatch (parallel work in libs/repro_home_*); chain returned " &
        "cakNix for package '" & packageId & "'")
    result.fromProductionCatalog = true
    if result.adapter != akBuiltin:
      result.cacheHit = resolutionChain.cacheHit
      result.resolvedVersion = resolutionChain.resolvedVersion
    # M1 (Realize-Layer-Plumbing-Closures): expose the chain trace on the
    # realized record so the realize-side symmetry gate can assert which
    # adapter resolved each package. Empty for non-chain branches; one
    # entry per adapter consulted on the chain branch.
    result.chainTrace = resolutionChain.chainTrace
    return

  let resolution =
    try:
      resolvePackage(cat, packageId)
    except EUnknownPackage as err:
      raiseRealizeFailed(packageId, "<none>", err.msg)
  case resolution.adapter
  of cakPath:
    result = realizePathAdapter(store, packageId, resolution.sourcePath)
  of cakScoop:
    when defined(windows):
      let spec = ScoopPackageSpec(
        bucket: resolution.bucket,
        app: resolution.app,
        version: resolution.resolvedVersion,
        executableName: resolution.executableName)
      result = realizeScoopAdapter(store, packageId, spec)
    else:
      raiseRealizeFailed(packageId, "scoop",
        "the scoop adapter is Windows-only; this build runs on a " &
        "non-Windows platform")
  of cakBuiltin:
    # M64 dispatch — the production catalog produced a cakBuiltin
    # resolution. M65 wires this branch into the apply pipeline via
    # `chainResolvePackage` (downstream M69 home.nim integration);
    # the legacy `resolvePackage` path continues to return cakPath /
    # cakScoop only.
    result = realizeBuiltinAdapter(store, resolution)
  of cakNix:
    # M65 placeholder: the M21 realize-side Nix branch lands in a
    # parallel libs/repro_home_* branch. The legacy `resolvePackage`
    # never returns cakNix today (only the M65 `chainResolvePackage`
    # accepts cakNix in the preference list, and its tryResolveNix
    # branch skips cleanly with `csoAdapterUnavailable`). Until the
    # parallel work lands, dispatch fails closed with a structured
    # diagnostic so a future caller routing a cakNix resolution
    # through here gets a clear "not yet implemented" message rather
    # than a silent miss.
    raiseRealizeFailed(packageId, "nix",
      "cakNix realize branch is not yet wired into the production " &
      "dispatch (parallel work in libs/repro_home_*); this code path " &
      "is reachable only via the M65 chain when a future caller " &
      "passes a cakNix resolution downstream")
  result.fromProductionCatalog = true
  if result.adapter != akBuiltin:
    # The builtin adapter computes its own cache-hit verdict from the
    # store lookup; preserve it. For the other adapters the
    # CatalogResolution carries the verdict already.
    result.cacheHit = resolution.cacheHit
    result.resolvedVersion = resolution.resolvedVersion

# ---------------------------------------------------------------------------
# M72 Deliverable 2: read-only package preview for `--plan`
# ---------------------------------------------------------------------------

type
  PackagePreviewKind* = enum
    ppkRealize = "realize"            ## genuine fresh realization
    ppkCacheHit = "cache-hit"         ## already installed & satisfying
    ppkMissing = "missing"            ## unknown to all catalogs

  PackagePreview* = object
    ## Read-only verdict for one `PlannedPackage` — what a real apply
    ## WOULD do, computed without realizing anything.
    packageId*: string
    kind*: PackagePreviewKind
    detail*: string
    adapter*: CatalogAdapterKind
      ## M0: the adapter that resolved the package via M65's
      ## ``chainResolvePackage`` (cakBuiltin / cakScoop / cakPath / cakNix).
      ## Defaulted; only populated for chain-routed previews. Test-seam
      ## bindings + the legacy fallback leave this at its zero value
      ## (``cakBuiltin``) and rely on ``detail`` for adapter identification.
    chainTrace*: seq[ChainStep]
      ## M0: the per-adapter trace M65's chain populated for this
      ## resolution. Empty for test-seam bindings + the legacy fallback;
      ## non-empty for every chain-routed preview (one entry per adapter
      ## consulted, in order). Surface for the deferred ``repro home
      ## why-adapter`` debug subcommand.
    resolvedVersion*: string
      ## M0: the version the catalog picked. For cakBuiltin this is
      ## ``builtinVersion``; for cakScoop ``resolvedVersion``. Empty for
      ## cakPath / cakNix.

proc previewPackageResolutions*(packages: seq[PlannedPackage];
    chain: seq[CatalogAdapterKind] = @[];
    hostCpu = detectHostCpu();
    hostOs = detectHostOs()):
    seq[PackagePreview] =
  ## M72 Deliverable 2 + M0 planner-path correctness fix: classify each
  ## planned package WITHOUT realizing it. The production catalog query
  ## (`scoop list`, bucket manifests, built-in catalog registry) is a
  ## READ; no `scoop install` runs. Resolution precedence matches
  ## `realizePlannedPackages` — test seams first, then the production
  ## catalog.
  ##
  ## M0 (Realize-Closure-And-Catalog-Expansion): for a package that has
  ## no test-seam binding, this proc now mirrors
  ## ``realizeViaProductionCatalog``'s dispatch — it routes through M65's
  ## ``chainResolvePackage`` (default platform chain: Windows builtin/
  ## scoop/path; Linux nix/builtin/path; macOS nix/path) whenever the
  ## package id is in the M65 catalog registry OR carries a pinned
  ## ``requestedVersion``. Pre-validation via ``lookupCatalogSlice``
  ## fails closed with a structured ``EUnknownPackageId`` /
  ## ``EVersionNotInCatalog`` message instead of misclassifying as
  ## "missing". Unregistered packages with no pin keep the pre-M65
  ## ``resolvePackage`` fallback so the legacy non-catalog flows (e.g.
  ## pure-Scoop-only references) still preview cleanly.
  ##
  ## M2.5 (Realize-Closure-And-Catalog-Expansion): the `chain` parameter
  ## carries the per-host `adapterPreference:` override (resolved
  ## upstream from `ApplyPlan.adapterPreference` via
  ## `resolveAdapterChainFor`). An empty `chain` falls back to the M65
  ## platform default. Both this proc and `realizeViaProductionCatalog`
  ## thread the same chain so PLAN-mode preview and the actual realize
  ## report the same adapter verdict per package.
  let pathCatalog = parsePathCatalog()
  let scoopCatalog = parseScoopCatalog()
  var prodCatalog = openProductionCatalog()
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
      # M0: same gate as `realizeViaProductionCatalog` — a registered
      # built-in catalog id OR a pinned version forces the M65 chain.
      let useChain = p.requestedVersion.len > 0 or isRegistered(p.packageId)
      if useChain:
        # Pre-validate the catalog slice so unknown ids / missing versions
        # surface as structured errors rather than a silent "missing" row.
        # The realize-side path raises `EApplyRealizeFailed`; the planner
        # is non-mutating so we surface the diagnostic as a `ppkMissing`
        # row carrying the structured message in `detail` — the CLI
        # already increments `driftCount` on a missing row, so PLAN mode
        # fails closed unless `--allow-drift` was passed.
        if isRegistered(p.packageId):
          try:
            discard lookupCatalogSlice(p.packageId, p.requestedVersion)
          except EVersionNotInCatalog as err:
            preview.kind = ppkMissing
            preview.detail = "version-not-in-catalog: " & err.msg
            result.add(preview)
            continue
          except EUnknownPackageId as err:
            preview.kind = ppkMissing
            preview.detail = "unknown-package-id: " & err.msg
            result.add(preview)
            continue
        var resolution: CatalogResolution
        var chainOk = true
        try:
          resolution = chainResolvePackage(prodCatalog, p.packageId,
            chain = chain, version = p.requestedVersion,
            binaries = p.binaries,
            hostCpu = hostCpu, hostOs = hostOs)
        except EAdapterChainExhausted as err:
          preview.kind = ppkMissing
          preview.detail = "adapter-chain-exhausted: " & err.msg
          chainOk = false
        except EUnknownPackage as err:
          preview.kind = ppkMissing
          preview.detail = "unknown package; searched catalogs: " &
            err.searchedCatalogs.join(", ")
          chainOk = false
        if not chainOk:
          result.add(preview)
          continue
        preview.adapter = resolution.adapter
        preview.chainTrace = resolution.chainTrace
        preview.resolvedVersion =
          if resolution.builtinVersion.len > 0: resolution.builtinVersion
          else: resolution.resolvedVersion
        case resolution.adapter
        of cakBuiltin:
          # Honest reporting: the M65 chain resolved the package via the
          # built-in catalog. The realize half will fetch the slice URL
          # and materialize it into the M56 store; report the URL +
          # digest algorithm so the operator can audit the source.
          preview.kind = ppkRealize
          preview.detail = "builtin " & resolution.urlUsed &
            (if resolution.builtinVersion.len > 0:
               " @" & resolution.builtinVersion else: "") &
            " (" & resolution.digestAlgorithm & ")"
        of cakPath:
          preview.kind = ppkCacheHit
          preview.detail = "path " & resolution.sourcePath &
            " already available"
        of cakScoop:
          if resolution.cacheHit:
            preview.kind = ppkCacheHit
            preview.detail = "scoop " & resolution.bucket & "/" &
              resolution.app & "@" & resolution.resolvedVersion &
              " already installed (no reinstall)"
          else:
            preview.kind = ppkRealize
            preview.detail = "scoop " & resolution.bucket & "/" &
              resolution.app &
              (if resolution.resolvedVersion.len > 0:
                 "@" & resolution.resolvedVersion else: "") &
              " would be installed"
        of cakNix:
          # M65: the cakNix branch is a placeholder until the parallel
          # realize-side Nix wiring lands. The chain itself skips
          # cleanly, but if a chain ever DOES return cakNix (a future
          # configuration), surface it honestly.
          preview.kind = ppkRealize
          preview.detail = "nix " & resolution.packageId &
            " (realize-side wiring pending)"
      else:
        # Pre-M65 legacy path for unregistered packages with no pin —
        # preserves back-compat for pure-Scoop / pure-PATH references
        # that have no built-in catalog entry.
        when defined(windows):
          try:
            let resolution = resolvePackage(prodCatalog, p.packageId,
              binaries = p.binaries)
            if resolution.adapter == cakPath:
              preview.kind = ppkCacheHit
              preview.detail = "path " & resolution.sourcePath &
                " already available"
            elif resolution.cacheHit:
              preview.kind = ppkCacheHit
              preview.detail = "scoop " & resolution.bucket & "/" &
                resolution.app & "@" & resolution.resolvedVersion &
                " already installed (no reinstall)"
            else:
              preview.kind = ppkRealize
              preview.detail = "scoop " & resolution.bucket & "/" &
                resolution.app &
                (if resolution.resolvedVersion.len > 0:
                   "@" & resolution.resolvedVersion else: "") &
                " would be installed"
          except EUnknownPackage as err:
            preview.kind = ppkMissing
            preview.detail = "unknown package; searched catalogs: " &
              err.searchedCatalogs.join(", ")
        else:
          try:
            let resolution = resolvePackage(prodCatalog, p.packageId,
              binaries = p.binaries)
            if resolution.adapter == cakPath:
              preview.kind = ppkCacheHit
              preview.detail = "path " & resolution.sourcePath &
                " already available"
            else:
              preview.kind = ppkRealize
              preview.detail = $resolution.adapter
          except EUnknownPackage as err:
            preview.kind = ppkMissing
            preview.detail = "unknown package; searched catalogs: " &
              err.searchedCatalogs.join(", ")
    result.add(preview)

# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------

proc realizePlannedPackages*(store: var Store;
                             packages: seq[PlannedPackage];
                             chain: seq[CatalogAdapterKind] = @[]):
    seq[RealizedRecord] =
  ## Realize every planned package through its declared adapter.
  ##
  ## Resolution precedence (M72): the `REPRO_TEST_PACKAGE_*` seams are
  ## TEST-ONLY overrides and win over the production catalog. A package
  ## with no seam binding falls through to the production catalog
  ## (`package_catalog.resolvePackage`) — the M72 production path.
  ##
  ## M2.5: the optional `chain` carries the per-host
  ## `adapterPreference:` override (resolved upstream from
  ## `ApplyPlan.adapterPreference` via `resolveAdapterChainFor`). An
  ## empty `chain` falls back to the M65 platform default. The chain is
  ## passed into `realizeViaProductionCatalog` so the chain-routed
  ## branch honours it.
  let pathCatalog = parsePathCatalog()
  let scoopCatalog = parseScoopCatalog()
  var prodCatalog = openProductionCatalog()
  for p in packages:
    if p.packageId in pathCatalog:
      result.add(realizePathAdapter(store, p.packageId,
        pathCatalog[p.packageId].sourcePath))
    elif p.packageId in scoopCatalog:
      when defined(windows):
        result.add(realizeScoopAdapter(store, p.packageId,
          scoopCatalog[p.packageId]))
      else:
        raiseRealizeFailed(p.packageId, "scoop",
          "the scoop adapter is Windows-only; this build runs on a " &
          "non-Windows platform")
    else:
      # M72: no test-seam binding — resolve through the production
      # adapter catalog of the real host environment.
      #
      # M1 (Realize-Layer-Plumbing-Closures): thread BOTH the per-host
      # `chain` (M2.5) AND `p.requestedVersion` (M69) into
      # `realizeViaProductionCatalog`. The chain reaches
      # `chainResolvePackage` so the operator-specified `adapterPreference:`
      # override is honored at realize time as well as preview time; the
      # version pin reaches `chainResolvePackage`'s `version` parameter so
      # `package(jdk, "21.0.5")` resolves the pinned slice rather than the
      # catalog HEAD. Both fixes were latent pre-M1 — preview honored
      # both, realize honored neither.
      result.add(realizeViaProductionCatalog(store, prodCatalog, p.packageId,
        requestedVersion = p.requestedVersion,
        chain = chain))
