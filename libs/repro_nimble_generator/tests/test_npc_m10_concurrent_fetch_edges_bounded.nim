## NPC-M10 verification `test_npc_m10_concurrent_fetch_edges_bounded`
## (from NPC-M4's review: fetch edges run concurrently, bounded).
##
## The engine dispatches executor-backed `bakMetadataFetch` edges through a
## registered ``ConcurrentBuiltinExecutor``: prepared on the scheduler's
## thread, their work run on worker threads at most ``maxParallelism`` at a
## time, then settled in the order they were prepared.
##
## 1. Engine: nine fetch edges whose work sleeps 150 ms each, and one pure
##    edge reading all their outputs. At ``maxParallelism = 3`` the work
##    overlaps (more than one at once) and never more than three at once;
##    the outputs, the results, the pure edge's output and the order of
##    settlement equal those of the same graph at ``maxParallelism = 1``,
##    which runs the edges inline, one at a time.
## 2. Generator: a refs wave over a fixture registry (with two origins the
##    egress policy refuses, one on the worker and one before dispatch) at
##    ``fetchParallelism = 4`` and at 1 gives the same root, the same
##    executed edges in the same order and the same captured refusals in the
##    same order.
##
## Falsifying mutation (recorded in the plan): a dispatch whose bound is
## unlimited (one worker per item) overlaps more than three and fails the
## test.

