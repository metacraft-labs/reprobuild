## Campaign M17 (ReproOS-Campaign-Completion.milestones.org),
## `t_publishers_refuse_level1_records`: Edge-Derived-Identities.md §3.4
## item 1 and its 2026-10-27 rider (§10 decision 13, conflict C3).
##
## An execution whose monitor evidence is Level 1 (`mesKnownScopeLoss`: a
## kill-before-flush loss) is stored, and serves THIS host exactly as it did
## before -- its downstream narrowing lives in the session's memory. That
## narrowing travels with nothing, so the record must never leave the host:
## neither cross-host publisher may be offered it. Both publishers are
## exercised in every case, so removing the Level-1 check from EITHER one
## turns a case red:
##
##   * the portable memo publisher (`finishPortableRecord`), both from the
##     live execution and from a later local hit, which is served with no
##     monitor evidence of its own and has only the level the producing run
##     stored beside its record (`InputAccesses.evidenceLevel`);
##   * the two-phase peer-cache publisher hook (`publishPeerCacheBundle`).
##
## Each refusal is a trace event that names the loss level. A Level-0
## control with the same action and inputs is offered to both, and the peer
## publisher is told it is Level 0. A hit on a record whose access sidecar
## predates the level field (version 1) publishes nothing either: what it
## does not say cannot be assumed to be Level 0.
##
## MOCK POLICY. Two seams, both justified by what is under test -- what the
## ENGINE offers each publisher:
##   * the publishers are recording closures in the engine's own hook slots
##     (`portableMemoPublisher`, `peerCacheActionPublisher`). The real
##     publishers behind those slots apply the same rule again and are
##     exercised against real stores by
##     `libs/repro_peer_cache/tests/t_peer_cache_refuses_timestamp_records_across_hosts.nim`
##     and `libs/repro_binary_cache_client/tests/t_portable_memo_refuses_timestamp_records.nim`;
##   * the monitor capture is written in io-mon's own encoding
##     (`io_mon/writer`) and handed to the action as a prewired
##     `monitorDepfile`, the seam a direct engine caller uses, because a
##     kill-before-flush loss cannot be produced on demand by a real process.
##     It carries the backend profile records io-mon writes first, as
##     `t_portable_record_from_local_hit` does.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
import repro_local_store
from repro_cas_store import CasStore
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath("build/test-tmp/t_publishers_refuse_level1_records-" &
  testCaseScratchSlug())

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc killBeforeFlush(): MonitorRecord =
  ## The one loss class io-mon reports at Level 1
  ## (test_m9r72_phaseD_end_to_end.nim, "kill-before-flush + real reads
  ## yields Level 1").
  MonitorRecord(kind: mrEventLoss, observationKind: moEventLoss,
    osPid: 1234, threadId: 5678,
    detail: "process killed with an un-flushed read batch " &
      "(kill-before-flush) diag-ctx=[pid=1234]")

