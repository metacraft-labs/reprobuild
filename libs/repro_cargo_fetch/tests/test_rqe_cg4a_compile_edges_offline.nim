## With registry crate sources in the store, the edges that compile them
## declare no network and read nothing under `~/.cargo`; the fetch edges are
## the only ones that declare the network, and nothing they do reads or
## writes cargo's own state either.
##
## Setup: two real `.crate` files made by `cargo package` (with a private
## `CARGO_HOME`) are served by an HTTPS mirror. Then the test process's
## `HOME` and `CARGO_HOME` are pointed at two sentinel directories, and a
## canary crate is planted in both, the way cargo keeps a downloaded crate:
## the archive under `registry/cache/<index>/` and its sources under
## `registry/src/<index>/`. The canary is on no mirror and at no origin.
## Every file, directory and modification time under the sentinels is
## recorded.
##
## What it checks:
##
## * The `cargo.fetch` edges are `netFetch` with tracked destinations; the
##   compile edge is `netDenied` with none; the graph of both passes the
##   network audit.
## * The canary's fetch edge fails, naming the crate, although its exact
##   bytes sit in the planted registry cache (`test_cpc_cargo_home_canary_
##   never_resolves`, for the fetch edge: a crate that exists only under
##   `~/.cargo` is not found). The real crate is fetched into the store.
## * A monitored rustc edge (the engine's automatic monitor, the graph-built
##   shim) compiles the fetched crate from its store prefix with `HOME` and
##   `CARGO_HOME` set to the sentinels, and sends no request to any server.
##   The monitor saw it read the crate's `src/lib.rs` in the store prefix
##   (vacuity), and none of its reads, probes or directory listings lies
##   under either sentinel. Positive control: the same check over a second
##   monitored edge that compiles the canary from the planted
##   `registry/src` does name a sentinel path, so the check can see a read
##   of `~/.cargo`.
## * After everything, the sentinels hold exactly what was planted, with the
##   same modification times: nothing was created, removed or written.
##
## Network denial is checked as declared and audited, not enforced: the
## engine enforces `netDenied` statically (the audit), and runtime
## enforcement does not exist yet. What makes an online compile impossible
## here is that the compile edge is handed only store paths.
##
## Falsifying mutation, applied once by hand and reverted (see the change's
## report): letting the fetch edge look in `$CARGO_HOME/registry/cache`
## before the mirrors resolves the canary, and the canary check fails.
##
## No mock: the production fetch and store, the real engine, the graph-built
## monitor, a real rustc (the one on `PATH`; the case is skipped, with the
## reason, when there is none) and a real HTTPS server on loopback.

import std/[algorithm, os, strutils, tables, tempfiles, times, unittest]

import repro_build_engine
import repro_core/ambient_execution
from repro_core/dependency_gathering import automaticMonitorGatheringPolicy
import repro_core/input_check_policy
import repro_lock/identity
import repro_test_support
import repro_test_support/reasoned_skip

import ./crate_fixtures

const CratesIoIndexDir = "index.crates.io-1949cf8c6b5b557f"
  ## The directory name cargo gives crates.io's sparse index under
  ## `registry/cache` and `registry/src`.

proc snapshot(roots: openArray[string]): seq[string] =
  ## Every entry under ``roots`` with its kind, size and modification time.
  for root in roots:
    for p in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                             pcLinkToDir}):
      let info = getFileInfo(p, followSymlink = false)
      result.add p & " " & $info.kind & " " & $info.size & " " &
        $info.lastWriteTime.toUnixFloat()
  result.sort()

proc inside(path, root: string): bool =
  path == root or path.startsWith(root & "/")

proc sentinelAccesses(res: ActionResult; roots: openArray[string]):
    seq[string] =
  ## Every monitored access of ``res`` that lies under one of ``roots``.
  for group in [res.evidence.monitorReads, res.evidence.monitorProbes,
                res.evidence.monitorDirectoryEnumerations]:
    for p in group:
      for r in roots:
        if p.inside(r): result.add p

proc plantCanary(cargoDir, bytes: string) =
  ## A crate cargo would have downloaded: its archive and its sources.
  let cache = cargoDir / "registry" / "cache" / CratesIoIndexDir
  let src = cargoDir / "registry" / "src" / CratesIoIndexDir / "canary-1.0.0"
  createDir(cache)
  createDir(src / "src")
  writeFile(cache / "canary-1.0.0.crate", bytes)
  writeFile(src / "Cargo.toml", "[package]\nname = \"canary\"\n" &
    "version = \"1.0.0\"\nedition = \"2021\"\n")
  writeFile(src / "src" / "lib.rs", "pub fn canary() {}\n")

