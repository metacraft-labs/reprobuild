## The rustc edge of a registry crate: one locked crates.io library,
## compiled from its read-only store prefix.
##
## A registry crate's sources arrive in the store root through its
## `cargo.fetch` edge (`fetch.nim`, `crate_store.nim`). This module turns one
## such crate into one build-graph edge that runs `rustc` the way cargo
## compiles a dependency, with a single flag added:
##
##   rustc --crate-name <crate> --edition=<edition> <prefix>/<lib root>
##         --crate-type lib --emit=dep-info,metadata,link
##         -C embed-bitcode=no <profile flags> [--cfg feature="<f>"]...
##         -C metadata=<hash> -C extra-filename=-<hash>
##         --out-dir <out> [-L dependency=<dir>]... [--extern <n>=<rmeta>]...
##         --cap-lints allow
##         --remap-path-prefix=<prefix>=<name>-<version>
##
## Everything up to `--cap-lints allow` is cargo's invocation for a
## dependency unit (cargo passes `--cap-lints allow` for every package whose
## source is not a path, and `--extern` names the dependency's `.rmeta`
## because cargo pipelines library compiles). The last flag is not cargo's.
##
## **Why the remap.** rustc writes the source path it was given into the
## rlib and the rmeta (panic locations, the source-file table, debug info).
## For a registry crate that path is the store prefix, which lies under the
## store root, so without the remap every library output names the store
## root's physical path, and the cache's embedded-path scan of the outputs
## then refuses to share the record between checkouts. With
## `--remap-path-prefix=<prefix>=<name>-<version>` the rlib and rmeta name
## `<name>-<version>/src/...` instead, which is what cargo's own (unstable)
## `trim-paths` profile setting does for registry dependencies
## (https://doc.rust-lang.org/cargo/reference/unstable.html, "Profile
## `trim-paths` option"; rustc's flag:
## https://doc.rust-lang.org/rustc/command-line-arguments.html#--remap-path-prefix-remap-source-names-in-output).
## The flag is part of the edge's argv, so it is in the edge's key; and the
## edge records it, as `RegistryCrateEdge.argvDifference`, as the one argv
## difference from cargo's invocation (`cargoArgv`).
##
## **The dep-info file is read evidence, not an output.** rustc still writes
## `<crate>-<hash>.d` (it is in cargo's `--emit`), and the remap does not
## rewrite the paths in it, so it would carry the store prefix and the
## output directory into any record that cached it. It is therefore not
## declared as an output: the edge's outputs are the rlib and the rmeta.
##
## **Dependency evidence.** The edge checks its inputs by content (`hybrid`)
## and is gathered by the automatic monitor, the policy a content-checked
## compile edge takes: the monitor records every file rustc reads (the
## crate's sources in the prefix, each dependency's metadata, the toolchain)
## and every directory it lists, so nothing rests on a declared list. The
## declared inputs only order the edge: the crate's manifest and crate root,
## and the `.rmeta` of every dependency in its closure.
##
## **Dependency on the fetch edge.** A unit is built from a crate whose
## prefix the store already holds and verifies (`presentCratePrefix`); a
## crate whose fetch edge has not run is refused. The prefix's path is a
## function of the crate's checksum and nothing else, and it is read-only,
## so the compile edge depends on the fetched sources by their content, not
## on the fetch edge's receipt (which names mirrors and a state directory
## and would tie the edge to one project).
##
## **What the caller supplies.** cargo decides each unit's features, profile
## flags and dependencies; this module does not. The caller passes them
## (`features`, `profileArgs`, `deps`), as cargo would have planned the unit,
## and the module checks them against the crate's manifest where it can: a
## feature the manifest does not declare is refused. What the module reads
## from the prefix's normalized `Cargo.toml` is what cargo reads from it for
## the compile: the library's crate name and root, the edition, and the
## package fields of cargo's crate environment.
##
## **The unit from cargo's plan (`registryCrateUnitEdge`).** In a workspace
## Reprobuild builds from cargo's recorded plan (`repro_cargo_edge/
## plan_units`), the unit is not the caller's: its argv, working directory
## and environment are cargo's own, read from the record run, so its
## features, cfgs, profile flags, `-C metadata` hash and `CARGO_*`
## environment are exactly cargo's. This module then adds what is particular
## to a registry crate (the store check, the refusals below, the remap) and
## builds the same kind of edge. The caller-supplied form
## (`registryCrateEdge`) remains for a unit named without a plan.
##
## **Refused, never half-built.** Build scripts and proc-macros are not
## built as edges yet. A crate whose manifest names a build script, that
## ships a `build.rs` beside its manifest, that declares `links`, or whose
## library is a proc-macro is refused with `RegistryCrateRefusal` before any
## action exists, naming the crate and the reason; a workspace that needs
## such a crate is built by cargo as a whole.

