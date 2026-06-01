## M72 Deliverable 1: production package catalog.
##
## `repro home apply` must realize packages WITHOUT the
## `REPRO_TEST_PACKAGE_*` seams set. This module resolves a
## `PlannedPackage` reference against the REAL adapter catalog of the
## host environment.
##
## On Windows the preferred production adapter is Scoop: a package is a
## Scoop package if it is installed (`scoop list`) OR available in a
## configured Scoop bucket (the bucket directory holds an `<app>.json`
## manifest). The M55 Scoop adapter
## (`repro_tool_profiles.resolveScoopTool`) performs the actual
## realization; this module only decides the binding and computes the
## cache-hit determination.
##
## On macOS/Linux the first production adapter is PATH: a package whose
## executable name is already discoverable on PATH is recorded through
## the universal path adapter. This prepares the non-Windows home apply
## path without pretending to have a full package-manager catalog yet.
##
## Cache-hit rule (per the M72 deliverable text): an app already
## installed at a version satisfying the profile is a cache-hit — it is
## recorded as realized, NOT reinstalled. The M55 adapter already reuses
## an existing `apps/<app>/<version>/` directory without re-running
## `scoop install`; this module classifies the outcome BEFORE dispatch
## by probing the Scoop install tree, so the apply pipeline can report
## `cache-hit` vs `realize` and the gate can assert no `scoop install`
## ran for an already-installed app.
##
## Resolution precedence (M72): an explicit `REPRO_TEST_PACKAGE_*`
## override is a TEST-ONLY seam and wins over this production catalog.
## The dispatcher in `realize.nim` consults the env seams first; this
## module is the fallback path for packages with no seam binding.
##
## Efficiency: `scoop list` is queried ONCE per apply (the installed-app
## table is built lazily and memoized inside `ProductionCatalog`), not
## once per package.

import std/[json, options, os, osproc, sets, strutils, tables]
from repro_core/paths import extendedPath

# M64: the cakBuiltin adapter resolves against the M63 VersionedProvisioning
# catalog. We import the schema (cross-platform; no Windows-only deps).
import repro_dsl_stdlib/packages_schema
# M65: the adapter chain consults the built-in catalog registry to
# look up `<tool>Catalog` literals for a given tool name. The registry
# is the single point of truth for "which tools have a built-in catalog
# entry"; the chain walks it via `getCatalog(toolName)`.
import repro_dsl_stdlib/catalog_registry

# M80: the plan classifier and the apply-time Scoop adapter
# (`repro_tool_profiles.resolveScoopTool`) share ONE installed-version
# cache-hit predicate — `installedVersionSatisfies` — so a
# `repro home apply --plan` dry run and the real `repro home apply`
# can never disagree on whether an installed-but-bucket-drifted package
# is a cache-hit.
when defined(windows):
  import repro_tool_profiles

const
  ScoopRootEnvVar = "SCOOP"
  ScoopOverrideEnvVar = "REPRO_TEST_SCOOP_OVERRIDE"
    ## Same test seam the M55 adapter / `realize.nim` honor: point at a
    ## sandboxed `scoop` executable. Non-exported here so it does not
    ## collide with `realize.nim`'s own `ScoopOverrideEnvVar*`.

