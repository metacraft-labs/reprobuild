## `ReachGoalRequest` / `ReachGoalResponse` and the derivation check —
## Distributed-Execution M7 (deployment-security-architecture.md FLOW-2:
## "the Boundary is a vocabulary, not a tunnel").
##
## A request NAMES a node of a graph descriptor and the snapshot it runs
## against, both by content digest. It may also state the argv and the input
## paths the caller expects that node to use — and the worker checks those
## claims against what it hydrated rather than using them: `checkDerivation`
## refuses a request whose argv is not exactly the descriptor node's argv, or
## whose input path is not a declared input of that node AND a tracked path
## of the verified snapshot. The worker then executes the DESCRIPTOR's argv.
## That is the property that makes this a vocabulary rather than a remote
## shell: no field of a request ever becomes a command.
##
## M2 extends the response with streamed events and the lazy-materialization
## policy; the request's fields are already the ones M2 needs.

import std/[sets, strutils]

from repro_core/codec import elementCountFits
import repro_workspace_snapshot/manifest

import ./graph_descriptor

const
  RequestMagic = "RGRQ"
  ResponseMagic = "RGRS"
  GoalVersion = 2'u16
    ## v2 (review fixes): input artifacts.
  ResponseVersion = 2'u16
    ## v2 (trust profiles): profile, isolation level, execution record.
  MaxClaims* = 4_096
  MaxReasonBytes* = 2_048
  MaxOutputs* = 10_000
  MaxCertificateBytes* = 64 * 1024
  MaxStderrTailBytes* = 4 * 1024

type
  InputArtifact* = object
    ## A declared output of one of the goal node's INPUT NODES, by content:
    ## the node that produced it, its declared path, its BLAKE3 digest.
    node*: string
    path*: string
    digest*: array[32, byte]

  ReachGoalRequest* = object
    requestId*: string
    graphDescriptorDigest*: array[32, byte]
    snapshotManifestDigest*: array[32, byte]
    goalNode*: string
    claimedArgv*: seq[string]
      ## Optional. When present it must equal the node's argv exactly.
    claimedInputs*: seq[string]
      ## Optional. Each must be a declared input of the node and a tracked
      ## path of the verified snapshot.
    issueCertificate*: bool
    inputArtifacts*: seq[InputArtifact]
      ## Outputs of the node's declared input nodes the worker materializes
      ## (read-only, executable) for it. Each must name a declared input
      ## node and one of that node's declared outputs; the bytes are
      ## hydrated by digest and verified.

  GoalStatus* = enum
    gsRefused = "refused"
    gsFailed = "failed"
    gsCompleted = "completed"

  GoalOutput* = object
    path*: string
    digest*: array[32, byte]
    size*: uint64

  ReachGoalResponse* = object
    requestId*: string
    status*: GoalStatus
    trigger*: string
      ## The detector trigger of a refusal (`goal-argv-not-derivable`, …).
    reason*: string
    exitCode*: int32
    outputs*: seq[GoalOutput]
    treeBefore*: string
    treeAfter*: string
    certificate*: string
      ## A signed `test-certificate.v1` (TOML) when one was requested and
      ## the tree re-verified; empty otherwise.
    leaseReports*: int32
    stderrTail*: string
      ## The last `MaxStderrTailBytes` of the action's stderr, for the
      ## caller's diagnostics (M2 replaces it with streamed events). It goes
      ## only to the caller, whose source it is; it never goes to the
      ## evidence sink.
    profile*: string
      ## The worker's trust profile (`trusted`, `hardened`).
    isolation*: string
      ## What confined the action (`linux-namespace`, `macos-seatbelt`,
      ## `windows-job`, …); empty when nothing ran.
    executionRecordDigest*: array[32, byte]
      ## BLAKE3 of the goal's execution record in the worker's CAS (argv,
      ## inputs, outputs, isolation level, detections); all zero when no
      ## record was written (a refusal before anything ran).

  GoalCodecError* = object of CatchableError

  DerivationVerdict* = object
    ok*: bool
    trigger*: string
    reason*: string
    nodeIndex*: int

# ---------------------------------------------------------------------------
# Derivation.
# ---------------------------------------------------------------------------

