## Campaign M17 chunk 2: a published record states where its evidence came
## from (Edge-Derived-Identities.md §3.1, "The evidence source": "either
## `monitored` (Level 0, non-empty), or the registry name of a
## declared-complete format").
##
## Until the field existed every unmonitored execution -- a builtin, a
## recognized depfile, a converter -- was graded with the ladder's default
## Level 0, and its published record said exactly what a monitored one said.
## `evidenceSourceOf` derives the source from the facts that decide whether
## the engine monitors an action (`monitoredAction` / `monitorEvidenceRequired`),
## and both publishers carry it:
##
##   * the source of each kind of action (unit cases, every policy kind);
##   * a builtin's execution reaches the portable publisher as an `rbpm-v2`
##     record stating `builtin`, and the peer-cache publisher with a query
##     stating `builtin`; a local hit on the record derives the same source
##     from the access sidecar.
##
## And the owner's decision of 2026-10-29 (Edge-Derived-Identities.md §3.4
## item 1 rider, §10 decision 23), "builtins yes, depfiles no", at the
## PRODUCER: a builtin's record is offered to both publishers; a process
## whose evidence is a make depfile is offered to neither, and each refusal
## names the format. Falsifiers: a rule that passes `format:` sources offers
## the depfile record; one that refuses every unmonitored source withholds the
## builtin's.
##
## MOCK POLICY: the two publishers are recording closures in the engine's
## hook slots, because what is under test is what the ENGINE hands them; the
## real publishers are exercised by `t_portable_memo_cache` and
## `t_peer_cache_refuses_timestamp_records_across_hosts`.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
from repro_cas_store import CasStore

const DepfileToolFlag = "--write-output-and-depfile"

# The depfile edge's tool: writes its output from its input and a make depfile
# naming the input, as a compiler's `-MD` does. This binary, run as a child.
if paramCount() == 4 and paramStr(1) == DepfileToolFlag:
  writeFile(paramStr(3), "derived:" & readFile(paramStr(2)))
  writeFile(paramStr(4), paramStr(3).replace('\\', '/') & ": " &
    paramStr(2).replace('\\', '/') & "\n")
  quit(0)

let TmpDir = absolutePath("build/test-tmp/t_published_record_states_evidence_source-" &
  testCaseScratchSlug())

proc report(name, path: string): RecognizedDependencyReportSpec =
  RecognizedDependencyReportSpec(formatName: DependencyFormatName(name),
    outputs: @[ExpectedDependencyFile(logicalName: "deps", path: path,
      required: false)], completeness: decComplete)

suite "M17 chunk 2: evidenceSourceOf":

  test "each kind of action states where its evidence comes from":
    let lock = lockIdentityOutsideSolvedGraph()
    # A process under the default policy runs under the monitor.
    check evidenceSourceOf(action("p", ["tool"], governingLockIdentity = lock)) ==
      MonitoredEvidence
    # The legacy depfile shorthand: a recognized format, unmonitored.
    check evidenceSourceOf(action("d", ["cc"], depfile = "out/a.d",
      governingLockIdentity = lock)) == formatEvidence("make-depfile")
    # A recognized report VALIDATED by the monitor is monitored evidence.
    check evidenceSourceOf(action("v", ["cc"],
      dependencyPolicy = monitorValidatedPolicy([report("make-depfile",
        "out/a.d")]), governingLockIdentity = lock)) == MonitoredEvidence
    # An edge that produces its own io-mon capture names that format; two
    # reports are both named, sorted.
    check evidenceSourceOf(action("i", ["ct"],
      dependencyPolicy = DependencyGatheringPolicy(kind: dgRecognizedFormat,
        completeness: decComplete,
        recognizedReports: @[report("make-depfile", "b.d"),
                             report(IomonFormatName, "a.iomon")]),
      governingLockIdentity = lock)) ==
      formatEvidence(IomonFormatName & "+make-depfile")
    # A converter's output format.
    check evidenceSourceOf(action("c", ["tool"],
      dependencyPolicy = DependencyGatheringPolicy(kind: dgPostBuildConverter,
        completeness: decComplete,
        postBuildConverters: @[PostBuildDependencyConverterSpec(
          outputKind: dcoRecognizedFormat,
          outputFormatName: DependencyFormatName("msvc-includes"))]),
      governingLockIdentity = lock)) == convertedEvidence("msvc-includes")
    # A builtin runs in-process: no child to monitor.
    let builtin = builtinAction(bakWriteText, "b", outputs = ["x"],
      text = "x", governingLockIdentity = lock)
    check evidenceSourceOf(builtin) == BuiltinEvidence
    # ...unless its caller prewired an io-mon capture, which the engine folds
    # exactly as its own monitor's.
    var captured = builtin
    captured.monitorDepfile = "capture.iomon"
    check evidenceSourceOf(captured) == MonitoredEvidence

