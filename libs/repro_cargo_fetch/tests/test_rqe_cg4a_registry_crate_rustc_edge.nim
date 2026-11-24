## The rustc edge of a registry crate compiles the crate from its store
## prefix, with the prefix remapped out of the rlib and the rmeta.
##
## Setup, shared by every case: real `.crate` files made by one `cargo
## package --workspace` (a private `CARGO_HOME`, offline) are served by the
## local HTTPS mirror and fetched into a private store root by the real
## `cargo.fetch` edges. `rqea` is a plain library; `rqeb` depends on `rqea`
## (a registry dependency in its published manifest) and calls it;
## `rqebuild` ships a `build.rs`; `rqepm` is a proc-macro crate. The rustc
## edges then run through the real engine, gathered by the graph-built
## monitor.
##
## What each case checks:
##
## * **The remap is in the edge's argv, record and key.** The edge's argv is
##   cargo's invocation (`cargoArgv`, which holds no remap) followed by
##   exactly `--remap-path-prefix=<prefix>=rqea-0.1.0`, where `<prefix>` is
##   the crate's prefix under the store root; the edge records that flag as
##   its one argv difference (`argvDifference`). The flag is in the key: the
##   same action without it, or with its prefix half naming another prefix,
##   has another weak fingerprint (control: the same action rebuilt with the
##   same argv has the same one); a crate with other bytes under the same
##   name and version gets another prefix, another flag and another key; and
##   once the remapped edge is cached, the same edge without the flag is not
##   a cache hit.
## * **The rlib and rmeta are path-free.** Under the dev profile (debuginfo
##   on) and the release profile, the engine's embedded-path scan
##   (`scanOutputForEmbeddedRoots`, the scan the cache runs over a record's
##   outputs: raw bytes, decompressed ELF sections and every `ar` member)
##   finds neither the store root's physical path nor the prefix in the rlib
##   or the rmeta. The dep-info file is not a declared output. Positive
##   control: the same unit compiled with cargo's argv alone (no remap)
##   yields an rlib and an rmeta in which the same scan finds the path, so
##   the scan can see an embedding.
## * **Dependencies flow through `--extern`.** `rqeb`'s edge depends on
##   `rqea`'s, passes `--extern rqea=<rqea's rmeta>` and puts `rqea`'s
##   output directory on its search path, and compiles (it calls
##   `rqea::a()`). Built again with nothing changed, both edges become cache
##   hits: a rustc compile reads unblessed entropy (its hash maps are
##   randomly seeded), so its first run is withheld from the cache, the
##   second run is the determinism probe that admits it when the outputs are
##   byte-identical, and from the third run on both edges are hits.
## * **Build scripts and proc-macros are refused, never half-built.** The
##   edge of `rqebuild` raises a refusal naming the crate and its build
##   script; the edge of `rqepm` one naming it a proc-macro crate; neither
##   leaves anything under the output root. A crate the store does not hold
##   and a feature the manifest does not declare are refused too.
##
## The compiler is the `rustc` on `PATH` (the dev shell's), not the
## store-root toolchain: realizing that toolchain takes about 1.6 GB of
## disk, which the hosts this suite runs on cannot spare for one test. What
## the remap removes depends on where the crate's sources are, not on where
## the compiler is, so the host compiler shows the same property. The case
## is skipped, with the reason, when there is no `rustc` or `cargo`.
##
## No mock: the production fetch, store and edge, the real engine and
## monitor, a real rustc and a real HTTPS server on loopback.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_build_engine/embedded_root_scan
import repro_core/ambient_execution
import repro_test_support
import repro_test_support/reasoned_skip

import ./crate_fixtures

type
  Setup = object
    ok: bool
    why: string
    cf: CrateFixture
    work, store, rustc: string
    rows: Table[string, CrateRow]
    config: BuildEngineConfig