import std/[algorithm, os, sets, strutils, tables]

import blake3
import toml_serialization
import toml_serialization/types as toml_types

import repro_build_engine
import repro_core/dependency_gathering
import repro_core/input_check_policy
import repro_lock/identity
import repro_local_store

import ./crate_rows
import ./crate_store

type
  RegistryCrateRefusalReason* = enum
    rcrNotFetched = "not-fetched"
      ## the store holds no verified prefix for the crate
    rcrManifest = "manifest"
      ## the prefix's `Cargo.toml` cannot be read as this crate's manifest
    rcrBuildScript = "build-script"
    rcrProcMacro = "proc-macro"
    rcrLinks = "links"
    rcrCrateType = "crate-type"
      ## a library crate type other than `lib` / `rlib`
    rcrFeature = "feature"
      ## a requested feature the manifest does not declare
    rcrUnit = "unit"
      ## a malformed unit (an extern name, a dependency edge)

  RegistryCrateRefusal* = object of CatchableError
    ## A registry crate this module will not build an edge for.
    reason*: RegistryCrateRefusalReason
    crate*: string   ## `<name>@<version>`

  CrateManifest* = object
    ## What a compile reads from a registry crate's normalized `Cargo.toml`.
    packageName*, version*, edition*: string
    libName*: string      ## the library's crate name (`-` became `_`)
    libPath*: string      ## the crate root, relative to the prefix
    buildScript*: string  ## the build script it names or ships, "" if none
    procMacro*: bool
    links*: string
    crateTypes*: seq[string]
    features*: HashSet[string]
      ## declared features plus the implicit feature of each optional
      ## dependency
    authors*: seq[string]
    description*, homepage*, repository*, license*, licenseFile*,
      rustVersion*, readme*: string

  RegistryCrateExtern* = object
    ## One `--extern`: the name the dependent crate uses, and the unit.
    name*: string
    edge*: RegistryCrateEdge

  RegistryCrateEdge* = ref object
    ## One registry crate's rustc edge and what its dependents need.
    row*: CrateRow
    prefix*: string        ## the crate's store prefix
    crateName*: string
    metadataHash*: string  ## `-C metadata=` and `-C extra-filename=-`
    outDir*: string
    rmeta*, rlib*: string  ## the declared outputs
    depInfo*: string       ## written by rustc, read by nobody, not an output
    cargoArgv*: seq[string]
      ## cargo's invocation for this unit (paths as this layout places them)
    argvDifference*: seq[string]
      ## what `action.argv` adds to `cargoArgv`: the remap flag, alone
    closure*: seq[RegistryCrateEdge]
      ## every unit this one depends on, transitively, without duplicates
      ## (empty for a unit from cargo's plan, which holds the closure itself)
    action*: BuildAction

const
  DevProfileArgs* = ["-C", "debuginfo=2"]
    ## cargo's `dev` profile for a dependency: `debug = true`, `opt-level = 0`
    ## (no flag), https://doc.rust-lang.org/cargo/reference/profiles.html
  ReleaseProfileArgs* = ["-C", "opt-level=3"]
    ## cargo's `release` profile: `opt-level = 3`, `debug = false` (no flag)
  RegistryCrateEdgePrefix* = "cargo.rustc/"
  RegistryCrateStatsId* = "rust.rustc-registry"
  UnitHashKind = "reprobuild.cargo-registry-unit.v1"