import std/[atomics, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_nimble_generator

import ./generator_fixtures

const
  Edges = 9
  Bound = 3

var active: Atomic[int]
var peak: Atomic[int]
var started: Atomic[int]

proc slowWork(input: string): string {.nimcall, gcsafe.} =
  ## Plain text in (`<output path>\n<payload>`), plain text out.
  let now = active.fetchAdd(1) + 1
  discard started.fetchAdd(1)
  var seen = peak.load()
  while now > seen and not peak.compareExchange(seen, now):
    discard
  sleep(150)
  let nl = input.find('\n')
  writeFile(input[0 ..< nl], "fetched " & input[nl + 1 .. ^1] & "\n")
  discard active.fetchSub(1)
  "ok:" & input[nl + 1 .. ^1]

var settled: seq[string]
var prepared: seq[string]

proc prepareStub(action: BuildAction): BuiltinWorkItem {.gcsafe.} =
  {.cast(gcsafe).}:
    prepared.add action.id
    createDir(parentDir(action.outputs[0]))
  BuiltinWorkItem(work: slowWork, input: action.outputs[0] & "\n" & action.id)

proc finishStub(action: BuildAction; dispatched: bool;
                outcome: BuiltinWorkOutcome): ActionResult {.gcsafe.} =
  {.cast(gcsafe).}: settled.add action.id & " " & outcome.output
  if not dispatched or not outcome.ok:
    return ActionResult(id: action.id, status: asFailed, exitCode: 1,
      launched: true, stderr: outcome.error)
  ActionResult(id: action.id, status: asSucceeded, launched: true)

proc inlineStub(action: BuildAction): ActionResult {.gcsafe.} =
  ## What the edge does inline: the same three steps on this thread.
  let item = prepareStub(action)
  var outcome = BuiltinWorkOutcome(ok: true)
  outcome.output = item.work(item.input)
  finishStub(action, true, outcome)

proc concatenate(action: BuildAction): ActionResult {.gcsafe.} =
  var text = ""
  for i in action.inputs: text.add readFile(i)
  writeFile(action.outputs[0], text)
  ActionResult(id: action.id, status: asSucceeded, launched: true)

proc graphIn(dir: string): BuildGraph =
  var actions: seq[BuildAction]
  var outs: seq[string]
  for i in 0 ..< Edges:
    let id = "fetch-" & $i
    let o = dir / "out" / (id & ".txt")
    outs.add o
    actions.add builtinAction(bakMetadataFetch, id,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      outputs = [o], cacheable = false,
      weakFingerprint = weakFingerprintFromText(id), text = id,
      networkMode = netFetch, netDestinations = ["https://forge.test/" & id])
  actions.add builtinAction(bakCatalogIndex, "concat",
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    inputs = outs, outputs = [dir / "out" / "all.txt"], cacheable = false,
    weakFingerprint = weakFingerprintFromText("concat"), text = "concat")
  graph(actions)

proc runAt(dir: string; parallelism: int): tuple[statuses: seq[string];
                                                  files: seq[string]] =
  active.store(0)
  peak.store(0)
  started.store(0)
  settled = @[]
  prepared = @[]
  registerMetadataFetchExecutor(inlineStub)
  registerConcurrentMetadataFetchExecutor(ConcurrentBuiltinExecutor(
    prepare: prepareStub, finish: finishStub))
  registerCatalogIndexExecutor(concatenate)
  try:
    var cfg = defaultBuildEngineConfig(dir / "cache")
    cfg.maxParallelism = uint32(parallelism)
    cfg.bypassRunQuota = true
    let r = runBuild(graphIn(dir), cfg)
    for res in r.results:
      result.statuses.add res.id & "=" & $res.status
    for i in 0 ..< Edges:
      result.files.add readFile(dir / "out" / ("fetch-" & $i & ".txt"))
    result.files.add readFile(dir / "out" / "all.txt")
  finally:
    clearMetadataFetchExecutor()
    clearConcurrentMetadataFetchExecutor()
    clearCatalogIndexExecutor()

suite "NPC-M10: fetch edges run concurrently, bounded":

  test "the engine overlaps fetch edges, never beyond the bound, with the sequential result":
    let base = createTempDir("npc-m10-concurrent-", "")
    let sequential = runAt(base / "sequential", 1)
    check peak.load() == 1
    check started.load() == Edges
    let sequentialSettled = settled
    let sequentialPrepared = prepared

    let concurrent = runAt(base / "concurrent", Bound)
    checkpoint "peak " & $peak.load()
    check started.load() == Edges
    check peak.load() > 1      # the edges overlap
    check peak.load() <= Bound # never more than the bound
    check concurrent.statuses == sequential.statuses
    check concurrent.files == sequential.files
    check settled == sequentialSettled
    check prepared == sequentialPrepared
    for s in concurrent.statuses:
      check s.endsWith("=" & $asSucceeded)

  test "a generator refs wave gives the same root, edges and refusals at any parallelism":
    let f = newFixture("m10-concurrent")
    var entries: seq[(string, string)]
    for i in 0 ..< 6:
      let path = "nim/p" & $i & ".git"
      let repo = f.newRepo(path)
      discard repo.commit(@[nimbleFile("p" & $i),
        file("src/p" & $i & ".nim", "discard\n")])
      repo.tag("v1." & $i & ".0")
      repo.publish()
      entries.add ("p" & $i, f.url(path))
    # Two origins the egress policy refuses, each captured whichever thread
    # would have run its edge: `a-private` by its address, which the worker
    # vets, and `b-scheme` by its scheme (rule 1), which the scheduler's
    # thread refuses before any work is dispatched. The wave runs in name
    # order, so the sequential capture order is `a-private`, `b-scheme`; a
    # concurrent run that captured a refusal when it met it, rather than
    # when its edge is settled, would list `b-scheme` first.
    entries.add ("a-private", f.url("nim/refused.git", host = "private.test"))
    entries.add ("b-scheme", "http" & f.url("nim/scheme.git")["https".len .. ^1])
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(entries)])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit), "s.toml")
    let work = createTempDir("npc-m10-concurrent-gen-", "")
    var one = f.genConfig(ss, 1_790_000_000'u64, work / "state-1",
      outputDir = work / "index-1")
    one.fetchParallelism = 1
    var four = f.genConfig(ss, 1_790_000_000'u64, work / "state-4",
      outputDir = work / "index-4")
    four.fetchParallelism = 4
    let a = generate(one)
    let b = generate(four)
    check a.built.rootId == b.built.rootId
    check a.built.root.packageCount == 6
    check a.executed == b.executed
    check a.refusals.len == 2
    if a.refusals.len == 2:
      check a.refusals[0].package == "a-private"
      check a.refusals[0].refusal.kind == erAddress
      check a.refusals[1].package == "b-scheme"
      check a.refusals[1].refusal.kind == erScheme
    check a.refusals == b.refusals
    var refsWave = 0
    for w in b.waves:
      if w.family == efRefs: refsWave += w.edges
    check refsWave == 8
