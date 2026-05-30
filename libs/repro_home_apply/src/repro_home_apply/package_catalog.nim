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

import std/[json, os, osproc, strutils, tables]
from repro_core/paths import extendedPath

# M64: the cakBuiltin adapter resolves against the M63 VersionedProvisioning
# catalog. We import the schema (cross-platform; no Windows-only deps).
import repro_dsl_stdlib/packages_schema

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

  EUnknownPackage* = object of CatchableError
    ## Raised when a package reference resolves to no production
    ## adapter catalog. Carries the package name and the list of
    ## catalogs searched so the apply pipeline can surface a
    ## structured diagnostic.
    packageId*: string
    searchedCatalogs*: seq[string]

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
  else:
    result.resolution.digestAlgorithm = "sha512"
    result.resolution.digestValue = pb.binary.sha512.toLowerAscii()
  result.resolution.archiveFormat = picked.archive_format
  result.resolution.installMethod = picked.install_method
  result.resolution.binRelpath = picked.bin_relpath
  result.resolution.extractPath = pb.binary.extract_path
  result.resolution.installerArgs = picked.installer_args
  result.resolution.pacmanPackages = picked.pacman_packages
  result.resolution.bootstrapArgv = picked.bootstrap_argv
  # Use the first bin_relpath as the executable name (leaf only).
  if picked.bin_relpath.len > 0:
    result.resolution.executableName = picked.bin_relpath[0].extractFilename
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
