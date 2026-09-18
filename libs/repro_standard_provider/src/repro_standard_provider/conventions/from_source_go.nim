## From-source Go convention — sibling of `from-source-cargo`.
##
## Covers the Go half of Agent Harbor's pinned tool tier: `shfmt` and
## `addlicense` today, and any other upstream Go module fetched as source
## rather than built in place.
##
## ## Recognition
##
## The convention claims a project when all of the following hold:
##
##   * a `repro.nim` / `reprobuild.nim` exists at the project root;
##   * its first `package <ident>:` block has a registered `fetch:` spec
##     with both a URL and a hash — the source has to be fetched, which is
##     what makes this from-source rather than in-tree;
##   * `go` appears in the package's `nativeBuildDeps`, which is the
##     discriminator;
##   * no `cargo` / `meson` / `cmake` / `autoconf` / `automake` / `libtool`
##     / `make` appears there, so a recipe driving one of those is claimed
##     by the sibling that understands it;
##   * no in-tree build manifest sits at the project root — `go.mod`
##     included, since a `go.mod` at the ROOT means a module being built in
##     place, which the in-tree `go` convention handles;
##   * at least one `executable` / `files` member is declared.
##
## Tool availability is not part of recognition, matching every from-source
## sibling: a host may register a recipe without a Go toolchain installed,
## and the build still needs one at execution time.
##
## ## Pipeline
##
## Fetch, then the sentinel. The module download and the compile live in the
## recipe's own `build:` block through `go_package(...)`, as every
## from-source sibling has since the M9.R.6.1 narrowing.
##
## ## Why there is no manifest gate here
##
## The cargo convention refuses a recipe with no `cargo-vendor.manifest`,
## because for cargo the closure is pinned in this repository and its
## absence means a build that only works where a registry cache is warm.
##
## Go's closure is pinned differently: `go.sum` lives inside the fetched
## source and `go mod download` verifies against it. There is nothing beside
## the recipe for this convention to check, and inventing a file to check
## would be a second, weaker statement of what `go.sum` already says. The
## asymmetry is real and is recorded in `go_package`'s docstring rather than
## hidden behind a symmetric-looking gate.

import std/[options, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
  FromSourceGoSubdir* = "from-source-go"
  GoDriverToken* = "go"
    ## The `nativeBuildDeps` entry that discriminates this convention.

  CompetingDrivers* = ["cargo", "meson", "cmake", "autoconf", "automake",
    "libtool", "make"]
    ## Drivers whose siblings claim first. `cargo` is listed because a
    ## recipe naming both is ambiguous about which toolchain produces the
    ## artefact, and guessing is worse than declining.

  InTreeBuildManifests* = ["Makefile.am", "configure.ac", "configure.in",
    "meson.build", "CMakeLists.txt", "Cargo.toml", "go.mod"]
    ## `go.mod` at the project ROOT means a module built in place. A
    ## from-source recipe's `go.mod` arrives inside the fetched tarball,
    ## under `src/`, so it is never at the root when recognition runs.

type
  GoMemberKind = enum
    gmkExecutable
    gmkFiles

  GoMember = object
    name: string
    kind: GoMemberKind

proc readRecipeSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc leadingWord(stripped, verb: string): bool =
  stripped.startsWith(verb) and
    (stripped.len == verb.len or stripped[verb.len] in {' ', '\t'})

proc firstToken(rest: string): string =
  for ch in rest:
    if ch in {' ', '\t', ':', ','}:
      break
    result.add(ch)

proc constraintHead(raw: string): string =
  ## The bare tool name out of a `nativeBuildDeps` entry — entries carry
  ## version constraints, so matching the whole string would recognise only
  ## the unconstrained spelling.
  for ch in raw.strip():
    if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
      break
    result.add(ch)

proc extractMembers(source: string): seq[GoMember] =
  ## Scan for `executable` / `files` declarations.
  ##
  ## No `library`: `go build` produces commands, and a Go module exposing a
  ## library exposes it as importable source rather than as an artefact
  ## this convention could stage.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = gmkExecutable
    var verb = ""
    if leadingWord(stripped, "executable"):
      verb = "executable"
      kind = gmkExecutable
    elif leadingWord(stripped, "files"):
      verb = "files"
      kind = gmkFiles
    else:
      continue
    let name = firstToken(stripped[verb.len .. ^1].strip())
    if name.len > 0:
      result.add(GoMember(name: name, kind: kind))

proc extractFirstPackageName(source: string): string =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not leadingWord(stripped, "package"):
      continue
    let name = firstToken(stripped[len("package") .. ^1].strip())
    if name.len > 0:
      return name
  ""

proc hasInTreeBuildManifest(projectRoot: string): bool =
  for name in InTreeBuildManifests:
    if fileExists(extendedPath(projectRoot / name)):
      return true
  false

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc sentinelStampPath(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceGoSubdir / "stamps" /
    "from-source-go-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 fetchActionId, fetchStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  createDir(extendedPath(parentDir(sentinelStampPath(projectRoot))))
  let stamp = sentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-go sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  buildAction(
    id = "from-source-go-sentinel",
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = if fetchActionId.len > 0: @[fetchActionId] else: @[],
    inputs = if fetchStamp.len > 0: @[fetchStamp] else: @[],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-go.sentinel",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

proc fromSourceGoRecognize(projectRoot: string;
                           request: ProviderGraphRequest):
                             bool {.gcsafe.} =
  if hasInTreeBuildManifest(projectRoot):
    return false
  let source = readRecipeSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
    return false
  {.cast(gcsafe).}:
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      return false
    var sawGo = false
    var sawCompetingDriver = false
    for raw in registeredNativeBuildDeps(dslPackageName):
      let head = constraintHead(raw)
      if head == GoDriverToken:
        sawGo = true
      elif head in CompetingDrivers:
        sawCompetingDriver = true
    if not sawGo or sawCompetingDriver:
      return false
  extractMembers(source).len > 0

proc syntheticPackage(projectRoot: string;
                      members: seq[GoMember]): PackageDef =
  var name = "from_source_go_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
  let projectMatch = resolveProjectFile(projectRoot)
  PackageDef(
    packageName: name,
    sourceFile:
      if projectMatch.path.len > 0: projectMatch.path
      else: projectRoot / LegacyProjectFileName,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc fromSourceGoEmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  {.cast(gcsafe).}:
    let source = readRecipeSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      raise newException(ValueError,
        "from-source-go convention: no executable / files members " &
        "declared in " & projectRoot)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-go convention: no 'package <name>:' block in " &
        projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-go convention: no fetch: spec registered for " &
        "package '" & dslPackageName & "' — recognise() should have " &
        "rejected this project")
    let pkg = syntheticPackage(projectRoot, members)
    let identity = computeCacheEntryIdentity(projectRoot, dslPackageName,
      "go")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      allActions.add(emitSynthesisSentinelAction(projectRoot,
        dslPackageName, fetchAct.id,
        fetchStampPath(projectRoot, spec.hashHex), identity))
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceGoConvention*(): LanguageConvention =
  ## Registered before the in-tree `go` convention, so a recipe that
  ## fetches its source is claimed here rather than by the one that expects
  ## a module already on disk. Recognition rejects when a root `go.mod` is
  ## present, so the order is defensive either way.
  LanguageConvention(
    name: "from-source-go",
    recognize: fromSourceGoRecognize,
    emitFragment: fromSourceGoEmitFragment)