suite "M17 chunk 2: both publishers are told the evidence source":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a builtin's record states `builtin` to both publishers, live and from a hit":
    let project = TmpDir / "proj"
    createDir(project / "src")
    createDir(project / "out")
    writeFile(project / "src" / "main.c", "int main;\n")
    let act = builtinAction(bakWriteText, "t-evidence-source", cwd = project,
      inputs = [project / "src" / "main.c"],
      outputs = [project / "out" / "result.txt"], cacheable = true,
      actionCachePolicy = ffpChecksum, text = "built\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var portable: ref seq[PortableMemoRecord]
    new(portable)
    var peer: ref seq[EvidenceSource]
    new(peer)
    var config = defaultBuildEngineConfig(TmpDir / "cache")
    config.maxParallelism = 1
    config.portableRoots = @[
      LogicalRoot(label: "project", path: project, kind: lrkTracked)]
    config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
        record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
      {.cast(gcsafe).}:
        portable[].add(record)
      ""
    config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
        record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        peer[].add(query.evidenceSource)
    let live = runBuild(graph(@[act], newSeq[BuildPool]()), config)
    require live.results.len == 1
    require live.results[0].launched
    check peer[] == @[BuiltinEvidence]
    require portable[].len == 1
    let record = portable[][0]
    check record.evidenceSource == BuiltinEvidence
    check record.evidenceLevel == elComplete
    check record.policy == ffpChecksum
    # The declared input is DECLARED in the published record.
    check record.declared.len == 1
    check record.declared.len == 1 and
      record.declared[0].path == "project:src/main.c"
    # A local hit derives the record from the sidecar, with the same source.
    # (Its publication is skipped as already published, so read the sidecar.)
    var sidecar = ""
    for path in walkDirRec(TmpDir / "cache"):
      if path.endsWith(InputAccessFileExt):
        sidecar = path
    require sidecar.len > 0
    let raw = readFile(extendedPath(sidecar))
    let accesses = decodeInputAccesses(raw.toOpenArrayByte(0, raw.high),
      extractFilename(sidecar).changeFileExt(""))
    require accesses.isSome
    check accesses.get().evidenceSource == BuiltinEvidence
    let warm = runBuild(graph(@[act], newSeq[BuildPool]()), config)
    require warm.results.len == 1
    check not warm.results[0].launched
    check warm.results[0].portable

  test "a depfile-evidenced record is offered to neither publisher; a builtin's is":
    let project = TmpDir / "dep"
    createDir(project / "src")
    createDir(project / "out")
    writeFile(project / "src" / "main.c", "int main;\n")
    let depAction = action("t-evidence-source-depfile",
      [getAppFilename(), DepfileToolFlag, project / "src" / "main.c",
       project / "out" / "derived.txt", project / "out" / "derived.d"],
      cwd = project, inputs = [project / "src" / "main.c"],
      outputs = [project / "out" / "derived.txt"],
      depfile = project / "out" / "derived.d",
      cacheable = true, actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check evidenceSourceOf(depAction) == formatEvidence("make-depfile")
    let builtin = builtinAction(bakWriteText, "t-evidence-source-builtin",
      cwd = project, inputs = [project / "src" / "main.c"],
      outputs = [project / "out" / "builtin.txt"], cacheable = true,
      actionCachePolicy = ffpChecksum, text = "built\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var portable: ref seq[PortableMemoRecord]
    new(portable)
    var peer: ref seq[EvidenceSource]
    new(peer)
    var config = defaultBuildEngineConfig(TmpDir / "dep-cache")
    config.maxParallelism = 1
    config.bypassRunQuota = true
    config.portableRoots = @[
      LogicalRoot(label: "project", path: project, kind: lrkTracked)]
    config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
        record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
      {.cast(gcsafe).}:
        portable[].add(record)
      ""
    config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
        record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        peer[].add(query.evidenceSource)
    let run = runBuild(graph(@[depAction, builtin], newSeq[BuildPool]()),
      config)
    var trace = ""
    for event in run.trace:
      trace.add(event.event & ": " & event.detail & "\n")
    checkpoint(trace)
    require run.results.len == 2
    for item in run.results:
      checkpoint(item.id & ": " & $item.status & " " & item.reason)
      require item.status == asSucceeded
    # Only the builtin reached either publisher.
    check peer[] == @[BuiltinEvidence]
    check portable[].len == 1
    check portable[].len == 1 and
      portable[][0].evidenceSource == BuiltinEvidence
    var portableRefusals, peerRefusals = 0
    for event in run.trace:
      if event.actionId == "t-evidence-source-depfile" and
          "make-depfile" in event.detail:
        if event.event == "portable-memo-publish-refused": inc portableRefusals
        if event.event == "peer-cache-publish-refused": inc peerRefusals
    check portableRefusals == 1
    check peerRefusals == 1
    # The record still serves this host.
    let again = runBuild(graph(@[depAction, builtin], newSeq[BuildPool]()),
      config)
    for item in again.results:
      check not item.launched
