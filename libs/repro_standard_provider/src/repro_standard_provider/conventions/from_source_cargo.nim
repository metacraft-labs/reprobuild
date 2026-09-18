## From-source Cargo convention — the Rust sibling of the from-source
## meson / cmake / autotools / make family.
##
## ## What it is for
##
## Agent Harbor's dev environment pins eight small Rust and Go CLIs that are
## fetched as release binaries today: `cargo-nextest`, `taplo-cli`,
## `cargo-sort`, `prek`, `just`, `jq`, `shfmt`, `addlicense`. Each has a
## buildable upstream tree and a lockfile, which makes the Rust half of that
## list the catalog's first genuine `packages/source/` entries outside the
## Linux desktop corpus. This convention is what lets a recipe say "fetch
## this crate, vendor its locked closure, build it" without hand-writing the
## acquisition.
##
## ## Recognition
##
## The convention claims a project when all of the following hold:
##
##   * a `repro.nim` / `reprobuild.nim` exists at the project root;
##   * its first `package <ident>:` block has a registered `fetch:` spec
##     with both a URL and a hash — the source has to be fetched, which is
##     what makes this from-source rather than in-tree;
##   * `cargo` appears in the package's `nativeBuildDeps`, which is the
##     discriminator: it is the unambiguous statement that the recipe drives
##     cargo;
##   * no `meson` / `cmake` / `autoconf` / `automake` / `libtool` / `make`
##     appears there, so a recipe that drives one of those is claimed by the
##     sibling that understands it;
##   * no in-tree build manifest sits at the project root, so an actual Rust
##     workspace being built in place is left to the in-tree `rust`
##     convention;
##   * at least one `executable` / `library` / `files` member is declared.
##
## Tool availability is deliberately NOT part of recognition, matching every
## from-source sibling: a host may legitimately register a recipe (so the
## unit and smoke tests round-trip) without a Rust toolchain installed. The
## build still needs one at execution time.
##
## ## Pipeline
##
## Three actions, narrow by design — the recipe's own `build:` block owns
## the compile and the staging, as it does for every from-source sibling
## since the M9.R.6.1 narrowing:
##
##   1. **Fetch** — the shared `fetch_action` emitter: download, verify,
##      extract to `<projectRoot>/src`.
##   2. **Vendor** — `cargo_vendor_action`: materialise the locked
##      dependency closure from the recipe's committed
##      `cargo-vendor.manifest` and write the `.cargo/config.toml` that
##      points cargo at it instead of the network. This is the step that
##      makes `cargo build --locked --offline` possible, and it is why this
##      convention exists as its own module rather than as a flag on
##      `from-source-custom`.
##   3. **Sentinel** — the synthesis stamp every from-source sibling emits,
##      carrying the binary-cache identity.
##
## ## Why the vendor step is not optional
##
## A recipe recognised here without a `cargo-vendor.manifest` is refused at
## emission time, by name. The alternative is a graph that builds fine on
## the machine that has a warm `~/.cargo/registry` and fails on every other
## one — which is the precise failure mode a from-source tier exists to
## remove, arriving with a message about a missing crate rather than about a
## missing pin.

import std/[options, os, strutils]

import repro_core
import repro_core/cargo_lock
import repro_provider_runtime
import repro_project_dsl
import repro_project_dsl/cargo_vendor
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
  FromSourceCargoSubdir* = "from-source-cargo"
  CargoDriverToken* = "cargo"
    ## The `nativeBuildDeps` entry that discriminates this convention.

  CompetingDrivers* = ["meson", "cmake", "autoconf", "automake", "libtool",
    "make"]
    ## Drivers whose from-source siblings claim first. `make` is included
    ## because a recipe that drives a Makefile wrapping cargo is a
    ## from-source-make recipe: the Makefile is what runs, and this
    ## convention's vendor step would be pinning a closure nothing consumes.

  InTreeBuildManifests* = ["Makefile.am", "configure.ac", "configure.in",
    "meson.build", "CMakeLists.txt", "Cargo.toml"]
    ## `Cargo.toml` at the project ROOT means an in-tree Rust workspace,
    ## which the `rust` convention builds in place. A from-source recipe's
    ## `Cargo.toml` arrives inside the fetched tarball, under `src/`, and is
    ## therefore not at the root when recognition runs.

