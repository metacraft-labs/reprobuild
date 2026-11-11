## Owner decision 2026-10-31 (Edge-Derived-Identities.md §3.1 / §10 decision
## 23 rider, "Refuse those kinds"): a builtin's record crosses hosts only
## when its kind reads EXACTLY its declared inputs (and the action's own
## fingerprinted payload). Decision 23 of 2026-10-29 let every builtin
## publish, on the premise that "the engine knows every byte a builtin
## reads"; that is false for most kinds -- a copy reads its source's mode
## bits, `ensure-line` reads the file it rewrites, `workspace-vcs`,
## `foreign-provision` and `metadata-fetch` run an executor that reads a
## repository, a daemon or the network.
##
## The rule is an ALLOWLIST (`publication_rule.PublishableBuiltinKinds`:
## `ensure-dir`, `write-text`, `stamp`); the record states its builtin kind
## inside its signed evidence source (`builtin:<kind>`), so a CONSUMER
## enforces the same rule on what a producer published:
##
##   * the table is complete: every builtin kind is either allowed or
##     refused, and the engine names each one;
##   * PRODUCER, one test per refused kind: the real engine runs the action
##     (an executor-dispatched kind through a stub executor that writes its
##     output) and offers its record to neither publisher, each refusal
##     naming the kind;
##   * CONSUMER, one test per refused kind: an `rbpm-v2` record and a v4
##     peer memo entry stating that kind keep it through their wire formats
##     (the memo entry's in its SIGNED attestation message) and are refused
##     by the consumer-side rule, naming the kind;
##   * an allowed builtin (`write-text`, `stamp`) still publishes to both;
##   * an unknown or future kind, and a record that does not state its
##     kind, are refused by default.
##
## MOCK POLICY: the two publishers are recording closures in the engine's
## hook slots (what is under test is what the ENGINE offers them), and the
## executor-dispatched kinds run a stub executor that writes the declared
## output, because their real executors (git, the Nix daemon, an HTTP
## fetch, the solver) read exactly the things that make them refused -- the
## refusal does not depend on what they read, only on the kind. The rule,
## the record formats and the engine are real.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_core/evidence_source
import repro_local_store
import repro_peer_cache
from repro_cas_store import CasStore

let TmpDir = absolutePath(
  "build/test-tmp/t_builtin_kinds_with_undeclared_reads-" &
  testCaseScratchSlug())

const
  Refused = [bakCopyFile, bakPreserveTree, bakEnsureLine, bakEnsureSnippet,
             bakWorkspaceVcs, bakBinaryCacheSubstitute, bakForeignProvision,
             bakMetadataFetch, bakSolveLock, bakLockUpdate]
  Allowed = [bakEnsureDir, bakWriteText, bakStamp]
  StubProvisioner = "t-stub-provisioner"

proc stubExecutor(action: BuildAction): ActionResult {.gcsafe.} =
  ## Writes the action's first declared output, as each real executor does.
  let path =
    if action.outputs[0].isAbsolute: action.outputs[0]
    else: action.cwd / action.outputs[0]
  createDir(path.parentDir)
  writeFile(path, "written by the " & $action.kind & " stub\n")
  ActionResult(id: action.id, status: asSucceeded, launched: true)

registerWorkspaceVcsExecutor(stubExecutor)
registerBinaryCacheSubstituteExecutor(stubExecutor)
registerMetadataFetchExecutor(stubExecutor)
registerSolveLockExecutor(stubExecutor)
registerLockUpdateExecutor(stubExecutor)
registerForeignProvisionExecutor(StubProvisioner, stubExecutor)

proc project(name: string): string =
  result = TmpDir / name
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", "int main;\n")

