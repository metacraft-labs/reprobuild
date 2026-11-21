## From-source cabal convention — the Haskell sibling of `from-source-cargo`
## and `from-source-npm`.
##
## ## What it is for
##
## A Haskell program upstream publishes only as source (or publishes no
## binary for some platform, as `nixfmt` does for Windows) can be built from
## its release tarball with `cabal build`, provided every Hackage package its
## plan uses is already on disk. This convention is what lets a recipe say
## "fetch this source, vendor its pinned Hackage closure, build it", with
## the closure committed beside the recipe as `hackage-vendor.manifest`
## (`repro_core/hackage_closure`).
##
## ## Recognition
##
## Claims a project when all of the following hold:
##
##   * a `repro.nim` / `reprobuild.nim` exists with a first `package` block;
##   * that package has a registered `fetch:` spec with a URL and a hash;
##   * `cabal` appears in the package's `nativeBuildDeps` — the discriminator
##     that the recipe drives a cabal build;
##   * no competing from-source driver appears there;
##   * a committed `hackage-vendor.manifest` sits beside the recipe — the
##     positive statement that the closure is pinned;
##   * no `.cabal` file or `cabal.project` at the project root, so a Haskell
##     package being built in place is left to the in-tree `haskell-cabal`
##     convention.
##
## Tool availability is deliberately NOT part of recognition, matching every
## from-source sibling.
##
## ## Pipeline
##
## Three actions; the recipe's own `build:` block (`cabal_package`) owns the
## patched copy, the offline build and the install:
##
##   1. **Fetch** — the shared `fetch_action` emitter.
##   2. **Vendor** — `emitHackageVendorAction`: download and verify every
##      file the manifest names into a `file+noindex` repository and write
##      the private cabal configuration that names only it.
##   3. **Sentinel** — the synthesis stamp carrying the binary-cache identity.

import std/[options, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_project_dsl/hackage_vendor
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName = ".repro/build"
  CabalDriverToken = "cabal"
  CompetingDrivers = ["cargo", "meson", "cmake", "autoconf", "automake",
    "libtool", "make", "go", "node", "dune", "mix", "rebar3", "gradle",
    "maven", "swift", "bundler", "composer"]

proc readRecipeSource(projectRoot: string): string =
  for name in ["repro.nim", "reprobuild.nim"]:
    let p = projectRoot / name
    if fileExists(p):
      try: return readFile(p)
      except CatchableError: return ""
  ""

proc firstPackageName(source: string): string =
  for raw in source.splitLines():
    let s = raw.strip()
    if s.startsWith("package ") and s.endsWith(":"):
      var ident = s["package ".len ..< ^1].strip()
      ident = ident.strip(chars = {'`'})
      return ident
  ""

proc constraintHead(raw: string): string =
  var head = raw.strip().strip(chars = {'"'})
  for i, ch in head:
    if ch in {' ', '\t', '>', '<', '=', '~', '^'}:
      return head[0 ..< i]
  head

proc hasInTreeCabalProject(projectRoot: string): bool =
  if fileExists(projectRoot / "cabal.project"):
    return true
  for kind, path in walkDir(projectRoot):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".cabal"):
      return true
  false

proc fromSourceCabalRecognize(projectRoot: string;
                              request: ProviderGraphRequest):
                                bool {.gcsafe.} =
  if not fileExists(hackageVendorManifestPath(projectRoot)):
    return false
  if hasInTreeCabalProject(projectRoot):
    return false
  let source = readRecipeSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = firstPackageName(source)
  if dslPackageName.len == 0:
    return false
  {.cast(gcsafe).}:
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      return false
    var sawCabal = false
    var sawCompeting = false
    for raw in registeredNativeBuildDeps(dslPackageName):
      let head = constraintHead(raw)
      if head == CabalDriverToken:
        sawCabal = true
      elif head in CompetingDrivers:
        sawCompeting = true
    sawCabal and not sawCompeting

proc cabalSentinelStampPath(projectRoot: string): string =
  projectRoot / ScratchDirName / "from-source-cabal" / "stamps" /
    "from-source-cabal-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 vendorActionId, vendorStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  ## The synthesis stamp every from-source sibling emits, ordered after the
  ## vendor step: the fetched source is not a buildable tree until the
  ## repository exists.
  createDir(extendedPath(parentDir(cabalSentinelStampPath(projectRoot))))
  let stamp = cabalSentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-cabal sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  buildAction(
    id = "from-source-cabal-sentinel",
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = @[vendorActionId],
    inputs = @[vendorStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-cabal.sentinel",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

proc syntheticPackage(projectRoot, dslPackageName: string): PackageDef =
  let projectMatch = resolveProjectFile(projectRoot)
  PackageDef(
    packageName: dslPackageName,
    sourceFile:
      if projectMatch.path.len > 0: projectMatch.path
      else: projectRoot / LegacyProjectFileName,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc fromSourceCabalEmitFragment(projectRoot: string;
                                 request: ProviderGraphRequest):
                                   GraphFragment {.gcsafe.} =
  {.cast(gcsafe).}:
    let source = readRecipeSource(projectRoot)
    let dslPackageName = firstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-cabal convention: no 'package <name>:' block in " &
        projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-cabal convention: no fetch: spec registered for " &
        "package '" & dslPackageName & "' — recognise() should have " &
        "rejected this project")
    # Raises, by name, when the manifest is absent or malformed.
    let plan = readHackageVendorManifest(projectRoot)
    let pkg = syntheticPackage(projectRoot, dslPackageName)
    let identity = computeCacheEntryIdentity(projectRoot, dslPackageName,
      "cabal")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let vendorAct = emitHackageVendorAction(projectRoot, dslPackageName,
        plan, fetchAct.id, fetchStamp)
      allActions.add(vendorAct)
      allActions.add(emitSynthesisSentinelAction(projectRoot,
        dslPackageName, vendorAct.id, hackageVendorStampPath(projectRoot),
        identity))
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceCabalConvention*(): LanguageConvention =
  ## Registered before the in-tree `haskell-cabal` convention, so a recipe
  ## that fetches its source is claimed here. Recognition rejects a project
  ## with a root `.cabal` file or `cabal.project`, so the order is defensive
  ## in either direction.
  LanguageConvention(
    name: "from-source-cabal",
    recognize: fromSourceCabalRecognize,
    emitFragment: fromSourceCabalEmitFragment)
