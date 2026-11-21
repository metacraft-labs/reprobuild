## `Edge-Determinism-And-Soft-Rebuild.md` §3.2 rule 3: a cache entry records
## the class its bytes were produced under. A write that RAN the action
## records the running edge's class and replaces what the entry recorded
## before, so an unlabelled edge's run records no class. Only a write that
## re-stores a record the cache already holds keeps the recorded class.
##
## The failure this protects against
## (reprobuild-pm `issues/2026-11-18-an-unlabelled-edges-run-inherits-the-class-sidecar-of-the-bytes-it-replaced.md`):
## the class is not in the cache key (§10.2), so an unlabelled edge reaches
## the entry another call site (or the same edge before a relabel) recorded
## `volatile` or `host-bound`. When that unlabelled edge re-runs with
## unchanged inputs, its `.rec` has the name of the one it replaces. The
## write path used to treat every class-free write over an existing record as
## a re-store and re-stamp the old `.det` sidecar onto the new bytes, write
## time included. So the bytes an unlabelled edge just produced carried a
## class, a host and a retention clause that described the bytes they
## replaced. Everything that reads the sidecar then judged the new bytes by
## it: the publishers and the host check through the recorded class, and the
## retention GC (`runRetentionGc`) through the recorded clause and the first
## run's write time.
##
## The last case keeps the other half of rule 3: a re-store of a record that
## carries no class (one decoded from a plain frame, which is what the
## shared-memory tier hands back) must still keep the recorded class, or a
## `volatile` entry would lose its retention the first time it was
## re-stored. It drives `refreshRestoredOutputs`, a re-store the engine makes
## after a restore from the CAS. The other re-stores -- the hybrid cut-off
## rewrite, the peer install -- take the same branch of the write path and
## are not driven here.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The builds drive the real `runBuild` scheduler, the real per-edge
## `ActionCache`, real `/bin/sh` subprocesses and real files. The last case
## calls the store's `refreshRestoredOutputs` directly, with a record whose
## class the test has blanked: that is the record the shared-memory tier
## decodes, not a stub of a collaborator. The clock is injected
## (`BuildEngineConfig.nowUnix`) so a `max-age` window is arithmetic, not a
## sleep.
##
## Out-of-band corroboration: the edge appends a line to its own log on each
## execution, so "was re-run" is a fact about the filesystem.

