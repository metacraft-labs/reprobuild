## ``BuildEngineConfig.forceRebuild = true`` must actually re-run the graph.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler in
## `repro_build_engine`, the real per-edge `ActionCache` in
## `repro_local_store`, real `/bin/sh` subprocesses and real files in a
## real temporary directory. The defect under test is a missing gate in
## the engine's own whole-graph short-circuit, so the short-circuit must
## be the production one; a fake executor or a stubbed cache would make
## the whole property vacuous.
##
## The defect: `tryFastNoopCacheHits` — the engine's whole-graph fast
## no-op scan — never consults `config.forceRebuild`. When the scan
## fires (the common warm case: `rebuildMissingOutputsOnCacheHit`,
## no progress callback, no publish-cached-results), it synthesizes
## `asCacheHit` / `cdHit` / `launched = false` for every action in the
## graph and returns before the scheduler — the only place
## `config.forceRebuild` is read — is ever entered.
##
## Why this was invisible from the CLI: `repro build --force-rebuild`
## installs a progress callback in every mode that renders progress, and
## the scan bails out on `progressCallback != nil`. So the flag works
## end-to-end while the engine API it is implemented on top of silently
## drops the request. Test 3 below pins exactly that asymmetry, so a
## future reader can see why "the CLI flag works" was never evidence
## that the engine honoured the field.
##
## Governing spec text:
##
## * `reprobuild-specs/Incremental-Invalidation.md` §"Forcing execution":
##   a forced build re-executes regardless of cache state.
## * `reprobuild-specs/Build-Engine-And-Scheduler.md` — the engine's
##   result fields report what the engine DID.
##
## Out-of-band corroboration: both edges append one line to a log file
## on every execution, so "was re-run" is a fact about the filesystem
## and not merely the engine's bookkeeping agreeing with itself.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("force-rebuild-engine-api." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  genLogPath: string
  probeLogPath: string
  genAction: BuildAction
  probeAction: BuildAction

proc lineCount(path: string): int =
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      inc result

proc makeFixture(): Fixture =
  let root = createTempDir("repro-force-rebuild-api-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / "seed.txt", "seed-generation-1\n")

  # Declares an OUTPUT. The report under fix said the fast scan swallows
  # `forceRebuild` for output-declaring edges too, not only zero-output
  # ones, so both shapes are in the graph.
  let gen = workRoot / "gen.sh"
  writeFile(gen,
    "#!/bin/sh\n" &
    "echo ran >> out/gen.log\n" &
    "cat src/seed.txt > out/gen.txt\n" &
    "printf '%s: %s\\n' out/gen.txt src/seed.txt > out/gen.dep\n")
  setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

  # Declares NO outputs — the `ct_test_nim_unittest.run` shape.
  let probe = workRoot / "probe.sh"
  writeFile(probe,
    "#!/bin/sh\n" &
    "echo ran >> out/probe.log\n" &
    "printf '%s: %s\\n' probe.stamp out/gen.txt > out/probe.dep\n")
  setFilePermissions(probe, {fpUserRead, fpUserWrite, fpUserExec})

  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    genLogPath: workRoot / "out" / "gen.log",
    probeLogPath: workRoot / "out" / "probe.log",
    genAction: action("force/generate", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/gen.txt"],
      depfile = "out/gen.dep",
      cacheable = true,
      weakFingerprint = weak("force/generate"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()),
    probeAction: action("force/probe", [probe],
      cwd = workRoot,
      deps = ["force/generate"],
      inputs = ["out/gen.txt"],
      outputs = [],
      depfile = "out/probe.dep",
      cacheable = true,
      weakFingerprint = weak("force/probe"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()))

proc buildGraphOf(f: Fixture): BuildGraph =
  graph([f.genAction, f.probeAction])

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs the engine in, and exactly the
  ## mode in which `tryFastNoopCacheHits` is eligible to fire.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32

suite "engine-API forceRebuild is honored":

  test "1. warm baseline: an unchanged graph runs nothing":
    # Not the property under test; it establishes that the warm state
    # test 2 forces out of really is a no-op state. Without it, test 2
    # would also pass against an engine that never caches anything.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.buildGraphOf()
    let config = warmConfig(f.cacheRoot)

    check runBuild(g, config).byId("force/generate").launched
    check lineCount(f.genLogPath) == 1
    check lineCount(f.probeLogPath) == 1

    let warm = runBuild(g, config)
    check not warm.byId("force/generate").launched
    check not warm.byId("force/probe").launched
    check lineCount(f.genLogPath) == 1
    check lineCount(f.probeLogPath) == 1

  test "2. forceRebuild = true re-runs both edges":
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.buildGraphOf()
    let config = warmConfig(f.cacheRoot)

    discard runBuild(g, config)
    discard runBuild(g, config)
    check lineCount(f.genLogPath) == 1
    check lineCount(f.probeLogPath) == 1

    var forced = warmConfig(f.cacheRoot)
    forced.forceRebuild = true
    let res = runBuild(g, forced)

    let gen = res.byId("force/generate")
    let probe = res.byId("force/probe")
    checkpoint("forced generate: status=" & $gen.status &
      " cacheDecision=" & $gen.cacheDecision &
      " launched=" & $gen.launched & " reason=" & gen.reason)
    checkpoint("forced probe: status=" & $probe.status &
      " cacheDecision=" & $probe.cacheDecision &
      " launched=" & $probe.launched & " reason=" & probe.reason)

    # The engine's own report.
    check gen.launched
    check probe.launched
    check gen.cacheDecision == cdMiss
    check probe.cacheDecision == cdMiss
    # `reason` is overwritten by the execution outcome once the edge runs
    # (`exit=0`), so the cache-skip note is not observable here; the
    # `cdMiss` decision above is the engine's record of the forced miss.
    check gen.status == asSucceeded
    check probe.status == asSucceeded

    # Out-of-band corroboration: the subprocesses really ran again.
    check lineCount(f.genLogPath) == 2
    check lineCount(f.probeLogPath) == 2

    # ... and forcing is not sticky: the next ordinary run is a no-op.
    let after = runBuild(g, config)
    check not after.byId("force/generate").launched
    check not after.byId("force/probe").launched
    check lineCount(f.genLogPath) == 2
    check lineCount(f.probeLogPath) == 2

  test "3. the same request through the progress-callback path already worked":
    ## `tryFastNoopCacheHits` bails out when a progress callback is
    ## installed, so this configuration reached the scheduler — the only
    ## place `config.forceRebuild` was ever read — even before the fix.
    ## It is recorded here so the two paths can never silently disagree
    ## about what `forceRebuild` means again.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.buildGraphOf()
    let config = warmConfig(f.cacheRoot)

    discard runBuild(g, config)
    discard runBuild(g, config)
    check lineCount(f.genLogPath) == 1

    var forced = warmConfig(f.cacheRoot)
    forced.forceRebuild = true
    var events = 0
    forced.progressCallback = proc(event: BuildProgressEvent) =
      inc events
    let res = runBuild(g, forced)
    check events > 0
    check res.byId("force/generate").launched
    check res.byId("force/probe").launched
    check lineCount(f.genLogPath) == 2
    check lineCount(f.probeLogPath) == 2
