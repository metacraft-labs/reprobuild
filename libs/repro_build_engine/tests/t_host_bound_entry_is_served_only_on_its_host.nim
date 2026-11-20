## `Edge-Determinism-And-Soft-Rebuild.md` §3 and §3.2 rule 4: a `host-bound`
## or `volatile` cache entry is a realization of ONE host, and a local read
## serves it only on that host.
##
## The attack this protects against
## (reprobuild-pm `issues/2026-11-17-a-host-bound-entry-is-served-on-another-host-when-its-cache-records-are-copied.md`):
## §3 forbids substituting a `host-bound` realization on another machine, but
## that rule used to be enforced only by the publishers (§10.3, §10.4). A cache
## record also reaches another machine WITHOUT being published -- in a store
## bundle (`repro store export | import`, which carries the `.det` sidecar
## byte for byte, Store-Bundles.md §2 item 1), in an rsync'd or CI-restored
## cache root, or in a cache root baked into a runner image. There the entry
## was an ordinary local hit, because nothing compared the host fingerprint it
## recorded with the host reading it. And a record installed from a peer or
## binary cache carries no class at all, so an edge that is itself
## `host-bound` was served another host's bytes as its own.
##
## How "another host" is produced. The fingerprint is the reading process's
## own (`hostFingerprint()`: machine-id, hostname, OS, architecture), so a
## test cannot change the reader. It changes the WRITER instead: the warmed
## cache root is copied to a fresh root -- the copy a bundle import, an rsync
## or an image bake makes -- and in the copy the host fingerprint recorded in
## each `.det` sidecar is overwritten with another host's, of the same length
## so the sidecar's framing is untouched. That is exactly what a copy made on
## another machine carries; nothing else in the copy differs. The second arm
## removes the sidecar instead, which is what a record installed from a peer
## or a binary cache looks like (§3.2 rule 3: it records no class). A third
## and a fourth relabel the edge `strong` and unlabelled (§3.2 rule 1: the
## use is still the recorded `host-bound`; rule 3: the re-run's record must
## not inherit the other host's sidecar). A `ffpHybrid` edge whose sidecar is
## gone must miss rather than abort the build. The last suite drives the
## whole-graph fast-no-op prefix through BOTH of its arms (the navigator scan
## `repro build` takes by default, `skipCacheHitEvidence`, and the
## per-record arm), which answer for the whole graph without a per-edge
## lookup and so check the host themselves (`servableOnThisHost`); each must
## give its fast path back once the re-run has recorded this host, and must
## refuse another host's recorded `host-bound` entry to an edge relabelled
## weaker. Its last case breaks a sidecar's back-reference: a stale sidecar
## vouches for nothing.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real per-edge
## `ActionCache`, real `/bin/sh` subprocesses and real files. Editing the
## sidecar bytes is the attacker's (or the copier's) action, not a stub of a
## collaborator. The clock is injected (`BuildEngineConfig.nowUnix`) so the
## `volatile` edge's `max-age` window is arithmetic, not a sleep.
##
## Out-of-band corroboration: every edge appends a line to its own log on each
## execution, so "was re-run" is a fact about the filesystem.

