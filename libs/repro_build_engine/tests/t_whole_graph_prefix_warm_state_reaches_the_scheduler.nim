## The whole-graph no-op prefix's warm state must reach the scheduler.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES ARE USED IN THIS FILE, AND NONE MAY
## BE ADDED. Every case drives the real `runBuild`, the real per-edge
## `ActionCache` and CAS in `repro_local_store`, the real `FileMetadataCache`,
## real `/bin/sh` children and real files under a real temporary directory. The
## quantity under test IS "how many filesystem observations survive the
## fall-through", so a fake filesystem or a synthesized record would decide the
## question by construction: a mocked probe is not an observation and would
## leave nothing to carry.
##
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------
## `tryFastNoopCacheHits` is a PREFIX to the scheduler, not an alternative to
## it. When it returns `none` the engine falls straight through and the
## scheduler runs the whole graph anyway, so on a bail-out the prefix's entire
## cost is ADDED to the normal path. It used to warm a `FileMetadataCache` of
## its own, load records into it, and then discard both at every one of its
## `return none` points — and the scheduler's very next statement allocated a
## SECOND, empty `initFileMetadataCache()`. Measured on three workloads
## (Action-Cache-Per-Edge-Store.milestones.org, AC-5), 88–96% of what the prefix
## spent on a bailing graph was that duplication.
##
## WHAT IS ASSERTED, AND WHY A POINTER WOULD NOT BE ENOUGH
## ---------------------------------------------------------------------
## Three things, and the first two are what make the third readable:
##
##   1. THE BUILD REALLY BAILED. The graph is warm except for one edge whose
##      input moved, so the prefix cannot answer "nothing to do" and the
##      scheduler really runs. Pinned by requiring exactly one launched edge:
##      a prefix HIT launches nothing, so a case that silently started taking
##      the whole-graph shortcut would go red here rather than pass
##      vacuously — which is what it would do if it only asserted on a row.
##
##   2. THE CACHE THE SCHEDULER GOT IS POPULATED. `repro fast noop prefix
##      metadata carry` is `entryCount` on the cache at the fall-through,
##      emitted at the fall-through and nowhere else. Revert the threading —
##      give the prefix `var metadataCache = initFileMetadataCache()` back and
##      let the scheduler allocate its own — and this is 0, because the
##      scheduler's cache is then freshly allocated at that exact point.
##
##   3. THE SCHEDULER USED IT RATHER THAN RE-OBSERVING. A carried entry that
##      the scheduler ignores saves nothing, and assertion 2 alone cannot tell
##      the two apart. `repro file metadata current-run hit` counts checks the
##      reported cache answered from its own table with no syscall; on this
##      graph it must cover the carry, which it can only do if the scheduler's
##      FIRST touch of a path the prefix observed was already a hit.
##
##   4. AND NO CHECK THIS BUILD MADE IS INVISIBLE — the half that needs no new
##      row. `recordedInputRevalidateStats`' own documented invariant is that
##      its process-global `checks` count is at most the sum of the per-cache
##      class counts. Two caches broke it: only one was ever finalised, so the
##      prefix's checks were performed and then left out of every row. Measured
##      on the 6-edge fixture, 12 checks against 7 reported. One cache: 12
##      against 13. This is the same fact as 88–96% waste, stated as a property
##      a test can refuse.
##
## AND THE VERDICTS ARE PINNED, on both paths, with literals. The prefix
## decides whether a whole graph is up to date, so a false hit here is a wrong
## build. The second case in each arm grades the HIT path — every edge
## `asUpToDate` / `cdHit` / `outputs-present`, nothing launched — and the first
## grades the FALL-THROUGH path edge by edge, the re-run edge included. Those
## literals are the guarantee that threading the cache moved cost and not
## answers: run the suite against a build with the threading reverted and every
## one of them still holds, while the carry assertion goes red.
##
## BOTH ARMS, ALWAYS. `tryFastNoopCacheHits` has two, chosen by
## `BuildEngineConfig.skipCacheHitEvidence`: the batched
## `scanHotIndexMetadataInputsUnchanged` (arm A, the CLI default) and the
## per-edge `lookupHotMetadataRecord` + `hotMetadataRecordInputsUnchanged`
## (arm B). They fill the cache from different call sites, so a property shown
## on one of them is a property shown nowhere. Every case below runs twice and
## the arm is named in the case name.
##
## POSIX ONLY. The edges are `/bin/sh` scripts, like every other engine test in
## this library that needs a real child without an io-monitor driver.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const
  CarryRow = "repro fast noop prefix metadata carry"
  PrefixOutputStatRow = "repro fast noop prefix output stat"
  CurrentRunHitRow = "repro file metadata current-run hit"
  ColdStatRow = "repro file metadata cold stat"
  WarmRevalidateRow = "repro file metadata warm revalidate"
  StoreAbsenceSkipRow = "repro store absence skips"
  RecordedRevalidateRow = "repro recorded input revalidate"

