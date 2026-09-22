## From-source npm convention — the JS/bun sibling of `from-source-cargo`.
##
## ## What it is for
##
## The npm-distributed coding agents (gemini-cli, qwen-code) and opencode are
## source-available workspace monorepos: `npm ci` then a bundle script
## (esbuild / tsc). This convention is what lets a recipe say "fetch this
## source, vendor its locked build closure, build it" without hand-writing
## the acquisition — the exact role `from-source-cargo` plays for Rust.
##
## ## Recognition
##
## Claims a project when all of the following hold:
##
##   * a `repro.nim` / `reprobuild.nim` exists with a first `package` block;
##   * that package has a registered `fetch:` spec with a URL and a hash —
##     the source is fetched, which is what makes this from-source;
##   * `node` appears in the package's `nativeBuildDeps` — the discriminator
##     that the recipe drives an npm build;
##   * no competing from-source driver (`cargo` / `meson` / `cmake` /
##     `autoconf` / `automake` / `libtool` / `make`) appears there;
##   * a committed `npm-build-closure.manifest` sits beside the recipe — the
##     positive statement that the offline closure has been pinned, and the
##     thing whose absence makes an npm build succeed only on a machine with
##     a warm registry cache;
##   * no in-tree `package.json` at the project root, so a JS project being
##     built in place is left to the in-tree jsts convention.
##
## Tool availability is deliberately NOT part of recognition, matching every
## from-source sibling.
##
## ## Pipeline
##
## Three actions; the recipe's own `build:` block owns the `npm ci --offline`
## and the bundle, as it does for every from-source sibling:
##
##   1. **Fetch** — the shared `fetch_action` emitter.
##   2. **Vendor** — `emitNpmVendorAction`: fetch the build closure from the
##      committed manifest, verify each archive's SHA-256, and rewrite the
##      lockfile into an offline `file:` mirror so `npm ci --offline` needs
##      no network. See `repro_project_dsl/npm_vendor`.
##   3. **Sentinel** — the synthesis stamp carrying the binary-cache identity.

import std/[options, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_project_dsl/npm_vendor
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName = ".repro/build"
  NodeDriverToken = "node"
  CompetingDrivers = ["cargo", "meson", "cmake", "autoconf", "automake",
    "libtool", "make", "go", "cabal", "dune", "mix", "rebar3", "gradle",
    "maven", "swift", "bundler", "composer"]

proc readRecipeSource(projectRoot: string): string =
  for name in ["repro.nim", "reprobuild.nim"]:
    let p = projectRoot / name
    if fileExists(p):
      try: return readFile(p)
      except CatchableError: return ""
  ""

proc firstPackageName(source: string): string =
  ## The `<ident>` of the first `package <ident>:` block. A backtick-quoted
  ## ident (`package `gemini-cli`:`) is unquoted.
  for raw in source.splitLines():
    let s = raw.strip()
    if s.startsWith("package ") and s.endsWith(":"):
      var ident = s["package ".len ..< ^1].strip()
      ident = ident.strip(chars = {'`'})
      return ident
  ""

proc constraintHead(raw: string): string =
  ## The tool name at the head of a `nativeBuildDeps` entry: `"node >=22"`
  ## -> `node`. Splits on the first whitespace or comparison operator.
  var head = raw.strip().strip(chars = {'"'})
  for i, ch in head:
    if ch in {' ', '\t', '>', '<', '=', '~', '^'}:
      return head[0 ..< i]
  head

proc hasInTreePackageJson(projectRoot: string): bool =
  fileExists(projectRoot / "package.json")

proc fromSourceNpmRecognize(projectRoot: string;
                            request: ProviderGraphRequest):
                              bool {.gcsafe.} =
  if hasInTreePackageJson(projectRoot):
    return false
  if not fileExists(npmBuildClosureManifestPath(projectRoot)):
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
    var sawNode = false
    var sawCompeting = false
    for raw in registeredNativeBuildDeps(dslPackageName):
      let head = constraintHead(raw)
      if head == NodeDriverToken:
        sawNode = true
      elif head in CompetingDrivers:
        sawCompeting = true
    sawNode and not sawCompeting

proc npmSentinelStampPath(projectRoot: string): string =
  projectRoot / ScratchDirName / "from-source-npm" / "stamps" /
    "from-source-npm-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 vendorActionId, vendorStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  ## The synthesis stamp every from-source sibling emits. Depends on the
  ## VENDOR step: the fetched source alone is not a buildable tree until the
  ## offline mirror is on disk, so a sentinel settling before it would
  ## report a synthesis that cannot build. (Replicated per convention, as
  ## every from-source sibling does — it is not shared.)
  createDir(extendedPath(parentDir(npmSentinelStampPath(projectRoot))))
  let stamp = npmSentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-npm sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  buildAction(
    id = "from-source-npm-sentinel",
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = @[vendorActionId],
    inputs = @[vendorStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-npm.sentinel",
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

proc fromSourceNpmEmitFragment(projectRoot: string;
                               request: ProviderGraphRequest):
                                 GraphFragment {.gcsafe.} =
  {.cast(gcsafe).}:
    let source = readRecipeSource(projectRoot)
    let dslPackageName = firstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-npm convention: no 'package <name>:' block in " &
        projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-npm convention: no fetch: spec registered for " &
        "package '" & dslPackageName & "' — recognise() should have " &
        "rejected this project")
    if not fileExists(npmBuildClosureManifestPath(projectRoot)):
      raise newException(ValueError,
        "from-source-npm convention: no " & NpmBuildClosureManifestName &
        " beside the recipe in " & projectRoot & " — an npm build with no " &
        "pinned closure succeeds only where the registry cache is already " &
        "warm. Generate it with tools/npm_closure_manifest.nim " &
        "--build-closure.")
    let pkg = syntheticPackage(projectRoot, dslPackageName)
    let identity = computeCacheEntryIdentity(projectRoot, dslPackageName,
      "npm")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let vendorAct = emitNpmVendorAction(projectRoot, dslPackageName,
        fetchAct.id, fetchStamp)
      allActions.add(vendorAct)
      allActions.add(emitSynthesisSentinelAction(projectRoot,
        dslPackageName, vendorAct.id, npmVendorStampPath(projectRoot),
        identity))
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceNpmConvention*(): LanguageConvention =
  ## Registered before the in-tree jsts convention, so a recipe that fetches
  ## its source and pins a build closure is claimed here rather than by the
  ## one that expects a `package.json` already on disk. Recognition rejects
  ## when a root `package.json` is present, so the order is defensive anyway.
  LanguageConvention(
    name: "from-source-npm",
    recognize: fromSourceNpmRecognize,
    emitFragment: fromSourceNpmEmitFragment)