proc writeCapture(path: string; records: varargs[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    @records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type
  PeerOffer = object
    level: EvidenceLevel
    policy: FileFingerprintPolicy
    source: EvidenceSource

  Built = object
    result: ActionResult
    trace: string
    portable: seq[PortableMemoRecord]
    peer: seq[PeerOffer]

proc build(project, cacheRoot, capture: string;
           publishers = true): Built =
  ## One build of a builtin whose monitor evidence is `capture`, with a
  ## recording publisher in each cross-host hook slot.
  var action = builtinAction(bakWriteText, "t-level1-publication",
    cwd = project,
    inputs = [project / "src" / "main.c"],
    outputs = [project / "out" / "result.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  action.monitorDepfile = capture
  var config = defaultBuildEngineConfig(cacheRoot)
  config.maxParallelism = 1
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  var portable: ref seq[PortableMemoRecord]
  new(portable)
  var peer: ref seq[PeerOffer]
  new(peer)
  if publishers:
    config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
        record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
      {.cast(gcsafe).}:
        portable[].add(record)
      ""
    config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
        record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        peer[].add(PeerOffer(level: query.evidenceLevel,
          policy: record.policy, source: query.evidenceSource))
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  checkpoint(run.results[0].reason)
  require run.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
  result.result = run.results[0]
  for event in run.trace:
    result.trace.add(event.event & ": " & event.detail & "\n")
  result.portable = portable[]
  result.peer = peer[]

proc newProject(name: string): string =
  result = TmpDir / name / "proj"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", "int main;\n")

proc refusals(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

proc accessSidecars(cacheRoot: string): seq[string] =
  for path in walkDirRec(cacheRoot):
    if path.endsWith(InputAccessFileExt):
      result.add(path)

suite "M17: neither publisher offers a Level-1 record":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a Level-1 execution serves locally and is offered to neither publisher":
    let project = newProject("level1")
    let capture = TmpDir / "level1" / "capture.iomon"
    writeCapture(capture, fileRead(project / "src" / "main.c"),
      killBeforeFlush())
    let cacheRoot = TmpDir / "level1" / "cache"
    let live = build(project, cacheRoot, capture)
    checkpoint(live.trace)
    require live.result.launched
    # The evidence really is Level 1: the engine said so, and still kept
    # the record (the next build hits it).
    check "known-scope loss" in live.result.evidence.diagnostics.join("\n")
    check live.result.portable
    check live.portable.len == 0
    check live.peer.len == 0
    let portableRefused = refusals(live.trace, "portable-memo-publish-refused")
    check portableRefused.len == 1
    check portableRefused.len == 1 and "Level 1" in portableRefused[0]
    let peerRefused = refusals(live.trace, "peer-cache-publish-refused")
    check peerRefused.len == 1
    check peerRefused.len == 1 and "Level 1" in peerRefused[0]

    # Local reuse is unaffected: the record serves this host.
    let warm = build(project, cacheRoot, capture)
    checkpoint(warm.trace)
    check not warm.result.launched
    check warm.result.status in {asCacheHit, asUpToDate}
    check readFile(project / "out" / "result.txt") == "built\n"
    # ...but the portable record a hit derives is the Level-1 record, and is
    # not offered either. The hit ran no monitor; the level came from the
    # sidecar the producing run stored.
    check warm.result.portable
    check warm.portable.len == 0
    check warm.peer.len == 0
    let warmRefused = refusals(warm.trace, "portable-memo-publish-refused")
    check warmRefused.len == 1
    check warmRefused.len == 1 and "Level 1" in warmRefused[0]

  test "a Level-0 control is offered to both, stated as Level 0":
    let project = newProject("level0")
    let capture = TmpDir / "level0" / "capture.iomon"
    writeCapture(capture, fileRead(project / "src" / "main.c"))
    let cacheRoot = TmpDir / "level0" / "cache"
    let live = build(project, cacheRoot, capture)
    checkpoint(live.trace)
    require live.result.launched
    check "known-scope loss" notin live.result.evidence.diagnostics.join("\n")
    check live.portable.len == 1
    check live.peer.len == 1
    check live.peer.len == 1 and live.peer[0].level == elComplete
    check live.peer.len == 1 and live.peer[0].policy == ffpChecksum
    # M17 chunk 2: both publishers are told where the evidence came from --
    # an io-mon capture, so `monitored` (Edge-Derived-Identities.md §3.1).
    check live.peer.len == 1 and live.peer[0].source == MonitoredEvidence
    check live.portable.len == 1 and
      live.portable[0].evidenceSource == MonitoredEvidence
    check refusals(live.trace, "portable-memo-publish-refused").len == 0
    check refusals(live.trace, "peer-cache-publish-refused").len == 0

  test "a hit on a record whose sidecar does not state a level publishes nothing":
    # A sidecar written before the level existed (version 1) cannot say the
    # execution was Level 0, and Level 1 is exactly what it could hide.
    let project = newProject("unstated")
    let capture = TmpDir / "unstated" / "capture.iomon"
    writeCapture(capture, fileRead(project / "src" / "main.c"))
    let cacheRoot = TmpDir / "unstated" / "cache"
    # Recorded with no publisher, so nothing is marked as already published.
    let live = build(project, cacheRoot, capture, publishers = false)
    require live.result.launched
    let sidecars = accessSidecars(cacheRoot)
    require sidecars.len == 1
    # Rewrite it as the version-1 sidecar the previous build wrote: the
    # same bytes without the trailing level byte (and, since version 3, the
    # evidence source after it).
    var raw = readFile(extendedPath(sidecars[0]))
    require raw.len > 6
    require raw[4] == char(3) and raw[5] == char(0)
    let stated = decodeInputAccesses(raw.toOpenArrayByte(0, raw.high),
      extractFilename(sidecars[0]).changeFileExt("")).get()
    raw[4] = char(1)
    raw.setLen(raw.len - 1 - 4 - ($stated.evidenceSource).len)
    writeFile(extendedPath(sidecars[0]), raw)
    let warm = build(project, cacheRoot, capture)
    checkpoint(warm.trace)
    check not warm.result.launched
    # The v1 sidecar still derives the portable record...
    check warm.result.portable
    # ...which stays on this host.
    check warm.portable.len == 0
    let refused = refusals(warm.trace, "portable-memo-publish-refused")
    check refused.len == 1
    check refused.len == 1 and "unstated" in refused[0]

  test "a hit on a record whose sidecar does not state an evidence source publishes nothing":
    # M17 chunk 2: a version-2 sidecar states the level but not where the
    # evidence came from (Edge-Derived-Identities.md §3.1), so a record
    # derived from a hit on it does not leave the host either. Falsifier:
    # dropping the source check from the rule publishes it.
    let project = newProject("unsourced")
    let capture = TmpDir / "unsourced" / "capture.iomon"
    writeCapture(capture, fileRead(project / "src" / "main.c"))
    let cacheRoot = TmpDir / "unsourced" / "cache"
    let live = build(project, cacheRoot, capture, publishers = false)
    require live.result.launched
    let sidecars = accessSidecars(cacheRoot)
    require sidecars.len == 1
    var raw = readFile(extendedPath(sidecars[0]))
    require raw.len > 6
    require raw[4] == char(3) and raw[5] == char(0)
    let stated = decodeInputAccesses(raw.toOpenArrayByte(0, raw.high),
      extractFilename(sidecars[0]).changeFileExt("")).get()
    check stated.evidenceLevel == elComplete
    check stated.evidenceSource == MonitoredEvidence
    # The version-2 sidecar: level stated, no source after it.
    raw[4] = char(2)
    raw.setLen(raw.len - 4 - ($stated.evidenceSource).len)
    writeFile(extendedPath(sidecars[0]), raw)
    let warm = build(project, cacheRoot, capture)
    checkpoint(warm.trace)
    check not warm.result.launched
    check warm.result.portable
    check warm.portable.len == 0
    let refused = refusals(warm.trace, "portable-memo-publish-refused")
    check refused.len == 1
    check refused.len == 1 and "evidence source" in refused[0]