proc rustcEdge(id, rustc, crateName, source, outDir: string;
               env: seq[string]): BuildAction =
  action(id,
    @[rustc, "--crate-name", crateName, "--edition=2021", "--crate-type",
      "lib", "--emit=link", "--out-dir", outDir, source],
    cwd = outDir, inputs = @[source],
    outputs = @[outDir / ("lib" & crateName & ".rlib")], cacheable = true,
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(), env = env,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

suite "test_rqe_cg4a_compile_edges_offline":
  test "compile edges read store paths only, offline, and ~/.cargo is untouched":
    # The compiler on PATH is the test's stand-in for a provisioned one.
    let rustc = uncontrolledFindExe("rustc")
    if rustc.len == 0:
      skip("no rustc on PATH: the compile edge needs one")
    else:
      let cf = newCrateFixture("compile-offline")
      let work = createTempDir("cg4a-compile-offline-", "")
      let store = work / "store"
      let crateBytes = packCrate(work, "rqeoffline", "0.2.0",
        @[("src/lib.rs", "pub fn offline() -> u8 { 7 }\n")])
      let canaryBytes = packCrate(work, "canary", "1.0.0",
        @[("src/lib.rs", "pub fn canary() {}\n")])
      let row = CrateRow(name: "rqeoffline", version: "0.2.0",
        cksum: sha256Hex(crateBytes))
      let canary = CrateRow(name: "canary", version: "1.0.0",
        cksum: sha256Hex(canaryBytes))
      cf.putOnHttpsMirror(row.cksum, crateBytes)

      # From here on, cargo's state is two sentinels holding the canary.
      let sentinelHome = work / "sentinel-home"
      let sentinelCargo = work / "sentinel-cargo-home"
      plantCanary(sentinelHome / ".cargo", canaryBytes)
      plantCanary(sentinelCargo, canaryBytes)
      let savedHome = getEnv("HOME")
      let savedCargo = getEnv("CARGO_HOME")
      putEnv("HOME", sentinelHome)
      putEnv("CARGO_HOME", sentinelCargo)
      let sentinels = [sentinelHome, sentinelCargo]
      let before = snapshot(sentinels)
      check before.len > 0

      let fetched = fetchLockedCrates(@[canary, row],
        cf.crateConfig(work / "state", store, @[cf.httpsMirror()]))
      var byName = initTable[string, CrateFetch]()
      for c in fetched.crates: byName[c.row.name] = c
      # The canary exists only under ~/.cargo: not found, and named.
      check byName["canary"].state == csFailed
      check "canary@1.0.0" in byName["canary"].failureText()
      check cratePrefixDirs(store, "canary").len == 0
      # The real crate is in the store.
      check byName["rqeoffline"].state == csFetched
      let prefix = byName["rqeoffline"].prefix
      check prefix.inside(store)
      for a in fetched.actions:
        check a.networkMode == netFetch
        check a.netDestinations.len > 0

      let tools = prepareMonitorTools(ReprobuildRepoRoot, work / "monitor",
        "cg4a-compile-offline")
      putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
      let env = @["PATH=" & getEnv("PATH"), "HOME=" & sentinelHome,
        "CARGO_HOME=" & sentinelCargo]
      let outDir = work / "out"
      let controlDir = work / "control-out"
      createDir(outDir)
      createDir(controlDir)
      let compile = rustcEdge("rustc-lib-rqeoffline", rustc, "rqeoffline",
        prefix / "src" / "lib.rs", outDir, env)
      let control = rustcEdge("rustc-lib-canary-control", rustc, "canary",
        sentinelCargo / "registry" / "src" / CratesIoIndexDir /
          "canary-1.0.0" / "src" / "lib.rs", controlDir, env)
      # The compile edge declares no network, the fetch edges do, and the
      # graph holding both is coherent.
      check compile.networkMode == netDenied
      check compile.netDestinations.len == 0
      var whole = fetched.actions
      whole.add compile
      check auditNetworkPolicy(graph(whole)).len == 0

      let requestsBefore = cf.f.requests().len
      var config = BuildEngineConfig(
        cacheRoot: work / "engine-cache",
        runQuotaCliPath: tools.monitorCliPath,
        monitorCliPath: tools.monitorCliPath,
        monitorCliArgs: tools.monitorCliArgs,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        bypassRunQuota: true)
      let run = runBuild(graph([compile]), config)
      require run.results.len == 1
      let res = run.results[0]
      checkpoint(res.id & ": " & $res.status & "\nstderr: " & res.stderr)
      check res.status == asSucceeded
      check fileExists(outDir / "librqeoffline.rlib")
      check cf.f.requests().len == requestsBefore
      # Vacuity: the monitor entered rustc and saw the store-prefix read.
      var sawSource = false
      for p in res.evidence.monitorReads:
        if p == prefix / "src" / "lib.rs": sawSource = true
      check sawSource
      let touched = sentinelAccesses(res, sentinels)
      checkpoint("sentinel accesses of the compile edge: " & $touched)
      check touched.len == 0

      # Positive control: the same check sees a compile that reads ~/.cargo.
      let controlRun = runBuild(graph([control]), config)
      require controlRun.results.len == 1
      check controlRun.results[0].status == asSucceeded
      check sentinelAccesses(controlRun.results[0], sentinels).len > 0

      # Nothing under either sentinel was created, removed or written.
      check snapshot(sentinels) == before

      putEnv("HOME", savedHome)
      if savedCargo.len > 0: putEnv("CARGO_HOME", savedCargo)
      else: delEnv("CARGO_HOME")
      removeTestTree(work)
      cleanup(cf)