proc refuse(reason: RegistryCrateRefusalReason; crate, msg: string) {.noreturn.} =
  var e = newException(RegistryCrateRefusal, msg)
  e.reason = reason
  e.crate = crate
  raise e

proc registryCrateEdgeId*(row: CrateRow; metadataHash: string): string =
  RegistryCrateEdgePrefix & row.label & "-" & metadataHash

proc remapFlag*(row: CrateRow; prefix: string): string =
  ## `--remap-path-prefix=<prefix>=<name>-<version>`. rustc splits the value
  ## at its LAST `=`, so a `=` in the prefix is harmless; the target is a
  ## validated crate name and version, which hold none.
  "--remap-path-prefix=" & prefix & "=" & crateTopDirectory(row)

# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------

proc isTable(v: TomlValueRef): bool =
  # `isNil`, not `!= nil`: the TOML library's `==` on values dereferences.
  not v.isNil and v.kind in {TomlKind.Table, TomlKind.InlineTable}

proc sub(v: TomlValueRef; key: string): TomlValueRef =
  if isTable(v) and v.tableVal[].hasKey(key): v.tableVal[][key] else: nil

proc str(v: TomlValueRef; crate, field: string): string =
  ## A string field, "" when absent; any other kind is a manifest refusal.
  ## A normalized manifest carries plain values only: an inherited
  ## `{ workspace = true }` never survives `cargo package`.
  if v.isNil: return ""
  if v.kind != TomlKind.String:
    refuse(rcrManifest, crate, "registry crate " & crate & ": Cargo.toml " &
      "field " & field & " is not a string")
  v.stringVal

proc crateNameOf(packageName: string): string =
  packageName.replace('-', '_')

proc isSafeRelative(path: string): bool =
  ## A relative path that stays inside the prefix.
  if path.len == 0 or path.isAbsolute or path.contains('\\'): return false
  for part in path.split('/'):
    if part == "..": return false
  true

proc collectOptionalDeps(table: TomlValueRef; into: var HashSet[string]) =
  if not isTable(table): return
  for name, dep in table.tableVal[]:
    let opt = dep.sub("optional")
    if not opt.isNil and opt.kind == TomlKind.Bool and opt.boolVal:
      into.incl name

