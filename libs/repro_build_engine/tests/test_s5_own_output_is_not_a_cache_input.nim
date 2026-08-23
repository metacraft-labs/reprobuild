## S5 — an action's own declared output is NOT one of its inputs.
##
## A linker opens the file it is writing. So does an archiver, and so does
## every compiler that stats its target before truncating it. The monitor
## records those accesses faithfully, they arrive in
## ``PathSetEvidence.monitorReads`` / ``monitorProbes``, and until this fix
## ``cacheInputPaths`` folded them straight into the action-cache key. The
## action therefore depended on itself, with both of the consequences you
## would predict:
##
##   * a warm relink missed with ``cdMiss reason=input metadata changed:
##     <its own output>``, because the relink had just rewritten the file
##     whose metadata the key remembered; and
##   * CAS restore could never fire at all — delete a materialized output
##     and the lookup for the entry that could restore it misses on the
##     very file that is missing.
##
## The rule pinned here is the hermetic-build rule: bytes the action
## produced in THIS run are not an input, because whatever content was
## there before cannot affect the result. See ``selfWrittenOutputKeys``.
##
## Both directions are asserted, because the dangerous failure here is the
## opposite one. Dropping a genuine input from the key means serving a
## stale result — a false cache hit, the cardinal sin — which is strictly
## worse than the miss being fixed. So the negative direction (own output
## absent) is always paired with the positive direction (genuine observed
## inputs still present), including inputs that live in the same directory
## as the output and one whose path has the output's path as a string
## prefix. An over-broad filter — by directory, by prefix, by "looks like
## an output" — fails those.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_local_store
import io_mon/[types, writer]

const UnitRoot =
  when defined(windows): "C:/repro-s5-unit"
  else: "/repro-s5-unit"

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

proc recordHasInput(record: ActionResultRecord; wanted: string): bool =
  for input in record.inputs:
    if input.path.norm == wanted.norm:
      return true

proc readRecord(path: string): ActionResultRecord =
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  decodeActionResultRecord(bytes)

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc pathProbe(path: string): MonitorRecord =
  MonitorRecord(kind: mrPathProbe, observationKind: moPathProbe,
    osPid: 4242, threadId: 4242, path: path, detail: "")

