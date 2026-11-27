## The `cargo.fetch` edges of a crates.io workspace built from cargo's plan
## run in `repro build`'s own graph, and a crate whose store prefix is gone
## is fetched again before anything reads it.
##
## THE CONTRACT. Graph production for such a workspace is edges
## (`rust_plan_mode`): one `cargo.fetch/<name>@<version>` edge per locked
## crate, a `bakSourceFetch` edge the engine runs through the executor
## `repro build` registers for its run (`runProjectGraph`,
## `repro_cargo_fetch.crateFetchSourceExecutor`). Not inside a nested engine
## at evaluation time, as before, where the fetch was outside the build's
## graph and leasing. The edge is not cacheable in a project build: it runs
## every build, contacts nothing when the store holds the prefix, and fetches
## a prefix the store lost, so a reused graph never hands the plan edge a
## prefix that is not there.
##
## THE CASES.
## 1. `repro build` of the fixture workspace (switch on): each fetch edge is
##    in the build's report, launched and succeeded; the plan edge and the
##    unit edges run; the workspace's binary prints what cargo's would. The
##    later builds run the fetch edges again (not cacheable), and the third
##    serves the plan edge and the library units from the cache (the second
##    is the determinism probe's run for edges that draw entropy).
## 2. The engine running the fetch edge `repro build` lowers
##    (`crateFetchAction`, not cacheable) through the executor it registers:
##    with the prefix present it is found in the store; with the prefix
##    removed it is fetched again from the configured mirror. With no
##    executor registered the edge fails, naming the missing registration.
##
## Falsifying mutation: `runProjectGraph` not registering the executor fails
## case 1 (the fetch edges raise "requires a registerSourceFetchExecutor").
##
## MOCK POLICY: NO MOCKS. The real CLI and engine, real `.crate` files made
## by `cargo package`, a file mirror (a directory laid out as a mirror is),
## a real store root.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cargo_fetch
import repro_test_support

import ./rqe_cg5_mode_a_support
import ./rqe_cg5_plan_fixture
import ./rqe_cg5_repro_build_support

proc findBinary(dir, stem: string): string =
  for path in walkDirRec(dir, yieldFilter = {pcFile}):
    let name = path.extractFilename
    if name.startsWith(stem & "-") and not name.contains('.') and
        fpUserExec in getFilePermissions(path):
      return path

suite "cargo.fetch edges run in repro build":

  test "repro build runs the fetch edges, the plan and the units":
    let work = createTempDir("rqe-cg5-fetch-", "")
    defer: removeTestTree(work)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    lockWorkspace(ws, work, reg)
    let env = reproBuildEnv(work, reg)
    let first = reproBuild(env, ws)
    checkpoint first.describe
    require first.code == 0
    let fetches = first.idsWithPrefix("cargo.fetch/")
    # One per crate the workspace locks: `regleaf` and `regmid` (the
    # fixture's registry also holds `regbs`, which this workspace does not
    # use).
    check fetches.len == 2
    for id in fetches:
      check first.action(id){"status"}.getStr() == "asSucceeded"
      check first.action(id){"launched"}.getBool()
    check first.launchedIds("cargo.plan/").len == 1
    check first.launchedIds("cargo.rustc/").len > 0
    let app = findBinary(ws / ".repro" / "build" / "cargo-units", "app")
    require app.len > 0
    check execCmdEx(app).output.strip() == "util:5 51"

    # cargo and rustc draw entropy (hash-map seeds), so their edges are
    # recorded only once the determinism probe has seen a second run with
    # the same inputs give the same outputs: the third build is the first
    # one an unchanged edge can be served in. A binary's link edge never
    # passes the probe: rustc links through a temporary directory with a
    # random name, which the monitor records as a read, so two runs never
    # have the same inputs. Only the library units are expected to be
    # served.
    var later: BuildOutcome
    for round in 2 .. 3:
      later = reproBuild(env, ws)
      checkpoint later.describe
      require later.code == 0
      # Not cacheable in a project build: each fetch edge runs every time,
      # and contacts nothing while the store holds the prefix.
      for id in later.idsWithPrefix("cargo.fetch/"):
        check later.action(id){"status"}.getStr() == "asSucceeded"
        check later.action(id){"launched"}.getBool()
    check later.launchedIds("cargo.plan/").len == 0
    for id in later.idsWithPrefix("cargo.rustc/"):
      if "--crate-type" in unitRecords(ws).filterIt(it.id == id)[0].argv and
          "lib" in unitRecords(ws).filterIt(it.id == id)[0].argv:
        checkpoint id
        check not later.action(id){"launched"}.getBool()

  test "the fetch edge finds a present prefix and refetches a removed one":
    let work = createTempDir("rqe-cg5-refetch-", "")
    defer: removeTestTree(work)
    let reg = setupRegistry(work, smReal)
    let row = reg.rows[0]
    var cfg = defaultCrateFetchConfig(work / "state",
      @[parseMirror(work / "mirror")])
    cfg.storeRoot = reg.store
    cfg.originBase = ""
    let receipt = work / "receipts" / "leaf.receipt"
    let edge = crateFetchAction(row, cfg, receipt, cacheable = false)
    proc build(): BuildRunResult =
      var config = defaultBuildEngineConfig(work / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 1
      runBuild(graph([edge]), config)
    registerSourceFetchExecutor(CrateFetchEdgePrefix,
      crateFetchSourceExecutor())
    block present:
      let res = build()
      check res.results[0].status == asSucceeded
      check "state present store" in readFile(receipt)
    block removed:
      let prefix = cratePrefixPath(reg.store, row)
      require dirExists(prefix)
      for p in walkDirRec(prefix, yieldFilter = {pcDir}):
        setFilePermissions(p, getFilePermissions(p) + {fpUserWrite})
      setFilePermissions(prefix, getFilePermissions(prefix) + {fpUserWrite})
      removeDir(prefix)
      let res = build()
      check res.results[0].status == asSucceeded
      check "state fetched mirror" in readFile(receipt)
      check fileExists(prefix / "Cargo.toml")
    clearSourceFetchExecutor(CrateFetchEdgePrefix)
    # Fail closed: with no executor for its prefix the edge fails, naming
    # what is missing, and fetches nothing.
    let none = build()
    check none.results[0].status == asFailed
    check "registerSourceFetchExecutor" in
      (none.results[0].stderr & none.results[0].reason)