import std/[options, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store

const
  ClassNames = ["strong", "hostbound", "volatile"]
  BaseNow = 1_704_067_200'i64      ## 2024-01-01T00:00:00Z
  VolatileMaxAgeSec = 86_400'i64   ## fresh for every read below

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("host-bound-entry-host." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc traceText(res: BuildRunResult): string =
  ## The scheduler trace, one `<action id> <event>: <detail>` per line. A
  ## launched action's `reason` is its exit status, so WHY its cache entry
  ## was refused is asserted here.
  for event in res.trace:
    result.add(event.actionId & " " & event.event & ": " & event.detail & "\n")

proc runCount(f: Fixture; name: string): int =
  let path = f.workRoot / "out" / (name & ".log")
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      inc result

proc makeFixture(): Fixture =
  let root = createTempDir("repro-host-bound-host-", "")
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
      # A depfile selects the legacy gathering policy, so the edge needs no
      # live io-monitor (as in `t_soft_rebuild_and_retention`).
      "printf '%s: %s\\n' out/" & name & ".out src/" & name & ".txt > out/" &
        name & ".dep\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(root: root, workRoot: workRoot, cacheRoot: root / "cache")

proc edge(f: Fixture; name: string; cls: EdgeDeterminism;
          retention = forever();
          policy = ffpTimestamp): BuildAction =
  action("host/" & name, [f.workRoot / (name & ".sh")],
    cwd = f.workRoot,
    inputs = ["src/" & name & ".txt"],
    outputs = ["out/" & name & ".out"],
    depfile = "out/" & name & ".dep",
    cacheable = true,
    weakFingerprint = weak(name),
    actionCachePolicy = policy,
    determinism = some(cls),
    cacheRetention = retention,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc unlabelledEdge(f: Fixture; name: string): BuildAction =
  ## §2.1's unlabelled edge: no class of its own, so it writes no sidecar.
  action("host/" & name, [f.workRoot / (name & ".sh")],
    cwd = f.workRoot,
    inputs = ["src/" & name & ".txt"],
    outputs = ["out/" & name & ".out"],
    depfile = "out/" & name & ".dep",
    cacheable = true,
    weakFingerprint = weak(name),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc edges(f: Fixture): seq[BuildAction] =
  @[f.edge("strong", edStrong),
    f.edge("hostbound", edHostBound),
    f.edge("volatile", edVolatile, maxAge(VolatileMaxAgeSec))]

proc config(cacheRoot: string): BuildEngineConfig =
  ## The mode `repro build` runs the engine in, with the whole-graph
  ## fast-no-op scan eligible to fire.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32
  result.nowUnix = BaseNow
  result.buildEpoch = "t-host-bound-epoch-1"

proc warm(f: Fixture; g: BuildGraph) =
  ## Cold build, then a warm one that launches nothing: without this every
  ## "re-ran" assertion below would also pass against a cache that never hit.
  discard runBuild(g, config(f.cacheRoot))
  let again = runBuild(g, config(f.cacheRoot))
  for name in ClassNames:
    doAssert f.runCount(name) == 1, name & " did not run exactly once cold"
    doAssert not again.byId("host/" & name).launched,
      name & " re-ran on the warm build; the fixture is not warm"

proc copyRoot(f: Fixture; tag: string): string =
  ## The copy a bundle import, an rsync or an image bake makes: same paths
  ## for the workspace, the action cache at a root of its own.
  result = f.root / ("cache-copy-" & tag)
  copyDir(f.cacheRoot, result)

proc detFor(cacheRoot: string; a: BuildAction): string =
  ## The edge's one `.det` sidecar in `cacheRoot`'s per-edge directory.
  var cache = openActionCache(cacheRoot / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  let records = cache.loadPerEdgeRecords(a.weakFingerprint)
  doAssert records.len == 1, a.id & ": expected one record"
  let dir = cacheRoot / "action-cache" / "hot-records"
  for kind, edgeDir in walkDir(dir):
    if kind != pcDir: continue
    for k, path in walkDir(edgeDir):
      if k == pcFile and path.extractFilename ==
          determinismFileName(digestHex(records[0].strongFingerprint)):
        return path
  raise newException(ValueError, a.id & ": no .det sidecar")

proc recordedHost(cacheRoot: string; a: BuildAction): string =
  var cache = openActionCache(cacheRoot / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  let records = cache.loadPerEdgeRecords(a.weakFingerprint)
  if records.len == 0: "" else: records[^1].determinism.hostFingerprint

proc otherHost(own: string): string =
  ## A fingerprint of the same length naming another machine.
  result = own
  for i in 0 ..< result.len:
    if result[i] in {'0' .. '9', 'a' .. 'z', 'A' .. 'Z'}:
      result[i] = (if result[i] == 'q': 'r' else: 'q')

proc forgeHost(cacheRoot: string; a: BuildAction) =
  let path = detFor(cacheRoot, a)
  let own = hostFingerprint()
  let raw = readFile(path)
  doAssert raw.count(own) == 1, a.id & ": sidecar does not name this host once"
  writeFile(path, raw.replace(own, otherHost(own)))
  doAssert recordedHost(cacheRoot, a) == otherHost(own),
    a.id & ": the forged sidecar no longer decodes"

suite "a host-bound or volatile entry is served only on its own host":

  test "a copied cache root does not serve another host's host-bound or volatile realization":
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = f.edges()
    let g = graph(actions)
    f.warm(g)

    let copy = f.copyRoot("other-host")
    for a in actions:
      forgeHost(copy, a)

    let res = runBuild(g, config(copy))
    let strong = res.byId("host/strong")
    checkpoint("strong: decision=" & $strong.cacheDecision & " reason=" &
      strong.reason)
    # Negative control: a `strong` entry is canonical everywhere (§3), so
    # the forged fingerprint changes nothing for it.
    check not strong.launched
    check f.runCount("strong") == 1
    for name in ["hostbound", "volatile"]:
      let r = res.byId("host/" & name)
      checkpoint(name & ": decision=" & $r.cacheDecision & " launched=" &
        $r.launched & " reason=" & r.reason)
      check r.launched
      check r.cacheDecision == cdMiss
      # The miss is the host check's, not some other effect of the forgery.
      check ("host/" & name & " cache-other-host: cached entry is another " &
        "host's") in res.traceText
      check f.runCount(name) == 2
      # The re-run is this host's realization, and records this host.
      check recordedHost(copy, actions[ClassNames.find(name)]) ==
        hostFingerprint()

    # ...and the re-run is served here from now on.
    let after = runBuild(g, config(copy))
    for name in ClassNames:
      check not after.byId("host/" & name).launched

  test "an entry with no recorded class is not served to a host-bound edge":
    ## §3.2 rule 3: a record installed from a peer or a binary cache records
    ## no class and no host. Rule 1 makes the use `host-bound` (the edge's
    ## class), and rule 4 then has no host to compare: a miss.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = f.edges()
    let g = graph(actions)
    f.warm(g)

    let copy = f.copyRoot("peer")
    for a in actions:
      removeFile(detFor(copy, a))

    let res = runBuild(g, config(copy))
    check not res.byId("host/strong").launched
    check f.runCount("strong") == 1
    # Only the `host-bound` arm proves rule 4 here: a `volatile` entry with no
    # recorded write time already misses under retention (§3.2 rule 2).
    for name in ["hostbound"]:
      let r = res.byId("host/" & name)
      checkpoint(name & ": decision=" & $r.cacheDecision & " launched=" &
        $r.launched & " reason=" & r.reason)
      check r.launched
      check f.runCount(name) == 2

  test "the producing host keeps its host-bound hits":
    ## The positive control: the check must not turn every host-bound hit
    ## into a miss. A copy that is NOT forged is this host's own realization.
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = graph(f.edges())
    f.warm(g)
    let copy = f.copyRoot("same-host")
    let res = runBuild(g, config(copy))
    for name in ClassNames:
      check not res.byId("host/" & name).launched
      check f.runCount(name) == 1

  test "an edge relabelled strong is not served another host's host-bound entry":
    ## §3.2 rule 1: the use takes the stricter of the class the entry records
    ## and the using edge's. The class is not in the cache key (§10.2), so the
    ## same edge relabelled `strong` reaches the entry recorded `host-bound`;
    ## that use is still `host-bound`, and rule 4 refuses another host's.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = f.edges()
    f.warm(graph(actions))
    let copy = f.copyRoot("relabel")
    forgeHost(copy, actions[1])

    let relabelled = graph([f.edge("strong", edStrong),
      f.edge("hostbound", edStrong)])
    doAssert relabelled.actions[1].weakFingerprint == actions[1].weakFingerprint
    var cfg = config(copy)
    # Per-action lookups only; the prefix arms get the same case in the
    # suite below.
    cfg.recordCacheHitProvenance = true
    let res = runBuild(relabelled, cfg)
    let r = res.byId("host/hostbound")
    checkpoint("relabelled: decision=" & $r.cacheDecision & " reason=" &
      r.reason)
    check r.launched
    check f.runCount("hostbound") == 2
    check not res.byId("host/strong").launched
    # The re-run recorded this host, so it is not repeated on every build: a
    # carried-forward sidecar must not stamp the new bytes with the other
    # host again (§3.2 rule 3).
    let again = runBuild(relabelled, cfg)
    check not again.byId("host/hostbound").launched
    check f.runCount("hostbound") == 2
    check recordedHost(copy, actions[1]) == hostFingerprint()

  test "an unlabelled edge re-runs another host's host-bound entry once, not on every build":
    ## §3.2 rules 1, 3 and 4. The unlabelled edge reaches the entry recorded
    ## `host-bound` on another host: the use is `host-bound`, so it misses and
    ## re-runs. Its run records no class (rule 3), so the other host's
    ## sidecar must not be carried forward onto the new bytes; if it were,
    ## every later build would miss again.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = f.edges()
    f.warm(graph(actions))
    let copy = f.copyRoot("unlabelled")
    forgeHost(copy, actions[1])
    let relabelled = graph([f.unlabelledEdge("hostbound")])
    doAssert relabelled.actions[0].weakFingerprint == actions[1].weakFingerprint
    var cfg = config(copy)
    cfg.recordCacheHitProvenance = true
    check runBuild(relabelled, cfg).byId("host/hostbound").launched
    check f.runCount("hostbound") == 2
    for i in 1 .. 2:
      let r = runBuild(relabelled, cfg).byId("host/hostbound")
      checkpoint("build " & $i & ": decision=" & $r.cacheDecision &
        " reason=" & r.reason)
      check not r.launched
    check f.runCount("hostbound") == 2

  test "a hybrid-policy host-bound edge with no sidecar misses instead of aborting":
    ## A `ffpHybrid` record read through the metadata-only hot path has no
    ## content hashes and no strong fingerprint. With no current sidecar the
    ## answer is still a miss (no recorded host), and nothing may try to
    ## recompute the fingerprint from those inputs and raise.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = @[f.edge("hostbound", edHostBound, policy = ffpHybrid)]
    let g = graph(actions)
    discard runBuild(g, config(f.cacheRoot))
    doAssert not runBuild(g, config(f.cacheRoot)).byId("host/hostbound").launched,
      "the hybrid fixture is not warm"
    let copy = f.copyRoot("hybrid-peer")
    removeFile(detFor(copy, actions[0]))
    # The fast-no-op prefix first (it reads the hot record), then the
    # per-edge lookup, which is served the re-run's record.
    for skip in [true, false]:
      var cfg = config(copy)
      cfg.skipCacheHitEvidence = skip
      let res = runBuild(g, cfg)
      let r = res.byId("host/hostbound")
      checkpoint("skipCacheHitEvidence=" & $skip & ": decision=" &
        $r.cacheDecision & " reason=" & r.reason)
      check r.launched == skip
      if skip:
        check "host/hostbound cache-other-host: cached entry records no host" in
          res.traceText
    check f.runCount("hostbound") == 2

  test "the portable pre-pass does not serve another host's host-bound entry":
    ## The lookup-before-scheduling pre-pass serves a content-checked edge
    ## from the portable memo, which lives under the cache root and so is in
    ## the copy too. An edge it resolves completes as a hit without a
    ## per-edge lookup, and a memo record names no host, so a `host-bound`
    ## edge must be left to the scheduler (§3.2 rule 4).
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = @[f.edge("strong", edStrong, policy = ffpChecksum),
      f.edge("hostbound", edHostBound, policy = ffpChecksum)]
    let g = graph(actions)
    proc portableConfig(cacheRoot: string): BuildEngineConfig =
      result = config(cacheRoot)
      result.portableRoots = @[
        LogicalRoot(label: "work", path: f.workRoot, kind: lrkTracked)]
      result.portableLookup = true
    discard runBuild(g, portableConfig(f.cacheRoot))
    doAssert f.runCount("hostbound") == 1 and f.runCount("strong") == 1
    let copy = f.copyRoot("portable")
    doAssert dirExists(copy / "portable-memo"),
      "the portable memo is not under the cache root; the case tests nothing"
    forgeHost(copy, actions[1])
    let res = runBuild(g, portableConfig(copy))
    let trace = res.traceText
    checkpoint(trace)
    # Positive control: the pre-pass is active and serves the `strong` edge.
    check not res.byId("host/strong").launched
    check "host/strong portable-resolved: local" in trace
    check "host/strong asCacheHit: portable-outputs-present" in trace
    let r = res.byId("host/hostbound")
    checkpoint("hostbound: decision=" & $r.cacheDecision & " reason=" & r.reason)
    check "host/hostbound portable-record-refused" in trace
    check r.launched
    check "host/hostbound cache-other-host: cached entry is another host's" in
      trace
    check f.runCount("hostbound") == 2

proc schedulerRan(res: BuildRunResult): bool =
  ## The whole-graph fast-no-op prefix returns before the scheduler
  ## initializes, so the scheduler's own metric says which path decided.
  for m in res.stats.metrics:
    if m.name == "repro scheduler initialize":
      return true
  false

proc prefixConfig(cacheRoot: string; navigator: bool): BuildEngineConfig =
  ## `navigator = true` is what `repro build` runs by default: the batch
  ## navigator scan (`scanHotIndexMetadataInputsUnchanged`). False takes the
  ## per-record arm.
  result = config(cacheRoot)
  result.statsEnabled = true
  result.skipCacheHitEvidence = navigator

suite "the whole-graph fast-no-op prefix":

  for navigator in [true, false]:
    let arm = if navigator: "navigator scan" else: "per-record arm"

    test "serves this host's host-bound entries and refuses another host's (" &
        arm & ")":
      ## Without a `volatile` edge in the graph the prefix is eligible, and
      ## it answers for the whole graph, so it needs its own host check.
      let f = makeFixture()
      defer: removeDir(f.root)
      let actions = @[f.edge("strong", edStrong),
        f.edge("hostbound", edHostBound)]
      let g = graph(actions)
      discard runBuild(g, prefixConfig(f.cacheRoot, navigator))
      let warmRes = runBuild(g, prefixConfig(f.cacheRoot, navigator))
      # Positive control: on the producing host the prefix still decides.
      check not warmRes.schedulerRan
      check not warmRes.byId("host/hostbound").launched
      check f.runCount("hostbound") == 1

      let copy = f.copyRoot("prefix")
      forgeHost(copy, actions[1])
      let res = runBuild(g, prefixConfig(copy, navigator))
      checkpoint("hostbound: decision=" &
        $res.byId("host/hostbound").cacheDecision &
        " reason=" & res.byId("host/hostbound").reason)
      check res.schedulerRan
      check res.byId("host/hostbound").launched
      check f.runCount("hostbound") == 2
      check not res.byId("host/strong").launched
      # ...and once the re-run recorded this host, the prefix decides again.
      let after = runBuild(g, prefixConfig(copy, navigator))
      check not after.schedulerRan
      check not after.byId("host/hostbound").launched

    test "refuses another host's host-bound entry to an edge relabelled strong (" &
        arm & ")":
      ## §3.2 rule 1 on the prefix: the record carries its class, so the use
      ## is the recorded `host-bound` even though the edge now says `strong`.
      let f = makeFixture()
      defer: removeDir(f.root)
      let actions = @[f.edge("strong", edStrong),
        f.edge("hostbound", edHostBound)]
      f.warm(graph(f.edges()))
      let copy = f.copyRoot("prefix-relabel")
      forgeHost(copy, actions[1])
      let relabelled = graph([f.edge("strong", edStrong),
        f.edge("hostbound", edStrong)])
      let res = runBuild(relabelled, prefixConfig(copy, navigator))
      check res.schedulerRan
      check res.byId("host/hostbound").launched
      check f.runCount("hostbound") == 2

  test "a sidecar that no longer describes its record does not vouch for the host":
    ## A store bundle or an older binary can replace a `.rec` and leave this
    ## host's earlier `.det` beside it. The sidecar's write-sequence
    ## back-reference then names a record that is gone, so it says nothing
    ## about the bytes now there, including whose they are.
    let f = makeFixture()
    defer: removeDir(f.root)
    let actions = f.edges()
    f.warm(graph(actions))
    let copy = f.copyRoot("stale-sidecar")
    let path = detFor(copy, actions[1])
    var raw = readFile(path)
    # Bytes 6..13 are the back-reference (magic, u16 version, u64 sequence).
    raw[6] = char((ord(raw[6]) + 1) and 0xff)
    writeFile(path, raw)
    let res = runBuild(graph(actions), config(copy))
    let r = res.byId("host/hostbound")
    checkpoint("stale: decision=" & $r.cacheDecision & " reason=" & r.reason)
    check r.launched
    check f.runCount("hostbound") == 2
