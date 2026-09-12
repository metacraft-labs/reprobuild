## The ``repro child cpu`` stats row prices the build's tool subprocesses.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case drives the real `runBuild` scheduler, the real per-edge
## `ActionCache`, real files under a real temporary directory, and real
## `/bin/sh` child processes that burn real CPU. The quantity under test IS
## "CPU consumed by processes this build spawned", so a mock launcher would
## make the file vacuous by construction: a fake child burns no CPU, and the
## positive case below would then be asserting that zero is positive.
##
## WHY THIS FILE EXISTS
##
## `repro process wait` reports WALL time the scheduler spent waiting on
## children. That single number cannot distinguish the two things that make a
## build slower, because both present identically as "it took longer":
##
## * the same work got SERIALISED — fewer children running at once; or
## * the work itself grew — the children did more, or more expensive, work.
##
## `repro child cpu` is the second coordinate that separates them. Read
## against `repro process wait`: wall inflated with child CPU flat means
## serialisation (look at effective parallelism); wall and child CPU both
## inflated means the work changed. `childCpuUs` in
## `libs/repro_build_engine/src/repro_build_engine.nim` carries the full
## diagnostic rule and the investigation that produced it.
##
## WHAT IS ASSERTED, AND WHY IT IS NOT A DURATION
##
## A stats row that reports a duration cannot be pinned to a number: the
## number is a property of the machine, and a test that asserted one would
## either be flaky or be retuned until it asserted nothing. What IS a
## property of the product is the row's ZERO-VERSUS-POSITIVE behaviour, and
## that is what every case here grades:
##
## * a build that spawns no children at all (every edge a warm cache hit)
##   reports approximately zero, because `RUSAGE_CHILDREN` moves only when a
##   child is reaped; and
## * a build that launches real child processes reports strictly positive.
##
## The two together are what make either meaningful. The zero alone would
## also be satisfied by a row wired to a constant 0.0, and the positive alone
## would also be satisfied by a row that leaked CPU from earlier builds in
## the same process. Neither can pass both.
##
## THE CONVENTION THIS FILE ESTABLISHES
##
## Nothing in the suite asserted on a stats row BY NAME before this file.
## `metricByName` / `childCpuUs` below are that convention: look the row up in
## `BuildRunResult.stats.metrics` by its exact rendered name, require it to be
## present rather than defaulting a miss to zero, and assert on the value.
## Defaulting a missing row to zero is the trap worth naming — every "reports
## approximately zero" case in a file like this would pass forever against a
## row that had been deleted outright.
##
## POSIX ONLY
##
## The measurement is `getrusage(RUSAGE_CHILDREN)`. Off POSIX `childCpuUs`
## returns a documented constant 0.0, so there is no measurement to grade and
## a case there would assert only that a constant equals itself. Gated the
## same way `test_wrapped_monitor_evidence_ownership.nim` gates its suite.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const ChildCpuRow = "repro child cpu"
const ProcessWaitRow = "repro process wait"

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("child-cpu-stats-row." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc metricByName(res: BuildRunResult; name: string): BuildStatsMetric =
  ## Look a stats row up by the name it is RENDERED under, and fail loudly
  ## when it is absent.
  ##
  ## Raising rather than returning a zero-valued default is the whole point.
  ## Several cases below assert that a row is approximately zero; if a miss
  ## came back as 0.0 those cases would keep passing after the row stopped
  ## being emitted at all, which is the one regression they exist to catch.
  for metric in res.stats.metrics:
    if metric.name == name:
      return metric
  var present: seq[string] = @[]
  for metric in res.stats.metrics:
    present.add(metric.name)
  raise newException(ValueError,
    "no stats row named '" & name & "'; present rows: " & present.join(", "))

proc hasMetric(res: BuildRunResult; name: string): bool =
  for metric in res.stats.metrics:
    if metric.name == name:
      return true

proc childCpuUs(res: BuildRunResult): float =
  res.metricByName(ChildCpuRow).totalUs

proc statsConfig(cacheRoot: string): BuildEngineConfig =
  ## The mode `repro build --measure=timing` runs in: metadata-only
  ## publication, in-place reuse, timing rows collected. Taken from the
  ## production default so a change to the default is felt here.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32
  result.statsEnabled = true

# A real child that burns a real, comfortably measurable amount of CPU in
# user mode, then produces its declared output and a depfile.
#
# The loop is the point: the child must consume enough CPU that `getrusage`
# reports it above its own reporting granularity, so the positive assertion
# is about the product and not about timer resolution. Arithmetic in the
# shell is a deliberately inefficient way to spend CPU, which is exactly what
# is wanted here.
#
# The depfile is a build RULE, not a stand-in for anything under test: an
# edge that declares none falls through to automatic monitor gathering, and
# this test has no io-monitor driver. Same reason the link wrapper exists in
# `t_warm_noop_consultation_hashes_no_bytes.nim`.
const BurnScript = """#!/bin/sh
set -e
out="$1"; dep="$2"; src="$3"
i=0
while [ "$i" -lt 30000 ]; do
  i=$((i + 1))
done
cat "$src" > "$out"
printf '%s: %s\n' "$out" "$src" > "$dep"
"""

proc fixtureGraph(workRoot: string; idPrefix: string; edges = 2): BuildGraph =
  ## `edges` CPU-burning shell edges, all cacheable, so the warm re-run has
  ## several cached artifacts to come back for rather than one.
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  let burn = workRoot / "burn.sh"
  writeFile(burn, BurnScript)
  setFilePermissions(burn, {fpUserRead, fpUserWrite, fpUserExec})
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< edges:
    let stem = "unit" & $i
    writeFile(workRoot / "src" / (stem & ".txt"), "payload " & $i & "\n")
    let id = idPrefix & "/burn-" & stem
    actions.add(action(id,
      [burn, "out/" & stem & ".txt", "out/" & stem & ".d",
       "src/" & stem & ".txt"],
      cwd = workRoot,
      inputs = ["src/" & stem & ".txt"],
      outputs = ["out/" & stem & ".txt"],
      depfile = "out/" & stem & ".d",
      cacheable = true,
      weakFingerprint = weak(id),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()))
  graph(actions)

proc launchedCount(res: BuildRunResult; g: BuildGraph): int =
  for act in g.actions:
    if res.byId(act.id).launched:
      inc result

proc allEdgesWereWarmHits(res: BuildRunResult; g: BuildGraph): bool =
  ## The warm run really consulted the cache and really reused everything.
  ## Without this, "approximately zero child CPU" would also be true of a
  ## build that failed to schedule anything.
  for act in g.actions:
    let r = res.byId(act.id)
    if r.launched:
      return false
    if r.cacheDecision != cdHit:
      return false
  true

# `getrusage` accounts child CPU in whole clock ticks on some platforms, so a
# build that reaped nothing can in principle report a tick of noise rather
# than a hard zero. 5 ms is far below what a single `BurnScript` child costs
# (tens of ms of shell arithmetic) and far above any such rounding, so it
# separates "reaped no children" from "reaped one" without asserting a
# duration.
const ZeroChildCpuToleranceUs = 5_000.0

when defined(posix):

  suite "the child cpu stats row prices spawned tool processes":

    test "a build that launches real children reports positive child cpu":
      let tempRoot = createTempDir("repro-child-cpu-cold", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let g = fixtureGraph(workRoot, "cold")

      let cold = runBuild(g, statsConfig(tempRoot / "cache"))
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded
      # The premise: children were really launched. A build that hit the
      # cache for everything would make the assertion below meaningless.
      check cold.launchedCount(g) == g.actions.len
      check fileExists(workRoot / "out" / "unit0.txt")

      check cold.childCpuUs() > 0.0

    test "a build whose every edge is a cache hit reports ~zero child cpu":
      ## `RUSAGE_CHILDREN` moves only when a child is REAPED, so a build that
      ## spawns nothing must show no movement across its own window. This is
      ## the property that makes the row readable at all: if it drifted
      ## upward on a build that ran no tools, every reading would carry an
      ## unknown amount of someone else's work.
      ##
      ## This warm run leaves through `tryFastNoopCacheHits`, the whole-graph
      ## shortcut, which is a SEPARATE exit from `runBuild` with its own
      ## stats finalisation. `metricByName` requiring the row to be present
      ## is what holds that exit to emitting it — the shortcut reported no
      ## child-cpu row at all when this file was first written.
      let tempRoot = createTempDir("repro-child-cpu-warm", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let g = fixtureGraph(workRoot, "warm")
      let config = statsConfig(tempRoot / "cache")

      let cold = runBuild(g, config)
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded
      # Stated so the comparison below is between a build that paid for
      # children and one that did not, in the SAME process.
      check cold.childCpuUs() > 0.0

      let warm = runBuild(g, config)
      check allEdgesWereWarmHits(warm, g)
      check warm.childCpuUs() < ZeroChildCpuToleranceUs

    test "the per-edge scheduler exit also reports ~zero on a warm no-op":
      ## The case above is served by the whole-graph shortcut. `runBuild`'s
      ## other exit — the per-edge scheduler — finalises its stats
      ## independently, so "the warm reading is zero" has to be established
      ## at both or the row's meaning depends on which path a build took.
      ##
      ## Installing a progress callback is what a real `repro build` does
      ## whenever it renders anything, and the shortcut declines to run when
      ## one is present. That is what routes this warm no-op through the
      ## scheduler instead.
      let tempRoot = createTempDir("repro-child-cpu-warm-scheduler", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let g = fixtureGraph(workRoot, "warm-scheduler")
      var config = statsConfig(tempRoot / "cache")

      let cold = runBuild(g, config)
      for act in g.actions:
        check cold.byId(act.id).status == asSucceeded
      check cold.childCpuUs() > 0.0

      var progressEvents = 0
      config.progressCallback = proc(event: BuildProgressEvent) =
        inc progressEvents
      let warm = runBuild(g, config)
      # The shortcut really was declined: without this the case would
      # silently degrade into a duplicate of the one above.
      check progressEvents > 0
      check allEdgesWereWarmHits(warm, g)
      check warm.childCpuUs() < ZeroChildCpuToleranceUs

    test "the row is per build, not cumulative across builds in a process":
      ## The row is a DIFFERENCE taken across one `runBuild`, not a reading
      ## of the process-wide counter. Without that, a long-lived process —
      ## the daemon, `repro watch`, this test binary — would report every
      ## earlier build's children too, and the ~zero case next door would
      ## decay into "no build in this process ever spawned anything".
      let tempRoot = createTempDir("repro-child-cpu-reset", "")
      defer: removeDir(tempRoot)

      # Build one pays for children and is deliberately the LARGER graph.
      let firstRoot = tempRoot / "first"
      let firstGraph = fixtureGraph(firstRoot, "reset-first", edges = 3)
      let first = runBuild(firstGraph, statsConfig(tempRoot / "first-cache"))
      for act in firstGraph.actions:
        check first.byId(act.id).status == asSucceeded
      check first.childCpuUs() > 0.0

      # Build two, in the same process, must report only its own children.
      # A cumulative counter would report at least build one's total here, so
      # requiring build two to come in BELOW build one is what falsifies it.
      let secondRoot = tempRoot / "second"
      let secondGraph = fixtureGraph(secondRoot, "reset-second", edges = 1)
      let second = runBuild(secondGraph, statsConfig(tempRoot / "second-cache"))
      for act in secondGraph.actions:
        check second.byId(act.id).status == asSucceeded
      check second.childCpuUs() > 0.0
      check second.childCpuUs() < first.childCpuUs()

    test "the row sits in the timing category with `repro process wait`":
      ## The row is only interpretable next to the wall-clock row it
      ## qualifies, so it must be collected by the same switch that collects
      ## that row and be absent when timing is not being measured. A row that
      ## appeared without `--measure=timing` would reach `repro stats` with
      ## nothing beside it to read it against.
      let tempRoot = createTempDir("repro-child-cpu-gate", "")
      defer: removeDir(tempRoot)

      let measuredRoot = tempRoot / "measured"
      let measuredGraph = fixtureGraph(measuredRoot, "gate-measured")
      let measured = runBuild(measuredGraph,
        statsConfig(tempRoot / "measured-cache"))
      for act in measuredGraph.actions:
        check measured.byId(act.id).status == asSucceeded
      check measured.hasMetric(ChildCpuRow)
      # Its companion row, from the same build, so "same category" is
      # asserted rather than asserted-about-in-prose.
      check measured.hasMetric(ProcessWaitRow)

      let offRoot = tempRoot / "off"
      let offGraph = fixtureGraph(offRoot, "gate-off")
      var offConfig = statsConfig(tempRoot / "off-cache")
      offConfig.statsEnabled = false
      let off = runBuild(offGraph, offConfig)
      # The build still ran and still spawned children; only the collection
      # is off. Without this the case would pass against a build that failed.
      for act in offGraph.actions:
        check off.byId(act.id).status == asSucceeded
      check off.launchedCount(offGraph) == offGraph.actions.len
      check not off.hasMetric(ChildCpuRow)
      check not off.hasMetric(ProcessWaitRow)
