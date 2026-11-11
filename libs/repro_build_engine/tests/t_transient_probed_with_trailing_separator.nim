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
## Mocks: none. The capture is the record shapes io-mon emits, read by the
## engine's own fold; the action runs through `runBuild`, and the
## temporary is absent from disk, as it is once the linker has renamed it.

import std/[os, sets, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
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

proc linkGraph(root, project, tempSuffix: string): BuildGraph =
  ## One link edge that read entropy (so only the determinism probe can
  ## admit it) and went through a temporary named `tempSuffix`.
  let capture = root / "link.rdep"
  let temporary = project / "build" / ("out.dll.tmp" & tempSuffix)
  writeCapture(capture, @[
    observed(mrFileRead, moFileRead, project / "src" / "main.c"),
    observed(mrFileWrite, moFileWrite, temporary),
    observed(mrPathProbe, moPathProbe, temporary & "/"),
    observed(mrFileRead, moFileRead, temporary),
    observed(mrNonDeterministic, moNonDeterministic,
      "BCryptGenRandom", "entropy source=BCryptGenRandom caller=program")])
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
    check transientWriteKey(temporary.replace('/', '\\') & "\\") in
      transient
    check transientWriteKey("/") == "/"

  test "does not move the determinism-probe key between runs":
    let root = freshRoot("probe")
    let project = root / "proj"
    createDir(project / "src")
    writeFile(project / "src" / "main.c", "int main;\n")
    var config = defaultBuildEngineConfig(root / "cache")
    config.maxParallelism = 1
    config.actionCacheRoot = root / "shared"
    let first = runBuild(linkGraph(root, project, "a6d2958"), config)
    check first.probeEvents() == @["determinism-probe-candidate"]
    # Same inputs, same output bytes; only the temporary's random name
    # differs, as it does on every real link.
    removeFile(project / "build" / "out.dll")
    let second = runBuild(linkGraph(root, project, "76f9569"), config)
    check second.probeEvents() == @["determinism-probe-verified"]
