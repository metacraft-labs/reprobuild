## M72 Deliverable 1: production package catalog.
##
## `repro home apply` must realize packages WITHOUT the
## `REPRO_TEST_PACKAGE_*` seams set. This module resolves a
## `PlannedPackage` reference against the REAL adapter catalog of the
## host environment.
##
## On Windows the only production adapter wired here is Scoop: a
## package is a Scoop package if it is installed (`scoop list`) OR
## available in a configured Scoop bucket (the bucket directory holds
## an `<app>.json` manifest). The M55 Scoop adapter
## (`repro_tool_profiles.resolveScoopTool`) performs the actual
## realization; this module only decides the binding and computes the
## cache-hit determination.
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

const
  ScoopRootEnvVar = "SCOOP"
  ScoopOverrideEnvVar = "REPRO_TEST_SCOOP_OVERRIDE"
    ## Same test seam the M55 adapter / `realize.nim` honor: point at a
    ## sandboxed `scoop` executable. Non-exported here so it does not
    ## collide with `realize.nim`'s own `ScoopOverrideEnvVar*`.

type
  CatalogAdapterKind* = enum
    cakScoop = "scoop"

  CatalogResolution* = object
    ## The production catalog's verdict for one package reference.
    packageId*: string
    adapter*: CatalogAdapterKind
    bucket*: string
    app*: string
    resolvedVersion*: string         ## the version the catalog resolved
    executableName*: string
    installed*: bool                 ## already present in the Scoop tree
    cacheHit*: bool                  ## installed AND version-satisfying
    searchedCatalogs*: seq[string]   ## buckets / sources searched

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
    ". On Windows declare the package in a configured Scoop bucket " &
    "(`scoop bucket add ...`) or install it (`scoop install ...`), or " &
    "set REPRO_TEST_PACKAGE_SOURCE / REPRO_TEST_PACKAGE_SCOOP for a " &
    "test-only adapter binding.")
  e.packageId = packageId
  e.searchedCatalogs = searched
  raise e

# ---------------------------------------------------------------------------
# Scoop environment discovery
# ---------------------------------------------------------------------------

proc resolveScoopExecutable(): string =
  let override = getEnv(ScoopOverrideEnvVar)
  if override.len > 0 and fileExists(override):
    return override
  let envBinary = getEnv("REPROBUILD_SCOOP_BINARY")
  if envBinary.len > 0 and fileExists(envBinary):
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
  if not dirExists(appsDir):
    return
  for kind, appPath in walkDir(appsDir):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let app = extractFilename(appPath)
    for vk, vPath in walkDir(appPath):
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
  if not dirExists(bucketsDir):
    return
  for kind, path in walkDir(bucketsDir):
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
    if fileExists(mp):
      var version = ""
      var binName = ""
      try:
        let parsed = parseJson(readFile(mp))
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
  if not fileExists(mp):
    return ""
  try:
    let parsed = parseJson(readFile(mp))
    if parsed.kind == JObject:
      return manifestBinName(parsed)
  except CatchableError:
    discard
  ""

# ---------------------------------------------------------------------------
# Resolution entry point
# ---------------------------------------------------------------------------

proc satisfiesProfile(installedVersion, wantedVersion: string): bool =
  ## A cache-hit requires the installed version to satisfy the profile.
  ## When the profile pins no version (`wantedVersion` empty), any
  ## installed version satisfies it. When a version is pinned, an exact
  ## match is required (the M55 adapter refuses to follow a bucket-head
  ## move away from a pinned version).
  if wantedVersion.len == 0:
    return installedVersion.len > 0
  installedVersion == wantedVersion

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
  result.adapter = cakScoop
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
      searched.add("scoop:bucket:" & manifest.bucket)
      result.bucket = manifest.bucket
      if manifest.binName.len > 0:
        result.executableName = manifest.binName
    if inst.installed:
      result.installed = true
      # When a bucket manifest is present, the profile-wanted version
      # is the manifest head; otherwise the installed version is the
      # only thing to satisfy against.
      let wanted =
        if manifest.found and manifest.version.len > 0: manifest.version
        else: inst.version
      result.resolvedVersion = inst.version
      result.cacheHit = satisfiesProfile(inst.version, wanted)
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
        if fileExists(installJson):
          try:
            let parsed = parseJson(readFile(installJson))
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
      result.installed = false
      result.cacheHit = false
      result.resolvedVersion = manifest.version
      return result
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)
  else:
    # No production adapter is wired off-Windows (the Scoop adapter is
    # Windows-only). Off-Windows production realization is out of M72
    # scope; the env seams remain the only binding.
    searched.add("(no production adapter on this platform)")
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)