proc actionOf(kind: BuildActionKind; p: string): BuildAction =
  ## A cacheable `ffpChecksum` action of `kind` with one declared input, so
  ## nothing but its kind can keep its record from publishing.
  let id = "t-kind-" & builtinKindName(kind)
  var outputs = @[p / "out" / (builtinKindName(kind) & ".txt")]
  var text = "text\n"
  var entries: seq[string] = @[]
  case kind
  of bakPreserveTree:
    outputs = @[p / ".repro" / "preserve-tree" / (id & ".manifest")]
    text = "src\ntree"
    entries = @["file\tmain.c"]
  of bakEnsureSnippet:
    entries = @["# begin", "# end", "# begin", "# end", "snippet"]
  else:
    discard
  result = builtinAction(kind, id, cwd = p,
    inputs = [p / "src" / "main.c"], outputs = outputs,
    cacheable = true, actionCachePolicy = ffpChecksum, text = text,
    entries = entries,
    weakFingerprint = weakFingerprintFromText(id & "/" & text),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  if kind == bakForeignProvision:
    result.argv = @[StubProvisioner, "selector"]
  if kind == bakPreserveTree:
    result.declaredOutputs = @[p / "tree"]

type Offered = ref object
  peer: seq[EvidenceSource]
  portable: seq[PortableMemoRecord]

proc runPublishing(p: string; actions: seq[BuildAction];
                   offered: Offered): tuple[results: seq[ActionResult];
                                            trace: seq[SchedulerTraceEvent]] =
  var config = defaultBuildEngineConfig(p / "cache")
  config.maxParallelism = 1
  config.bypassRunQuota = true
  config.portableRoots = @[
    LogicalRoot(label: "project", path: p, kind: lrkTracked)]
  config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      offered.portable.add(record)
    ""
  config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
      record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      offered.peer.add(query.evidenceSource)
  let run = runBuild(graph(actions, newSeq[BuildPool]()), config)
  for event in run.trace:
    checkpoint(event.event & ": " & event.detail)
  (run.results, run.trace)

# A real published record of an allowed builtin, to state other kinds on.
var allowedRecord: ActionResultRecord
var allowedMemo: PortableMemoRecord

proc produceAllowed(): tuple[p: string; offered: Offered;
                             run: tuple[results: seq[ActionResult];
                                        trace: seq[SchedulerTraceEvent]]] =
  ## Runs the allowed builtins through the real engine and keeps what they
  ## published in `allowedMemo` / `allowedRecord`. Every case runs in its own
  ## process under the suite runner, so a CONSUMER case cannot rely on the
  ## "allowed builtin" case having run first in the same process: it calls
  ## `requireAllowedRecord`, which produces the record itself when needed.
  result.p = project("allowed")
  result.offered = Offered()
  result.run = runPublishing(result.p,
    @[actionOf(bakWriteText, result.p), actionOf(bakStamp, result.p)],
    result.offered)
  for record in result.offered.portable:
    if record.evidenceSource.builtinKind == "write-text":
      allowedMemo = record
  let evidence = dependencyEvidencePath(result.p / "cache", "t-kind-write-text")
  if fileExists(evidence):
    let raw = readFile(evidence)
    var bytes = newSeq[byte](raw.len)
    if raw.len > 0:
      copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
    allowedRecord = decodeActionResultRecord(bytes)

proc requireAllowedRecord() =
  if allowedMemo.weakHex.len == 0:
    discard produceAllowed()

suite "owner decision 2026-10-31: the builtin-kind allowlist":

  setup:
    # A fresh tree per case: a cache left by an earlier run serves the
    # producer cases from it (`asCacheHit`), and nothing then publishes.
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "the table is complete: every builtin kind is allowed or refused, by name":
    for kind in BuildActionKind:
      if kind == bakProcess:
        continue
      check (kind in Refused) != (kind in Allowed)
      check (builtinKindName(kind) in PublishableBuiltinKinds) ==
        (kind in Allowed)
      let source = evidenceSourceOf(actionOf(kind, TmpDir / "names"))
      check source == builtinEvidence(builtinKindName(kind))
      var parsed: EvidenceSource
      check parseEvidenceSource($source, parsed) and parsed == source
      check $source == "builtin:" & builtinKindName(kind)

  test "an allowed builtin publishes to both publishers, stating its kind":
    let (p, offered, run) = produceAllowed()
    for item in run.results:
      require item.status == asSucceeded
    check offered.peer.len == 2
    check builtinEvidence("write-text") in offered.peer
    check builtinEvidence("stamp") in offered.peer
    check offered.portable.len == 2
    for record in offered.portable:
      check record.evidenceSource.builtinKind in ["write-text", "stamp"]
      check portableRecordRefusal(record) == ""
    check allowedMemo.weakHex.len > 0
    for event in run.trace:
      check event.event notin ["peer-cache-publish-refused",
        "portable-memo-publish-refused"]
    require fileExists(dependencyEvidencePath(p / "cache", "t-kind-write-text"))
    check publicationRefusal(allowedRecord, elComplete,
      builtinEvidence("write-text")) == ""
    # `ensure-dir` passes the kind rule too (it is usually refused for
    # naming no input, which is a different rule).
    check nonMonitoredSourceRefusal(builtinEvidence("ensure-dir")) == ""

  for kind in Refused:
    let name = builtinKindName(kind)

    test "PRODUCER: a '" & name & "' builtin's record is offered to neither publisher":
      let p = project("producer-" & name)
      let offered = Offered()
      let run = runPublishing(p, @[actionOf(kind, p)], offered)
      require run.results.len == 1
      checkpoint(run.results[0].reason & " " & run.results[0].stderr)
      require run.results[0].status == asSucceeded
      require run.results[0].launched
      check offered.peer.len == 0
      check offered.portable.len == 0
      var peerRefusals, portableRefusals = 0
      for event in run.trace:
        if "'" & name & "' builtin" in event.detail:
          if event.event == "peer-cache-publish-refused": inc peerRefusals
          if event.event == "portable-memo-publish-refused": inc portableRefusals
      check peerRefusals == 1
      check portableRefusals == 1

    test "CONSUMER: a record another host published as a '" & name & "' builtin is refused":
      requireAllowedRecord()
      require allowedMemo.weakHex.len > 0
      # rbpm-v2: the kind survives the wire format and the consumer's rule
      # refuses it by name.
      var memo = allowedMemo
      memo.evidenceSource = builtinEvidence(name)
      let decoded = decodeMemo(encodeMemo(memo))
      check decoded.evidenceSource == builtinEvidence(name)
      let refusal = portableRecordRefusal(decoded)
      check "'" & name & "' builtin" in refusal
      # Peer memo entry v4: the kind is inside the SIGNED attestation
      # message, survives encode/decode, and the consumer refuses it.
      let weak = digestOf("weak".toOpenArrayByte(0, 3))
      var entry = MemoEntry(weakFingerprint: weak, pathSetDigest: weak,
        strongFingerprint: weak,
        recordBytes: encodeActionResultRecord(allowedRecord),
        evidenceLevel: elComplete, evidenceSource: builtinEvidence(name))
      var asAllowed = entry
      asAllowed.evidenceSource = builtinEvidence("write-text")
      check attestationMessage(entry) != attestationMessage(asAllowed)
      let served = decodeMemoEntry(encodeMemoEntry(entry))
      check served.evidenceSource == builtinEvidence(name)
      check "'" & name & "' builtin" in memoEntryRefusal(served, allowedRecord)
      check memoEntryRefusal(decodeMemoEntry(encodeMemoEntry(asAllowed)),
        allowedRecord) == ""

  test "an unknown or future kind, and a record that does not state its kind, are refused":
    for unknown in ["some-future-kind", "process", "Write-Text"]:
      let refusal = nonMonitoredSourceRefusal(builtinEvidence(unknown))
      check "'" & unknown & "' builtin" in refusal
      check publicationRuleRefusal(ffpChecksum, "", elComplete,
        builtinEvidence(unknown), 1).len > 0
    # The bare `builtin` an older producer wrote: kind unstated, refused.
    var legacy: EvidenceSource
    check parseEvidenceSource("builtin", legacy)
    check legacy.kind == eskBuiltin and legacy.builtinKind.len == 0
    check "does not state the builtin's kind" in
      nonMonitoredSourceRefusal(legacy)
    var empty: EvidenceSource
    check not parseEvidenceSource("builtin:", empty)
