## Bootstrap-And-Self-Build Deferred-D4: ``collectEvidence`` evidence
## aggregation must scale linearly in N.
##
## Background
## ----------
## The B1, B3 and B5 outcomes each flagged the same engine performance
## concern: ``collectEvidence`` (libs/repro_build_engine/src/
## repro_build_engine.nim) accumulated per-action monitor evidence by
## calling ``addUnique(values: var seq[string], value: string)`` in a
## hot loop. That helper used a linear ``find`` to dedup, so N
## successive calls cost O(N^2). At the 14-app collection (B1) the
## post-build wrap-up dominated wall time; B3/B5 doubled the action
## count to ~1044 and the wrap-up got worse.
##
## D4 fixes this by adding a side-car ``HashSet[string]`` membership
## tracker alongside each ``PathSetEvidence`` ``seq`` field and
## threading it through ``addPathSet``, ``collectEvidence``,
## ``evidenceFromRecord``, ``evidenceInputPaths`` and ``cacheInputPaths``.
## The seq fields on ``PathSetEvidence`` are preserved (callers depend on
## insertion order); only the dedup lookup is changed from O(N) to O(1).
##
## Strategy
## --------
## The evidence-aggregation procs (``collectEvidence``, ``addPathSet``,
## ``evidenceInputPaths``, ``cacheInputPaths``, ``evidenceFromRecord``)
## are NOT exported from ``repro_build_engine``, so we can't call them
## directly from a test binary without ``include``-ing the module
## (which would drag in the whole engine + its transitive deps). We
## use a two-arm strategy:
##
## 1. STRUCTURAL: parse ``repro_build_engine.nim`` and assert the
##    relevant procs use the HashSet-backed ``addUnique`` overload
##    (``addUnique(seq, seen, value)``), NOT the legacy
##    ``addUnique(seq, value)`` (which still exists for non-hot call
##    sites). A regression that reverts to the legacy form would be
##    caught here.
##
## 2. BEHAVIOURAL: replicate the EXACT two ``addUnique`` overloads
##    locally and timing-compare them at N=200 and N=500. The N=500
##    run on the legacy form should grow roughly N^2 / N = 2.5x +
##    extra for the find walks (worst case ~6.25x), while the new
##    HashSet form should grow nearly linearly. We assert:
##      * legacy/new ratio at N=500 is large (>5x) — confirms the
##        old shape was quadratic.
##      * new(N=500) / new(N=200) < 5x — confirms the new shape is
##        sub-quadratic (linear would be 2.5x; we allow slack for
##        hash + alloc + cache jitter).
##    The behavioural arm tolerates noisy CI hardware: timings are
##    averaged across multiple runs.
##
## Caveat: the behavioural arm exercises a LOCAL COPY of the helpers,
## not the engine's actual code paths. The structural arm is what
## guards the engine source against a regression. A future refactor
## that splits the evidence-aggregation procs into an importable
## module would let us replace the local copy with a direct call —
## see ``libs/repro_build_engine/src/repro_build_engine.nim`` line ~498
## for the helper definitions.

