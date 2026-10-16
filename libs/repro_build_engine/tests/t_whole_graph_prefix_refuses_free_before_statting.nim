## The whole-graph no-op prefix must spend its free refusals before its
## expensive ones.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES ARE USED IN THIS FILE, AND NONE MAY
## BE ADDED. Every case drives the real `runBuild`, the real per-edge
## `ActionCache` and CAS in `repro_local_store`, real `/bin/sh` children and
## real files under a real temporary directory. The quantity under test IS the
## number of `lstat`-shaped probes a refusal costs, so a mocked filesystem would
## make the zero true by construction rather than by the code under test.
##
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------
## `tryFastNoopCacheHits` bails out when any action is uncacheable or carries a
## `dynamicDepsFile`. Both are plain `BuildAction` field reads — no syscall, no
## record, no allocation — but they used to be tested INSIDE the loop that also
## `allOutputsExist()`s each edge and reads each edge's hot record. So a graph
## whose uncacheable edge sorted LAST paid n edges of filesystem work and then
## refused anyway, every single build.
##
## That is not an exotic graph. EVERY graph carrying an `install`, `test` or
## `preinstall` edge is in that class. The zlib `all` target the AC-5 campaign
## measured happens to exclude them, which is why the waste never appeared in
## those numbers — the measurement was taken on the one shape that does not pay
## it. See Action-Cache-Per-Edge-Store.milestones.org, AC-5 deliverable 3.
##
## WHAT IS ASSERTED
## ---------------------------------------------------------------------
## `repro fast noop prefix output stat` counts the `allOutputsExist()` probes
## the PREFIX made before it returned, emitted at the fall-through and nowhere
## else. (`repro output stat` cannot answer this: the scheduler emits it too,
## and on a bailing graph the scheduler's contribution swamps the prefix's.)
##
##   * ZERO on a warm graph whose only uncacheable edge sorts LAST. This is the
##     criterion. Move the two field reads back into the loops and it reads
##     `Edges` instead.
##   * STRICTLY POSITIVE on the same fixture with the uncacheable edge removed
##     and a late bail arranged by moving an input instead. Without this case
##     the criterion above would also be satisfied by a row wired to a constant
##     0, which is exactly the failure mode `metricByName` exists to catch one
##     half of.
##
## The verdicts are pinned with literals on both cases. Hoisting a refusal
## EARLIER cannot change an answer — every hoisted condition returns the same
## `none` the loop returned — but "cannot" is a claim, and these are what check
## it.
##
## BOTH ARMS. The hoisted refusals sit above the `skipCacheHitEvidence` split,
## so one arm would in principle do; both are run anyway, because the thing
## that would break the criterion is somebody re-introducing a per-edge check
## into one arm's loop, and a file that covered one arm would not see it.
##
## POSIX ONLY — the edges are `/bin/sh` scripts.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const
  PrefixOutputStatRow = "repro fast noop prefix output stat"
  CarryRow = "repro fast noop prefix metadata carry"

const Edges = 5
  ## The cacheable, warm edges. Each one is an output stat the prefix must NOT
  ## pay for before refusing on the uncacheable edge that sorts after them.