type
  CatalogAdapterKind* = enum
    cakPath = "path"
    cakScoop = "scoop"
    cakBuiltin = "builtin"
      ## M64: a tool resolved against a checked-in
      ## ``<tool>Catalog: seq[VersionedProvisioning]`` literal under
      ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/``.  The
      ## adapter downloads the slice URL, verifies the SHA, extracts
      ## per ``archive_format``, and materializes the bytes directly
      ## into a content-addressed prefix.  See M63's
      ## ``packages_schema.nim`` and the M64 ``builtin_adapter`` module
      ## for the realization flow.
    cakNix = "nix"
      ## M65: placeholder for the M21 Nix profile adapter. The M65
      ## adapter chain accepts ``cakNix`` in the preference list and
      ## skips it cleanly when the realize-side Nix adapter is not
      ## present (the parallel work in ``libs/repro_home_*`` will land
      ## the production Nix branch). Listing ``cakNix`` here keeps the
      ## chain configuration future-proof so a host can declare
      ## ``adapter_preference: [nix, builtin, path]`` today without a
      ## schema migration when the Nix branch lands.

  ChainStepOutcome* = enum
    ## M65: the per-step verdict the selection chain records in its
    ## trace. ``csoResolved`` is the terminating outcome; the other
    ## variants are skip reasons that drive the structured
    ## diagnostic when the entire chain is exhausted.
    csoResolved = "resolved"
    csoAdapterUnavailable = "adapter-unavailable"
      ## The adapter is platform-incompatible (cakScoop on Linux),
      ## missing a host binary (cakScoop without ``scoop`` on PATH), or
      ## not yet implemented (cakNix today). The chain moves on.
    csoCatalogMiss = "catalog-miss"
      ## cakBuiltin specific: the tool has no entry in the M65 catalog
      ## registry, or the registered catalog is empty.
    csoToolNotFound = "tool-not-found"
      ## cakPath / cakScoop specific: the executable is not discoverable
      ## on PATH and no bucket manifest carries it.
    csoSchemaError = "schema-error"
      ## cakBuiltin specific: ``resolveBuiltinPackage`` returned a
      ## structured error (platform-not-supported, schema-invalid,
      ## version-not-in-catalog). The chain moves on with the detail
      ## captured in the trace.

  ChainStep* = object
    ## M65: one step of the adapter selection chain. The full
    ## ``chainTrace`` is attached to ``CatalogResolution.chainTrace``
    ## (on a hit, the trace ends at the resolving step; on miss the
    ## chain reports ``EAdapterChainExhausted`` carrying every step).
    adapter*: CatalogAdapterKind
    outcome*: ChainStepOutcome
    reason*: string

  CatalogResolution* = object
    ## The production catalog's verdict for one package reference.
    packageId*: string
    adapter*: CatalogAdapterKind
    bucket*: string
    app*: string
    resolvedVersion*: string         ## the version the catalog resolved
    executableName*: string
    sourcePath*: string              ## path-adapter executable source
    installed*: bool                 ## already present in the Scoop tree
    cacheHit*: bool                  ## installed AND version-satisfying
    searchedCatalogs*: seq[string]   ## buckets / sources searched
    # M64 cakBuiltin fields — populated by `resolveBuiltinPackage`. They
    # carry the realization inputs forward so `realizeBuiltinPackage`
    # does not need to re-resolve the slice.
    builtinVersion*: string          ## VersionedProvisioning.version
    urlUsed*: string                 ## PlatformBinary.url chosen for host
    digestAlgorithm*: string         ## "sha256" | "sha512"
    digestValue*: string             ## hex digest (lowercase)
    archiveFormat*: ArchiveFormat
    installMethod*: InstallMethod
    binRelpath*: seq[string]
    extractPath*: string             ## inner-dir flatten
    installerArgs*: seq[string]
    pacmanPackages*: seq[string]
    bootstrapArgv*: seq[string]
    envSubstitutions*: seq[tuple[name, value: string]]
    # M3 (Realize-Closure-And-Catalog-Expansion) — residual 7z family
    # metadata. ``nested7z`` is per-platform (carried out of the
    # selected ``PlatformBinary``); ``preInstallActions`` and
    # ``preInstallUnrecognized`` are per-version (cross-platform).
    nested7z*: bool
    preInstallActions*: seq[PreInstallAction]
    preInstallUnrecognized*: seq[string]
    # M4 (Realize-Closure-And-Catalog-Expansion) — per-platform MSI
    # admin-install override. When true, the realize loop uses
    # ``msiexec /a`` instead of ``dark.exe`` for MSI extraction. The
    # global ``CAKBUILTIN_PREFER_MSIEXEC=1`` env var has the same
    # effect; this flag is the per-(cpu, os) override.
    msiAdminInstall*: bool
    # M5 (Realize-Closure-And-Catalog-Expansion) — Scoop-style launcher
    # emit. After extract / install_method dispatch, the realize loop
    # walks this sequence and synthesizes one .ps1 + one .cmd launcher
    # per spec at ``<prefix>/bin/<launcher_name>.{ps1,cmd}`` invoking
    # the discovered interpreter against the spec's prefix-relative
    # ``target``. Composer's .phar wrap is the M5 anchor case.
    launcherEmit*: seq[LauncherEmitSpec]
    # M65: per-resolution chain trace. Populated by `chainResolvePackage`
    # to record every adapter consulted, in order, with each adapter's
    # outcome + skip reason. On a successful resolution the trace ends
    # at the resolving step (the final entry has
    # `outcome == csoResolved`); on an exhaustion the trace carries
    # every step the chain walked before raising. Empty for the legacy
    # `resolvePackage(cat, packageId)` signature (which does not run
    # the chain — it preserves the pre-M65 single-adapter behaviour
    # for callers that have not yet been migrated).
    chainTrace*: seq[ChainStep]

  EUnknownPackage* = object of CatchableError
    ## Raised when a package reference resolves to no production
    ## adapter catalog. Carries the package name and the list of
    ## catalogs searched so the apply pipeline can surface a
    ## structured diagnostic.
    packageId*: string
    searchedCatalogs*: seq[string]

  EAdapterChainExhausted* = object of CatchableError
    ## M65: every adapter in the configured chain was tried and none
    ## resolved the package. The exception carries the package id, the
    ## chain that was walked, and the full chain trace (one
    ## ``ChainStep`` per adapter consulted) so the CLI layer can render
    ## a per-adapter skip-reason diagnostic. The ``--plan`` extension
    ## reads ``chainTrace`` directly to render its plan classifier.
    packageId*: string
    chain*: seq[CatalogAdapterKind]
    chainTrace*: seq[ChainStep]

  ProductionCatalog* = object
    ## Per-apply catalog handle. Built once; the installed-app table
    ## and the bucket inventory are memoized so a multi-package apply
    ## shells out to `scoop` at most once.
    scoopRoot: string
    scoopExe: string
    installedQueried: bool
    installedApps: Table[string, string]   ## app -> installed version
    buckets: seq[string]                   ## configured bucket names

proc raiseUnknownPackage*(packageId: string;
                          searched: seq[string]) {.noreturn.} =
  var e = newException(EUnknownPackage,
    "no production adapter catalog knows package '" & packageId &
    "'. Searched: " &
    (if searched.len > 0: searched.join(", ") else: "<no catalogs configured>") &
    ". Make the executable available on PATH, declare the package in a " &
    "configured platform catalog (Scoop on Windows), or set " &
    "REPRO_TEST_PACKAGE_SOURCE / REPRO_TEST_PACKAGE_SCOOP for a test-only " &
    "adapter binding.")
  e.packageId = packageId
  e.searchedCatalogs = searched
  raise e

# ---------------------------------------------------------------------------
# M0 (Realize-Layer-Plumbing-Closures spec) — extractor-discovery edges
# ---------------------------------------------------------------------------
#
# The realize loop's cakBuiltin adapter needs a small set of helper
# executables (``7z.exe``, ``lessmsi.exe``, ``dark.exe``, ``innounp.exe``)
# depending on the package's ``archive_format`` + ``install_method``.
# When the operator bundles those extractors as catalog packages in the
# SAME ``home.nim`` (the M3 bundling-posture decision from the
# Realize-Closure-And-Catalog-Expansion predecessor campaign), the
# realize-op order MUST honour these discovery edges — the consumer
# cannot realize until its extractor's prefix exists.
#
# The mapping below is the M0 hard-coded form. A future milestone could
# lift it to schema-driven catalog metadata (a ``requires_for_realize:``
# field on ``VersionedProvisioning``); for M0 the small constant table is
# the right tradeoff.
#
# Extractor-provider map (M0):
#
#   7z.exe       ← 7zip       (consumed by afSevenZip / afSevenZipSfx
#                              archive formats and the imInstallerNsis
#                              install method)
#   lessmsi.exe  ← lessmsi    (consumed by imInstallerMsi)
#   dark.exe     ← wix3       (consumed by imInstallerNsisBundle;
#                              dark unwraps the Burn outer)
#   lessmsi.exe  ← lessmsi    (also consumed by imInstallerNsisBundle;
#                              extracts the inner MSIs after dark)
#   innounp.exe  ← innounp    (consumed by imInstallerInnoSetup)

