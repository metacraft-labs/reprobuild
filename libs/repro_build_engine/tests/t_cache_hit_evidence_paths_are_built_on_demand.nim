## Reconstructing a cache hit's evidence is O(RECORDED INPUTS), and on a
## warm no-op almost nobody reads the result.
##
## `evidenceFromRecord` rebuilds a `PathSetEvidence` for every action the
## action cache serves: it copies both declared seqs and then hashes, copies
## and accumulates one string per entry in the record's input set — summed
## over every record the run looked up. Only TWO consumers ever read those
## STRINGS (`repro watch`'s watched-path set, `--write-report`'s
## `actions[].evidence`), and both are decided before the build starts. Every
## other consumer — the per-action log line's `evidence=depfile:<n>`,
## `--show=cache-evidence`, the `dependency-evidence` stats observation —
## takes lengths and nothing else.
##
## So `BuildEngineConfig.elideCacheHitEvidencePaths` lets a run say "no
## consumer of mine wants the strings", and the engine fills in
## `ActionResult.evidencePathCounts` instead. THE WHOLE POINT IS THAT NOTHING
## ELSE MOVES, and that is what this file grades, in both directions:
##
##   * the COUNTS are IDENTICAL, not approximately identical. Every accessor
##     a count reader can call is compared against the same accessor on a
##     run that built the full path sets, on the same tree, from the same
##     record. An implementation that skipped the de-duplication, or that
##     filled in zeroes, or that guessed `record.inputs.len`, fails here.
##   * the PATHS are still there when they are wanted. The elision is
##     opt-in and its default is off, because the failure mode of the other
##     polarity is silent: `repro watch` arming its watcher on an empty
##     path set is blind to every source file and still looks exactly like
##     a working watch loop. The CLI end of that is graded by
##     `tests/e2e/watch/t_e2e_repro_watch_arms_on_cache_hit_evidence.nim`;
##     this file grades the engine end, which is the one that decides
##     whether the strings exist at all.
##
## BOTH CACHE-HIT ARMS ARE GRADED, and that is not redundancy. A warm no-op
## does NOT go through the scheduler: `tryFastNoopCacheHits` short-circuits
## the whole graph and materialises the results itself, and it is the arm
## the measured regression lives on. The scheduler's per-action `aclHit`
## arms are the ones every other build takes. They reach the same seam by
## different routes, and a fix wired to one of them takes effect or not
## depending on which route the graph happened to take — so each case below
## runs both, and asserts which arm it got rather than assuming.
##
## MOCK POLICY — ONE SYNTHESISED CAPTURE, AND WHY IT IS THE RIGHT BOUNDARY.
## The observed reads are supplied as a real RMDF file, encoded with io-mon's
## OWN canonical encoder and carrying io-mon's own backend profile, exactly
## as `test_s5_own_output_is_not_a_cache_input.nim` does and for the same
## reason. Everything downstream of it is production code: the production
## fold turns it into evidence, the production publish writes the record, the
## production lookup reads it back, and the production
## `evidenceFromRecord` / `evidenceCountsFromRecord` pair reconstructs from
## it. What a real monitored process would add here is a runquotad and a
## preloaded shim — neither of which is on the path under test, which begins
## at a record that already exists. The end-to-end half, with a real build
## and a real capture, is the e2e file named above.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_build_engine
import repro_local_store
import io_mon/[capabilities, types, writer]

proc norm(path: string): string =
  path.replace('\\', '/')

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc rmdfBytes(records: varargs[MonitorRecord]): string =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    @records)
  result = newString(raw.len)
  if raw.len > 0:
    copyMem(addr result[0], unsafeAddr raw[0], raw.len)

type
  Counts = object
    ## Every integer a count reader in `repro_cli_support` can ask an
    ## `ActionResult` for. Collected through the ACCESSORS rather than the
    ## fields, because the accessors are what those readers call and are
    ## therefore what has to stay identical.
    elided: bool
    declaredInputs, declaredOutputs, depfileInputs: int
    monitorReads, monitorWrites, monitorProbes, diagnostics: int