proc readCrateManifest*(row: CrateRow; prefix: string): CrateManifest =
  ## Read the normalized `Cargo.toml` `cargo package` wrote into ``row``'s
  ## prefix. Raises `RegistryCrateRefusal` (`rcrManifest`) for a manifest
  ## that is missing, does not parse, names another package or version, or
  ## puts the crate root outside the prefix. The manifest is crate content,
  ## not trusted input.
  let crate = row.label
  let path = prefix / "Cargo.toml"
  if not fileExists(path):
    refuse(rcrManifest, crate, "registry crate " & crate & ": " & path &
      " does not exist")
  let root =
    try: Toml.decode(readFile(path), TomlValueRef)
    except CatchableError as e:
      refuse(rcrManifest, crate, "registry crate " & crate & ": " & path &
        " does not parse: " & e.msg)
  let pkg = root.sub("package")
  if not isTable(pkg):
    refuse(rcrManifest, crate, "registry crate " & crate & ": " & path &
      " has no [package] table")
  result.packageName = pkg.sub("name").str(crate, "package.name")
  result.version = pkg.sub("version").str(crate, "package.version")
  if result.packageName != row.name or result.version != row.version:
    refuse(rcrManifest, crate, "registry crate " & crate & ": " & path &
      " is the manifest of " & result.packageName & "@" & result.version)
  result.edition = pkg.sub("edition").str(crate, "package.edition")
  if result.edition.len == 0:
    result.edition = "2015"   # Cargo Book, "The `edition` field"
  if not result.edition.allCharsInSet({'0'..'9'}):
    refuse(rcrManifest, crate, "registry crate " & crate & ": edition " &
      result.edition.escape() & " is not an edition year")
  # The build script: a `build` key naming a file (or `true`), or a
  # `build.rs` beside the manifest even when `build = false`, the same
  # rule as for a workspace member (a file cargo is told not to run can
  # still be one another configuration runs).
  let build = pkg.sub("build")
  if not build.isNil:
    case build.kind
    of TomlKind.String: result.buildScript = build.stringVal
    of TomlKind.Bool:
      if build.boolVal: result.buildScript = "build.rs"
    else:
      refuse(rcrManifest, crate, "registry crate " & crate &
        ": package.build is neither a path nor a boolean")
  if result.buildScript.len == 0 and fileExists(prefix / "build.rs"):
    result.buildScript = "build.rs"
  result.links = pkg.sub("links").str(crate, "package.links")
  let authors = pkg.sub("authors")
  if not authors.isNil and authors.kind == TomlKind.Array:
    for a in authors.arrayVal:
      result.authors.add a.str(crate, "package.authors")
  result.description = pkg.sub("description").str(crate,
    "package.description")
  result.homepage = pkg.sub("homepage").str(crate, "package.homepage")
  result.repository = pkg.sub("repository").str(crate, "package.repository")
  result.license = pkg.sub("license").str(crate, "package.license")
  result.licenseFile = pkg.sub("license-file").str(crate,
    "package.license-file")
  result.rustVersion = pkg.sub("rust-version").str(crate,
    "package.rust-version")
  let readme = pkg.sub("readme")
  if not readme.isNil and readme.kind == TomlKind.String:
    result.readme = readme.stringVal   # `readme = false` means none
  let lib = root.sub("lib")
  result.libName = crateNameOf(result.packageName)
  result.libPath = "src/lib.rs"
  if not lib.isNil:
    if not isTable(lib):
      refuse(rcrManifest, crate, "registry crate " & crate &
        ": [lib] is not a table")
    let name = lib.sub("name").str(crate, "lib.name")
    if name.len > 0: result.libName = crateNameOf(name)
    let p = lib.sub("path").str(crate, "lib.path")
    if p.len > 0: result.libPath = p
    for key in ["proc-macro", "proc_macro"]:
      let pm = lib.sub(key)
      if not pm.isNil and pm.kind == TomlKind.Bool and pm.boolVal:
        result.procMacro = true
    let types = lib.sub("crate-type")
    if not types.isNil and types.kind == TomlKind.Array:
      for t in types.arrayVal:
        result.crateTypes.add t.str(crate, "lib.crate-type")
  if not isSafeRelative(result.libPath):
    refuse(rcrManifest, crate, "registry crate " & crate & ": crate root " &
      result.libPath.escape() & " is not a path inside the crate")
  let features = root.sub("features")
  if isTable(features):
    for name, _ in features.tableVal[]:
      result.features.incl name
  # An optional dependency is also a feature of its own name (Cargo Book,
  # "Features", "Optional dependencies").
  for key in ["dependencies", "build-dependencies"]:
    collectOptionalDeps(root.sub(key), result.features)
  let targets = root.sub("target")
  if isTable(targets):
    for _, t in targets.tableVal[]:
      for key in ["dependencies", "build-dependencies"]:
        collectOptionalDeps(t.sub(key), result.features)

proc refuseUnbuildable*(row: CrateRow; m: CrateManifest) =
  ## Raise `RegistryCrateRefusal` when ``m`` describes a crate whose compile
  ## needs what an edge cannot supply yet: a build script's output, a
  ## proc-macro (a host unit), `links` metadata, or a crate type other than
  ## a Rust library.
  let crate = row.label
  const whole = "; a workspace that needs it is built by cargo as a whole"
  if m.buildScript.len > 0:
    refuse(rcrBuildScript, crate, "registry crate " & crate &
      " has a build script (" & m.buildScript & "), and build scripts are " &
      "not built as edges yet" & whole)
  if m.procMacro:
    refuse(rcrProcMacro, crate, "registry crate " & crate & " is a " &
      "proc-macro crate, and proc-macros are not built as edges yet" & whole)
  if m.links.len > 0:
    refuse(rcrLinks, crate, "registry crate " & crate & " declares links = " &
      m.links.escape() & ", and links metadata is not supplied by edges " &
      "yet" & whole)
  for t in m.crateTypes:
    if t notin ["lib", "rlib"]:
      refuse(rcrCrateType, crate, "registry crate " & crate & " has crate " &
        "type " & t.escape() & "; only a Rust library (lib, rlib) is built " &
        "as an edge" & whole)