const
  ExtractorProvider7zip*    = "7zip"
  ExtractorProviderLessmsi* = "lessmsi"
  ExtractorProviderWix3*    = "wix3"
  ExtractorProviderInnounp* = "innounp"

proc extractorDependencies*(packageId: string;
                            resolution: CatalogResolution): seq[string] =
  ## Return the set of catalog-package names that must be realized BEFORE
  ## ``packageId`` can be realized, derived from the resolution's
  ## ``archive_format`` + ``install_method`` requirements.
  ##
  ## Hard-coded extractor-provider map (M0). Future enhancement:
  ## schema-driven ``requires_for_realize:`` field in
  ## ``VersionedProvisioning``.
  ##
  ## Returns an EMPTY seq when ``resolution.adapter`` is NOT ``cakBuiltin``
  ## (Scoop / PATH / Nix adapters handle their own extraction — the
  ## discovery edge does not apply). This matches the M0 spec's
  ## Outstanding Task note: "topo edges that originate from a
  ## cakScoop-resolved consumer are silently dropped".
  ##
  ## The returned seq never contains ``packageId`` itself (self-edges are
  ## skipped) — even though e.g. ``sevenzip.nim`` itself uses
  ## ``imInstallerMsi`` which needs ``lessmsi``, that's a real edge
  ## (sevenzip → lessmsi); the self-edge filter is for the degenerate
  ## case where the mapping ever points a package at itself.
  if resolution.adapter != cakBuiltin:
    return @[]
  var deps: seq[string] = @[]
  # archive_format-driven edges
  case resolution.archiveFormat
  of afSevenZip, afSevenZipSfx:
    deps.add(ExtractorProvider7zip)
  else:
    discard
  # install_method-driven edges (these override / extend the
  # archive_format edges for the installer families)
  case resolution.installMethod
  of imInstallerNsis:
    deps.add(ExtractorProvider7zip)
  of imInstallerMsi:
    deps.add(ExtractorProviderLessmsi)
  of imInstallerNsisBundle:
    # dark.exe to unwrap the Burn outer, lessmsi.exe to extract the
    # inner MSIs. Order in the seq is stable so a downstream consumer
    # that uses the order for tie-breaking gets a deterministic result.
    deps.add(ExtractorProviderWix3)
    deps.add(ExtractorProviderLessmsi)
  of imInstallerInnoSetup:
    deps.add(ExtractorProviderInnounp)
  else:
    discard
  # Deduplicate while preserving first-seen order, and drop any
  # self-edge (a package never depends on itself).
  var seen = initHashSet[string]()
  for d in deps:
    if d == packageId: continue
    if d in seen: continue
    seen.incl d
    result.add d

# ---------------------------------------------------------------------------
# Scoop environment discovery
# ---------------------------------------------------------------------------

