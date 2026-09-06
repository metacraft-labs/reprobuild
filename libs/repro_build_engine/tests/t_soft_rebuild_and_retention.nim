## `Edge-Determinism-And-Soft-Rebuild.md` §3–§4: the determinism class must
## actually change what the cache does.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler in
## `repro_build_engine`, the real per-edge `ActionCache` in
## `repro_local_store`, real `/bin/sh` subprocesses, and real files in a real
## temporary directory. The property under test is that a class recorded on a
## cache entry changes a cache DECISION, and both halves of that sentence are
## production code; a fake executor or a stubbed cache would make it vacuous.
##
## The one thing that is injected is the CLOCK
## (`BuildEngineConfig.nowUnix`). That is not a mock of a collaborator: it is
## the alternative to `sleep`, which is what a retention test would otherwise
## have to do to cross a `max-age` boundary. The milestone's verification
## entry demands it in those words — "Uses an injected clock, not a real
## sleep."
##
## Out-of-band corroboration: every edge appends one line to its own log file
## on each execution, so "was re-run" is a fact about the filesystem and not
## the engine's bookkeeping agreeing with itself. Every assertion about a
## cache decision is paired with a line count.
##
## The graph is one edge of each class, all independent (no `deps`), because
## §1.4's composition rule would otherwise make the `strong` edge downstream
## of the `volatile` one `volatile` too — which is correct behaviour and the
## opposite of what these cases need to isolate.
##
## Governing spec text:
##   * §4.1 `--soft-rebuild`       — invalidate `volatile` only.
##   * §4.2 `--rebuild-host-bound` — invalidate `volatile` + `host-bound`.
##   * §4.3 `--hard-rebuild`       — invalidate every class.
##   * §4.4 no flag                — unchanged, EXCEPT that an expired
##                                   `volatile` entry becomes a miss.
##   * §4.5 `--only <pattern>`     — scope any of the three.

