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
## 2. BEHAVIOURAL: replicate the membership logic of the two
##    ``addUnique`` overloads locally and count logical membership
##    checks at N=800 and N=2000. The old linear-find shape performs a
##    sequence scan for each candidate and therefore grows
##    super-linearly. The HashSet shape performs one membership probe
##    per non-empty candidate and therefore grows linearly. Counting
##    comparisons directly makes the complexity assertion deterministic
##    and avoids wall-clock noise from allocators, CPU throttling, or
##    shared CI runners.
##
## Caveat: the behavioural arm exercises a LOCAL COPY of the helpers,
## not the engine's actual code paths. The structural arm is what
## guards the engine source against a regression. A future refactor
## that splits the evidence-aggregation procs into an importable
## module would let us replace the local copy with a direct call —
## see ``libs/repro_build_engine/src/repro_build_engine.nim`` line ~498
## for the helper definitions.

import std/[os, sets, strutils, unittest]

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
# Complexity-count helpers
# ---------------------------------------------------------------------------

proc countLegacyDedup(values: seq[string]):
    tuple[comparisons: int; uniqueCount: int] =
  ## Mirrors the old ``addUnique`` membership logic and counts every
  ## equality comparison done by the linear ``find`` scan.
  var dest: seq[string] = @[]
  for v in values:
    if v.len == 0:
      continue
    var found = false
    for existing in dest:
      inc result.comparisons
      if existing == v:
        found = true
        break
    if not found:
      dest.add(v)
  result.uniqueCount = dest.len

proc countFastDedup(values: seq[string]):
    tuple[probes: int; uniqueCount: int] =
  ## Mirrors the D4 fix at the algorithm boundary: one HashSet
  ## membership operation per non-empty candidate while the seq retains
  ## insertion order.
  var dest: seq[string] = @[]
  var seen = initHashSet[string]()
  for v in values:
    if v.len == 0:
      continue
    inc result.probes
    dest.fastAddUnique(seen, v)
  result.uniqueCount = dest.len

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
    # hot paths must use the HashSet overload. RMDF folding now lives in
    # ``foldMonitorDepFileEvidence`` and ``collectEvidence`` threads the
    # same ``EvidenceSeenSets`` through it, so scan both bodies and assert
    # NONE of the calls of the form ``evidence.monitorReads.addUnique(path)``
    # (the legacy single-arg shape) remain.
    let collectStart = src.find("proc collectEvidence(")
    check collectStart >= 0
    # Find the end of collectEvidence — first ``\nproc `` after the body.
    let bodyStart = src.find('\n', collectStart) + 1
    let collectEnd = src.find("\nproc ", bodyStart)
    let collectBody =
      if collectEnd < 0: src.substr(bodyStart)
      else: src.substr(bodyStart, collectEnd - 1)
    check "foldMonitorDepFileEvidence(action.monitorDepfile" in collectBody
    check "action.cwd, result.evidence, seen" in collectBody

    let foldStart = src.find("proc foldMonitorDepFileEvidence*(")
    check foldStart >= 0
    let foldBodyStart = src.find('\n', foldStart) + 1
    let foldEnd = src.find("\nproc ", foldBodyStart)
    let foldBody =
      if foldEnd < 0: src.substr(foldBodyStart)
      else: src.substr(foldBodyStart, foldEnd - 1)

    # The legacy shape on the evidence fields would be e.g.
    # ``evidence.monitorReads.addUnique(path)``. The new shape is
    # ``evidence.monitorReads.addUnique(seen.monitorReads, path)``.
    # Assert the new shape appears at least once and the old shape does NOT.
    check "seen.monitorReads" in foldBody
    check "seen.monitorWrites" in foldBody
    check "seen.monitorProbes" in foldBody
    # Anti-regression: the legacy single-arg dotted call on monitor* fields
    # must NOT appear in either hot body.
    check not ("monitorReads.addUnique(path)" in collectBody)
    check not ("monitorWrites.addUnique(path)" in collectBody)
    check not ("monitorProbes.addUnique(path)" in collectBody)
    check not ("monitorReads.addUnique(path)" in foldBody)
    check not ("monitorWrites.addUnique(path)" in foldBody)
    check not ("monitorProbes.addUnique(path)" in foldBody)
    checkpoint("engine source structural check: OK")

  test "behavioural: HashSet dedup scales linearly while linear-find is quadratic":
    # N=800 / N=2000 keep the 2.5x ratio the linear-scale arm reasons
    # about while landing both points at realistic B3/B5 action counts.
    let pathsLow = makePaths(800)
    let pathsHigh = makePaths(2000)

    let legacyLow = countLegacyDedup(pathsLow)
    let legacyHigh = countLegacyDedup(pathsHigh)
    let fastLow = countFastDedup(pathsLow)
    let fastHigh = countFastDedup(pathsHigh)

    checkpoint("legacy  N=800 comparisons: " & $legacyLow.comparisons)
    checkpoint("legacy  N=2000 comparisons: " & $legacyHigh.comparisons)
    checkpoint("fast    N=800 probes: " & $fastLow.probes)
    checkpoint("fast    N=2000 probes: " & $fastHigh.probes)

    # Both paths deduplicate to the same ordered unique set.
    check legacyLow.uniqueCount == fastLow.uniqueCount
    check legacyHigh.uniqueCount == fastHigh.uniqueCount

    # The HashSet shape performs exactly one membership probe per
    # non-empty candidate, so it scales linearly with N.
    check fastLow.probes == pathsLow.len
    check fastHigh.probes == pathsHigh.len
    let fastScale = fastHigh.probes.float / fastLow.probes.float
    checkpoint("fast probe scale 2000/800: " &
      fastScale.formatFloat(ffDecimal, 2) & "x")
    check fastScale == 2.5

    # The legacy linear-find shape does many more comparisons at the
    # high point and its growth is super-linear over the same input
    # distribution. This is deterministic because it counts the loop
    # body, not elapsed time.
    let speedupHigh = legacyHigh.comparisons.float / fastHigh.probes.float
    checkpoint("logical probe reduction at N=2000: " &
      speedupHigh.formatFloat(ffDecimal, 2) & "x")
    check speedupHigh >= 100.0

    let legacyScale =
      legacyHigh.comparisons.float / legacyLow.comparisons.float
    checkpoint("legacy comparison scale 2000/800: " &
      legacyScale.formatFloat(ffDecimal, 2) & "x")
    check legacyScale >= 5.5

    checkpoint("D4 evidence-aggregation scaling: OK")