proc resolveScoopExecutable(): string =
  let override = getEnv(ScoopOverrideEnvVar)
  if override.len > 0 and fileExists(extendedPath(override)):
    return override
  let envBinary = getEnv("REPROBUILD_SCOOP_BINARY")
  if envBinary.len > 0 and fileExists(extendedPath(envBinary)):
    return envBinary
  for candidate in ["scoop.cmd", "scoop.exe", "scoop.ps1", "scoop"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved
  ""

proc resolveScoopRoot(): string =
  let explicit = getEnv(ScoopRootEnvVar)
  if explicit.len > 0:
    return explicit
  let home = getEnv("USERPROFILE", getEnv("HOME"))
  if home.len > 0:
    return home / "scoop"
  ""

proc openProductionCatalog*(): ProductionCatalog =
  ## Build a fresh per-apply catalog handle. Cheap: it only records the
  ## Scoop root + executable paths; the installed-app table and bucket
  ## inventory are filled lazily on first query.
  result.scoopRoot = resolveScoopRoot()
  result.scoopExe = resolveScoopExecutable()
  result.installedQueried = false
  result.installedApps = initTable[string, string]()

# ---------------------------------------------------------------------------
# `scoop list` — installed-app inventory
# ---------------------------------------------------------------------------

proc parseScoopListJson(raw: string; outTable: var Table[string, string]):
    bool =
  ## `scoop list` on a modern Scoop emits a JSON array of objects with
  ## `Name` + `Version` (and `Source`) keys when stdout is not a TTY.
  ## Returns true if the JSON shape was recognized.
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError:
    return false
  if node.kind != JArray:
    return false
  for item in node:
    if item.kind != JObject:
      continue
    let name = item{"Name"}.getStr("")
    let version = item{"Version"}.getStr("")
    if name.len > 0:
      outTable[name.toLowerAscii()] = version
  true

proc readInstalledFromTree(scoopRoot: string;
                           outTable: var Table[string, string]) =
  ## Fallback inventory: walk `<scoop-root>/apps/<app>/<version>/` —
  ## the same on-disk shape `scoop install` produces. The `current`
  ## junction is skipped; the exact-version directory is the install
  ## marker. This is the robust path the M55 sandbox fixtures rely on
  ## (`populateScoopApp` lays down `apps/<app>/<version>` directly).
  let appsDir = scoopRoot / "apps"
  if not dirExists(extendedPath(appsDir)):
    return
  for kind, appPath in walkDir(extendedPath(appsDir)):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let app = extractFilename(appPath)
    for vk, vPath in walkDir(extendedPath(appPath)):
      if vk notin {pcDir, pcLinkToDir}:
        continue
      let ver = extractFilename(vPath)
      if ver != "current":
        outTable[app.toLowerAscii()] = ver

proc ensureInstalledQueried(cat: var ProductionCatalog) =
  ## Populate `installedApps` exactly once per apply. Prefers
  ## `scoop list` (the spec-named query) and falls back to walking the
  ## install tree when `scoop list` is unavailable or its output cannot
  ## be parsed. Either way the shell-out happens at most once.
  if cat.installedQueried:
    return
  cat.installedQueried = true
  var parsed = false
  if cat.scoopExe.len > 0:
    var command =
      if cat.scoopExe.endsWith(".ps1"):
        "powershell -NoProfile -ExecutionPolicy Bypass -File " &
          quoteShell(cat.scoopExe) & " list"
      else:
        quoteShell(cat.scoopExe) & " list"
    if cat.scoopRoot.len > 0:
      putEnv(ScoopRootEnvVar, cat.scoopRoot)
    try:
      let res = execCmdEx(command)
      if res.exitCode == 0:
        parsed = parseScoopListJson(res.output, cat.installedApps)
    except CatchableError:
      parsed = false
  # Always reconcile against the on-disk tree: `scoop list` JSON output
  # is version-dependent, and the M55 sandbox fixtures populate the
  # tree directly without a `scoop` metadata write. The tree walk is a
  # single directory enumeration — still O(1) shell-outs per apply.
  readInstalledFromTree(cat.scoopRoot, cat.installedApps)
  discard parsed

proc installedVersion*(cat: var ProductionCatalog; app: string):
    tuple[installed: bool; version: string] =
  ## Return whether `app` is installed and at which version. Triggers
  ## the one-time `scoop list` query on first call.
  ensureInstalledQueried(cat)
  let key = app.toLowerAscii()
  if key in cat.installedApps:
    (true, cat.installedApps[key])
  else:
    (false, "")

# ---------------------------------------------------------------------------
# Bucket inventory — "available in a configured bucket"
# ---------------------------------------------------------------------------

proc ensureBucketsQueried(cat: var ProductionCatalog) =
  if cat.buckets.len > 0:
    return
  let bucketsDir = cat.scoopRoot / "buckets"
  if not dirExists(extendedPath(bucketsDir)):
    return
  for kind, path in walkDir(extendedPath(bucketsDir)):
    if kind in {pcDir, pcLinkToDir}:
      cat.buckets.add(extractFilename(path))

proc bucketManifestPath(scoopRoot, bucket, app: string): string =
  scoopRoot / "buckets" / bucket / "bucket" / (app & ".json")

proc manifestBinName(node: JsonNode): string =
  ## Extract the executable leaf name from a Scoop manifest's `bin`
  ## field. `bin` may be a string, an array, or an array of pairs;
  ## the M55 adapter resolves the executable by its declared path, so
  ## the catalog reports the FIRST entry's leaf name.
  if node.isNil:
    return ""
  let binNode = node{"bin"}
  if binNode.isNil:
    return ""
  case binNode.kind
  of JString:
    extractFilename(binNode.getStr(""))
  of JArray:
    if binNode.len == 0:
      ""
    elif binNode[0].kind == JString:
      extractFilename(binNode[0].getStr(""))
    elif binNode[0].kind == JArray and binNode[0].len > 0 and
         binNode[0][0].kind == JString:
      extractFilename(binNode[0][0].getStr(""))
    else:
      ""
  else:
    ""

proc findBucketManifest*(cat: var ProductionCatalog; app: string):
    tuple[found: bool; bucket, version, binName: string] =
  ## Search every configured Scoop bucket for an `<app>.json` manifest.
  ## Returns the first bucket that carries one plus the manifest's
  ## declared `version` and `bin` (executable leaf name). This is the
  ## "available in a configured bucket" branch of the M72 deliverable.
  ensureBucketsQueried(cat)
  for bucket in cat.buckets:
    let mp = bucketManifestPath(cat.scoopRoot, bucket, app)
    if fileExists(extendedPath(mp)):
      var version = ""
      var binName = ""
      try:
        let parsed = parseJson(readFile(extendedPath(mp)))
        if parsed.kind == JObject:
          version = parsed{"version"}.getStr("")
          binName = manifestBinName(parsed)
      except CatchableError:
        version = ""
      return (true, bucket, version, binName)
  (false, "", "", "")

proc installedExecutableName(scoopRoot, app, version: string): string =
  ## Read the executable leaf name an installed app declares. Scoop
  ## copies the bucket manifest into `apps/<app>/<version>/
  ## manifest.json`; the M55 sandbox fixture writes that too.
  let mp = scoopRoot / "apps" / app / version / "manifest.json"
  if not fileExists(extendedPath(mp)):
    return ""
  try:
    let parsed = parseJson(readFile(extendedPath(mp)))
    if parsed.kind == JObject:
      return manifestBinName(parsed)
  except CatchableError:
    discard
  ""

# ---------------------------------------------------------------------------
# Resolution entry point
# ---------------------------------------------------------------------------

proc satisfiesProfile(installedVersion, pinnedVersion,
                      preferredVersion: string): bool =
  ## M80: a cache-hit requires an already-installed version that
  ## satisfies the package's version reference — and the bucket head
  ## is NEVER consulted here. This delegates to the SAME
  ## `installedVersionSatisfies` predicate that M77's apply-time
  ## `resolveScoopTool` uses, so the `--plan` classifier and the real
  ## apply cannot diverge.
  ##
  ## A `home.nim` package reference is always a bare/unpinned reference
  ## (`PlannedPackage` carries only a `packageId`, no version), so
  ## `pinnedVersion` and `preferredVersion` are both empty here and ANY
  ## installed version satisfies it — exactly what `resolveScoopTool`
  ## does (it cache-hits the installed version and runs no
  ## `scoop install`, leaving the drifted bucket head irrelevant). The
  ## pinned / ranged parameters are threaded through so a future
  ## version-pinned package reference resolves identically on both
  ## paths.
  if installedVersion.len == 0:
    return false
  when defined(windows):
    installedVersionSatisfies([installedVersion], pinnedVersion,
      preferredVersion).satisfied
  else:
    # Non-Windows path adapter has no version reference; an installed
    # executable is a cache-hit.
    pinnedVersion.len == 0 and preferredVersion.len == 0

proc resolvePathPackage(packageId: string; searched: var seq[string]):
    tuple[found: bool; resolution: CatalogResolution] =
  searched.add("path:" & getEnv("PATH"))
  let exe = findExe(packageId)
  if exe.len == 0:
    return (false, CatalogResolution())
  var r = CatalogResolution(
    packageId: packageId,
    adapter: cakPath,
    app: packageId,
    executableName: extractFilename(exe),
    sourcePath: exe,
    installed: true,
    cacheHit: true,
    searchedCatalogs: searched)
  (true, r)

proc resolvePackage*(cat: var ProductionCatalog; packageId: string):
    CatalogResolution =
  ## Resolve one `PlannedPackage` reference against the production
  ## catalog. Raises `EUnknownPackage` (naming the package and the
  ## catalogs searched) when no adapter recognizes it.
  ##
  ## Resolution order on Windows:
  ##   1. installed Scoop app (`scoop list`) — cache-hit candidate.
  ##   2. available in a configured Scoop bucket — realize via Scoop.
  result.packageId = packageId
  result.adapter = cakPath
  result.app = packageId
  result.executableName = packageId
  var searched: seq[string]

  when defined(windows):
    searched.add("scoop:installed-apps")
    let inst = installedVersion(cat, packageId)
    # Find the bucket manifest too: it tells us the bucket name (the
    # M55 adapter needs `bucket/app`), the available version, and the
    # declared executable leaf name.
    let manifest = findBucketManifest(cat, packageId)
    if manifest.found:
      result.adapter = cakScoop
      searched.add("scoop:bucket:" & manifest.bucket)
      result.bucket = manifest.bucket
      if manifest.binName.len > 0:
        result.executableName = manifest.binName
    if inst.installed:
      result.adapter = cakScoop
      result.installed = true
      # M80: an already-installed package is a cache-hit independent of
      # whether the Scoop bucket head has drifted ahead of it. A
      # `home.nim` package reference is a bare/unpinned reference, so
      # ANY installed version satisfies it — and `satisfiesProfile`
      # delegates to the SAME `installedVersionSatisfies` predicate
      # that M77's apply-time `resolveScoopTool` consults. The previous
      # M72 code required the installed version to EQUAL the bucket
      # head (`manifest.version`); that made `--plan` report an
      # installed-but-bucket-drifted package as `realize` while the
      # actual apply correctly cache-hit it. The bucket head is NOT
      # consulted here — exactly as `resolveScoopTool` does not consult
      # it for an installed app.
      result.resolvedVersion = inst.version
      result.cacheHit = satisfiesProfile(inst.version,
        pinnedVersion = "", preferredVersion = "")
      # Prefer the executable name the installed app's own manifest
      # declares (Scoop copies the bucket manifest into the version
      # dir on install; the M55 sandbox fixture writes it too).
      let installedExe = installedExecutableName(cat.scoopRoot, packageId,
        inst.version)
      if installedExe.len > 0:
        result.executableName = installedExe
      if result.bucket.len == 0:
        # Installed but no bucket on disk — read the per-app
        # install.json to recover the originating bucket so the M55
        # adapter can still bind `bucket/app`.
        let installJson = cat.scoopRoot / "apps" / packageId / inst.version /
          "install.json"
        if fileExists(extendedPath(installJson)):
          try:
            let parsed = parseJson(readFile(extendedPath(installJson)))
            if parsed.kind == JObject:
              result.bucket = parsed{"bucket"}.getStr("")
          except CatchableError:
            discard
      if result.bucket.len == 0:
        result.bucket = "main"
      return result
    if manifest.found:
      # Available but not installed → a genuine realize (the M55
      # adapter will run `scoop install`).
      result.adapter = cakScoop
      result.installed = false
      result.cacheHit = false
      result.resolvedVersion = manifest.version
      return result
    let pathResolution = resolvePathPackage(packageId, searched)
    if pathResolution.found:
      return pathResolution.resolution
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)
  else:
    let pathResolution = resolvePathPackage(packageId, searched)
    if pathResolution.found:
      return pathResolution.resolution
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)