suite "S5 an action's own declared output is not one of its inputs":

  test "cacheInputPaths drops the own output and keeps its neighbours":
    ## The narrow assertion, straight on the fold that builds the
    ## action-cache key. The evidence below is the shape a real link edge
    ## produces: the linker read and probed the binary it was writing, and
    ## it also read genuine inputs that happen to live in the very same
    ## directory — an import library and a manifest whose path literally
    ## starts with the output's path. Only the exact declared output may
    ## disappear.
    let workRoot = UnitRoot / "proj"
    let outDir = workRoot / "out"
    let ownOutput = outDir / "app.exe"
    let siblingInput = outDir / "app.lib"
    let prefixInput = outDir / "app.exe.manifest"
    let declaredInput = workRoot / "src" / "main.o"
    let unrelatedInput = workRoot / "src" / "shared.h"

    let act = action("link", ["linker", "-o", ownOutput],
      cwd = workRoot,
      inputs = ["src/main.o"],
      outputs = ["out/app.exe"],
      cacheable = true,
      monitorDepfile = workRoot / "link.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.declaredOutputs = act.outputs
    evidence.monitorReads = @[declaredInput, ownOutput, siblingInput,
                              prefixInput, unrelatedInput]
    evidence.monitorProbes = @[ownOutput, siblingInput]
    evidence.depfileInputs = @[ownOutput, unrelatedInput]
    evidence.monitorWrites = @[ownOutput]

    let inputs = act.cacheInputPaths(evidence)

    # The defect.
    check not inputs.hasPath(ownOutput)

    # The cardinal-sin guard: every genuine input survives, including the
    # two that an over-broad directory or prefix filter would take with it.
    check inputs.hasPath(declaredInput)
    check inputs.hasPath(siblingInput)
    check inputs.hasPath(prefixInput)
    check inputs.hasPath(unrelatedInput)

  test "a path declared as BOTH input and output stays in the key":
    ## The carve-out. An incremental tool that reads the state a previous
    ## run left behind genuinely consumes its own output — the action is
    ## not hermetic, and the one thing it must never do is silently take a
    ## hit on stale state. The declaration wins over the self-write filter,
    ## the path stays in the key, and the action misses instead. This is
    ## also what keeps the new filter from colliding with
    ## ``cacheInputPaths``' ``declaredMaterialized`` retention, whose whole
    ## job is that an explicit declaration outranks a heuristic.
    let workRoot = UnitRoot / "incremental"
    let statePath = workRoot / "state" / "db.idx"

    let act = action("incremental", ["tool"],
      cwd = workRoot,
      inputs = ["state/db.idx"],
      outputs = ["state/db.idx"],
      cacheable = true,
      monitorDepfile = workRoot / "tool.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.declaredOutputs = act.outputs
    evidence.monitorReads = @[statePath]
    evidence.monitorWrites = @[statePath]

    check act.selfConsumedDeclaredPaths().hasPath(statePath)
    check act.cacheInputPaths(evidence).hasPath(statePath)

  test "a hermetic action reports no self-consumed declared path":
    ## Distinguishing case for the carve-out: an ordinary edge must not
    ## trip it, or the diagnostic below would fire on every action and the
    ## exemption would swallow the fix.
    let workRoot = UnitRoot / "proj"
    let act = action("link", ["linker"],
      cwd = workRoot,
      inputs = ["src/main.o"],
      outputs = ["out/app.exe"],
      cacheable = true,
      monitorDepfile = workRoot / "link.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check act.selfConsumedDeclaredPaths().len == 0

  test "the non-hermetic declaration is reported, not silently accepted":
    ## ...and it says so out loud in the action's evidence diagnostics, so
    ## the permanent miss that follows does not read as a caching bug.
    let tempRoot = createTempDir("repro-s5-selfconsume", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    createDir(workRoot / "state")
    writeFile(workRoot / "state" / "db.idx", "prior state\n")

    let rmdfPath = tempRoot / "tool.rdep"
    writeFile(rmdfPath, cast[string](encodeCanonical(
      @[fileRead(workRoot / "state" / "db.idx")])))

    var act = builtinAction(bakWriteText, "incremental",
      cwd = workRoot,
      inputs = ["state/db.idx"],
      outputs = ["state/db.idx"],
      cacheable = true,
      text = "rewritten state\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.monitorDepfile = rmdfPath

    let config = defaultBuildEngineConfig(tempRoot / "cache")
    let run = runBuild(graph([act]), config)
    check run.results[0].status == asSucceeded
    var reported = false
    for diagnostic in run.results[0].evidence.diagnostics:
      if "both an input and an output" in diagnostic:
        reported = true
    check reported

  test "a deleted output is RESTORED from the CAS on the next build":
    ## The end-to-end point of the whole fix, and the property that has
    ## never held on Windows: with the output blobs actually in the local
    ## CAS, deleting a materialized output must produce a cache HIT that
    ## restores it, not a miss on the deleted file itself.
    ##
    ## ``defaultBuildEngineConfig`` is already the blob-storing
    ## configuration — ``deferLocalOutputBlobs = false`` stores the
    ## payloads and ``rebuildMissingOutputsOnCacheHit = false`` takes the
    ## restore branch rather than re-running the action. (``repro build``
    ## flips both, which is why the CLI's own builds never exercise this
    ## path.)
    ##
    ## Before the fix this test fails on the second run: the record's input
    ## set contained ``out/product.txt``, the file that was just deleted,
    ## so the lookup returned ``aclMissInputChanged`` and the action re-ran.
    let tempRoot = createTempDir("repro-s5-cas-restore", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    let outputPath = workRoot / "out" / "product.txt"
    # A genuine observed input that lives in the SAME directory as the
    # output. It must stay in the key: if the filter were scoped to the
    # output DIRECTORY instead of the output PATH, this test would still
    # pass its restore assertion while having silently stopped tracking a
    # real dependency — so the record is asserted on directly, and the
    # next test makes the neighbour's change force a miss.
    let neighbourPath = workRoot / "out" / "neighbour.txt"
    let sourcePath = workRoot / "src" / "input.txt"
    createDir(workRoot / "src")
    createDir(workRoot / "out")
    writeFile(sourcePath, "payload\n")
    writeFile(neighbourPath, "neighbour\n")

    let rmdfPath = tempRoot / "copy.rdep"
    writeFile(rmdfPath, cast[string](encodeCanonical(@[
      fileRead(sourcePath),
      fileRead(neighbourPath),
      fileRead(outputPath),
      pathProbe(outputPath)])))

    var act = builtinAction(bakCopyFile, "produce",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/product.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.monitorDepfile = rmdfPath

    let config = defaultBuildEngineConfig(cacheRoot)
    check not config.deferLocalOutputBlobs
    check not config.rebuildMissingOutputsOnCacheHit

    let first = runBuild(graph([act]), config)
    check first.results[0].status == asSucceeded
    check first.results[0].launched
    check fileExists(outputPath)

    # The published record is the artefact the next lookup compares
    # against. Assert the property on it directly, both directions.
    let record = readRecord(dependencyEvidencePath(cacheRoot, act.id))
    check not record.recordHasInput(outputPath)
    check record.recordHasInput(neighbourPath)
    check record.recordHasInput(sourcePath)

    removeFile(outputPath)
    check not fileExists(outputPath)

    let second = runBuild(graph([act]), config)
    check second.results[0].cacheDecision == cdHit
    check second.results[0].status == asCacheHit
    check not second.results[0].launched
    check second.results[0].reason == "restored"
    check fileExists(outputPath)
    check readFile(outputPath) == "payload\n"

  test "a genuine neighbouring input's change still forces a miss":
    ## The same scenario with one byte of the neighbouring observed input
    ## changed. It must MISS. Without this, the restore test alone would
    ## pass just as happily against a filter that dropped every path under
    ## the output's directory — which would be a false cache hit waiting
    ## to happen.
    let tempRoot = createTempDir("repro-s5-cas-invalidate", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    let outputPath = workRoot / "out" / "product.txt"
    let neighbourPath = workRoot / "out" / "neighbour.txt"
    let sourcePath = workRoot / "src" / "input.txt"
    createDir(workRoot / "src")
    createDir(workRoot / "out")
    writeFile(sourcePath, "payload\n")
    writeFile(neighbourPath, "neighbour\n")

    let rmdfPath = tempRoot / "copy.rdep"
    writeFile(rmdfPath, cast[string](encodeCanonical(@[
      fileRead(sourcePath),
      fileRead(neighbourPath),
      fileRead(outputPath),
      pathProbe(outputPath)])))

    var act = builtinAction(bakCopyFile, "produce",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/product.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.monitorDepfile = rmdfPath

    let config = defaultBuildEngineConfig(cacheRoot)
    let first = runBuild(graph([act]), config)
    check first.results[0].status == asSucceeded

    removeFile(outputPath)
    writeFile(neighbourPath, "neighbour changed\n")

    let second = runBuild(graph([act]), config)
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].launched
