## Test support (not a test): registry crates compiled by the store-root
## Rust toolchain, through the real engine and monitor, with the logical
## roots `repro build` declares, so each edge gets the engine's own portable
## verdict.
##
## The toolchain is the catalog's pinned Linux x86_64 `rustc` arm, realized
## by the engine's tarball realizer (`resolveTarballTool`) and relocated onto
## the loader and C library of the catalog's `gcc` realization in the same
## tool store. Realizing it takes about 1.6 GB, so it is realized once into
## a store root that survives between runs and is shared with the other
## store-root Rust test (`t_store_root_rustc_links_through_the_store_root_c_driver`):
## `REPRO_CONFORMANCE_STORE` when set, else `build/test-store/store-root-rustc`
## in this checkout. The first run on an empty store downloads the Rust
## release, the C toolchain and `patchelf`, each checked against its pinned
## SHA-256.
##
## The fixture crates are real `.crate` files made by `cargo package`,
## served by the loopback HTTPS mirror and fetched by the real `cargo.fetch`
## edges into a crate store INSIDE that store root, so the crate prefixes,
## the toolchain and its C library all lie under the one `store` logical
## root, as they do under a user's store root. The crate store is private to
## one test run and removed with it; the toolchain is kept.
##
## The session must not run under a command tracer preloaded into every
## process (`LD_PRELOAD`): the engine passes the environment on to the
## actions, the tracer's library lies outside every logical root, and so
## every record of such a session is non-portable, which these tests would
## report as a failure. The engine's own monitor shim is preloaded too; the
## engine leaves it out of the inputs by its own rule. Removing the variable
## in this process does not help: such a tracer is already loaded here and
## puts itself back into every child at exec time. So `newCrateRun` skips,
## naming the library, when anything but the monitor shim is preloaded, and
## these tests are run from a shell without the tracer (a plain login).

import std/[os, strutils, tables, tempfiles]

import repro_build_engine
import repro_build_engine/embedded_root_scan
import repro_core/ambient_execution
import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
# Imported for its effect: it registers every catalog package with a tarball
# arm, `rustc` and `gcc` among them.
import repro_dsl_stdlib/catalog_tarball_packages
import repro_test_support

import ./crate_fixtures

export crate_fixtures, embedded_root_scan, repro_build_engine

const
  StoreRootRustVersion* = "1.94.0"
    ## The stdlib's default release, the arm a plain `uses: "rustc"` takes.
  OutsideRoots* = "outside every logical root"
    ## The engine's reason for an input under no logical root
    ## (`computePortableFingerprint`).
  PortableEvent* = "portable-fingerprint"
  NotPortableEvent* = "portable-fingerprint-unavailable"
    ## The trace events `finishPortableRecord` writes for its verdict.

type
  Realized* = object
    prefix*, executable*: string

  StoreRootRust* = object
    ## A store root holding the relocated toolchain.
    storeRoot*: string
    rustc*, gcc*: Realized

  CrateRun* = object
    ## One fixture's crates fetched into a crate store under the store root,
    ## and an engine configured with the logical roots of a project there.
    ok*: bool
    why*: string
    tc*: StoreRootRust
    cf*: CrateFixture
    base*, project*, work*, crateStore*: string
    rows*: Table[string, CrateRow]
    config*: BuildEngineConfig

  EdgeRun* = object
    ## What one engine run said about one edge.
    result*: ActionResult
    trace*: seq[string]   ## `<event> <detail>` for this edge, in order