# ---------------------------------------------------------------------------
# M64 — cakBuiltin resolver (probe the M63 VersionedProvisioning catalog)
# ---------------------------------------------------------------------------
#
# `resolveBuiltinPackage` takes a packageId + an in-memory catalog
# (`seq[VersionedProvisioning]`, the shape `<tool>Catalog: seq[...]`
# literals export from `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/
# packages/<tool>.nim`) + an optional version constraint and returns a
# fully-populated `CatalogResolution` whose `adapter == cakBuiltin` and
# whose `urlUsed / digestAlgorithm / digestValue / archiveFormat /
# installMethod / binRelpath / extractPath / installerArgs /
# pacmanPackages / bootstrapArgv / envSubstitutions` carry the
# realization inputs the cakBuiltin realize loop consumes.
#
# Version resolution: an empty `version` selects the catalog default
# (last entry); a non-empty `version` is matched exactly against
# `vp.version`. Per-platform resolution uses
# `packages_schema.selectPlatformBinary` with the host's (cpu, os)
# tuple.
#
# Returns `(found = false, resolution = default)` on miss. Callers
# (M65's adapter chain) treat a miss as "this adapter cannot resolve
# the package; try the next adapter" rather than fail-closed.

type
  BuiltinResolveError* = enum
    breOk = "ok"
    breVersionNotInCatalog = "version-not-in-catalog"
      ## Requested `version` does not match any slice in the catalog.
    breEmptyCatalog = "empty-catalog"
      ## The catalog is empty — the packages/<tool>.nim is missing the
      ## `let <tool>Catalog* = @[...]` literal or shipped a stub.
    brePlatformNotSupported = "platform-not-supported"
      ## A matching version was found but it has no `PlatformBinary`
      ## entry for the current (cpu, os) tuple.
    breSchemaInvalid = "schema-invalid"
      ## The selected slice failed `validateVersionedProvisioning`.

  BuiltinResolveResult* = object
    found*: bool
    resolution*: CatalogResolution
    error*: BuiltinResolveError
    errorDetail*: string

