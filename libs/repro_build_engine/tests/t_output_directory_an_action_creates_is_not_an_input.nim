## A directory a declared output lives in is not an EXISTENCE input of the
## action that writes the output — in particular not when the action itself
## created it.
##
## The defect (reprobuild-pm
## `issues/2026-10-16-action-created-directories-recorded-as-post-run-inputs.md`):
## an action shaped `sh -c 'mkdir -p build && cat input.txt >
## build/artifact.txt'` probes `build/` BEFORE `mkdir` creates it. The monitor
## faithfully reports that probe, and the recorder identifies every input by
## what is on disk AFTER the run — so the record said `build` is a
## DIRECTORY while what the action observed was ABSENT. Every consumer whose
## tree does not already hold that directory then recomputes `absent` and can
## never match: a second checkout looking the record up in the portable memo
## plane, a peer, and the producing checkout itself after `rm -rf build`.
## Only the producer's own warm builds converged, because its first run had
## left the directory behind.
##
## The rule pinned here (Filesystem-Policy-And-Observed-Inputs.md §"A
## directory an output lives in is not an existence input"): every ancestor
## directory of a declared output exists after every successful run and after
## every cache hit (restoring the output creates it), so its existence is the
## action's own side effect, the S5 rule one path component up. Both
## directions are asserted, as in `test_s5_own_output_is_not_a_cache_input`:
## the dangerous failure is the false HIT, so every negative assertion is
## paired with a genuine input that must survive — a string-prefix sibling,
## a non-ancestor path beneath the output directory, a file next to the
## output, and an ancestor the author DECLARED as an input.
##
## MOCK POLICY — one justified stand-in. The scheduler (`runBuild`), the
## evidence fold, the per-edge action cache, the CAS, the restore path, the
## portable fingerprint and the portable memo store and lookup are all the
## production ones, run against the real filesystem. What is supplied is the
## monitor capture: an RMDF written with io-mon's OWN canonical encoder and
## this host's real backend profile (`profileRecords`), read back by the
## production reader. It is supplied because the action under test is a
## builtin copy, which the engine does not monitor, and because the property
## is about how the engine KEYS an observation, not about whether a given
## shell happens to probe before `mkdir` on a given platform (measured by the
## issue on macOS with the real shim; the RMDF reproduces that observation
## exactly: a probe of the directory, a read of the source, a write of the
## output).