# ---------------------------------------------------------------------------
# The crate environment
# ---------------------------------------------------------------------------

proc semverParts(version: string): tuple[major, minor, patch, pre: string] =
  var core = version
  let plus = core.find('+')
  if plus >= 0: core = core[0 ..< plus]
  let dash = core.find('-')
  if dash >= 0:
    result.pre = core[dash + 1 .. ^1]
    core = core[0 ..< dash]
  let parts = core.split('.')
  if parts.len > 0: result.major = parts[0]
  if parts.len > 1: result.minor = parts[1]
  if parts.len > 2: result.patch = parts[2]

proc cargoCrateEnv*(m: CrateManifest; prefix: string): seq[string] =
  ## The variables cargo sets for a dependency's compile, from its manifest
  ## (Cargo Book, "Environment variables Cargo sets for crates",
  ## https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-crates).
  ## Not set: `CARGO` (the caller adds it when it runs a cargo), and
  ## `CARGO_PRIMARY_PACKAGE` (a dependency is not a primary package).
  let v = semverParts(m.version)
  result = @[
    "CARGO_CRATE_NAME=" & m.libName,
    "CARGO_MANIFEST_DIR=" & prefix,
    "CARGO_MANIFEST_PATH=" & prefix / "Cargo.toml",
    "CARGO_PKG_AUTHORS=" & m.authors.join(":"),
    "CARGO_PKG_DESCRIPTION=" & m.description,
    "CARGO_PKG_HOMEPAGE=" & m.homepage,
    "CARGO_PKG_LICENSE=" & m.license,
    "CARGO_PKG_LICENSE_FILE=" & m.licenseFile,
    "CARGO_PKG_NAME=" & m.packageName,
    "CARGO_PKG_README=" & m.readme,
    "CARGO_PKG_REPOSITORY=" & m.repository,
    "CARGO_PKG_RUST_VERSION=" & m.rustVersion,
    "CARGO_PKG_VERSION=" & m.version,
    "CARGO_PKG_VERSION_MAJOR=" & v.major,
    "CARGO_PKG_VERSION_MINOR=" & v.minor,
    "CARGO_PKG_VERSION_PATCH=" & v.patch,
    "CARGO_PKG_VERSION_PRE=" & v.pre]

# ---------------------------------------------------------------------------
# The edge
# ---------------------------------------------------------------------------

proc isRustIdent(s: string): bool =
  s.len > 0 and s[0] notin {'0'..'9'} and
    s.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'})

proc externOf*(edge: RegistryCrateEdge): RegistryCrateExtern =
  ## The `--extern` a dependent passes for ``edge`` under its crate name.
  RegistryCrateExtern(name: edge.crateName, edge: edge)

proc unitHash(row: CrateRow; m: CrateManifest; profileArgs: openArray[string];
              features: openArray[string];
              deps: openArray[RegistryCrateExtern]): string =
  ## The unit's `-C metadata` value: 16 hex digits, as cargo's, covering
  ## everything that tells two units apart (the crate's identity and
  ## checksum, its crate name and edition, the profile flags, the features
  ## and each dependency's extern name and unit). cargo's own value is
  ## internal to cargo and not reproduced.
  var s = UnitHashKind & "\0" & row.name & "\0" & row.version & "\0" &
    row.cksum & "\0" & m.libName & "\0" & m.edition & "\0"
  for a in profileArgs: s.add "p:" & a & "\0"
  for f in features: s.add "f:" & f & "\0"
  for d in deps: s.add "d:" & d.name & "=" & d.edge.metadataHash & "\0"
  let digest = blake3.digest(s)
  for i in 0 ..< 8: result.add toHex(int(digest[i]), 2).toLowerAscii()