proc detectHostCpu*(): PlatformCpu =
  ## Map the Nim `hostCPU` token to the schema's `PlatformCpu` enum.
  ## Unknown CPUs fall through to `pcAny` (the realize loop will then
  ## look for an arch-independent slice; if none exists,
  ## `selectPlatformBinary` reports `found=false`).
  when defined(amd64) or defined(x86_64):
    pcX86_64
  elif defined(arm64) or defined(aarch64):
    pcAArch64
  elif defined(i386) or defined(i686) or defined(x86):
    pcX86
  else:
    pcAny

proc detectHostOs*(): PlatformOs =
  when defined(windows):
    poWindows
  elif defined(linux):
    poLinux
  elif defined(macosx) or defined(osx):
    poMacos
  else:
    poAny

proc resolveBuiltinPackage*(packageId: string;
                            catalog: openArray[VersionedProvisioning];
                            version = "";
                            hostCpu = detectHostCpu();
                            hostOs = detectHostOs()):
    BuiltinResolveResult =
  ## Probe a checked-in VersionedProvisioning catalog for a satisfying
  ## (version, platform) tuple and produce a `CatalogResolution`
  ## carrying every input the M64 realize loop needs.
  result.found = false
  result.error = breOk
  result.resolution.packageId = packageId
  result.resolution.adapter = cakBuiltin
  result.resolution.app = packageId
  result.resolution.searchedCatalogs = @["builtin:" & packageId]
  if catalog.len == 0:
    result.error = breEmptyCatalog
    result.errorDetail = "builtin catalog for '" & packageId & "' is empty"
    return
  var picked: VersionedProvisioning
  if version.len == 0:
    let def = selectDefault(catalog)
    if not def.found:
      result.error = breEmptyCatalog
      result.errorDetail = "selectDefault returned no entry"
      return
    picked = def.entry
  else:
    let exact = selectVersion(catalog, version)
    if not exact.found:
      result.error = breVersionNotInCatalog
      result.errorDetail = "no slice with version '" & version &
        "' in builtin catalog for '" & packageId & "'"
      return
    picked = exact.entry
  let schemaErrors = validateVersionedProvisioning(picked)
  if schemaErrors.len > 0:
    result.error = breSchemaInvalid
    result.errorDetail = "selected slice failed validation: " &
      schemaErrors.join("; ")
    return
  let pb = selectPlatformBinary(picked, hostCpu, hostOs)
  if not pb.found:
    result.error = brePlatformNotSupported
    result.errorDetail = "no platform slice for cpu=" & $hostCpu &
      " os=" & $hostOs & " in builtin catalog for '" & packageId &
      "' version '" & picked.version & "'"
    return
  # Populate the resolution.
  result.found = true
  result.resolution.resolvedVersion = picked.version
  result.resolution.builtinVersion = picked.version
  result.resolution.urlUsed = pb.binary.url
  if pb.binary.sha256.len > 0:
    result.resolution.digestAlgorithm = "sha256"
    result.resolution.digestValue = pb.binary.sha256.toLowerAscii()
  elif pb.binary.sha512.len > 0:
    result.resolution.digestAlgorithm = "sha512"
    result.resolution.digestValue = pb.binary.sha512.toLowerAscii()
  else:
    # M1 (Realize-Closure spec): sha1 is the weak fallback; the realize
    # loop emits a ``WSha1HashAccepted`` warning when it runs. Slice
    # validation in ``validateVersionedProvisioning`` already enforced
    # that at least one of the three digests is populated, so reaching
    # this arm without sha1 set is a schema-validator bug, not a runtime
    # case.
    result.resolution.digestAlgorithm = "sha1"
    result.resolution.digestValue = pb.binary.sha1.toLowerAscii()
  # M9.5: per-platform overrides for archive_format + bin_relpath. The
  # cross-OS catalog harvester pass (M9.5) needs them because a single
  # tool's upstream ships different archive shapes per OS (e.g. gh ships
  # ``.zip`` on Windows + ``.tar.gz`` on Linux) and the realized binary
  # path differs by OS (``.exe`` suffix only on Windows). The default
  # PlatformBinary leaves both unset → fall back to the VersionedProvisioning
  # values.
  if pb.binary.has_archive_format_override:
    result.resolution.archiveFormat = pb.binary.archive_format_override
  else:
    result.resolution.archiveFormat = picked.archive_format
  result.resolution.installMethod = picked.install_method
  if pb.binary.bin_relpath_override.len > 0:
    result.resolution.binRelpath = pb.binary.bin_relpath_override
  else:
    result.resolution.binRelpath = picked.bin_relpath
  result.resolution.extractPath = pb.binary.extract_path
  result.resolution.installerArgs = picked.installer_args
  result.resolution.pacmanPackages = picked.pacman_packages
  result.resolution.bootstrapArgv = picked.bootstrap_argv
  # M3: thread the residual 7z-family metadata through.
  result.resolution.nested7z = pb.binary.nested_7z
  result.resolution.preInstallActions = picked.pre_install_actions
  result.resolution.preInstallUnrecognized = picked.pre_install_unrecognized
  # M4: thread the per-platform MSI admin-install override through.
  result.resolution.msiAdminInstall = pb.binary.msi_admin_install
  # M5: thread the launcher_emit spec list through.
  result.resolution.launcherEmit = picked.launcher_emit
  # Use the first bin_relpath as the executable name (leaf only). M9.5:
  # honor the per-platform bin_relpath_override when present (the Linux
  # binary is ``gh`` without the ``.exe`` suffix that the Windows slice
  # carries).
  let effectiveBinRelpath =
    if pb.binary.bin_relpath_override.len > 0:
      pb.binary.bin_relpath_override
    else:
      picked.bin_relpath
  if effectiveBinRelpath.len > 0:
    result.resolution.executableName = effectiveBinRelpath[0].extractFilename
  else:
    result.resolution.executableName = packageId
  # Stable env-substitution order — sort by key so the realize loop
  # produces deterministic output and `serializeAsCode` round-trips.
  var keys: seq[string] = @[]
  for k in picked.env.keys:
    keys.add(k)
  for i in 0 ..< keys.len:
    for j in i + 1 ..< keys.len:
      if keys[j] < keys[i]:
        let tmp = keys[i]
        keys[i] = keys[j]
        keys[j] = tmp
  for k in keys:
    result.resolution.envSubstitutions.add((name: k, value: picked.env[k]))
  result.resolution.installed = false
  result.resolution.cacheHit = false  # set true by `realizeBuiltinPackage`
                                      # when the CAS prefix exists