import std/[options, os, sets, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import io_mon/[capabilities, types, writer]

const UnitRoot =
  when defined(windows): "C:/repro-output-ancestor-unit"
  else: "/repro-output-ancestor-unit"

proc norm(path: string): string =
  result = path.replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

proc recordHasInput(record: ActionResultRecord; wanted: string): bool =
  # Compared in both spellings: on macOS `createTempDir` answers
  # `/var/folders/...` while the recorder may hold the resolved
  # `/private/var/folders/...`, and a negative assertion that only checked
  # one spelling would pass vacuously.
  let resolved =
    try: expandFilename(wanted) except CatchableError: wanted
  for input in record.inputs:
    if input.path.norm == wanted.norm or input.path.norm == resolved.norm:
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

proc fileWrite(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc pathProbe(path: string): MonitorRecord =
  MonitorRecord(kind: mrPathProbe, observationKind: moPathProbe,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc dirEnumerate(path: string): MonitorRecord =
  MonitorRecord(kind: mrDirectoryEnumerate,
    observationKind: moDirectoryEnumerate,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc rmdfBytes(records: varargs[MonitorRecord]): string =
  ## The capture io-mon writes: backend profile and capability gaps first,
  ## then the observations. See `test_s5_own_output_is_not_a_cache_input`
  ## for why the preamble is required.
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    @records)
  result = newString(raw.len)
  if raw.len > 0:
    copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc fingerprintFor(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

type Checkout = object
  root: string
  source: string
  outputDir: string
  output: string
  rmdf: string

proc checkout(parent: string; content = "payload\n"): Checkout =
  ## A project whose build directory does NOT exist yet — the fresh-checkout
  ## shape the issue measured.
  result.root = parent / "proj"
  result.source = result.root / "input.txt"
  result.outputDir = result.root / "build"
  result.output = result.outputDir / "artifact.txt"
  result.rmdf = parent / "copy.rdep"
  createDir(result.root)
  writeFile(result.source, content)
  # The shell's observations, in the order it made them: `mkdir -p` probed
  # `build` (absent), `cat` read the source, the redirection wrote the
  # output. The probe is reported twice: once as the declaration spells it
  # and once with the existing prefix symlink-resolved, which is how the
  # real macOS monitor reports it (`/private/var/...` for a `/var/...`
  # temp dir). The second spelling is what `outputAncestorDirectoryKeys`'
  # resolved half exists for; on a host without a symlinked temp prefix the
  # two are the same path.
  let resolvedOutputDir = expandFilename(result.root) / "build"
  writeFile(result.rmdf, rmdfBytes(
    pathProbe(result.outputDir),
    pathProbe(resolvedOutputDir),
    fileRead(result.source),
    fileWrite(result.output)))

proc copyAction(c: Checkout): BuildAction =
  result = builtinAction(bakCopyFile, "make-artifact",
    cwd = c.root,
    inputs = ["input.txt"],
    outputs = ["build/artifact.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.weakFingerprint = fingerprintFor("make-artifact")
  result.monitorDepfile = c.rmdf

proc configFor(c: Checkout; cacheRoot: string;
               sharedRoot = ""): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  if sharedRoot.len > 0:
    result.actionCacheRoot = sharedRoot
    result.portableRoots = @[
      LogicalRoot(label: "project", path: c.root, kind: lrkTracked)]

suite "a directory an action's output lives in is not an existence input":

  test "cacheInputPaths drops the output's ancestors and nothing beside them":
    let work = UnitRoot / "proj"
    let act = action("produce", ["sh", "-c", "mkdir -p build/sub && ..."],
      cwd = work,
      inputs = ["gen"],
      outputs = ["build/sub/artifact.txt", "gen/declared-dir-output.txt"],
      cacheable = true,
      monitorDepfile = work / "produce.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.declaredOutputs = act.outputs
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [
        work / "build",                 # ancestor: dropped
        work / "build/",                # the same, as a monitor may spell it
        work / "build" / "sub",         # the output's parent: dropped
        work / "buildx",                # string-prefix sibling: KEPT
        work / "build" / "other",       # below build, not an ancestor: KEPT
        work / "gen"])                  # ancestor, but DECLARED input: KEPT
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [
        work / "build" / "sub",         # a directory open of the parent
        work / "build" / "sub" / "neighbour.txt",   # a real input: KEPT
        work / "input.txt"])            # a real input: KEPT

    let inputs = act.cacheInputPaths(evidence)

    # The defect: the existence of the directories the action writes into.
    check not inputs.hasPath(work / "build")
    check not inputs.hasPath(work / "build" / "sub")
    for path in inputs:
      check path.norm != (work / "build").norm
    # The cardinal-sin guard.
    check inputs.hasPath(work / "buildx")
    check inputs.hasPath(work / "build" / "other")
    check inputs.hasPath(work / "build" / "sub" / "neighbour.txt")
    check inputs.hasPath(work / "input.txt")
    check inputs.hasPath(work / "gen")

  test "an ancestor the action ENUMERATED keeps its place in the key":
    ## The membership carve-out. An enumeration is folded into the probe
    ## channel too, and the record attaches a membership digest only to a
    ## path in the keyed list, so dropping an enumerated ancestor as an
    ## "existence" observation would silently drop its listing. The output's
    ## OWN parent is the exception: its membership is already derived state
    ## (`selfWrittenDirectoryKeys`), so only its existence was ever keyed.
    let work = UnitRoot / "glob"
    let act = action("concat", ["sh", "-c", "mkdir -p build/sub && cat *.txt > build/sub/all.txt"],
      cwd = work,
      outputs = ["build/sub/all.txt"],
      cacheable = true,
      monitorDepfile = work / "concat.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    for dir in [work, work / "build" / "sub"]:
      evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [dir])
      evidence.monitorDirectoryEnumerations.observeAll(
        evidence.evidenceProvenance, evcMonitorCapture, [dir])
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [work / "build"])
    let inputs = act.cacheInputPaths(evidence)
    check inputs.hasPath(work)                   # listed: KEPT
    check not inputs.hasPath(work / "build")     # probed only: dropped
    check not inputs.hasPath(work / "build" / "sub")  # own parent: dropped

  test "a declared write root and its ancestors are covered too":
    let work = UnitRoot / "install"
    var act = action("install", ["make", "install"],
      cwd = work,
      cacheable = true,
      monitorDepfile = work / "install.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.declaredOutputs = @["stage/prefix"]
    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.declaredOutputs
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [work / "stage", work / "stage" / "prefix",
                          work / "Makefile"])
    let inputs = act.cacheInputPaths(evidence)
    check not inputs.hasPath(work / "stage")
    check not inputs.hasPath(work / "stage" / "prefix")
    check inputs.hasPath(work / "Makefile")

  test "the record does not carry the directory the action created":
    let tempRoot = createTempDir("repro-output-ancestor-record", "")
    defer: removeDir(tempRoot)
    let c = checkout(tempRoot / "a")
    let cacheRoot = tempRoot / "cache"
    check not dirExists(c.outputDir)

    let first = runBuild(graph([c.copyAction()]), configFor(c, cacheRoot))
    require first.results[0].status == asSucceeded
    require first.results[0].launched
    check dirExists(c.outputDir)

    let record = readRecord(dependencyEvidencePath(cacheRoot,
      c.copyAction().id))
    check not record.recordHasInput(c.outputDir)
    check not record.recordHasInput(c.output)
    check record.recordHasInput(c.source)

  test "rm -rf of the created directory is RESTORED, not re-run":
    ## The producing checkout deleting the directory the action created.
    ## Measured to hold before the fix as well (the local restore path does
    ## not trip over the recorded directory), so this is not the reproducer
    ## — the record and portable cases are. It is the guard that dropping
    ## the directory from the key did not cost the restoring hit.
    let tempRoot = createTempDir("repro-output-ancestor-restore", "")
    defer: removeDir(tempRoot)
    let c = checkout(tempRoot / "a")
    let cacheRoot = tempRoot / "cache"
    let config = configFor(c, cacheRoot)
    check not config.rebuildMissingOutputsOnCacheHit

    let first = runBuild(graph([c.copyAction()]), config)
    require first.results[0].status == asSucceeded
    require first.results[0].launched

    removeDir(c.outputDir)
    check not dirExists(c.outputDir)

    let second = runBuild(graph([c.copyAction()]), config)
    check second.results[0].cacheDecision == cdHit
    check not second.results[0].launched
    check second.results[0].reason == "restored"
    check readFile(c.output) == "payload\n"

  test "a genuine input change after rm -rf still misses":
    ## The paired negative: a filter that dropped more than the ancestors
    ## would pass the restore test above just as happily.
    let tempRoot = createTempDir("repro-output-ancestor-invalidate", "")
    defer: removeDir(tempRoot)
    let c = checkout(tempRoot / "a")
    let cacheRoot = tempRoot / "cache"
    let config = configFor(c, cacheRoot)
    let first = runBuild(graph([c.copyAction()]), config)
    require first.results[0].status == asSucceeded

    removeDir(c.outputDir)
    writeFile(c.source, "changed\n")
    let second = runBuild(graph([c.copyAction()]), config)
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].launched
    check readFile(c.output) == "changed\n"

  test "a file added to an ancestor the action listed still misses":
    ## The false hit the membership carve-out exists to prevent, end to end:
    ## the action lists the project root (a glob), and a new entry there must
    ## invalidate it even though the root is an ancestor of its output.
    let tempRoot = createTempDir("repro-output-ancestor-listing", "")
    defer: removeDir(tempRoot)
    let c = checkout(tempRoot / "a")
    writeFile(c.rmdf, rmdfBytes(
      dirEnumerate(c.root),
      pathProbe(c.outputDir),
      fileRead(c.source),
      fileWrite(c.output)))
    let config = configFor(c, tempRoot / "cache")
    let first = runBuild(graph([c.copyAction()]), config)
    require first.results[0].status == asSucceeded
    require first.results[0].launched
    let record = readRecord(dependencyEvidencePath(tempRoot / "cache",
      c.copyAction().id))
    check record.recordHasInput(c.root)
    check not record.recordHasInput(c.outputDir)

    writeFile(c.root / "extra.txt", "new entry\n")
    let second = runBuild(graph([c.copyAction()]), config)
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].launched

  test "a fresh second checkout finds the first checkout's portable record":
    ## The issue's headline: checkout B has never built, so it has no
    ## `build/`. It looks the action up by portable weak fingerprint and
    ## recomputes the strong fingerprint from ITS tree; before the fix the
    ## record held `project:build` as present and B computed absent.
    let tempRoot = createTempDir("repro-output-ancestor-portable", "")
    defer: removeDir(tempRoot)
    let shared = tempRoot / "shared"
    let a = checkout(tempRoot / "a")
    let b = checkout(tempRoot / "b-at" / "another" / "depth")
    let ra = runBuild(graph([a.copyAction()]),
      configFor(a, tempRoot / "cache-a", shared)).results[0]
    require ra.status == asSucceeded
    require ra.portable
    check not dirExists(b.outputDir)

    let rootsB = @[LogicalRoot(label: "project", path: b.root,
      kind: lrkTracked)]
    let hit = lookupMemo(shared / "portable-memo", rootsB, ra.portableWeakHex)
    check hit.isSome
    if hit.isSome:
      check hit.get().strongHex == ra.portableStrongHex
      check hit.get().outputs == ra.portableOutputs

    # And B, building for itself, publishes the very same strong
    # fingerprint: the only thing that ever differed was the pre-run state
    # of a directory the action creates.
    let rb = runBuild(graph([b.copyAction()]),
      configFor(b, tempRoot / "cache-b", tempRoot / "shared-b")).results[0]
    require rb.portable
    check rb.portableStrongHex == ra.portableStrongHex

    # The control: a checkout whose real input differs does not match.
    let c = checkout(tempRoot / "c", "other payload\n")
    let rootsC = @[LogicalRoot(label: "project", path: c.root,
      kind: lrkTracked)]
    check lookupMemo(shared / "portable-memo", rootsC,
      ra.portableWeakHex).isNone