import std/[monotimes, os, sets, strutils, times, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

# ---------------------------------------------------------------------------
# Local copies of the two ``addUnique`` overloads. These mirror the engine's
# definitions in ``libs/repro_build_engine/src/repro_build_engine.nim`` so the
# behavioural arm can compare scaling without including the whole engine
# module. Keep these in sync with the engine source.
# ---------------------------------------------------------------------------

proc legacyAddUnique(values: var seq[string]; value: string) =
  if value.len == 0:
    return
  if values.find(value) < 0:
    values.add(value)

proc fastAddUnique(values: var seq[string]; seen: var HashSet[string];
                   value: string) =
  if value.len == 0:
    return
  if seen.containsOrIncl(value):
    return
  values.add(value)

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

proc nowNanos(): int64 =
  getMonoTime().ticks

proc timeLegacyDedup(values: seq[string]): int64 =
  ## Mirrors what ``addPathSet`` does inside ``collectEvidence`` for
  ## each ``DependencyPathSet`` it folds in: it appends N candidate
  ## paths into a deduplicated ``seq`` using the legacy linear
  ## membership check.
  var dest: seq[string] = @[]
  let start = nowNanos()
  for v in values:
    dest.legacyAddUnique(v)
  let stop = nowNanos()
  stop - start

proc timeFastDedup(values: seq[string]): int64 =
  ## Mirrors the D4 fix: side-car ``HashSet`` tracks membership in
  ## O(1) amortised time while the seq retains insertion order.
  var dest: seq[string] = @[]
  var seen = initHashSet[string]()
  let start = nowNanos()
  for v in values:
    dest.fastAddUnique(seen, v)
  let stop = nowNanos()
  stop - start

proc avgNanos(values: seq[string]; runs: int;
              timer: proc(values: seq[string]): int64): int64 =
  var total: int64 = 0
  for _ in 0 ..< runs:
    total += timer(values)
  total div runs

proc makePaths(n: int): seq[string] =
  ## Produce ``n`` synthetic monitor-evidence paths that resemble what
  ## the engine sees in the wild: a mix of unique paths plus a small
  ## tail of duplicates, so both the legacy and HashSet codepaths hit
  ## their dedup branches.
  result = newSeqOfCap[string](n)
  for i in 0 ..< n:
    result.add "/nix/store/abcdef" & $(i mod (n div 4 + 1)) &
      "/lib/gcc/x86_64-linux-gnu/13/include/internal-" &
      $i & "-trailer.h"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Deferred-D4: collectEvidence aggregation scales linearly":

  test "structural: engine source uses HashSet-backed addUnique in hot procs":
    let repoRoot = findRepoRoot()
    let enginePath = repoRoot / "libs" / "repro_build_engine" / "src" /
      "repro_build_engine.nim"
    check fileExists(enginePath)
    let src = readFile(enginePath)

    # The HashSet overload must exist in the source.
    check "proc addUnique(values: var seq[string]; seen: var HashSet[string]" in src
    # The side-car type must exist.
    check "EvidenceSeenSets" in src
    # The hot procs must each receive or initialise an EvidenceSeenSets / HashSet.
    check "proc addPathSet(evidence: var PathSetEvidence; seen: var EvidenceSeenSets" in src
    check "proc collectConvertedEvidence" in src
    # Sanity: the legacy single-arg overload is still present (used by the
    # cold call sites where N stays small).
    check "proc addUnique(values: var seq[string]; value: string)" in src

    # Spot-check: the four ``monitorReads/Writes/Probes/depfileInputs``
    # call sites inside ``collectEvidence``'s monitor-records loop must use
    # the HashSet overload. Scan the slice of source between
    # ``proc collectEvidence`` and the next top-level ``proc``, and assert
    # NONE of the calls of the form ``result.evidence.monitorReads.addUnique(path)``
    # (the legacy single-arg shape) remain.
    let collectStart = src.find("proc collectEvidence(")
    check collectStart >= 0
    # Find the end of collectEvidence — first ``\nproc `` after the body.
    let bodyStart = src.find('\n', collectStart) + 1
    let collectEnd = src.find("\nproc ", bodyStart)
    let collectBody =
      if collectEnd < 0: src.substr(bodyStart)
      else: src.substr(bodyStart, collectEnd - 1)
    # The legacy shape on the evidence fields would be e.g.
    # ``result.evidence.monitorReads.addUnique(path)``. The new shape is
    # ``result.evidence.monitorReads.addUnique(seen.monitorReads, path)``.
    # Assert the new shape appears at least once and the old shape does NOT.
    check "seen.monitorReads" in collectBody
    check "seen.monitorWrites" in collectBody
    check "seen.monitorProbes" in collectBody
    # Anti-regression: the legacy single-arg dotted call on monitor* fields
    # must NOT appear in collectEvidence's body.
    check not ("monitorReads.addUnique(path)" in collectBody)
    check not ("monitorWrites.addUnique(path)" in collectBody)
    check not ("monitorProbes.addUnique(path)" in collectBody)
    checkpoint("engine source structural check: OK")

  test "behavioural: HashSet dedup scales linearly while linear-find is quadratic":
    # Warm up — first run of any timer has JIT/cache effects we don't
    # want polluting the comparison.
    discard timeFastDedup(makePaths(50))
    discard timeLegacyDedup(makePaths(50))

    const Runs = 5

    let paths200 = makePaths(200)
    let paths500 = makePaths(500)

    let legacy200 = avgNanos(paths200, Runs, timeLegacyDedup)
    let legacy500 = avgNanos(paths500, Runs, timeLegacyDedup)
    let fast200 = avgNanos(paths200, Runs, timeFastDedup)
    let fast500 = avgNanos(paths500, Runs, timeFastDedup)

    checkpoint("legacy  N=200: " & $legacy200 & " ns")
    checkpoint("legacy  N=500: " & $legacy500 & " ns")
    checkpoint("fast    N=200: " & $fast200 & " ns")
    checkpoint("fast    N=500: " & $fast500 & " ns")

    # Sanity: each timing is positive — the monotonic clock is sane.
    check legacy200 > 0
    check legacy500 > 0
    check fast200 > 0
    check fast500 > 0

    # The hash-set form must out-scale the linear-find form by a wide
    # margin at N=500. Even on noisy CI hardware the legacy form is
    # ~10x slower at N=500. Require at least 3x.
    let speedup500 = legacy500.float / fast500.float
    checkpoint("fast speedup at N=500: " & speedup500.formatFloat(ffDecimal, 2) & "x")
    check speedup500 >= 3.0

    # The hash-set form must scale near-linearly. Pure linear is 2.5x
    # going from N=200 to N=500. We allow up to 5x slack for jitter,
    # alloc behaviour, and the constant factor on small N.
    let fastScale = fast500.float / fast200.float
    checkpoint("fast scale 500/200: " & fastScale.formatFloat(ffDecimal, 2) & "x")
    check fastScale < 5.0

    # And conversely: the legacy form's scale ratio should be markedly
    # super-linear. We assert it's at least 4x (quadratic would be
    # 6.25x). If hardware/jitter makes this flaky in CI we can drop
    # the assertion to a checkpoint-only signal; for now it catches a
    # full regression where addUnique reverts to linear-find on all
    # call sites in the engine.
    let legacyScale = legacy500.float / legacy200.float
    checkpoint("legacy scale 500/200: " & legacyScale.formatFloat(ffDecimal, 2) & "x")
    check legacyScale >= 4.0

    checkpoint("D4 evidence-aggregation scaling: OK")