proc rustcUnitAction*(id: string; argv: openArray[string]; cwd: string;
                      deps, inputs, outputs, env: openArray[string];
                      commandStatsId: string;
                      isolateHostEnvironment = false;
                      scratchDirs: openArray[string] = []): BuildAction =
  ## The engine action of one rustc unit, as every cargo unit edge declares
  ## it: cacheable, its inputs checked by content (`hybrid`) and gathered by
  ## the automatic monitor (so nothing rests on the declared inputs, which
  ## only order it), in the `compile` pool, outside any solved graph's lock
  ## identity until a planner names one. ``scratchDirs`` are emptied before
  ## each run and are never evidence (an incremental-compilation directory).
  result = action(id, argv,
    cwd = cwd,
    deps = deps,
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    commandStatsId = commandStatsId,
    cacheable = true,
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    isolateHostEnvironment = isolateHostEnvironment,
    env = env,
    # Every input of the edge is content: the crate's checksum-addressed
    # prefix or the workspace's sources, its dependencies' outputs and the
    # toolchain. No solved graph's identity is wired in yet; the planner
    # that derives these units from a build of the lock is what will name
    # it.
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.scratchDirs = @scratchDirs

proc registryCrateEdge*(row: CrateRow; storeRoot, rustc, outRoot: string;
                        profileArgs: openArray[string];
                        features: openArray[string] = [];
                        deps: openArray[RegistryCrateExtern] = [];
                        extraEnv: openArray[string] = []):
    RegistryCrateEdge =
  ## The rustc edge of ``row`` (see the module docstring), compiling from
  ## its prefix in the store at ``storeRoot`` ("" = the user's store root)
  ## with ``rustc``, into its own directory under ``outRoot``.
  ##
  ## ``profileArgs`` are cargo's profile flags for the unit
  ## (`DevProfileArgs`, `ReleaseProfileArgs`); ``features`` its enabled
  ## features; ``deps`` its dependencies, each the edge of a unit built
  ## earlier, under the name the crate uses for it. ``extraEnv`` is added to
  ## cargo's crate environment (`KEY=value`).
  ##
  ## Raises `RegistryCrateRefusal` for a crate that is not fetched, whose
  ## manifest cannot be read, that needs a build script, a proc-macro or
  ## `links` (`refuseUnbuildable`), or for a feature the manifest does not
  ## declare. Nothing is created before every check has passed except the
  ## unit's output directory.
  validateRow(row)
  let crate = row.label
  let prefix = block:
    var s = openStore(if storeRoot.len > 0: absolutePath(storeRoot)
                      else: resolveStoreRoot())
    defer: s.close()
    s.presentCratePrefix(row)
  if prefix.len == 0:
    refuse(rcrNotFetched, crate, "registry crate " & crate & " (sha256:" &
      row.cksum & ") is not in the store; its cargo.fetch edge must run " &
      "before its compile edge is built")
  let m = readCrateManifest(row, prefix)
  refuseUnbuildable(row, m)
  if not fileExists(prefix / m.libPath):
    refuse(rcrManifest, crate, "registry crate " & crate & ": crate root " &
      m.libPath & " does not exist in " & prefix)
  var feats: seq[string]
  for f in features:
    if f notin m.features:
      refuse(rcrFeature, crate, "registry crate " & crate &
        " declares no feature " & f.escape())
    if f notin feats: feats.add f
  feats.sort()   # cargo passes them sorted
  var externs = @deps
  externs.sort(proc(a, b: RegistryCrateExtern): int = cmp(a.name, b.name))
  var closure: seq[RegistryCrateEdge]
  var seenNames = initHashSet[string]()
  for d in externs:
    if not isRustIdent(d.name):
      refuse(rcrUnit, crate, "registry crate " & crate & ": extern name " &
        d.name.escape() & " is not a Rust identifier")
    if d.edge.isNil:
      refuse(rcrUnit, crate, "registry crate " & crate & ": dependency " &
        d.name & " has no edge")
    if d.name in seenNames:
      refuse(rcrUnit, crate, "registry crate " & crate & ": extern name " &
        d.name & " is given twice")
    seenNames.incl d.name
    for e in d.edge.closure & @[d.edge]:
      var known = false
      for c in closure:
        if c.action.id == e.action.id: known = true
      if not known: closure.add e
  closure.sort(proc(a, b: RegistryCrateEdge): int = cmp(a.action.id,
    b.action.id))

  let hash = unitHash(row, m, profileArgs, feats, externs)
  let outDir = absolutePath(outRoot) / (crateTopDirectory(row) & "-" & hash)
  let stem = m.libName & "-" & hash
  let rmeta = outDir / ("lib" & stem & ".rmeta")
  let rlib = outDir / ("lib" & stem & ".rlib")

  # cargo's argv for a dependency unit, in cargo's order.
  var argv = @[rustc, "--crate-name", m.libName, "--edition=" & m.edition,
    prefix / m.libPath, "--crate-type", "lib",
    "--emit=dep-info,metadata,link", "-C", "embed-bitcode=no"]
  argv.add profileArgs
  for f in feats:
    argv.add "--cfg"
    argv.add "feature=\"" & f & "\""
  argv.add ["-C", "metadata=" & hash, "-C", "extra-filename=-" & hash,
    "--out-dir", outDir]
  # cargo passes one `-L dependency=` for its one deps directory; here each
  # unit has its own directory, so every unit of the closure is on the
  # search path (rustc finds an indirect dependency there by its hash).
  for c in closure:
    argv.add "-L"
    argv.add "dependency=" & c.outDir
  for d in externs:
    argv.add "--extern"
    argv.add d.name & "=" & d.edge.rmeta
  argv.add ["--cap-lints", "allow"]
  let difference = @[remapFlag(row, prefix)]

  var inputs = @[prefix / "Cargo.toml", prefix / m.libPath]
  var depIds: seq[string]
  for c in closure: inputs.add c.rmeta
  for d in externs: depIds.add d.edge.action.id
  var env = cargoCrateEnv(m, prefix)
  env.add extraEnv
  createDir(outDir)
  # cargo runs a dependency's rustc in the package's root.
  let compile = rustcUnitAction(registryCrateEdgeId(row, hash),
    argv & difference, cwd = prefix, deps = depIds, inputs = inputs,
    outputs = [rmeta, rlib], env = env,
    commandStatsId = RegistryCrateStatsId)
  RegistryCrateEdge(row: row, prefix: prefix, crateName: m.libName,
    metadataHash: hash, outDir: outDir, rmeta: rmeta, rlib: rlib,
    depInfo: outDir / (stem & ".d"), cargoArgv: argv,
    argvDifference: difference, closure: closure, action: compile)

# ---------------------------------------------------------------------------
# The unit from cargo's plan
# ---------------------------------------------------------------------------

type
  RegistryCrateUnit* = object
    ## One registry crate's unit as cargo planned it, with every path
    ## absolute on this host: what a record run of cargo recorded for the
    ## unit (`repro_cargo_edge/cargo_plan`), not what a caller decided.
    hash*: string
      ## cargo's own `-C extra-filename` value, without its `-`: the unit's
      ## name in the edge's id and directory.
    crateName*: string    ## the unit's `--crate-name`
    argv*: seq[string]
      ## cargo's rustc command line for the unit, rustc first
    cwd*: string          ## the directory cargo ran rustc in
    env*: seq[string]     ## the variables cargo set for it, `NAME=value`
    outDir*: string       ## its `--out-dir`
    outputs*: seq[string]
      ## every file its `--emit` writes, the dep-info file included
    deps*: seq[string]    ## the ids of the edges of the units it consumes
    inputs*: seq[string]  ## the files of those units it reads, in order
    scratchDirs*: seq[string]
      ## directories rustc keeps state in between runs (its incremental
      ## directory), emptied before each run and never evidence
    isolateHostEnvironment*: bool
      ## launch from `env` alone, nothing of the engine's environment

proc registryCrateUnitEdge*(row: CrateRow; storeRoot: string;
                            unit: RegistryCrateUnit): RegistryCrateEdge =
  ## The rustc edge of ``row`` for a unit cargo planned (see the module
  ## docstring, "The unit from cargo's plan"). The argv, working directory,
  ## environment and outputs are ``unit``'s; this proc checks them against
  ## the crate and adds the remap, so the edge differs from cargo's
  ## invocation by that one flag, as the caller-supplied form does.
  ##
  ## Raises `RegistryCrateRefusal` for a crate the store at ``storeRoot``
  ## ("" = the user's store root) does not hold (`rcrNotFetched`); whose
  ## manifest cannot be read; that needs a build script, a proc-macro,
  ## `links` or a crate type other than a Rust library
  ## (`refuseUnbuildable`); or for a unit that is not a compile of this
  ## crate's library from its prefix (`rcrUnit`): run elsewhere than in the
  ## prefix, under another crate name, without the crate root, with a remap
  ## of its own, or without both an rlib and an rmeta among its outputs.
  validateRow(row)
  let crate = row.label
  let prefix = block:
    var s = openStore(if storeRoot.len > 0: absolutePath(storeRoot)
                      else: resolveStoreRoot())
    defer: s.close()
    s.presentCratePrefix(row)
  if prefix.len == 0:
    refuse(rcrNotFetched, crate, "registry crate " & crate & " (sha256:" &
      row.cksum & ") is not in the store; its cargo.fetch edge must run " &
      "before its compile edge is built")
  let m = readCrateManifest(row, prefix)
  refuseUnbuildable(row, m)
  proc unitRefusal(why: string) {.noreturn.} =
    refuse(rcrUnit, crate, "registry crate " & crate & ": the planned unit " &
      unit.hash & " " & why)
  if unit.hash.len == 0 or not unit.hash.allCharsInSet(HexDigits):
    unitRefusal("has no hexadecimal unit hash")
  if unit.argv.len < 2: unitRefusal("has no rustc command line")
  # The prefix the store names is the one cargo ran in: the plan's prefix is
  # the same path when both come from this store root, as resolved paths.
  proc same(a, b: string): bool =
    a == b or (dirExists(a) and dirExists(b) and sameFile(a, b))
  if not same(unit.cwd, prefix):
    unitRefusal("runs in " & unit.cwd & ", not in the crate's prefix " &
      prefix)
  if unit.crateName != m.libName:
    unitRefusal("compiles crate " & unit.crateName & ", not the library " &
      m.libName & " of the manifest")
  var root = false
  for a in unit.argv[1 .. ^1]:
    if a.startsWith("--remap-path-prefix"):
      unitRefusal("already passes " & a)
    if a == m.libPath or a == prefix / m.libPath or a == unit.cwd / m.libPath:
      root = true
  if not root:
    unitRefusal("does not compile the crate root " & m.libPath)
  var rmeta, rlib, depInfo: string
  var declared: seq[string]
  for o in unit.outputs:
    if o.endsWith(".d"): depInfo = o
    else:
      declared.add o
      if o.endsWith(".rmeta"): rmeta = o
      elif o.endsWith(".rlib"): rlib = o
  if rmeta.len == 0 or rlib.len == 0:
    unitRefusal("does not write both an rlib and an rmeta")
  # The remap names the prefix as the argv spells it, which is the path
  # rustc writes into its outputs.
  let difference = @[remapFlag(row, unit.cwd)]
  createDir(unit.outDir)
  let compile = rustcUnitAction(registryCrateEdgeId(row, unit.hash),
    unit.argv & difference, cwd = unit.cwd, deps = unit.deps,
    inputs = unit.inputs, outputs = declared, env = unit.env,
    commandStatsId = RegistryCrateStatsId,
    isolateHostEnvironment = unit.isolateHostEnvironment,
    scratchDirs = unit.scratchDirs)
  RegistryCrateEdge(row: row, prefix: prefix, crateName: m.libName,
    metadataHash: unit.hash, outDir: unit.outDir, rmeta: rmeta, rlib: rlib,
    depInfo: depInfo, cargoArgv: unit.argv, argvDifference: difference,
    action: compile)