# ---------------------------------------------------------------------------
# M65 — adapter selection chain
# ---------------------------------------------------------------------------
#
# The chain accepts a per-host-configurable adapter preference list
# (default: platform-specific) and walks it in order, asking each
# adapter "can you resolve this package?" until one says yes. The trace
# of every step is attached to the resolution for ``--plan`` /
# ``repro show-conventions`` introspection; on exhaustion a structured
# ``EAdapterChainExhausted`` carrying the same trace is raised.
#
# The chain consults adapters in this conceptual order (cache-first is
# the implicit M56 store lookup that happens inside each adapter's
# realize loop, NOT a resolution-time concern — the resolver only
# decides WHICH adapter realizes; the realize loop's own
# `cacheHit` verdict is reported back through the M64 dispatcher):
#
#   1. cakBuiltin — `getCatalog(packageId)` against the M65 registry.
#                   A registered tool with a non-empty catalog that
#                   yields a `BuiltinResolveResult.found == true` is a
#                   chain hit.
#   2. cakNix     — placeholder. The M21 realize-side Nix adapter is
#                   landing in a parallel branch; until it is wired
#                   into the resolver, cakNix is skipped cleanly with
#                   `csoAdapterUnavailable`.
#   3. cakScoop   — Windows-only. Falls back to the existing
#                   `resolvePackage` logic for the Scoop branch.
#   4. cakPath    — the universal "executable already on PATH" adapter.
#                   Last-resort.
#
# The chain is greedy first-match. Adapters not listed in the
# preference are skipped silently (no trace entry). A preference of
# `[builtin, path]` will never consult cakScoop even on Windows.

const
  WindowsDefaultChain* = @[cakBuiltin, cakScoop, cakPath]
    ## M65: the default Windows adapter preference. cakBuiltin is the
    ## new primary; cakScoop is the user-facing interop branch for
    ## Scoop-native users; cakPath is the last-resort PATH fallback.

  LinuxDefaultChain* = @[cakNix, cakBuiltin, cakPath]
    ## M65: the default Linux adapter preference. cakNix is the
    ## existing M21 production path (skipped cleanly when the realize-
    ## side branch is not yet wired); cakBuiltin is the secondary; the
    ## PATH adapter remains the last-resort fallback.

  MacosDefaultChain* = @[cakNix, cakPath]
    ## M65: the default macOS adapter preference. cakBuiltin is not yet
    ## supported on macOS per the M64 outstanding-task list (slices
    ## ship Windows + Linux today; macOS slices land in a future
    ## campaign). Mac users continue using Nix; PATH is the fallback.

proc defaultAdapterChain*(): seq[CatalogAdapterKind] =
  ## Return the platform-default adapter preference chain. Callers
  ## that want to override the default pass an explicit ``chain`` to
  ## ``chainResolvePackage``; M69's ``adapter_preference:`` DSL hook
  ## reads the per-host preference out of ``home.nim`` and threads it
  ## through here.
  when defined(windows):
    WindowsDefaultChain
  elif defined(linux):
    LinuxDefaultChain
  elif defined(macosx) or defined(osx):
    MacosDefaultChain
  else:
    @[cakPath]