const Edges = 6
  ## Enough that a late bail leaves a substantial prefix of the graph already
  ## observed, and small enough that the cold build stays quick.

# A real child: copy the source to the output and emit a depfile naming it.
# The depfile is a build RULE, not a stand-in for anything under test — an edge
# that declares none falls through to automatic monitor gathering, and this file
# starts no io-monitor driver. Same reason `t_child_cpu_stats_row.nim` ships a
# script.
const CopyScript = """#!/bin/sh
set -e
out="$1"; dep="$2"; src="$3"
cat "$src" > "$out"
printf '%s: %s\n' "$out" "$src" > "$dep"
"""

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("whole-graph-prefix-warm-state." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc metricByName(res: BuildRunResult; name: string): BuildStatsMetric =
  ## Look a stats row up by the name it is RENDERED under, and fail loudly when
  ## it is absent. Defaulting a miss to zero is the trap: every "must be zero"
  ## case in this file would then keep passing against a row that had been
  ## deleted outright. The convention is `t_child_cpu_stats_row.nim`'s.
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
  ## The mode `repro build --measure=timing` runs in — metadata-only
  ## publication, in-place reuse, timing rows collected — which is also the
  ## shape `tryFastNoopCacheHits` requires to run at all
  ## (`rebuildMissingOutputsOnCacheHit`, no progress callback, no forced
  ## rebuild). Taken from the production default so a change to the default is
  ## felt here.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32
  result.statsEnabled = true
  result.skipCacheHitEvidence = skipEvidence

proc stem(i: int): string = "unit" & $i

proc fixtureGraph(workRoot, idPrefix: string): BuildGraph =
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  let copy = workRoot / "copy.sh"
  writeFile(copy, CopyScript)
  setFilePermissions(copy, {fpUserRead, fpUserWrite, fpUserExec})
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< Edges:
    writeFile(workRoot / "src" / (stem(i) & ".txt"), "payload " & $i & "\n")
    let id = idPrefix & "/copy-" & stem(i)
    actions.add(action(id,
      [copy, "out/" & stem(i) & ".txt", "out/" & stem(i) & ".d",
       "src/" & stem(i) & ".txt"],
      cwd = workRoot,
      inputs = ["src/" & stem(i) & ".txt"],
      outputs = ["out/" & stem(i) & ".txt"],
      depfile = "out/" & stem(i) & ".d",
      cacheable = true,
      weakFingerprint = weak(id),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()))
  graph(actions)

type Arm = tuple[name: string; skipEvidence: bool]

const Arms: array[2, Arm] = [
  (name: "arm A (batched hot-index scan)", skipEvidence: true),
  (name: "arm B (per-edge hot record)", skipEvidence: false)]

proc describe(res: BuildRunResult; g: BuildGraph): string =
  for act in g.actions:
    let r = res.byId(act.id)
    result.add("\n    " & act.id & " status=" & $r.status &
      " decision=" & $r.cacheDecision & " reason=" & r.reason &
      " launched=" & $r.launched)

proc reportRows(label: string; res: BuildRunResult) =
  ## Printed, not asserted on: the three `repro file metadata *` class counts
  ## are the decomposition a reader needs to interpret the two assertions, and
  ## pinning them to numbers would be pinning a property of the host.
  echo label,
    " carry=", res.rowCount(CarryRow),
    " prefixOutputStat=", res.rowCount(PrefixOutputStatRow),
    " currentRunHit=", res.rowCount(CurrentRunHitRow),
    " coldStat=", res.rowCount(ColdStatRow),
    " warmRevalidate=", res.rowCount(WarmRevalidateRow),
    " recordedRevalidate=", res.rowCount(RecordedRevalidateRow)

when defined(posix):

  suite "the whole-graph prefix's warm state reaches the scheduler":

    for arm in Arms:

      test "a late bail hands the scheduler a populated cache — " & arm.name:
        ## The fixture is warm except for the LAST edge, whose input content
        ## moved. The prefix therefore observes most of the graph, discovers it
        ## cannot answer, and falls through — the exact shape in which its work
        ## used to be thrown away.
        let tempRoot = createTempDir("repro-prefix-carry", "")
        defer: removeDir(tempRoot)
        let workRoot = tempRoot / "work"
        let g = fixtureGraph(workRoot, "carry")
        let config = statsConfig(tempRoot / "cache", arm.skipEvidence)

        let cold = runBuild(g, config)
        for act in g.actions:
          check cold.byId(act.id).status == asSucceeded
        reportRows("    cold  " & arm.name & ":", cold)

        # The edge that sorts LAST is the one that moves, so the prefix pays
        # for the whole graph before refusing.
        let changedId = g.actions[Edges - 1].id
        writeFile(workRoot / "src" / (stem(Edges - 1) & ".txt"),
          "payload changed\n")

        let warm = runBuild(g, config)
        reportRows("    warm  " & arm.name & ":", warm)

        # 1 — THE PREMISE. A prefix HIT launches nothing, so this is what
        # distinguishes "the scheduler ran" from "the shortcut answered". It
        # also pins the verdicts on the FALL-THROUGH path, with literals.
        check warm.byId(changedId).launched
        check warm.byId(changedId).status == asSucceeded
        check warm.byId(changedId).cacheDecision == cdMiss
        for i in 0 ..< Edges - 1:
          let r = warm.byId(g.actions[i].id)
          check not r.launched
          check r.status == asUpToDate
          check r.cacheDecision == cdHit
          check r.reason == "outputs-present"
        checkpoint("warm verdicts:" & warm.describe(g))

        # 2 — THE CACHE THE SCHEDULER GOT IS POPULATED. Revert the threading
        # and this row reads 0: the scheduler's cache is allocated at exactly
        # the point this is measured. `>= Edges - 1` rather than `> 0` because
        # every observed edge contributes at least its one declared input, so a
        # carry that collapsed to a single entry would be a regression a `> 0`
        # assertion would sleep through.
        let carry = warm.rowCount(CarryRow)
        check carry >= Edges - 1

        # 3 — AND THE SCHEDULER USED IT. Every carried path the scheduler
        # revalidates is answered from the table instead of `lstat`, so the
        # current-run-hit count covers the carry. With the threading reverted
        # the scheduler starts cold and this collapses — measured at 1 against
        # 7, on both arms, at both 6 and 120 edges.
        let currentRunHits = warm.rowCount(CurrentRunHitRow)
        check currentRunHits >= carry
        check currentRunHits >= Edges - 1

        # 4 — THE REPORTED CLASSES ACCOUNT FOR THE CHECKS THE BUILD MADE. This
        # is the half of the criterion that does not depend on the new row at
        # all, and it is the clearest statement of what two caches cost.
        #
        # `recordedInputRevalidateStats` documents the invariant: its `checks`
        # count is process-global and "is therefore <= the sum of the four
        # `repro file metadata *` counts". That was FALSE on a bailing graph
        # while there were two caches — only one of them was ever finalised, so
        # every check the prefix made was performed, paid for, and then left
        # out of every class row. Measured on the 6-edge fixture: 12 checks
        # against 1 + 0 + 6 + 0 = 7 reported, a 5-check hole that is exactly
        # the prefix's discarded work. With one cache: 12 against 13.
        #
        # So this inequality is not bookkeeping pedantry — it is the property
        # "no metadata check this build performed is invisible", and the only
        # way to satisfy it on a fall-through is for the prefix's observations
        # to live in the cache that gets reported, which is the same cache the
        # scheduler reads.
        check currentRunHits + warm.rowCount(ColdStatRow) +
          warm.rowCount(WarmRevalidateRow) + warm.rowCount(StoreAbsenceSkipRow) >=
          warm.rowCount(RecordedRevalidateRow)

        # The prefix really did pay for output stats on this graph — the
        # control for the companion file's "zero on an uncacheable graph"
        # assertion, which would also be satisfied by a row wired to 0.
        check warm.rowCount(PrefixOutputStatRow) > 0

      test "a whole-graph hit still reports the same verdicts — " & arm.name:
        ## The HIT path, graded with the same literals the scheduler uses for
        ## the same state (`asUpToDate` / `cdHit` / `outputs-present`). The
        ## prefix and the scheduler share one cache now; this is the case that
        ## says sharing it did not change what either of them concludes.
        let tempRoot = createTempDir("repro-prefix-hit", "")
        defer: removeDir(tempRoot)
        let workRoot = tempRoot / "work"
        let g = fixtureGraph(workRoot, "hit")
        let config = statsConfig(tempRoot / "cache", arm.skipEvidence)

        let cold = runBuild(g, config)
        for act in g.actions:
          check cold.byId(act.id).status == asSucceeded

        let warm = runBuild(g, config)
        checkpoint("hit verdicts:" & warm.describe(g))
        for act in g.actions:
          let r = warm.byId(act.id)
          check not r.launched
          check r.status == asUpToDate
          check r.cacheDecision == cdHit
          check r.reason == "outputs-present"

        # There is no fall-through on this path, so neither fall-through row is
        # emitted. Asserted because the alternative — emitting them from the
        # prefix's hit exits too — would make the companion file's "zero output
        # stats" criterion ambiguous: a zero would no longer mean "refused
        # before statting".
        expect ValueError:
          discard warm.rowCount(CarryRow)
        expect ValueError:
          discard warm.rowCount(PrefixOutputStatRow)