type
  CargoMemberKind = enum
    cmkExecutable
    cmkLibrary
    cmkFiles

  CargoMember = object
    name: string
    kind: CargoMemberKind

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
  ## The bare tool name out of a `nativeBuildDeps` entry.
  ##
  ## Entries carry version constraints (`"cargo >=1.92"`), so matching the
  ## whole string against a driver name would recognise only the
  ## unconstrained spelling — and a recipe that pinned its cargo would fall
  ## through to whichever sibling claimed it next.
  for ch in raw.strip():
    if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
      break
    result.add(ch)

proc extractMembers(source: string): seq[CargoMember] =
  ## Scan for `executable` / `library` / `files` declarations.
  ##
  ## A text scan rather than a macro hook, matching every from-source
  ## sibling: recognition runs before the recipe is compiled, so the only
  ## thing available is the text.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = cmkExecutable
    var verb = ""
    if leadingWord(stripped, "executable"):
      verb = "executable"
      kind = cmkExecutable
    elif leadingWord(stripped, "library"):
      verb = "library"
      kind = cmkLibrary
    elif leadingWord(stripped, "files"):
      verb = "files"
      kind = cmkFiles
    else:
      continue
    let name = firstToken(stripped[verb.len .. ^1].strip())
    if name.len > 0:
      result.add(CargoMember(name: name, kind: kind))

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

proc stampDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceCargoSubdir / "stamps"

proc sentinelStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-cargo-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 vendorActionId, vendorStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  ## The synthesis stamp every from-source sibling emits. Depends on the
  ## VENDOR step rather than the fetch: for a cargo recipe the source alone
  ## is not a usable tree, and a sentinel that settled before the closure
  ## was on disk would report a synthesis that cannot build.
  createDir(extendedPath(parentDir(sentinelStampPath(projectRoot))))
  let stamp = sentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-cargo sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  buildAction(
    id = "from-source-cargo-sentinel",
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = @[vendorActionId],
    inputs = @[vendorStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-cargo.sentinel",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

proc fromSourceCargoRecognize(projectRoot: string;
                              request: ProviderGraphRequest):
                                bool {.gcsafe.} =
  ## See the module docstring for the contract. Declaration-based: no
  ## host-PATH gate, because the engine resolves tool identity after
  ## recognition and may satisfy `cargo` from the store or the cache.
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
    var sawCargo = false
    var sawCompetingDriver = false
    for raw in registeredNativeBuildDeps(dslPackageName):
      let head = constraintHead(raw)
      if head == CargoDriverToken:
        sawCargo = true
      elif head in CompetingDrivers:
        sawCompetingDriver = true
    if not sawCargo or sawCompetingDriver:
      return false
  extractMembers(source).len > 0

proc syntheticPackage(projectRoot: string;
                      members: seq[CargoMember]): PackageDef =
  var name = "from_source_cargo_convention"
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

proc fromSourceCargoEmitFragment(projectRoot: string;
                                 request: ProviderGraphRequest):
                                   GraphFragment {.gcsafe.} =
  {.cast(gcsafe).}:
    let source = readRecipeSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      raise newException(ValueError,
        "from-source-cargo convention: no executable / library / files " &
        "members declared in " & projectRoot)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-cargo convention: no 'package <name>:' block in " &
        projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-cargo convention: no fetch: spec registered for " &
        "package '" & dslPackageName & "' — recognise() should have " &
        "rejected this project")
    # Raises, by name, when the closure is not pinned. See the module
    # docstring: the alternative is a graph that builds on the machine with
    # a warm registry cache and nowhere else.
    let plan = readVendorManifest(projectRoot)
    let pkg = syntheticPackage(projectRoot, members)
    let identity = computeCacheEntryIdentity(projectRoot, dslPackageName,
      "cargo")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let vendorAct = emitCargoVendorAction(projectRoot, dslPackageName,
        plan, fetchAct.id, fetchStamp)
      allActions.add(vendorAct)
      allActions.add(emitSynthesisSentinelAction(projectRoot,
        dslPackageName, vendorAct.id, cargoVendorStampPath(projectRoot),
        identity))
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceCargoConvention*(): LanguageConvention =
  ## Registered before the in-tree `rust` convention, so a recipe that
  ## fetches its source is claimed here rather than by the one that expects
  ## a workspace already on disk. Recognition rejects when a root
  ## `Cargo.toml` is present, so the order is defensive either way.
  LanguageConvention(
    name: "from-source-cargo",
    recognize: fromSourceCargoRecognize,
    emitFragment: fromSourceCargoEmitFragment)