proc checkDerivation*(req: ReachGoalRequest; desc: GraphCacheDescriptor;
                      snap: WorkspaceSnapshotManifest;
                      tracked: openArray[string]): DerivationVerdict =
  ## Is everything `req` names derivable from the hydrated `desc` and the
  ## verified `snap` (whose tracked path set is `tracked`)? See the module
  ## doc. Pure.
  if desc.snapshotContentId != contentIdOf(snap):
    return DerivationVerdict(trigger: "goal-descriptor-unbound",
      reason: "the descriptor was evaluated from " & desc.snapshotContentId &
        " but the snapshot is " & contentIdOf(snap))
  let idx = desc.findNode(req.goalNode)
  if idx < 0:
    return DerivationVerdict(trigger: "goal-argv-not-derivable",
      reason: "node '" & req.goalNode & "' is not in the hydrated descriptor")
  let node = desc.nodes[idx]
  if req.claimedArgv.len > 0 and req.claimedArgv != node.argv:
    return DerivationVerdict(trigger: "goal-argv-not-derivable",
      reason: "the requested argv is not the argv of node '" & node.id &
        "' in the hydrated descriptor")
  var trackedSet = initHashSet[string]()
  for p in tracked: trackedSet.incl(p)
  var declared = initHashSet[string]()
  for p in node.inputs: declared.incl(p)
  for p in req.claimedInputs:
    let bad = validateRelPath(p)
    if bad.len > 0:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input " & p & ": " & bad)
    if p notin declared:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input " & p & " is not a declared input of node '" &
          node.id & "'")
    if p notin trackedSet:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input " & p & " is not part of the verified snapshot")
  for p in node.inputs:
    if p notin trackedSet:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "node '" & node.id & "' declares input " & p &
          ", which the verified snapshot does not contain")
  # Input artifacts: each an output the DESCRIPTOR says an input node of
  # this node declares — the request supplies only the digest.
  var inputNodes = initHashSet[string]()
  for dep in node.inputNodes: inputNodes.incl(dep)
  var seenArtifacts = initHashSet[string]()
  for a in req.inputArtifacts:
    if a.node notin inputNodes:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input artifact " & a.node & ":" & a.path & " names a node " &
          "that is not a declared input node of '" & node.id & "'")
    let depIdx = desc.findNode(a.node)
    if depIdx < 0 or a.path notin desc.nodes[depIdx].outputs:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input artifact " & a.node & ":" & a.path & " is not a " &
          "declared output of node '" & a.node & "'")
    let key = a.node & "\0" & a.path
    if key in seenArtifacts:
      return DerivationVerdict(trigger: "goal-path-outside-snapshot",
        reason: "input artifact " & a.node & ":" & a.path & " is named twice")
    seenArtifacts.incl(key)
  DerivationVerdict(ok: true, nodeIndex: idx)

# ---------------------------------------------------------------------------
# Codec.
# ---------------------------------------------------------------------------

proc putU16(b: var seq[byte]; v: uint16) =
  b.add(byte(v and 0xff)); b.add(byte(v shr 8))
proc putU32(b: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): b.add(byte((v shr uint32(s)) and 0xff))
proc putU64(b: var seq[byte]; v: uint64) =
  for s in countup(0, 56, 8): b.add(byte((v shr uint64(s)) and 0xff))
proc putStr(b: var seq[byte]; s: string) =
  b.putU32(uint32(s.len))
  for ch in s: b.add(byte(ord(ch)))

proc need(d: openArray[byte]; pos, n: int) =
  if n < 0 or pos + n > d.len:
    raise newException(GoalCodecError, "truncated goal message")
proc getU16(d: openArray[byte]; pos: var int): uint16 =
  need(d, pos, 2)
  result = uint16(d[pos]) or (uint16(d[pos + 1]) shl 8)
  pos += 2
proc getU32(d: openArray[byte]; pos: var int): uint32 =
  need(d, pos, 4)
  for i in 0 ..< 4: result = result or (uint32(d[pos + i]) shl uint32(8 * i))
  pos += 4
proc getU64(d: openArray[byte]; pos: var int): uint64 =
  need(d, pos, 8)
  for i in 0 ..< 8: result = result or (uint64(d[pos + i]) shl uint64(8 * i))
  pos += 8
proc getStr(d: openArray[byte]; pos: var int; maxLen: int): string =
  let n = int(getU32(d, pos))
  if n > maxLen:
    raise newException(GoalCodecError, "goal message string too long")
  need(d, pos, n)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(d[pos + i])
  pos += n
proc getCount(d: openArray[byte]; pos: var int; minimumBytes: int): int =
  ## An element count, bounded BEFORE anything is sized or looped over by
  ## it: each element takes at least `minimumBytes` (repro_core/codec).
  let raw = getU32(d, pos)
  if not elementCountFits(raw, d.len - pos, minimumBytes):
    raise newException(GoalCodecError, "goal codec element count exceeds remaining bytes")
  int(raw)

proc get32(d: openArray[byte]; pos: var int): array[32, byte] =
  need(d, pos, 32)
  for i in 0 ..< 32: result[i] = d[pos + i]
  pos += 32
proc checkMagic(d: openArray[byte]; magic: string) =
  need(d, 0, magic.len + 2)
  for i, ch in magic:
    if d[i] != byte(ord(ch)):
      raise newException(GoalCodecError, "not a goal message")

