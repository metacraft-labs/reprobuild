## A temporary the action wrote and removed is not an input, whatever
## spelling the monitor recorded a probe of it under.
##
## lld-link writes its image through a randomly named temporary
## (`noexp.dll.tmpa6d2958`). The monitor recorded the WRITE without a
## trailing separator and a PROBE of the same path with one
## (`noexp.dll.tmpa6d2958\`). `transientOwnWrites` held the written
## spelling only, so the probed one was kept as an input: the random name
## entered the determinism-probe key, every run recorded a new candidate,
## and the probe never decided.
##
## The other direction matters as much: a name the action wrote and removed
## must never take a REAL input out of the key. On POSIX a backslash is an
## ordinary filename character, so a removed `main.c\` is not `main.c`.
##
## Mocks: none. The capture is the record shapes io-mon emits, read by the
## engine's own fold; the action runs through `runBuild`, and the
## temporary is absent from disk, as it is once the linker has renamed it.

import std/[options, os, sets, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_transient_probed_with_trailing_separator-" &
  testCaseScratchSlug())

const LinkId = "t-link"

proc observed(kind: MonitorRecordKind; observation: MonitorObservationKind;
              path: string; detail = ""): MonitorRecord =
  MonitorRecord(kind: kind, observationKind: observation,
    osPid: 4242, threadId: 4242, path: path, detail: detail)

proc writeCapture(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc linkGraph(root, project, tempSuffix: string;
               removedWrite = ""): BuildGraph =
  ## One link edge that read entropy (so only the determinism probe can
  ## admit it) and went through a temporary named `tempSuffix`, probed with
  ## the host's trailing separator as the linker probes it. `removedWrite`
  ## is one more path the action wrote and that is gone at the end.
  let capture = root / "link.rdep"
  let temporary = project / "build" / ("out.dll.tmp" & tempSuffix)
  var records = @[
    observed(mrFileRead, moFileRead, project / "src" / "main.c"),
    observed(mrFileWrite, moFileWrite, temporary),
    observed(mrPathProbe, moPathProbe, temporary & DirSep),
    observed(mrFileRead, moFileRead, temporary),
    observed(mrNonDeterministic, moNonDeterministic,
      "BCryptGenRandom", "entropy source=BCryptGenRandom caller=program")]
  if removedWrite.len > 0:
    records.add(observed(mrFileWrite, moFileWrite, removedWrite))
  writeCapture(capture, records)
  var link = builtinAction(bakWriteText, LinkId, cwd = project,
    inputs = [project / "src" / "main.c"],
    outputs = [project / "build" / "out.dll"],
    text = "image\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  link.monitorDepfile = capture
  link.nonDeterminism = ndpUnblessed
  graph(@[link], newSeq[BuildPool]())

proc freshRoot(name: string): string =
  ## A scratch root with nothing left in it by an earlier run: a candidate
  ## an earlier run recorded would decide this run's probe.
  result = TmpDir / name
  removeDir(result)
  createDir(result)

proc configFor(root: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(root / "cache")
  result.maxParallelism = 1
  result.actionCacheRoot = root / "shared"

proc accessSidecars(root: string): seq[InputAccesses] =
  ## The input accesses stored beside each published record, decoded: what
  ## the portable record of that action is derived from.
  for path in walkDirRec(root):
    if path.endsWith(InputAccessFileExt):
      let raw = readFile(path)
      let decoded = decodeInputAccesses(raw.toOpenArrayByte(0, raw.high),
        path.extractFilename[0 ..< ^InputAccessFileExt.len])
      require decoded.isSome
      result.add(decoded.get)

proc probeEvents(run: BuildRunResult): seq[string] =
  for r in run.results:
    checkpoint(r.id & ": " & $r.status & " " & r.reason)
    require r.status in {asSucceeded, asCacheHit, asUpToDate}
  for item in run.trace:
    if item.actionId == LinkId and
        item.event.startsWith("determinism-probe-"):
      result.add(item.event)

suite "a temporary probed with a trailing separator":

  test "is one of the action's own transient writes":
    let root = freshRoot("unit")
    let temporary = root / "out.dll.tmpa6d2958"
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    discard foldMonitorRecordsEvidence(
      [observed(mrFileWrite, moFileWrite, temporary)], root, evidence, seen)
    let transient = transientOwnWrites(evidence)
    check transientWriteKey(temporary) in transient
    check transientWriteKey(temporary & "/") in transient
    check transientWriteKey(temporary & "//") in transient
    when defined(windows):
      check transientWriteKey(temporary.replace('/', '\\') & "\\") in
        transient
    else:
      # A different file on POSIX, so not this temporary.
      check transientWriteKey(temporary & "\\") notin transient
    check transientWriteKey("/") == "/"

  test "a write whose key names a file on disk is not a temporary":
    ## `main.c/` cannot be stat'ed when `main.c` is a regular file, but
    ## its key is `main.c`, which exists.
    let root = freshRoot("existing")
    let source = root / "main.c"
    writeFile(source, "int main;\n")
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    discard foldMonitorRecordsEvidence(
      [observed(mrFileWrite, moFileWrite, source & "/")], root, evidence,
      seen)
    check transientWriteKey(source) notin transientOwnWrites(evidence)

  test "does not move the determinism-probe key between runs":
    let root = freshRoot("probe")
    let project = root / "proj"
    createDir(project / "src")
    writeFile(project / "src" / "main.c", "int main;\n")
    let config = configFor(root)
    let first = runBuild(linkGraph(root, project, "a6d2958"), config)
    check first.probeEvents() == @["determinism-probe-candidate"]
    # Same inputs, same output bytes; only the temporary's random name
    # differs, as it does on every real link.
    removeFile(project / "build" / "out.dll")
    let second = runBuild(linkGraph(root, project, "76f9569"), config)
    check second.probeEvents() == @["determinism-probe-verified"]
    # The admitted record's input accesses keep the source and drop the
    # temporary, under either spelling.
    let sidecars = accessSidecars(root)
    check sidecars.len == 1
    for accesses in sidecars:
      check project / "src" / "main.c" in accesses.reads
      for path in accesses.reads & accesses.probes & accesses.enumerations:
        check "out.dll.tmp" notin path

  test "a removed name ending in a separator does not hide a real input":
    ## A write recorded as `main.c\` or `main.c/` folds to the key of the
    ## real input `main.c`. On POSIX `main.c\` is its own file, and
    ## `stat("main.c/")` fails because `main.c` is not a directory, so
    ## either spelling looks written-and-gone. Taking its key as a
    ## temporary took the real input out of the probe key, and a changed
    ## source was admitted as a verified rerun.
    for i, suffix in ["\\", "/"]:
      let root = freshRoot("separator" & $i)
      let project = root / "proj"
      createDir(project / "src")
      let source = project / "src" / "main.c"
      writeFile(source, "int main;\n")
      let config = configFor(root)
      let first = runBuild(linkGraph(root, project, "a6d2958",
        removedWrite = source & suffix), config)
      check first.probeEvents() == @["determinism-probe-candidate"]
      removeFile(project / "build" / "out.dll")
      writeFile(source, "int main(void) { return 1; }\n")
      let second = runBuild(linkGraph(root, project, "a6d2958",
        removedWrite = source & suffix), config)
      checkpoint("removed write: main.c" & suffix)
      check second.probeEvents() == @["determinism-probe-candidate"]
