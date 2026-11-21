## Campaign M17 (ReproOS-Campaign-Completion.milestones.org): a
## zero-evidence record never leaves the host
## (Edge-Derived-Identities.md §3.4 item 1, "Level 0 with at least one
## observation").
##
## Two shapes of "zero evidence", one guard each, and both cross-host
## publishers checked in every case:
##
##   1. A MONITORED execution whose monitor reported success and observed
##      nothing. The engine's zero-evidence guard (`applyMonitorEvidenceStatus`,
##      `cirEmptyEvidence`; `t_zero_evidence_edge_is_not_cacheable`) withholds
##      the record itself, so no publisher is ever reached and the trace names
##      `empty-evidence`. This case pins that the guard sits in front of BOTH
##      publishers: removing it records the execution and offers it to both.
##   2. A record that names no observed input at all -- here a builtin with
##      no inputs, which no monitor grades. It is stored and serves this host,
##      but a record with an empty path set would be accepted by any host on
##      its weak fingerprint alone, so the publication rule
##      (`repro_local_store.publicationRefusal`) keeps it local, with a trace
##      event per publisher saying so.
##
## A control with one input is offered to both publishers.
##
## MOCK POLICY: as `t_publishers_refuse_level1_records` -- recording closures
## in the engine's two publisher hook slots (the real publishers are
## exercised by the M17 peer-cache and portable-memo tests), and a monitor
## capture in io-mon's own encoding handed over as a prewired
## `monitorDepfile`.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
import repro_local_store
from repro_cas_store import CasStore
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_publishers_refuse_zero_evidence_records-" &
  testCaseScratchSlug())

proc writeCapture(path: string; records: varargs[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    @records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Built = object
  result: ActionResult
  trace: string
  portable: int
  peer: int

proc build(project, cacheRoot: string; inputs: seq[string];
           capture = ""): Built =
  var action = builtinAction(bakWriteText, "t-zero-evidence-publication",
    cwd = project,
    inputs = inputs,
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
  var portable: ref int
  new(portable)
  var peer: ref int
  new(peer)
  config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      inc portable[]
    ""
  config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
      record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc peer[]
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

proc events(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

suite "M17: a zero-evidence record is offered to neither publisher":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a monitored execution that observed nothing reaches neither publisher":
    let project = newProject("monitored")
    let capture = TmpDir / "monitored" / "capture.iomon"
    writeCapture(capture)          # the profile, and no observation at all
    let cacheRoot = TmpDir / "monitored" / "cache"
    let first = build(project, cacheRoot, @[project / "src" / "main.c"],
      capture)
    checkpoint(first.trace)
    require first.result.launched
    check first.portable == 0
    check first.peer == 0
    let skipped = events(first.trace, "cache-skip-ineligible")
    check skipped.len == 1
    check skipped.len == 1 and "empty-evidence" in skipped[0]
    # Nothing was recorded, so it runs again.
    let second = build(project, cacheRoot, @[project / "src" / "main.c"],
      capture)
    check second.result.launched
    check second.portable == 0
    check second.peer == 0

  test "a record naming no input stays local and still serves this host":
    let project = newProject("no-input")
    let cacheRoot = TmpDir / "no-input" / "cache"
    let first = build(project, cacheRoot, @[])
    checkpoint(first.trace)
    require first.result.launched
    check first.portable == 0
    check first.peer == 0
    let portableRefused = events(first.trace, "portable-memo-publish-refused")
    check portableRefused.len == 1
    check portableRefused.len == 1 and
      "names no observed input" in portableRefused[0]
    let peerRefused = events(first.trace, "peer-cache-publish-refused")
    check peerRefused.len == 1
    check peerRefused.len == 1 and "names no observed input" in peerRefused[0]
    # The local record is unaffected: the next build is a hit.
    let second = build(project, cacheRoot, @[])
    check not second.result.launched
    check second.peer == 0
    check second.portable == 0

  test "control: a record with an input is offered to both publishers":
    let project = newProject("control")
    let cacheRoot = TmpDir / "control" / "cache"
    let first = build(project, cacheRoot, @[project / "src" / "main.c"])
    checkpoint(first.trace)
    require first.result.launched
    check first.portable == 1
    check first.peer == 1
    check events(first.trace, "portable-memo-publish-refused").len == 0
    check events(first.trace, "peer-cache-publish-refused").len == 0