proc encodeRequest*(r: ReachGoalRequest): seq[byte] =
  for ch in RequestMagic: result.add(byte(ord(ch)))
  result.putU16(GoalVersion)
  result.putStr(r.requestId)
  result.add(r.graphDescriptorDigest)
  result.add(r.snapshotManifestDigest)
  result.putStr(r.goalNode)
  result.putU32(uint32(r.claimedArgv.len))
  for a in r.claimedArgv: result.putStr(a)
  result.putU32(uint32(r.claimedInputs.len))
  for p in r.claimedInputs: result.putStr(p)
  result.add(if r.issueCertificate: 1'u8 else: 0'u8)
  result.putU32(uint32(r.inputArtifacts.len))
  for a in r.inputArtifacts:
    result.putStr(a.node)
    result.putStr(a.path)
    result.add(a.digest)

proc decodeRequest*(d: openArray[byte]): ReachGoalRequest =
  checkMagic(d, RequestMagic)
  var pos = RequestMagic.len
  if getU16(d, pos) != GoalVersion:
    raise newException(GoalCodecError, "unsupported goal request version")
  result.requestId = getStr(d, pos, 256)
  result.graphDescriptorDigest = get32(d, pos)
  result.snapshotManifestDigest = get32(d, pos)
  result.goalNode = getStr(d, pos, MaxNameBytes)
  let na = getCount(d, pos, 4)
  if na > MaxArgs: raise newException(GoalCodecError, "too many argv claims")
  for _ in 0 ..< na: result.claimedArgv.add(getStr(d, pos, MaxArgBytes))
  let ni = getCount(d, pos, 4)
  if ni > MaxClaims: raise newException(GoalCodecError, "too many input claims")
  for _ in 0 ..< ni: result.claimedInputs.add(getStr(d, pos, MaxPathBytes))
  need(d, pos, 1)
  result.issueCertificate = d[pos] != 0
  inc pos
  let nart = getCount(d, pos, 40)     # node, path, 32-byte digest
  if nart > MaxClaims:
    raise newException(GoalCodecError, "too many input artifacts")
  for _ in 0 ..< nart:
    var a: InputArtifact
    a.node = getStr(d, pos, MaxNameBytes)
    a.path = getStr(d, pos, MaxPathBytes)
    a.digest = get32(d, pos)
    result.inputArtifacts.add(a)
  if pos != d.len:
    raise newException(GoalCodecError, "trailing bytes after goal request")

proc encodeResponse*(r: ReachGoalResponse): seq[byte] =
  for ch in ResponseMagic: result.add(byte(ord(ch)))
  result.putU16(ResponseVersion)
  result.putStr(r.requestId)
  result.add(byte(ord(r.status)))
  result.putStr(r.trigger)
  result.putStr(if r.reason.len > MaxReasonBytes: r.reason[0 ..< MaxReasonBytes]
                else: r.reason)
  result.putU32(cast[uint32](r.exitCode))
  result.putU32(uint32(r.outputs.len))
  for o in r.outputs:
    result.putStr(o.path)
    result.add(o.digest)
    result.putU64(o.size)
  result.putStr(r.treeBefore)
  result.putStr(r.treeAfter)
  result.putStr(r.certificate)
  result.putU32(cast[uint32](r.leaseReports))
  result.putStr(if r.stderrTail.len > MaxStderrTailBytes:
      r.stderrTail[^MaxStderrTailBytes .. ^1]
    else: r.stderrTail)
  result.putStr(r.profile)
  result.putStr(r.isolation)
  result.add(r.executionRecordDigest)

proc decodeResponse*(d: openArray[byte]): ReachGoalResponse =
  checkMagic(d, ResponseMagic)
  var pos = ResponseMagic.len
  if getU16(d, pos) != ResponseVersion:
    raise newException(GoalCodecError, "unsupported goal response version")
  result.requestId = getStr(d, pos, 256)
  need(d, pos, 1)
  let st = int(d[pos]); inc pos
  if st > ord(high(GoalStatus)):
    raise newException(GoalCodecError, "bad goal status")
  result.status = GoalStatus(st)
  result.trigger = getStr(d, pos, 128)
  result.reason = getStr(d, pos, MaxReasonBytes)
  result.exitCode = cast[int32](getU32(d, pos))
  let no = getCount(d, pos, 44)       # path, 32-byte digest, u64 size
  if no > MaxOutputs: raise newException(GoalCodecError, "too many outputs")
  for _ in 0 ..< no:
    var o: GoalOutput
    o.path = getStr(d, pos, MaxPathBytes)
    o.digest = get32(d, pos)
    o.size = getU64(d, pos)
    result.outputs.add(o)
  result.treeBefore = getStr(d, pos, 64)
  result.treeAfter = getStr(d, pos, 64)
  result.certificate = getStr(d, pos, MaxCertificateBytes)
  result.leaseReports = cast[int32](getU32(d, pos))
  result.stderrTail = getStr(d, pos, MaxStderrTailBytes)
  result.profile = getStr(d, pos, 32)
  result.isolation = getStr(d, pos, 128)
  result.executionRecordDigest = get32(d, pos)
  if pos != d.len:
    raise newException(GoalCodecError, "trailing bytes after goal response")