import std/[options, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("soft-rebuild-and-retention." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string

const
  ClassNames = ["strong", "weak", "hostbound", "volatile"]
  # 2024-01-01T00:00:00Z. A fixed base so every expiry assertion in this file
  # is a statement about arithmetic, not about when the suite happened to run.
  BaseNow = 1_704_067_200'i64
  VolatileMaxAgeSec = 3600'i64

proc lineCount(path: string): int =
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      inc result

proc logPathFor(f: Fixture; name: string): string =
  f.workRoot / "out" / (name & ".log")

proc runCount(f: Fixture; name: string): int =
  lineCount(f.logPathFor(name))

proc makeFixture(): Fixture =
  let root = createTempDir("repro-soft-rebuild-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  for name in ClassNames:
    writeFile(workRoot / "src" / (name & ".txt"), "seed-" & name & "\n")
    let script = workRoot / (name & ".sh")
    writeFile(script,
      "#!/bin/sh\n" &
      "echo ran >> out/" & name & ".log\n" &
      "cat src/" & name & ".txt > out/" & name & ".out\n" &
      # A depfile, for the same reason the neighbouring
      # `t_force_rebuild_is_honored_by_engine_api` fixture writes one: it
      # selects the legacy depfile gathering policy, so the edge does not
      # require a live io-monitor to complete. Without it every action here
      # ends `asFailed` and the whole file passes or fails on the wrong
      # thing.
      "printf '%s: %s\\n' out/" & name & ".out src/" & name & ".txt > out/" &
        name & ".dep\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(root: root, workRoot: workRoot, cacheRoot: root / "cache")

proc edge(f: Fixture; name: string; cls: EdgeDeterminism;
          retention = forever()): BuildAction =
  action("determinism/" & name, [f.workRoot / (name & ".sh")],
    cwd = f.workRoot,
    inputs = ["src/" & name & ".txt"],
    outputs = ["out/" & name & ".out"],
    depfile = "out/" & name & ".dep",
    cacheable = true,
    weakFingerprint = weak(name),
    actionCachePolicy = ffpTimestamp,
    determinism = some(cls),
    cacheRetention = retention,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc mixedGraph(f: Fixture;
                volatileRetention = forever()): BuildGraph =
  graph([
    f.edge("strong", edStrong),
    f.edge("weak", edWeak),
    f.edge("hostbound", edHostBound),
    f.edge("volatile", edVolatile, volatileRetention)])

proc warmConfig(f: Fixture; nowUnix = BaseNow): BuildEngineConfig =
  ## Exactly the mode `repro build` runs the engine in, including the
  ## whole-graph fast-no-op scan being eligible to fire — which is where the
  ## first version of this feature silently did nothing.
  result = defaultBuildEngineConfig(f.cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32
  result.nowUnix = nowUnix
  result.buildEpoch = "t-soft-rebuild-epoch-1"

proc warmUp(f: Fixture; g: BuildGraph; config: BuildEngineConfig) =
  ## Build once (cold) and once more (warm), leaving every edge cached and
  ## every log at exactly one line. Asserts the warm state rather than
  ## assuming it: without this, every "did not re-run" assertion below would
  ## also pass against an engine that never cached anything.
  discard runBuild(g, config)
  for name in ClassNames:
    doAssert f.runCount(name) == 1,
      name & " did not run exactly once on the cold build"
  let warm = runBuild(g, config)
  for name in ClassNames:
    doAssert not warm.byId("determinism/" & name).launched,
      name & " re-ran on the warm build; the fixture is not actually warm"
    doAssert f.runCount(name) == 1

suite "soft-rebuild consumption and volatile retention":

  test "t_soft_rebuild_invalidates_only_volatile":
    ## §4.1. Asserted by execution counts, not by log scraping.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.mixedGraph()
    let config = f.warmConfig()
    f.warmUp(g, config)

    var soft = f.warmConfig()
    soft.rebuildClass = rbSoft
    let res = runBuild(g, soft)

    for name in ["strong", "weak", "hostbound"]:
      let r = res.byId("determinism/" & name)
      checkpoint(name & ": decision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check not r.launched
      check r.cacheDecision == cdHit
      check f.runCount(name) == 1

    let vol = res.byId("determinism/volatile")
    checkpoint("volatile: decision=" & $vol.cacheDecision &
      " launched=" & $vol.launched & " reason=" & vol.reason)
    check vol.launched
    check vol.cacheDecision == cdMiss
    check f.runCount("volatile") == 2

    # ...and it is not sticky: the next ordinary run is a no-op again.
    let after = runBuild(g, config)
    for name in ClassNames:
      check not after.byId("determinism/" & name).launched
    check f.runCount("volatile") == 2

  test "t_rebuild_host_bound_invalidates_volatile_and_host_bound":
    ## §4.2, and §4.3 in the same fixture so the two verbs are compared
    ## against one warm state rather than two.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.mixedGraph()
    let config = f.warmConfig()
    f.warmUp(g, config)

    var hb = f.warmConfig()
    hb.rebuildClass = rbHostBound
    let res = runBuild(g, hb)

    for name in ["strong", "weak"]:
      check not res.byId("determinism/" & name).launched
      check res.byId("determinism/" & name).cacheDecision == cdHit
      check f.runCount(name) == 1
    for name in ["hostbound", "volatile"]:
      check res.byId("determinism/" & name).launched
      check res.byId("determinism/" & name).cacheDecision == cdMiss
      check f.runCount(name) == 2

    # `--hard-rebuild` re-runs all four.
    var hard = f.warmConfig()
    hard.rebuildClass = rbHard
    let hardRes = runBuild(g, hard)
    for name in ClassNames:
      check hardRes.byId("determinism/" & name).launched
      check hardRes.byId("determinism/" & name).cacheDecision == cdMiss
    check f.runCount("strong") == 2
    check f.runCount("weak") == 2
    check f.runCount("hostbound") == 3
    check f.runCount("volatile") == 3

  test "t_rebuild_only_selector_scopes_invalidation":
    ## §4.5. Two `volatile` edges; the selector names one. The OTHER
    ## `volatile` edge staying cached is the whole assertion — a selector
    ## that was ignored would re-run both and still look like a working
    ## `--soft-rebuild`.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = graph([
      f.edge("volatile", edVolatile),
      f.edge("hostbound", edVolatile)])   # a SECOND volatile edge
    let config = f.warmConfig()
    discard runBuild(g, config)
    discard runBuild(g, config)
    check f.runCount("volatile") == 1
    check f.runCount("hostbound") == 1

    var scoped = f.warmConfig()
    scoped.rebuildClass = rbSoft
    scoped.rebuildOnly = @["determinism/volatile"]
    let res = runBuild(g, scoped)

    check res.byId("determinism/volatile").launched
    check f.runCount("volatile") == 2
    check not res.byId("determinism/hostbound").launched
    check res.byId("determinism/hostbound").cacheDecision == cdHit
    check f.runCount("hostbound") == 1

    # A glob form of the same selector. `*` anchors the pattern, so this
    # also proves the anchored arm is reachable and does not accidentally
    # behave like the substring arm.
    var globbed = f.warmConfig()
    globbed.rebuildClass = rbSoft
    globbed.rebuildOnly = @["determinism/vol*"]
    discard runBuild(g, globbed)
    check f.runCount("volatile") == 3
    check f.runCount("hostbound") == 1

    # A selector that matches NOTHING invalidates nothing — the negative
    # control for the selector itself.
    var nomatch = f.warmConfig()
    nomatch.rebuildClass = rbHard
    nomatch.rebuildOnly = @["no-such-edge"]
    let noneRes = runBuild(g, nomatch)
    check not noneRes.byId("determinism/volatile").launched
    check not noneRes.byId("determinism/hostbound").launched
    check f.runCount("volatile") == 3
    check f.runCount("hostbound") == 1

  test "t_volatile_retention_expiry_is_a_miss":
    ## §4.4's one automatic invalidation, with NO flag passed and an
    ## injected clock. A hit before N seconds, a miss after.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = f.mixedGraph(volatileRetention = maxAge(VolatileMaxAgeSec))
    let config = f.warmConfig(nowUnix = BaseNow)
    f.warmUp(g, config)

    # One second inside the window: still a hit.
    let insideCfg = f.warmConfig(nowUnix = BaseNow + VolatileMaxAgeSec - 1)
    let inside = runBuild(g, insideCfg)
    checkpoint("inside window: " & inside.byId("determinism/volatile").reason)
    check not inside.byId("determinism/volatile").launched
    check inside.byId("determinism/volatile").cacheDecision == cdHit
    check f.runCount("volatile") == 1

    # One second past it: a miss, with no flag anywhere.
    let outsideCfg = f.warmConfig(nowUnix = BaseNow + VolatileMaxAgeSec + 1)
    let outside = runBuild(g, outsideCfg)
    let vol = outside.byId("determinism/volatile")
    checkpoint("outside window: decision=" & $vol.cacheDecision &
      " launched=" & $vol.launched & " reason=" & vol.reason)
    check vol.launched
    check vol.cacheDecision == cdMiss
    check f.runCount("volatile") == 2

    # The other three classes are untouched by the passage of time. This is
    # the negative control for retention: an implementation that expired
    # everything on a clock tick would pass the assertion above.
    for name in ["strong", "weak", "hostbound"]:
      check not outside.byId("determinism/" & name).launched
      check f.runCount(name) == 1

    # The re-run RESTAMPED the entry, so the same late clock is now inside
    # the fresh window. Without this the feature would re-run the edge on
    # every subsequent build forever, which is `no-store`, not `max-age`.
    let again = runBuild(g, outsideCfg)
    check not again.byId("determinism/volatile").launched
    check f.runCount("volatile") == 2

  test "t_default_build_semantics_unchanged":
    ## The campaign regression guard: `repro build` with no flag must behave
    ## for `strong` / `weak` / `host-bound` / fresh-`volatile` exactly as it
    ## did before any of this existed.
    let f = makeFixture()
    defer: removeDir(f.root)

    # Arm 1: every class labelled, `volatile` fresh under a long max-age.
    let g = f.mixedGraph(volatileRetention = maxAge(86_400))
    let config = f.warmConfig()
    f.warmUp(g, config)
    for i in 0 ..< 3:
      let res = runBuild(g, config)
      for name in ClassNames:
        check not res.byId("determinism/" & name).launched
        check res.byId("determinism/" & name).cacheDecision == cdHit
        check f.runCount(name) == 1

    # Arm 2: the UNLABELLED graph — the shape of every edge in the existing
    # recipe corpus, which declares no `determinism` at all. It must warm
    # and stay warm, and `--soft-rebuild` must leave it alone, because an
    # unlabelled edge is `weak` by §2.1 and `weak` is not volatile.
    let f2 = makeFixture()
    defer: removeDir(f2.root)
    let plain = graph([
      action("plain/edge", [f2.workRoot / "strong.sh"],
        cwd = f2.workRoot,
        inputs = ["src/strong.txt"],
        outputs = ["out/strong.out"],
        depfile = "out/strong.dep",
        cacheable = true,
        weakFingerprint = weak("plain"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())])
    let plainCfg = f2.warmConfig()
    discard runBuild(plain, plainCfg)
    check f2.runCount("strong") == 1
    check not runBuild(plain, plainCfg).byId("plain/edge").launched
    check f2.runCount("strong") == 1

    var soft = f2.warmConfig()
    soft.rebuildClass = rbSoft
    check not runBuild(plain, soft).byId("plain/edge").launched
    check f2.runCount("strong") == 1

    # ...but `--hard-rebuild` still reaches it, so "unlabelled" is not
    # "unreachable".
    var hard = f2.warmConfig()
    hard.rebuildClass = rbHard
    check runBuild(plain, hard).byId("plain/edge").launched
    check f2.runCount("strong") == 2

  test "the recorded entry carries class, host fingerprint and write time":
    ## §3's write column. The metadata must survive a round trip through the
    ## on-disk sidecar, or every decision above is being made from data the
    ## next process cannot read.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = [
      f.edge("strong", edStrong),
      f.edge("weak", edWeak),
      f.edge("hostbound", edHostBound),
      f.edge("volatile", edVolatile, maxAge(VolatileMaxAgeSec))]
    let g = graph(actions)
    let config = f.warmConfig()
    discard runBuild(g, config)

    # `<cacheRoot>/action-cache` is where the engine opens the per-edge
    # store (`warmActionCacheFor(sharedRoot / "action-cache")`), and the
    # weak fingerprint is read off the constructed action rather than
    # re-derived here -- `action()` mixes the environment and the governing
    # lock into it, and a test that re-derived the mix would be asserting
    # against its own copy of the keying rule instead of the engine's.
    var cache = openActionCache(f.cacheRoot / "action-cache", attachShm = false)
    defer: cache.closeShmTier()

    for i, cls in [edStrong, edWeak, edHostBound, edVolatile]:
      let name = ClassNames[i]
      let records = cache.loadPerEdgeRecords(actions[i].weakFingerprint)
      check records.len >= 1
      let meta = records[^1].determinism
      checkpoint(name & ": declared=" & $meta.declared & " class=" &
        $meta.class & " retention=" & $meta.retention &
        " host=" & meta.hostFingerprint)
      check meta.declared
      check meta.class == cls
      check meta.writeTimeUnix == BaseNow
      check meta.hostFingerprint.len > 0
      check meta.buildEpoch == "t-soft-rebuild-epoch-1"
      if cls == edVolatile:
        check meta.retention.kind == crkMaxAge
        check meta.retention.seconds == VolatileMaxAgeSec
      else:
        check meta.retention.kind == crkForever