proc countsOf(item: ActionResult): Counts =
  Counts(
    elided: item.evidencePathsElided(),
    declaredInputs: item.declaredInputCount(),
    declaredOutputs: item.declaredOutputCount(),
    depfileInputs: item.depfileInputCount(),
    monitorReads: item.monitorReadCount(),
    monitorWrites: item.monitorWriteCount(),
    monitorProbes: item.monitorProbeCount(),
    diagnostics: item.evidenceDiagnosticCount())

proc pathCount(item: ActionResult): int =
  item.evidence.declaredInputs.len + item.evidence.declaredOutputs.len +
    item.evidence.depfileInputs.len + item.evidence.monitorReads.len +
    item.evidence.monitorWrites.len + item.evidence.monitorProbes.len +
    item.evidence.diagnostics.len

proc observedPaths(item: ActionResult): HashSet[string] =
  ## The reconstructed path strings, in the union the two real consumers
  ## read (`collectInputEvidence` and `watchPathsFromOutcome` take exactly
  ## these four groups).
  result = initHashSet[string]()
  for group in [item.evidence.declaredInputs, item.evidence.depfileInputs,
      item.evidence.monitorReads, item.evidence.monitorProbes]:
    for path in group:
      result.incl(path.norm)

const ObservedInputCount = 24
  ## Enough undeclared observed reads that a count arrived at by any route
  ## OTHER than the real one — `record.inputs.len`, the declared count, zero
  ## — is a different number from the right one. With one or two it is easy
  ## for a wrong implementation to coincide with a right one.

type Fixture = object
  root, work, cacheRoot, output: string
  declared: seq[string]
  observed: seq[string]
  act: BuildAction