import std/[options, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store

const
  BaseNow = 1_704_067_200'i64   ## 2024-01-01T00:00:00Z
  MaxAgeSec = 60'i64
  EdgeName = "shared"

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string

proc weak(): ContentDigest =
  weakFingerprintFromText("run-records-its-own-class." & EdgeName)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc traceText(res: BuildRunResult): string =
  for event in res.trace:
    result.add(event.actionId & " " & event.event & ": " & event.detail & "\n")

proc runCount(f: Fixture): int =
  let path = f.workRoot / "out" / (EdgeName & ".log")
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      inc result

proc makeFixture(): Fixture =
  let root = createTempDir("repro-run-records-class-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / (EdgeName & ".txt"), "seed\n")
  let script = workRoot / (EdgeName & ".sh")
  writeFile(script,
    "#!/bin/sh\n" &
    "echo ran >> out/" & EdgeName & ".log\n" &
    "cat src/" & EdgeName & ".txt > out/" & EdgeName & ".out\n" &
    # A depfile selects the legacy gathering policy, so the edge needs no
    # live io-monitor (as in `t_soft_rebuild_and_retention`).
    "printf '%s: %s\\n' out/" & EdgeName & ".out src/" & EdgeName &
      ".txt > out/" & EdgeName & ".dep\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(root: root, workRoot: workRoot, cacheRoot: root / "cache")

proc edge(f: Fixture; cls = none(EdgeDeterminism);
          retention = forever()): BuildAction =
  ## One action identity. `cls = none` is §2.1's unlabelled edge: the same
  ## weak fingerprint, no class of its own.
  if cls.isSome:
    action("run/" & EdgeName, [f.workRoot / (EdgeName & ".sh")],
      cwd = f.workRoot,
      inputs = ["src/" & EdgeName & ".txt"],
      outputs = ["out/" & EdgeName & ".out"],
      depfile = "out/" & EdgeName & ".dep",
      cacheable = true,
      weakFingerprint = weak(),
      actionCachePolicy = ffpTimestamp,
      determinism = cls,
      cacheRetention = retention,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
  else:
    action("run/" & EdgeName, [f.workRoot / (EdgeName & ".sh")],
      cwd = f.workRoot,
      inputs = ["src/" & EdgeName & ".txt"],
      outputs = ["out/" & EdgeName & ".out"],
      depfile = "out/" & EdgeName & ".dep",
      cacheable = true,
      weakFingerprint = weak(),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc config(f: Fixture; now = BaseNow): BuildEngineConfig =
  result = defaultBuildEngineConfig(f.cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32
  result.nowUnix = now
  result.buildEpoch = "t-run-records-class-epoch-1"
  # Per-action lookups: every build below is answered by the per-edge
  # lookup, not by a whole-graph shortcut.
  result.recordCacheHitProvenance = true

proc entryKey(f: Fixture): ContentDigest =
  ## The weak fingerprint the engine keys the entry by. It is the same for
  ## the labelled and the unlabelled edge: the class is not in the key.
  f.edge().weakFingerprint

proc recorded(f: Fixture): EntryDeterminism =
  ## What the entry records now, as every reader sees it: the newest record
  ## with its current sidecar.
  var cache = openActionCache(f.cacheRoot / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  let records = cache.loadPerEdgeRecords(f.entryKey)
  doAssert records.len == 1, "expected one record, found " & $records.len
  records[0].determinism

proc detFiles(f: Fixture): seq[string] =
  let dir = f.cacheRoot / "action-cache" / "hot-records"
  for kind, edgeDir in walkDir(dir):
    if kind != pcDir: continue
    for k, path in walkDir(edgeDir):
      if k == pcFile and path.endsWith(DeterminismFileExt):
        result.add(path)

suite "a run records the class of the edge that ran":

  test "an unlabelled edge's run over a volatile entry records no class and no stale write time":
    ## The entry is recorded `volatile` with `max-age`. Later the unlabelled
    ## edge runs with unchanged inputs. Its run records no class (rule 3), so
    ## nothing stamps the new bytes with the first run's write time.
    ##
    ## The closing loop is NOT evidence today, and is kept on purpose. §3.2
    ## rule 2 applies the RECORDED retention clause to every use; under it,
    ## bytes re-stamped with an expired write time would be born expired and
    ## the unlabelled edge would re-run on every build. The read path does
    ## not apply the recorded clause to an edge that has no clause of its own
    ## yet (reprobuild-pm Warm-Runners milestone WR8-D3), so the loop passes
    ## with or without the fix. It is here so that closing that gap cannot
    ## bring the every-build re-run in. What fails without the fix is the
    ## three checks on the record before it.
    let f = makeFixture()
    defer: removeDir(f.root)
    let labelled = graph([f.edge(some(edVolatile), maxAge(MaxAgeSec))])
    let unlabelled = graph([f.edge()])
    doAssert unlabelled.actions[0].weakFingerprint ==
      labelled.actions[0].weakFingerprint

    check runBuild(labelled, f.config()).byId("run/" & EdgeName).launched
    check f.runCount == 1
    check f.recorded.declared
    check f.recorded.class == edVolatile
    check f.recorded.writeTimeUnix == BaseNow
    # Positive control for the `detFiles.len == 0` check below: the walk
    # finds the sidecar a labelled run writes.
    check f.detFiles.len == 1
    # Inside the window the unlabelled edge is served the volatile entry and
    # writes nothing: a hit does not relabel the entry.
    check not runBuild(unlabelled, f.config(BaseNow + MaxAgeSec div 2))
      .byId("run/" & EdgeName).launched
    check f.runCount == 1
    check f.recorded.class == edVolatile

    let late = BaseNow + 2 * MaxAgeSec
    var forced = f.config(late)
    forced.forceRebuild = true
    check runBuild(unlabelled, forced).byId("run/" & EdgeName).launched
    check f.runCount == 2

    # The run's own record: no class, no write time, no sidecar beside it.
    check not f.recorded.declared
    check f.recorded.writeTimeUnix == 0
    check f.detFiles.len == 0

    for i in 1 .. 2:
      let res = runBuild(unlabelled, f.config(late + i))
      let r = res.byId("run/" & EdgeName)
      checkpoint("build " & $i & " after the re-run: decision=" &
        $r.cacheDecision & " reason=" & r.reason & "\n" & res.traceText)
      check not r.launched
    check f.runCount == 2

  test "an unlabelled edge's run does not inherit the class of the host-bound bytes it replaces":
    ## The other direction: nothing has expired, the unlabelled edge is made
    ## to run with unchanged inputs (a forced rebuild), and its bytes must
    ## not carry the `host-bound` label of the realization they replace.
    let f = makeFixture()
    defer: removeDir(f.root)
    discard runBuild(graph([f.edge(some(edHostBound))]), f.config())
    check f.recorded.declared
    check f.recorded.class == edHostBound
    check f.recorded.hostFingerprint == hostFingerprint()
    check f.detFiles.len == 1

    var forced = f.config()
    forced.forceRebuild = true
    check runBuild(graph([f.edge()]), forced).byId("run/" & EdgeName).launched
    check f.runCount == 2
    check not f.recorded.declared
    check f.recorded.hostFingerprint.len == 0
    check f.detFiles.len == 0

  test "a labelled edge's run replaces the class an earlier run recorded":
    ## Rule 3 across a sequence of runs of one identity: each run's record
    ## carries the class of the edge that ran, whatever the entry recorded
    ## before -- a class over a class, none over a class, a class over none.
    let f = makeFixture()
    defer: removeDir(f.root)
    var forced = f.config()
    forced.forceRebuild = true
    discard runBuild(graph([f.edge(some(edHostBound))]), f.config())
    discard runBuild(graph([f.edge(some(edVolatile), maxAge(MaxAgeSec))]),
      forced)
    check f.recorded.class == edVolatile
    discard runBuild(graph([f.edge()]), forced)
    check not f.recorded.declared
    discard runBuild(graph([f.edge(some(edHostBound))]), forced)
    check f.recorded.declared
    check f.recorded.class == edHostBound
    check f.runCount == 4

  test "a re-store of a record that carries no class keeps the recorded class":
    ## Rule 3: "A write that only re-stores a record this cache already holds
    ## keeps the recorded class". A record decoded from a plain frame carries
    ## no class. If its re-store dropped the sidecar, a `volatile` entry would
    ## be served forever with no retention. This case passes with and without
    ## the fix: it is the control that the fix did not take the carry-forward
    ## away from a re-store.
    let f = makeFixture()
    defer: removeDir(f.root)
    discard runBuild(graph([f.edge(some(edVolatile), maxAge(MaxAgeSec))]),
      f.config())
    block:
      var cache = openActionCache(f.cacheRoot / "action-cache",
        attachShm = false)
      defer: cache.closeShmTier()
      var plain = cache.loadPerEdgeRecords(f.entryKey)
      doAssert plain.len == 1
      plain[0].determinism = EntryDeterminism()
      discard cache.refreshRestoredOutputs(plain[0], f.workRoot)
    check f.recorded.declared
    check f.recorded.class == edVolatile
    check f.recorded.writeTimeUnix == BaseNow
    # The write time it kept is the first run's: the labelled edge is still
    # served inside the window (a dropped sidecar has no write time, which is
    # a miss), and misses once the window has passed.
    let labelled = graph([f.edge(some(edVolatile), maxAge(MaxAgeSec))])
    check not runBuild(labelled, f.config(BaseNow + MaxAgeSec div 2))
      .byId("run/" & EdgeName).launched
    check f.runCount == 1
    check runBuild(labelled, f.config(BaseNow + 2 * MaxAgeSec))
      .byId("run/" & EdgeName).launched
    check f.runCount == 2