const CopyScript = """#!/bin/sh
set -e
out="$1"; dep="$2"; src="$3"
cat "$src" > "$out"
printf '%s: %s\n' "$out" "$src" > "$dep"
"""

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("whole-graph-prefix-free-refusal." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc metricByName(res: BuildRunResult; name: string): BuildStatsMetric =
  ## Absent is an ERROR, not zero. Both cases below read this row and one of
  ## them asserts it is zero; defaulting a miss to zero would keep that case
  ## green after the row stopped being emitted at all.
  for metric in res.stats.metrics:
    if metric.name == name:
      return metric
  var present: seq[string] = @[]
  for metric in res.stats.metrics:
    present.add(metric.name)
  raise newException(ValueError,
    "no stats row named '" & name & "'; present rows: " & present.join(", "))

proc rowCount(res: BuildRunResult; name: string): int =
  res.metricByName(name).count

proc statsConfig(cacheRoot: string; skipEvidence: bool): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32
  result.statsEnabled = true
  result.skipCacheHitEvidence = skipEvidence

proc stem(i: int): string = "unit" & $i

proc copyEdge(workRoot, copy, id: string; i: int;
              cacheable: bool): BuildAction =
  writeFile(workRoot / "src" / (stem(i) & ".txt"), "payload " & $i & "\n")
  action(id,
    [copy, "out/" & stem(i) & ".txt", "out/" & stem(i) & ".d",
     "src/" & stem(i) & ".txt"],
    cwd = workRoot,
    inputs = ["src/" & stem(i) & ".txt"],
    outputs = ["out/" & stem(i) & ".txt"],
    depfile = "out/" & stem(i) & ".d",
    cacheable = cacheable,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc prepare(workRoot: string): string =
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  result = workRoot / "copy.sh"
  writeFile(result, CopyScript)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc graphWithTrailingUncacheableEdge(workRoot: string): BuildGraph =
  ## `Edges` cacheable edges followed by ONE uncacheable edge. The order of
  ## `BuildGraph.actions` is the order the prefix iterates —
  ## `inferDeclaredActionDeps` copies the graph and only adds `deps` — so the
  ## uncacheable edge really is the last one reached. The edges are independent
  ## of each other, so nothing about the refusal depends on scheduling order.
  var actions: seq[BuildAction] = @[]
  let copy = prepare(workRoot)
  for i in 0 ..< Edges:
    actions.add(copyEdge(workRoot, copy, "free/cacheable-" & stem(i), i,
      cacheable = true))
  # Named to sort last as well as to be declared last, so the property does not
  # rest on declaration order alone.
  actions.add(copyEdge(workRoot, copy, "free/zz-install", Edges,
    cacheable = false))
  graph(actions)

proc graphAllCacheable(workRoot: string): BuildGraph =
  var actions: seq[BuildAction] = @[]
  let copy = prepare(workRoot)
  for i in 0 ..< Edges:
    actions.add(copyEdge(workRoot, copy, "paid/cacheable-" & stem(i), i,
      cacheable = true))
  graph(actions)

proc describe(res: BuildRunResult; g: BuildGraph): string =
  for act in g.actions:
    let r = res.byId(act.id)
    result.add("\n    " & act.id & " status=" & $r.status &
      " decision=" & $r.cacheDecision & " reason=" & r.reason &
      " launched=" & $r.launched)

type Arm = tuple[name: string; skipEvidence: bool]

const Arms: array[2, Arm] = [
  (name: "arm A (batched hot-index scan)", skipEvidence: true),
  (name: "arm B (per-edge hot record)", skipEvidence: false)]

when defined(posix):

  suite "the whole-graph prefix refuses for free before it stats anything":

    for arm in Arms:

      test "an uncacheable edge sorting last costs no output stat — " & arm.name:
        let tempRoot = createTempDir("repro-prefix-free-refusal", "")
        defer: removeDir(tempRoot)
        let workRoot = tempRoot / "work"
        let g = graphWithTrailingUncacheableEdge(workRoot)
        let config = statsConfig(tempRoot / "cache", arm.skipEvidence)
        let uncacheableId = g.actions[g.actions.len - 1].id

        let cold = runBuild(g, config)
        for act in g.actions:
          check cold.byId(act.id).status == asSucceeded

        let warm = runBuild(g, config)
        checkpoint("warm verdicts:" & warm.describe(g))
        echo "    free refusal ", arm.name,
          ": prefixOutputStat=", warm.rowCount(PrefixOutputStatRow),
          " carry=", warm.rowCount(CarryRow)

        # THE PREMISE, in two halves. The uncacheable edge must really have run
        # — an uncacheable edge always does — and the others must really have
        # been warm, cached and present. Without the second half the graph might
        # be refusing for a missing output instead, and the zero below would be
        # measuring the wrong refusal.
        check warm.byId(uncacheableId).launched
        check warm.byId(uncacheableId).status == asSucceeded
        check warm.byId(uncacheableId).cacheDecision == cdNotCacheable
        check warm.byId(uncacheableId).reason == "exit=0"
        for i in 0 ..< Edges:
          let r = warm.byId(g.actions[i].id)
          check not r.launched
          check r.status == asUpToDate
          check r.cacheDecision == cdHit
          check r.reason == "outputs-present"

        # THE CRITERION. `not action.cacheable` is a field read; paying `Edges`
        # output stats to reach it is work done for an answer already known.
        check warm.rowCount(PrefixOutputStatRow) == 0
        # And nothing was observed, so there is nothing to carry either.
        #
        # STATED HONESTLY: this is NOT the discriminating half. Un-hoisting the
        # refusals leaves it at 0 as well — measured — because both arms fill
        # the metadata cache only AFTER their loop, in the batched scan or the
        # record input scan, and the un-hoisted refusal still returns before
        # either. It is here as a forward guard: it is the assertion that goes
        # red if a future change moves metadata work INTO the loop, which would
        # make the refusal expensive again by a route the output-stat row above
        # cannot see.
        check warm.rowCount(CarryRow) == 0

      test "a late bail with no uncacheable edge does pay output stats — " &
          arm.name:
        ## The control. The row must be capable of being non-zero on a graph
        ## that genuinely walks the loop, or the zero above says nothing.
        let tempRoot = createTempDir("repro-prefix-paid-refusal", "")
        defer: removeDir(tempRoot)
        let workRoot = tempRoot / "work"
        let g = graphAllCacheable(workRoot)
        let config = statsConfig(tempRoot / "cache", arm.skipEvidence)

        let cold = runBuild(g, config)
        for act in g.actions:
          check cold.byId(act.id).status == asSucceeded

        # The bail is a moved input on the LAST edge, so the prefix walks the
        # whole graph: same traversal, same cost, a refusal that is NOT free.
        writeFile(workRoot / "src" / (stem(Edges - 1) & ".txt"),
          "payload changed\n")
        let warm = runBuild(g, config)
        checkpoint("warm verdicts:" & warm.describe(g))
        echo "    paid refusal ", arm.name,
          ": prefixOutputStat=", warm.rowCount(PrefixOutputStatRow),
          " carry=", warm.rowCount(CarryRow)

        check warm.byId(g.actions[Edges - 1].id).launched
        check warm.rowCount(PrefixOutputStatRow) > 0
