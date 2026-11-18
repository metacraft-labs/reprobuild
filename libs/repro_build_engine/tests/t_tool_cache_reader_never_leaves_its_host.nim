## An edge that names a content-keyed tool-owned cache is `host-bound` in
## the engine, whatever it declared, and none of its records cross a host.
##
## Issue: reprobuild-pm
## `issues/2026-11-12-content-keyed-tool-caches-are-shared-as-widely-as-correctness-allows-with-no-trust.md`.
## Governing text: Tool-Owned-Caches.md §"Trust Boundary" and
## Edge-Determinism-And-Soft-Rebuild.md §1.4 (composition), §3 and §5
## (a host-bound record is neither published nor substituted).
##
## The attack itself -- another writer of Go's build cache changing a Go
## edge's output under an unchanged fingerprint -- is driven end to end with
## a real `go build` in
## `tests/integration/t_edge_reading_a_shared_tool_cache_is_never_published_cross_host.nim`.
## That test needs Go. This one pins the ENGINE half of the rule with no
## external tool, so it runs on every host:
##
##   * the class composition: an edge declared `strong` (the most portable
##     class) that names a cache resolves to `host-bound`, and so does an
##     unlabelled one, and the record carries the derived class;
##   * none of the five cross-host paths is taken: peer-cache publish,
##     portable-memo publish, binary-cache publish, peer-cache fetch and
##     remote portable lookup; each refusal is traced naming the cache;
##   * a control, identical but naming no cache, takes all five, so every
##     hook is live and the refusals are not an artefact of the harness.
##
## MOCK POLICY. The five cross-host hooks are recording closures in the
## engine's own slots, as in `t_publishers_refuse_level1_records`; the real
## publishers and fetchers behind them are exercised against real stores
## elsewhere, and the question here is whether the engine calls them at all.
## The monitor capture is a prewired `monitorDepfile` in io-mon's own
## encoding (the seam a direct engine caller uses), so the record's evidence
## is complete and no other publication rule could explain a refusal.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_core/paths
import repro_local_store
from repro_cas_store import CasStore
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath("build/test-tmp/t_tool_cache_reader_never_leaves_its_host-" &
  testCaseScratchSlug())

type
  Offered = object
    ## How often one build took each cross-host path.
    peerPublish, portablePublish, binaryPublish: int
    peerFetch, remoteLookup: int

  Built = object
    action: BuildAction
    result: ActionResult
    trace: string
    offered: Offered

proc writeCapture(path: string; reads: openArray[string]) =
  ## Complete monitor evidence: io-mon's backend profile records, then one
  ## read per path.
  var records = profileRecords(defaultHooksMonitorProfile())
  for read in reads:
    records.add(MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 4242, threadId: 4242, path: read, detail: ""))
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc build(name: string; caches: openArray[string];
           determinism: Option[EdgeDeterminism]): Built =
  let project = TmpDir / name / "proj"
  createDir(project / "src")
  createDir(project / "out")
  writeFile(project / "src" / "input.txt", "input\n")
  var action = builtinAction(bakWriteText, "t-tool-cache-reader-" & name,
    cwd = project,
    inputs = [project / "src" / "input.txt"],
    outputs = [project / "out" / "result.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  action.contentKeyedToolCaches = @caches
  action.determinism = determinism
  let capture = TmpDir / name / "capture.iomon"
  writeCapture(capture, [project / "src" / "input.txt"])
  action.monitorDepfile = capture

  var offered: ref Offered
  new(offered)
  var config = defaultBuildEngineConfig(TmpDir / name / "cache")
  config.maxParallelism = 1
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  config.binaryCacheIntermediateScope = true
  # The lookup-before-scheduling pre-pass, which is where a remote portable
  # record would be substituted.
  config.portableLookup = true
  config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      inc offered.portablePublish
    ""
  config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
      record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc offered.peerPublish
  config.binaryCachePublisher = proc (req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc offered.binaryPublish
    BinaryCachePublishResult(ok: true, statusCode: 200)
  config.peerCacheActionFetcher = proc (query: PeerCacheActionQuery):
      Option[seq[byte]] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc offered.peerFetch
    none(seq[byte])
  config.peerCacheActionInstaller = proc (query: PeerCacheActionQuery;
      bundleBytes: seq[byte]; cas: var CasStore; cache: ptr ActionCache):
      tuple[ok: bool; reason: string] {.gcsafe, closure.} =
    (false, "never installed: the fetcher answers none")
  config.portableMemoLookup = proc (roots: seq[LogicalRoot]; weakHex: string;
      resolve: IdentityResolver): Option[PortableMemoRecord] {.gcsafe,
      closure.} =
    {.cast(gcsafe).}:
      inc offered.remoteLookup
    none(PortableMemoRecord)

  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  checkpoint(run.results[0].reason)
  require run.results[0].status == asSucceeded
  var trace = ""
  for event in run.trace:
    trace.add(event.event & ": " & event.detail & "\n")
  checkpoint(trace)
  Built(action: action, result: run.results[0], trace: trace,
    offered: offered[])

proc events(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

proc checkStaysOnHost(built: Built; cache: string) =
  check built.result.launched
  check built.action.determinismClass == edHostBound
  check built.offered == Offered()
  for event in ["peer-cache-publish-refused", "portable-memo-host-bound",
                "binary-cache-publish-refused", "peer-cache-fetch-refused",
                "portable-lookup-remote-refused"]:
    checkpoint event
    let refused = events(built.trace, event)
    check refused.len == 1
    check refused.len == 1 and cache in refused[0] and
      $edHostBound in refused[0]

suite "an edge naming a content-keyed tool cache never leaves its host":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "an edge declared strong composes to host-bound and takes no cross-host path":
    let cache = TmpDir / "shared-tool-cache"
    let built = build("strong", [cache], some(edStrong))
    checkStaysOnHost(built, cache)
    # Composition, not an override: the declared class is untouched.
    check built.action.determinism == some(edStrong)

  test "an unlabelled edge is host-bound, and its record says so":
    let cache = TmpDir / "shared-tool-cache"
    let built = build("unlabelled", [cache], none(EdgeDeterminism))
    checkStaysOnHost(built, cache)
    # The record carries the derived class, so a consumer that sees only
    # the record (the peer-cache publisher) refuses it too.
    let stamp = entryDeterminismFor(defaultBuildEngineConfig(TmpDir),
      built.action)
    check stamp.declared
    check stamp.class == edHostBound

  test "control: the same edge naming no cache takes every cross-host path":
    let built = build("control", [], some(edStrong))
    check built.result.launched
    check built.action.determinismClass == edStrong
    check built.offered.peerPublish == 1
    check built.offered.portablePublish == 1
    check built.offered.binaryPublish == 1
    check built.offered.peerFetch == 1
    check built.offered.remoteLookup == 1