proc setupFixture(tag: string): Fixture =
  result = default(Fixture)
  result.root = createTempDir("repro-evidence-on-demand-" & tag & "-", "")
  result.work = result.root / "work"
  result.cacheRoot = result.root / "cache"
  result.output = result.work / "out" / "product.txt"
  createDir(result.work / "src")
  createDir(result.work / "obs")
  createDir(result.work / "out")

  # The DECLARED input. `bakCopyFile` takes exactly one, which is also
  # what makes `declaredInputs == 1` a number a wrong implementation could
  # coincide with — hence the much larger observed population below, which
  # is the count that actually discriminates.
  for name in ["input.txt"]:
    let path = result.work / "src" / name
    writeFile(path, "declared " & name & "\n")
    result.declared.add(path)

  # …and a population of OBSERVED reads the record will carry but the
  # action never declared. These are the entries the reconstruction loops
  # over, and the ones the elided arm must count without building.
  var records: seq[MonitorRecord] = @[]
  for i in 0 ..< ObservedInputCount:
    let path = result.work / "obs" / ("observed-" & $i & ".h")
    writeFile(path, "observed " & $i & "\n")
    result.observed.add(path)
    records.add(fileRead(path))
  # A DUPLICATE and a DECLARED path among the observed records. Both are
  # entries `evidenceFromRecord` de-duplicates or filters away, so a
  # counting arm that merely totalled the record's inputs would overcount
  # by exactly these two.
  records.add(fileRead(result.observed[0]))
  records.add(fileRead(result.declared[0]))

  let rmdfPath = result.root / "copy.rdep"
  writeFile(rmdfPath, rmdfBytes(records))

  result.act = builtinAction(bakCopyFile, "produce",
    cwd = result.work,
    inputs = ["src/input.txt"],
    outputs = ["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.act.monitorDepfile = rmdfPath

proc baseConfig(f: Fixture; wholeGraphArm: bool): BuildEngineConfig =
  result = defaultBuildEngineConfig(f.cacheRoot)
  if wholeGraphArm:
    # The shape a warm `repro build` no-op really has, and the only one
    # `tryFastNoopCacheHits` will take: rebuild-missing-outputs rather than
    # CAS restore, no progress callback, nothing published.
    result.rebuildMissingOutputsOnCacheHit = true
    result.deferLocalOutputBlobs = true

proc runOnce(f: Fixture; config: BuildEngineConfig): ActionResult =
  let build = runBuild(graph([f.act]), config)
  doAssert build.results.len == 1
  build.results[0]

type
  Graded = object
    ## What one arm's three runs OBSERVED. Returned rather than asserted
    ## in place so the assertions live in the `test` bodies below, where a
    ## reader — and `scripts/check_vacuous_test_cases.py` — can see what
    ## each case actually claims.
    armName: string
    executedStatus: ActionStatus
    executedElided: bool
    hitStatus, elidedStatus: ActionStatus
    hitDecision, elidedDecision: CacheDecision
    defaultElideFlag: bool
    fullElided, elidedElided: bool
    fullPathCount, elidedPathCount: int
    missingPaths: seq[string]
      ## Every path that MUST be in the reconstruction and is not. Collected
      ## rather than checked one by one so a failure names all of them.
    fullCounts, elidedCounts: Counts
    declaredInputsInFixture: int

proc gradeArm(wholeGraphArm: bool): Graded =
  result = default(Graded)
  result.armName = if wholeGraphArm: "whole-graph fast no-op scan"
                   else: "per-action scheduler"
  let f = setupFixture(if wholeGraphArm: "fast" else: "sched")
  defer: removeDir(f.root)
  result.declaredInputsInFixture = f.declared.len

  # 1. Execute. Publishes the record every later run reconstructs from.
  let first = f.runOnce(f.baseConfig(wholeGraphArm))
  result.executedStatus = first.status
  # An executed action's evidence is collected live and is NEVER elided,
  # whatever the flag says — the flag is about reconstruction only.
  result.executedElided = first.evidencePathsElided()

  # 2. Cache hit with the paths WANTED. This is today's behaviour and the
  #    reference every number below is compared against.
  var withPaths = f.baseConfig(wholeGraphArm)
  result.defaultElideFlag = withPaths.elideCacheHitEvidencePaths
  let full = f.runOnce(withPaths)
  result.hitStatus = full.status
  result.hitDecision = full.cacheDecision
  result.fullElided = full.evidencePathsElided()
  result.fullPathCount = full.pathCount()
  result.fullCounts = full.countsOf()

  # The strings that must be there, and that the watcher needs: every
  # undeclared observed read, plus the declared input. The declared entries
  # keep the action's OWN spelling (`evidenceFromRecord` copies
  # `action.inputs` verbatim, relative paths and all) while the observed
  # ones arrive materialised from the record — compared as they really are
  # rather than normalised to one shape, because `addWatchCandidate`
  # resolves the relative form against the project root and a test that
  # papered over the difference would not notice it disappearing.
  let seenPaths = full.observedPaths()
  for path in f.observed:
    if path.norm notin seenPaths: result.missingPaths.add(path)
  for declared in f.act.inputs:
    if declared.norm notin seenPaths: result.missingPaths.add(declared)

  # 3. The same cache hit with the paths ELIDED.
  var withoutPaths = f.baseConfig(wholeGraphArm)
  withoutPaths.elideCacheHitEvidencePaths = true
  let elided = f.runOnce(withoutPaths)
  result.elidedStatus = elided.status
  result.elidedDecision = elided.cacheDecision
  result.elidedElided = elided.evidencePathsElided()
  result.elidedPathCount = elided.pathCount()
  result.elidedCounts = elided.countsOf()

proc gradeChecks(g: Graded; expectedHitStatus: ActionStatus) =
  ## The preconditions, shared because they are identical for both arms and
  ## because getting one of them wrong is how a case comes to compare two
  ## freshly executed actions and prove nothing about reconstruction. The
  ## CLAIMS live in the two `test` bodies below, spelled out, where a reader
  ## — and `scripts/check_vacuous_test_cases.py` — can see them.
  checkpoint("arm: " & g.armName)
  checkpoint("with paths:    " & $g.fullCounts)
  checkpoint("without paths: " & $g.elidedCounts)
  checkpoint("missing paths: " & $g.missingPaths)
  require g.executedStatus == asSucceeded
  require g.hitDecision == cdHit
  require g.elidedDecision == cdHit
  require g.hitStatus == expectedHitStatus
  require g.elidedStatus == expectedHitStatus

suite "cache-hit evidence paths are built on demand":

  test "the whole-graph fast no-op arm keeps every count and drops the strings":
    ## `asUpToDate` is `tryFastNoopCacheHits`'s vocabulary. Requiring it is
    ## what makes this case about the whole-graph short-circuit rather than
    ## about whichever arm the graph happened to take.
    let g = gradeArm(wholeGraphArm = true)
    g.gradeChecks(expectedHitStatus = asUpToDate)

    # An executed action's evidence is collected live and is NEVER elided.
    check not g.executedElided
    # The default is OFF, and with it off every string is present.
    check not g.defaultElideFlag
    check not g.fullElided
    check g.missingPaths.len == 0
    check g.fullPathCount > 0
    # The flag did something…
    check g.elidedElided
    check g.elidedPathCount == 0
    # …and it did ONLY that. Identical field by field, not approximately.
    check g.elidedCounts.declaredInputs == g.fullCounts.declaredInputs
    check g.elidedCounts.declaredOutputs == g.fullCounts.declaredOutputs
    check g.elidedCounts.depfileInputs == g.fullCounts.depfileInputs
    check g.elidedCounts.monitorReads == g.fullCounts.monitorReads
    check g.elidedCounts.monitorWrites == g.fullCounts.monitorWrites
    check g.elidedCounts.monitorProbes == g.fullCounts.monitorProbes
    check g.elidedCounts.diagnostics == g.fullCounts.diagnostics
    # Vacuity guard. Every equality above holds trivially if the
    # reconstruction found nothing to count, and "both sides are zero" is
    # exactly what a broken record lookup would produce. The undeclared
    # observed reads land in ONE of the two observed channels depending on
    # the action's dependency policy, so the claim is on their sum — and
    # the sum is the population, with the planted duplicate and the planted
    # declared path removed.
    check g.fullCounts.depfileInputs + g.fullCounts.monitorReads ==
      ObservedInputCount
    check g.fullCounts.declaredInputs == g.declaredInputsInFixture
    check g.fullCounts.declaredOutputs == 1

  test "the per-action scheduler arm keeps every count and drops the strings":
    ## The SAME claims against the scheduler's per-action `aclHit` arms,
    ## which every build that is not a whole-graph no-op takes. `asCacheHit`
    ## is that arm's vocabulary, and requiring it is what stops this case
    ## from silently becoming a second copy of the one above. The assertions
    ## are written out rather than shared through a helper so each case
    ## states what it claims.
    let g = gradeArm(wholeGraphArm = false)
    g.gradeChecks(expectedHitStatus = asCacheHit)

    check not g.executedElided
    check not g.defaultElideFlag
    check not g.fullElided
    check g.missingPaths.len == 0
    check g.fullPathCount > 0
    check g.elidedElided
    check g.elidedPathCount == 0
    check g.elidedCounts.declaredInputs == g.fullCounts.declaredInputs
    check g.elidedCounts.declaredOutputs == g.fullCounts.declaredOutputs
    check g.elidedCounts.depfileInputs == g.fullCounts.depfileInputs
    check g.elidedCounts.monitorReads == g.fullCounts.monitorReads
    check g.elidedCounts.monitorWrites == g.fullCounts.monitorWrites
    check g.elidedCounts.monitorProbes == g.fullCounts.monitorProbes
    check g.elidedCounts.diagnostics == g.fullCounts.diagnostics
    check g.fullCounts.depfileInputs + g.fullCounts.monitorReads ==
      ObservedInputCount
    check g.fullCounts.declaredInputs == g.declaredInputsInFixture
    check g.fullCounts.declaredOutputs == 1

  test "the two reconstructions agree on records the publish path cannot write":
    ## The equalities above run against records this engine WROTE, and
    ## `cacheInputPaths` de-duplicates before it publishes — so a counting
    ## arm that skipped de-duplication entirely would pass every case above.
    ## Measured: removing the `containsOrIncl` left all three green.
    ##
    ## Records are not only written by this engine, though. They are read
    ## back from a user-level cache root shared with other `repro` builds,
    ## and (Peer-Cache M1) pulled from a LAN peer. So the agreement asserted
    ## here is over ARBITRARY records rather than well-formed ones, by
    ## handing both reconstructions the same hostile input directly:
    ## duplicates, a declared path repeated among the observed set, and a
    ## declared path in its materialised spelling.
    let workRoot =
      when defined(windows): "C:/repro-evidence-counts/proj"
      else: "/repro-evidence-counts/proj"
    let act = action("reconstruct", ["tool"],
      cwd = workRoot,
      inputs = ["src/main.c", "src/main.h"],
      outputs = ["out/main.o"],
      cacheable = true,
      monitorDepfile = workRoot / "tool.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var record: ActionResultRecord
    for path in [
        workRoot / "obs" / "a.h",
        workRoot / "obs" / "b.h",
        workRoot / "obs" / "a.h",          # a duplicate
        workRoot / "src" / "main.c",       # a DECLARED input, materialised
        workRoot / "obs" / "c.h",
        workRoot / "obs" / "b.h",          # a second duplicate
        workRoot / "src" / "main.h"]:      # the other declared input
      record.inputs.add(FileFingerprint(path: path))

    let evidence = evidenceFromRecord(act, record)
    let counts = evidenceCountsFromRecord(act, record)
    checkpoint("full: reads=" & $evidence.monitorReads.len &
      " depfile=" & $evidence.depfileInputs.len)
    check counts.elided
    check counts.declaredInputs == evidence.declaredInputs.len
    check counts.declaredOutputs == evidence.declaredOutputs.len
    check counts.depfileInputs == evidence.depfileInputs.len
    check counts.monitorReads == evidence.monitorReads.len
    check counts.monitorWrites == evidence.monitorWrites.len
    check counts.monitorProbes == evidence.monitorProbes.len
    check counts.diagnostics == evidence.diagnostics.len
    # Vacuity guard, and the discriminating number: three distinct
    # undeclared reads out of seven record entries. `7` is what dropping
    # the declared filter gives, `5` is what dropping de-duplication gives,
    # `0` is what an unimplemented arm gives.
    check counts.depfileInputs + counts.monitorReads == 3

  test "eliding paths changes no cache decision on a changed input":
    ## The elision is presentation-layer work. Nothing it touches may reach
    ## a cache key — so the same tree, mutated the same way, must still
    ## MISS under both settings. Without this the two cases above would be
    ## just as green against an implementation that stopped revalidating.
    for elide in [false, true]:
      let f = setupFixture("invalidate")
      defer: removeDir(f.root)
      var config = f.baseConfig(wholeGraphArm = true)
      config.elideCacheHitEvidencePaths = elide

      require f.runOnce(config).status == asSucceeded
      require f.runOnce(config).cacheDecision == cdHit

      # An UNDECLARED, observed-only input changes. It is in the record's
      # keyed input set, so the next lookup must miss.
      writeFile(f.observed[3], "observed 3 changed\n")
      let after = f.runOnce(config)
      checkpoint("elide=" & $elide & " decision=" & $after.cacheDecision)
      check after.cacheDecision != cdHit
      check after.launched