proc tryResolveBuiltin(packageId: string;
                       version: string;
                       hostCpu: PlatformCpu;
                       hostOs: PlatformOs;
                       step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakBuiltin branch of the chain. Looks the tool up in the
  ## M65 catalog registry; on a hit, runs
  ## ``resolveBuiltinPackage`` and reports the resolution. On a miss or
  ## a structured error the resolver fills ``step`` with the skip
  ## reason and returns ``(false, ...)`` so the chain moves on.
  step.adapter = cakBuiltin
  let catOpt = getCatalog(packageId)
  if catOpt.isNone:
    step.outcome = csoCatalogMiss
    step.reason = "no built-in catalog registered for '" & packageId &
      "' (M65 registry knows " &
      (if RegisteredTools.len > 0:
         "@[\"" & RegisteredTools.join("\", \"") & "\"]"
       else: "<none>") & ")"
    return (false, CatalogResolution())
  let cat = catOpt.get
  if cat.len == 0:
    step.outcome = csoCatalogMiss
    step.reason = "built-in catalog for '" & packageId & "' is empty"
    return (false, CatalogResolution())
  let res = resolveBuiltinPackage(packageId, cat, version, hostCpu, hostOs)
  if not res.found:
    step.outcome = csoSchemaError
    step.reason = "resolveBuiltinPackage: " & $res.error & " (" &
      res.errorDetail & ")"
    return (false, CatalogResolution())
  step.outcome = csoResolved
  step.reason = "matched version '" & res.resolution.builtinVersion &
    "' for " & $hostCpu & "-" & $hostOs
  (true, res.resolution)

proc tryResolveNix(packageId: string; step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakNix branch of the chain. The M21 realize-side Nix
  ## adapter lands in a parallel branch under ``libs/repro_home_*``;
  ## until that integration is wired into the resolver, cakNix is
  ## skipped cleanly with ``csoAdapterUnavailable``. The chain moves
  ## on. Windows always skips cakNix regardless of registration —
  ## Nix is not supported on Windows.
  step.adapter = cakNix
  step.outcome = csoAdapterUnavailable
  when defined(windows):
    step.reason = "cakNix is not supported on Windows (skipped)"
  else:
    step.reason = "cakNix resolver not yet wired into the M65 chain " &
      "(parallel work in libs/repro_home_*); skipped cleanly so the " &
      "chain falls through to the next adapter"
  (false, CatalogResolution())

proc tryResolveScoop(cat: var ProductionCatalog; packageId: string;
                     step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakScoop branch of the chain. Windows-only; on non-
  ## Windows hosts the step is recorded as ``csoAdapterUnavailable``
  ## and the chain moves on. On Windows we look the package up in
  ## ``scoop list`` + the configured bucket inventory using the same
  ## helpers the legacy ``resolvePackage`` uses.
  step.adapter = cakScoop
  when not defined(windows):
    step.outcome = csoAdapterUnavailable
    step.reason = "cakScoop is Windows-only"
    return (false, CatalogResolution())
  else:
    let inst = installedVersion(cat, packageId)
    let manifest = findBucketManifest(cat, packageId)
    if (not inst.installed) and (not manifest.found):
      step.outcome = csoToolNotFound
      step.reason = "no installed Scoop app named '" & packageId &
        "' and no bucket manifest carries it"
      return (false, CatalogResolution())
    var resolution = CatalogResolution(
      packageId: packageId,
      adapter: cakScoop,
      app: packageId,
      executableName: packageId)
    if manifest.found:
      resolution.bucket = manifest.bucket
      if manifest.binName.len > 0:
        resolution.executableName = manifest.binName
      if not inst.installed:
        resolution.resolvedVersion = manifest.version
    if inst.installed:
      resolution.installed = true
      resolution.resolvedVersion = inst.version
      resolution.cacheHit = satisfiesProfile(inst.version,
        pinnedVersion = "", preferredVersion = "")
      let installedExe = installedExecutableName(cat.scoopRoot, packageId,
        inst.version)
      if installedExe.len > 0:
        resolution.executableName = installedExe
      if resolution.bucket.len == 0:
        let installJson = cat.scoopRoot / "apps" / packageId / inst.version /
          "install.json"
        if fileExists(extendedPath(installJson)):
          try:
            let parsed = parseJson(readFile(extendedPath(installJson)))
            if parsed.kind == JObject:
              resolution.bucket = parsed{"bucket"}.getStr("")
          except CatchableError:
            discard
      if resolution.bucket.len == 0:
        resolution.bucket = "main"
    step.outcome = csoResolved
    step.reason =
      if inst.installed:
        "installed at version '" & inst.version & "' (bucket=" &
          resolution.bucket & ")"
      else:
        "available in bucket '" & manifest.bucket & "' at version '" &
          manifest.version & "' (not yet installed)"
    return (true, resolution)

proc tryResolvePath(packageId: string; step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakPath branch of the chain. The last-resort adapter:
  ## the executable is on PATH, so we record it as a path-adapter
  ## resolution. Already-on-PATH is an implicit cache-hit.
  step.adapter = cakPath
  let exe = findExe(packageId)
  if exe.len == 0:
    step.outcome = csoToolNotFound
    step.reason = "'" & packageId & "' not found on PATH"
    return (false, CatalogResolution())
  step.outcome = csoResolved
  step.reason = "found '" & exe & "' on PATH"
  var resolution = CatalogResolution(
    packageId: packageId,
    adapter: cakPath,
    app: packageId,
    executableName: extractFilename(exe),
    sourcePath: exe,
    installed: true,
    cacheHit: true,
    searchedCatalogs: @["path:" & getEnv("PATH")])
  (true, resolution)

proc raiseAdapterChainExhausted*(packageId: string;
                                 chain: seq[CatalogAdapterKind];
                                 trace: seq[ChainStep]) {.noreturn.} =
  ## M65: every adapter in ``chain`` was tried and none resolved
  ## ``packageId``. The error carries the chain that was walked plus
  ## the per-step skip reason so the CLI layer can render a structured
  ## diagnostic ("nix: no nixPackage branch; builtin: no slice matches;
  ## scoop: not installed; path: not on PATH"). Mirrors the
  ## ``EAdapterChainExhausted`` shape the M65 spec specifies.
  var chainStr = ""
  for i, a in chain:
    if i > 0: chainStr.add(", ")
    chainStr.add($a)
  var reasonStr = ""
  for i, step in trace:
    if i > 0: reasonStr.add("; ")
    reasonStr.add($step.adapter & ": " & step.reason)
  var e = newException(EAdapterChainExhausted,
    "adapter chain exhausted for package '" & packageId &
    "'. Chain walked: [" & chainStr & "]. Per-adapter outcomes: " &
    reasonStr & ". Declare the package in a recognized adapter " &
    "catalog (built-in registry, Scoop, Nix), make its executable " &
    "available on PATH, or override `adapter_preference:` in home.nim.")
  e.packageId = packageId
  e.chain = chain
  e.chainTrace = trace
  raise e

proc chainResolvePackage*(cat: var ProductionCatalog;
                          packageId: string;
                          chain: seq[CatalogAdapterKind] = @[];
                          version = "";
                          hostCpu = detectHostCpu();
                          hostOs = detectHostOs()):
    CatalogResolution =
  ## M65: the production adapter selection chain. Walks ``chain`` in
  ## order, returning the first adapter's resolution. When ``chain`` is
  ## empty the platform default is used (Windows: builtin/scoop/path;
  ## Linux: nix/builtin/path; macOS: nix/path).
  ##
  ## Raises ``EAdapterChainExhausted`` if every adapter in the chain
  ## was tried and none resolved.
  ##
  ## The returned ``CatalogResolution.chainTrace`` carries one entry
  ## per adapter consulted, in order, with the per-adapter outcome +
  ## skip reason (the final entry on a hit has
  ## ``outcome == csoResolved`` — the others are skip reasons).
  let effective =
    if chain.len == 0: defaultAdapterChain()
    else: chain
  var trace: seq[ChainStep] = @[]
  for adapter in effective:
    var step = ChainStep(adapter: adapter, outcome: csoAdapterUnavailable,
      reason: "")
    case adapter
    of cakBuiltin:
      let outcome = tryResolveBuiltin(packageId, version, hostCpu, hostOs,
        step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakNix:
      let outcome = tryResolveNix(packageId, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakScoop:
      let outcome = tryResolveScoop(cat, packageId, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakPath:
      let outcome = tryResolvePath(packageId, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
  raiseAdapterChainExhausted(packageId, effective, trace)