proc toolUseFor(packageName: string): InterfaceToolUse =
  ## The tool use a recipe declaring `uses: "<packageName>"` gets, from the
  ## registered stdlib package.
  doAssert CatalogTarballModules.len > 0
  let iface = toProjectInterface(PackageDef(
    packageName: "storeRootRegistryCrate",
    nativeBuildDeps: @[PackageUseDef(rawConstraint: packageName,
      packageSelector: packageName, executableName: packageName,
      depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1
  iface.toolUses[0]

proc realize(packageName, version, storeRoot: string): Realized =
  ## The package's Linux x86_64 arm of `version` (any when empty), realized
  ## through the engine's tarball realizer into `<storeRoot>/tool-store`.
  var use = toolUseFor(packageName)
  var chosen: seq[InterfaceTarballProvisioning]
  for arm in use.tarballProvisioning:
    if armMatchesTarget(arm, "linux", "x86_64") and
        (version.len == 0 or arm.detail.version == version):
      chosen.add(arm)
  doAssert chosen.len > 0, "no Linux x86_64 arm of " & packageName
  use.tarballProvisioning = @[chosen[0]]
  let profile = resolveTarballTool(use, storeRoot / "tool-store")
  Realized(prefix: profile.selectedStorePath,
    executable: profile.resolvedExecutablePath)

proc inside*(path, root: string): bool =
  ## Whether `path` lies in `root`. The monitor reports paths as the program
  ## spelled them (`<gcc>/bin/../lib/...`), so both are normalized first.
  let p = normalizedPath(path)
  let r = normalizedPath(root).strip(leading = false, chars = {'/'})
  p == r or p.startsWith(r & "/")

proc storeRootRust*(): StoreRootRust =
  ## The relocated store-root toolchain, realized on first use.
  let root = absolutePath(getEnv("REPRO_CONFORMANCE_STORE",
    ReprobuildRepoRoot / "build" / "test-store" / "store-root-rustc"))
  createDir(root)
  StoreRootRust(storeRoot: root,
    gcc: realize("gcc", "", root),
    rustc: realize("rustc", StoreRootRustVersion, root))

proc foreignPreload*(): string =
  ## The first library in `LD_PRELOAD` that is not the engine's monitor shim,
  ## or "" when there is none. The variable is a list separated by colons or
  ## spaces (ld.so(8)).
  for entry in getEnv("LD_PRELOAD").split({':', ' '}):
    if entry.len > 0 and
        not extractFilename(entry).startsWith("librepro_monitor_shim"):
      return entry

proc newCrateRun*(name: string; packages: seq[FixturePackage]): CrateRun =
  ## `packages` packed, served and fetched into a crate store under the
  ## store root; an engine whose portable roots are those `repro build`
  ## declares for a project with that store (`declaredFilesystemRoots`).
  ## Not `ok` (with the reason) where the toolchain is not relocated or
  ## the fixture tool is missing.
  when not (defined(linux) and defined(amd64)):
    result.why = "the catalog relocates the Rust toolchain on Linux x86_64 only"
    return
  else:
    let preload = foreignPreload()
    if preload.len > 0:
      result.why = "a library other than the monitor shim is preloaded " &
        "into this session (" & preload & "); every process the engine " &
        "starts reads it from outside every logical root, so no record can " &
        "be portable here. Run these tests from a shell without it"
      return
    # The fixture tool that makes real crates, not something under test.
    if uncontrolledFindExe("cargo").len == 0:
      result.why = "no cargo on PATH: the fixture crates are made by " &
        "cargo package"
      return
    result.tc = storeRootRust()
    let scratch = ReprobuildRepoRoot / "build" / "test-tmp" / name
    createDir(scratch)
    result.base = createTempDir("run-", "", scratch)
    result.project = result.base / "project"
    result.work = result.base / "work"
    createDir(result.project)
    createDir(result.work)
    result.crateStore = createTempDir("crate-store-" & name & "-", "",
      result.tc.storeRoot)
    result.cf = newCrateFixture(name)
    let crates = packCrates(result.work, packages)
    var rows: seq[CrateRow]
    for p in packages:
      let bytes = crates[p.name]
      let row = CrateRow(name: p.name, version: p.version,
        cksum: sha256Hex(bytes))
      result.cf.putOnHttpsMirror(row.cksum, bytes)
      result.rows[p.name] = row
      rows.add row
    let fetched = fetchLockedCrates(rows, result.cf.crateConfig(
      result.work / "fetch-state", result.crateStore,
      @[result.cf.httpsMirror()]))
    doAssert fetched.ok, "fixture fetch failed"
    let tools = prepareMonitorTools(ReprobuildRepoRoot, result.base /
      "monitor", name)
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    result.config = BuildEngineConfig(
      cacheRoot: result.base / "engine-cache",
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true)
    result.config.portableRoots = declaredFilesystemRoots(result.project,
      result.work, storeRoot = result.tc.storeRoot,
      outRoot = result.project / "out")
    result.ok = true

proc outRoot*(r: CrateRun; name: string): string =
  ## A unit output root inside the project's `out` root.
  r.project / "out" / name

proc teardown*(r: CrateRun) =
  ## Remove the run's tree and its crate store; the toolchain stays.
  if r.base.len > 0:
    removeTestTree(r.base)
    removeTestTree(r.crateStore)
    cleanup(r.cf)

proc runOnce*(r: CrateRun; actions: openArray[BuildAction]):
    Table[string, EdgeRun] =
  ## One engine run of ``actions``; per edge, its result and its trace.
  let run = runBuild(graph(actions), r.config)
  for res in run.results:
    var e = EdgeRun(result: res)
    for entry in run.trace:
      if entry.actionId == res.id:
        e.trace.add(entry.event & " " & entry.detail)
    result[res.id] = e

proc verdict*(e: EdgeRun): string =
  ## The edge's portable-verdict trace line of this run, "" if it has none
  ## (the run recorded nothing).
  for line in e.trace:
    if line.startsWith(PortableEvent & " ") or
        line.startsWith(NotPortableEvent & " "):
      return line
  ""

proc trackedNeedles*(r: CrateRun): seq[EmbeddedRootNeedle] =
  ## Every tracked logical root's physical path: the needles the cache's D4
  ## scan uses for a record's outputs (`embeddedRootReason`).
  for root in r.config.portableRoots:
    if root.kind == lrkTracked and root.path.len > 0:
      result.add EmbeddedRootNeedle(label: root.label, path: root.path)

proc rebuiltWithArgv*(a: BuildAction; argv: seq[string]; id = ""):
    BuildAction =
  ## ``a`` constructed again by the engine's constructor with every field
  ## the registry crate edge sets, except the argv (and, when given, the id).
  action(if id.len > 0: id else: a.id, argv, cwd = a.cwd, deps = a.deps,
    inputs = a.inputs, outputs = a.outputs, pool = a.pool,
    commandStatsId = a.commandStatsId, cacheable = a.cacheable,
    actionCachePolicy = a.actionCachePolicy,
    dependencyPolicy = a.dependencyPolicy, env = a.env,
    governingLockIdentity = a.governingLockIdentity)