proc fixturePackages(): seq[FixturePackage] =
  @[
    FixturePackage(name: "rqea", version: "0.1.0",
      files: @[("src/lib.rs",
        "pub fn a() -> u8 { if std::env::args().count() > 99 " &
        "{ panic!(\"too many\") } 1 }\n")]),
    FixturePackage(name: "rqeb", version: "0.1.0",
      manifestExtra: "\n[dependencies]\nrqea = { path = \"../rqea\", " &
        "version = \"0.1.0\" }\n",
      files: @[("src/lib.rs", "pub fn b() -> u8 { rqea::a() + 1 }\n")]),
    FixturePackage(name: "rqebuild", version: "0.1.0",
      files: @[("src/lib.rs", "pub fn c() {}\n"),
               ("build.rs", "fn main() {}\n")]),
    FixturePackage(name: "rqepm", version: "0.1.0",
      manifestExtra: "proc-macro = true\n",
      files: @[("src/lib.rs", "")])]

proc newSetup(): Setup =
  # The compiler and packager on PATH are the test's stand-ins for the
  # provisioned ones (see the header).
  result.rustc = uncontrolledFindExe("rustc")
  if result.rustc.len == 0 or uncontrolledFindExe("cargo").len == 0:
    result.why = "no rustc or cargo on PATH: the edge needs a compiler and " &
      "the fixture crates are made by cargo package"
    return
  result.cf = newCrateFixture("rustc-edge")
  result.work = createTempDir("cg4a-rustc-edge-", "")
  result.store = result.work / "store"
  let crates = packCrates(result.work, fixturePackages())
  var rows: seq[CrateRow]
  for name, bytes in crates:
    let row = CrateRow(name: name, version: "0.1.0", cksum: sha256Hex(bytes))
    result.cf.putOnHttpsMirror(row.cksum, bytes)
    result.rows[name] = row
    rows.add row
  let fetched = fetchLockedCrates(rows, result.cf.crateConfig(
    result.work / "state", result.store, @[result.cf.httpsMirror()]))
  doAssert fetched.ok, "fixture fetch failed"
  let tools = prepareMonitorTools(ReprobuildRepoRoot, result.work /
    "monitor", "cg4a-rustc-edge")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  result.config = BuildEngineConfig(
    cacheRoot: result.work / "engine-cache",
    runQuotaCliPath: tools.monitorCliPath,
    monitorCliPath: tools.monitorCliPath,
    monitorCliArgs: tools.monitorCliArgs,
    maxParallelism: 1'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    bypassRunQuota: true)
  result.ok = true

proc teardown(s: Setup) =
  if s.work.len > 0:
    removeTestTree(s.work)
    cleanup(s.cf)

proc rebuiltWithArgv(a: BuildAction; argv: seq[string]; id = ""): BuildAction =
  ## ``a`` constructed again by the engine's constructor with every field
  ## the edge sets, except the argv (and, when given, the id).
  action(if id.len > 0: id else: a.id, argv, cwd = a.cwd, deps = a.deps,
    inputs = a.inputs, outputs = a.outputs, pool = a.pool,
    commandStatsId = a.commandStatsId, cacheable = a.cacheable,
    actionCachePolicy = a.actionCachePolicy,
    dependencyPolicy = a.dependencyPolicy, env = a.env,
    governingLockIdentity = a.governingLockIdentity)

proc runOnce(s: Setup; actions: openArray[BuildAction]):
    Table[string, ActionResult] =
  let run = runBuild(graph(actions), s.config)
  for r in run.results:
    checkpoint(r.id & ": " & $r.status & " " & $r.cacheDecision & " " &
      r.reason & (if r.stderr.len > 0: "\nstderr: " & r.stderr else: ""))
    result[r.id] = r

proc scanFor(path: string; s: Setup; prefix: string): EmbeddedRootFinding =
  ## The cache's embedded-path scan of one output, for the store root and
  ## the crate's prefix (the prefix lies under the store root, so a finding
  ## names whichever comes first).
  scanOutputForEmbeddedRoots(path, [
    EmbeddedRootNeedle(label: "store", path: absolutePath(s.store)),
    EmbeddedRootNeedle(label: "crate prefix", path: prefix)])

let s = newSetup()

suite "registry crate rustc edge":
  test "the remap is the edge's one argv difference and is in its key":
    if not s.ok:
      skip(s.why)
    else:
      let row = s.rows["rqea"]
      let e = registryCrateEdge(row, s.store, s.rustc, s.work / "out-key",
        DevProfileArgs)
      check e.prefix.startsWith(absolutePath(s.store) / "prefixes" / "rqea" /
        "0.1.0-")
      let remap = "--remap-path-prefix=" & e.prefix & "=rqea-0.1.0"
      check e.argvDifference == @[remap]
      check e.action.argv == e.cargoArgv & @[remap]
      for a in e.cargoArgv:
        check not a.startsWith("--remap-path-prefix")
      check e.prefix / "src" / "lib.rs" in e.cargoArgv
      check e.action.networkMode == netDenied

      # In the key: the engine's own weak fingerprint, per argv.
      check rebuiltWithArgv(e.action, e.action.argv).weakFingerprint ==
        e.action.weakFingerprint
      check rebuiltWithArgv(e.action, e.cargoArgv).weakFingerprint !=
        e.action.weakFingerprint
      let otherPrefix = e.prefix & "-elsewhere"
      check rebuiltWithArgv(e.action, e.cargoArgv & @["--remap-path-prefix=" &
        otherPrefix & "=rqea-0.1.0"]).weakFingerprint !=
        e.action.weakFingerprint

      # Another crate under the same name and version: other bytes, so
      # another checksum, another prefix, another flag and another key.
      let other = packCrates(s.work / "other", @[FixturePackage(
        name: "rqea", version: "0.1.0",
        files: @[("src/lib.rs", "pub fn a() -> u8 { 2 }\n")])])["rqea"]
      let otherRow = CrateRow(name: "rqea", version: "0.1.0",
        cksum: sha256Hex(other))
      s.cf.putOnHttpsMirror(otherRow.cksum, other)
      check fetchLockedCrates(@[otherRow], s.cf.crateConfig(s.work /
        "state-other", s.store, @[s.cf.httpsMirror()])).ok
      let e2 = registryCrateEdge(otherRow, s.store, s.rustc, s.work /
        "out-key", DevProfileArgs)
      check e2.prefix != e.prefix
      check e2.argvDifference == @["--remap-path-prefix=" & e2.prefix &
        "=rqea-0.1.0"]
      check e2.action.weakFingerprint != e.action.weakFingerprint

      # And the engine keys on it: once the remapped edge is cached, the
      # same edge without the flag is not a hit.
      var last: ActionResult
      var statuses: seq[string]
      for i in 1 .. 3:
        let r = runOnce(s, [e.action])
        last = r[e.action.id]
        statuses.add $i & ": " & $last.status
        check last.status in {asSucceeded, asCacheHit}
      echo "    runs (rqea, remapped): " & statuses.join(", ")
      check last.status == asCacheHit
      let bare = rebuiltWithArgv(e.action, e.cargoArgv)
      let r = runOnce(s, [bare])
      check r[bare.id].status == asSucceeded
      check r[bare.id].launched

  test "the rlib and rmeta are free of the store path; without the remap they are not":
    if not s.ok:
      skip(s.why)
    else:
      let row = s.rows["rqea"]
      for (profile, args) in [("dev", @DevProfileArgs),
                              ("release", @ReleaseProfileArgs)]:
        checkpoint("profile " & profile)
        let e = registryCrateEdge(row, s.store, s.rustc, s.work / ("out-" &
          profile), args)
        let c = registryCrateEdge(row, s.store, s.rustc, s.work /
          ("out-control-" & profile), args)
        check e.action.outputs == @[e.rmeta, e.rlib]
        check e.depInfo notin e.action.outputs
        let control = rebuiltWithArgv(c.action, c.cargoArgv,
          c.action.id & "-no-remap")
        let r = runOnce(s, [e.action, control])
        require r[e.action.id].status == asSucceeded
        require r[control.id].status == asSucceeded
        check fileExists(e.depInfo)   # written, just not an output
        for output in [e.rlib, e.rmeta]:
          let f = scanFor(output, s, e.prefix)
          checkpoint(output & ": found=" & $f.found & " " & f.path & " " &
            f.where & " " & f.unscannable)
          check not f.found
          check f.unscannable.len == 0
        # Positive control: cargo's argv alone embeds the path.
        for output in [c.rlib, c.rmeta]:
          let f = scanFor(output, s, c.prefix)
          checkpoint(output & " (no remap): found=" & $f.found & " " &
            f.where)
          check f.found

  test "a dependency flows through --extern and both edges are cached":
    if not s.ok:
      skip(s.why)
    else:
      let outRoot = s.work / "out-chain"
      let a = registryCrateEdge(s.rows["rqea"], s.store, s.rustc, outRoot,
        DevProfileArgs)
      let b = registryCrateEdge(s.rows["rqeb"], s.store, s.rustc, outRoot,
        DevProfileArgs, deps = [externOf(a)])
      check b.action.deps == @[a.action.id]
      check a.rmeta in b.action.inputs
      let ext = b.action.argv.find("rqea=" & a.rmeta)
      check ext > 0 and b.action.argv[ext - 1] == "--extern"
      check "dependency=" & a.outDir in b.action.argv
      check b.closure.len == 1 and b.closure[0] == a
      check b.metadataHash != a.metadataHash
      var statuses: seq[string]
      var last: Table[string, ActionResult]
      for i in 1 .. 3:
        last = runOnce(s, [a.action, b.action])
        statuses.add $i & ": " & $last[a.action.id].status & "/" &
          $last[b.action.id].status
        check last[a.action.id].status in {asSucceeded, asCacheHit}
        check last[b.action.id].status in {asSucceeded, asCacheHit}
        if i == 1:
          check last[a.action.id].launched
          check last[b.action.id].launched
      # Printed, not only checkpointed: which run first hits is engine
      # behaviour worth seeing in a passing log.
      echo "    runs (rqea/rqeb): " & statuses.join(", ")
      check last[a.action.id].status == asCacheHit
      check last[b.action.id].status == asCacheHit
      check fileExists(b.rlib) and fileExists(b.rmeta)

  test "a build-script or proc-macro crate is refused before any action exists":
    if not s.ok:
      skip(s.why)
    else:
      let outRoot = s.work / "out-refused"
      try:
        discard registryCrateEdge(s.rows["rqebuild"], s.store, s.rustc, outRoot,
          DevProfileArgs)
        check false
      except RegistryCrateRefusal as e:
        checkpoint(e.msg)
        check e.reason == rcrBuildScript
        check e.crate == "rqebuild@0.1.0"
        check "registry crate rqebuild@0.1.0 has a build script (build.rs)" in
          e.msg
        check "not built as edges yet" in e.msg
      try:
        discard registryCrateEdge(s.rows["rqepm"], s.store, s.rustc, outRoot,
          DevProfileArgs)
        check false
      except RegistryCrateRefusal as e:
        checkpoint(e.msg)
        check e.reason == rcrProcMacro
        check "registry crate rqepm@0.1.0 is a proc-macro crate" in e.msg
      try:
        discard registryCrateEdge(s.rows["rqea"], s.store, s.rustc, outRoot,
          DevProfileArgs, features = ["nope"])
        check false
      except RegistryCrateRefusal as e:
        check e.reason == rcrFeature
      try:
        discard registryCrateEdge(CrateRow(name: "absent", version: "1.0.0",
          cksum: repeat('0', 64)), s.store, s.rustc, outRoot, DevProfileArgs)
        check false
      except RegistryCrateRefusal as e:
        check e.reason == rcrNotFetched
        check "absent@1.0.0" in e.msg
      # Never half-built: no unit directory was made for any of them.
      check not dirExists(outRoot)

teardown(s)
