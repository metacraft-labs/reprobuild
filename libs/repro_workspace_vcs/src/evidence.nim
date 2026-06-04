## Workspace VCS — unified evidence schema (M4).
##
## M1/M2/M3 expose two parallel structured query-result shapes:
## ``GitQueryResult`` in ``git_actions`` and ``HgQueryResult`` in
## ``hg_actions``. Both carry the same logical fields (status,
## head-sha, is-clean, is-published, diagnostic) but live in distinct
## per-VCS types so neither needs to know about the other.
##
## M4 folds those siblings into a single **unified** evidence record
## with a ``vcsKind`` discriminator (git vs hg), an SSZ-envelope binary
## codec for persistence and inter-process exchange, and a derived JSON
## inspection view that ``writeBuildReport`` embeds under the new
## top-level ``workspaceVcs`` array.
##
## Design rules (mirrored verbatim from the milestone):
##
##   1. One unified record, discriminator field. Downstream tools
##      (``repro workspace status``, ``repro check``, M6+ planners)
##      consume ``WorkspaceVcsEvidence`` directly and never reach back
##      into the per-VCS ``GitQueryResult`` / ``HgQueryResult`` types.
##   2. SSZ envelope per Domain-Types.md: a small Reprobuild header
##      (magic + schema version + payload length) wraps an SSZ-encoded
##      ``seq[WorkspaceVcsEvidenceSsz]`` body. The envelope is the
##      canonical on-the-wire representation.
##   3. JSON is a derived view of the same record. A single ``toJson``
##      proc emits the build-report shape; ``fromJson`` reverses it so
##      the round-trip test can prove no silent translation loss.
##   4. Adapters from the per-VCS shapes. ``evidenceFor(GitQueryResult,
##      …)`` / ``evidenceFor(HgQueryResult, …)`` are the only seam
##      callers need; the per-VCS types stay exactly as-is.
##   5. ``observedAtUnixMs`` is observation-only metadata — it MUST NOT
##      participate in any cache key. Callers that fold this evidence
##      into a downstream action's fingerprint use ``vcsToolDigestHex``
##      (the M1/M3 identity digest) instead.

import std/[json, sequtils]

import repro_core/codec
import ssz_serialization

import git_actions
import hg_actions

const
  WorkspaceVcsEvidenceMagic* = "reprobuild.workspaceVcsEvidence.v1"
    ## First bytes of the SSZ envelope. Stable across the M4 schema;
    ## a future format change requires a new magic string so a stale
    ## reader fails closed instead of silently misinterpreting the
    ## payload.
  WorkspaceVcsEvidenceSchemaVersion* = 1'u16
    ## Schema/version tag inside the envelope header. Bumped only when
    ## the SSZ body shape itself changes incompatibly.

  MaxEvidenceListItems = 4096
  MaxEvidenceTextBytes = 4096

type
  WorkspaceVcsKind* = enum
    ## Discriminator: which VCS this evidence record came from. Distinct
    ## from the M2/M3 receipt-level ``WorkspaceVcsKind = "git"`` /
    ## ``WorkspaceVcsKindHg = "hg"`` constants — those are string tags
    ## inside receipts; this is the typed enum used by the unified
    ## evidence record.
    wvkGit
    wvkHg

  WorkspaceVcsQueryOp* = enum
    ## The three observation-only query ops M2/M3 define. Downstream
    ## tools rely on this discriminator to know which of
    ## ``headSha`` / ``isClean`` / ``isPublished`` is the meaningful
    ## field on a given record.
    wvqHeadSha
    wvqIsClean
    wvqIsPublished

  WorkspaceVcsEvidenceStatus* = enum
    ## Resolution status. ``wvesResolved`` means the query produced a
    ## structured answer; ``wvesFailed`` means the underlying VCS
    ## subprocess refused or the working tree did not match the
    ## query's preconditions. The structured ``diagnostic`` field
    ## carries the human-facing reason on failure.
    wvesResolved
    wvesFailed

  WorkspaceVcsEvidence* = object
    ## Unified evidence record. ``path`` is the workspace-relative path
    ## of the queried repo; ``vcsToolDigestHex`` is the M1/M3 identity
    ## digest hex of the resolving git/hg binary so a downstream action
    ## fingerprint folds the same identity bit M2/M3 already fold into
    ## their per-action fingerprints. ``observedAtUnixMs`` is the
    ## wall-clock time of observation and MUST NOT participate in any
    ## cache key.
    vcsKind*: WorkspaceVcsKind
    path*: string
    op*: WorkspaceVcsQueryOp
    status*: WorkspaceVcsEvidenceStatus
    headSha*: string
    isClean*: bool
    isPublished*: bool
    diagnostic*: string
    vcsToolDigestHex*: string
    observedAtUnixMs*: int64

  WorkspaceVcsEvidenceCodecError* = object of CatchableError
    ## Raised by the binary codec on envelope/SSZ-payload validation
    ## failures. The exception's ``msg`` names which check failed so a
    ## caller can attribute the failure (wrong magic, truncated, SSZ
    ## decode error, unknown enum value, etc.).

  # --- SSZ wire representation -------------------------------------

  SszEvidenceText = List[byte, MaxEvidenceTextBytes]

  WorkspaceVcsEvidenceSsz = object
    vcsKind: uint8
    op: uint8
    status: uint8
    isClean: uint8
    isPublished: uint8
    path: SszEvidenceText
    headSha: SszEvidenceText
    diagnostic: SszEvidenceText
    vcsToolDigestHex: SszEvidenceText
    observedAtUnixMs: uint64  ## bit-cast of the source ``int64``: SSZ
                              ## has no signed wire type, so we round-trip
                              ## the value's two's-complement bit pattern
                              ## via ``cast``. The unified record exposes
                              ## the field as ``int64``; the codec stays
                              ## strictly inside SSZ-supported scalars.

  WorkspaceVcsEvidenceListSsz = object
    items: List[WorkspaceVcsEvidenceSsz, MaxEvidenceListItems]

proc fail(message: string) {.noreturn.} =
  raise newException(WorkspaceVcsEvidenceCodecError, message)

# ---- Adapters from the per-VCS shapes ------------------------------

proc statusFromGit(status: GitQueryStatus): WorkspaceVcsEvidenceStatus =
  case status
  of gqsOk: wvesResolved
  of gqsFailed: wvesFailed

proc statusFromHg(status: HgQueryStatus): WorkspaceVcsEvidenceStatus =
  case status
  of hqsOk: wvesResolved
  of hqsFailed: wvesFailed

proc evidenceFor*(query: GitQueryResult; path: string;
                  op: WorkspaceVcsQueryOp;
                  vcsToolDigestHex: string;
                  observedAtUnixMs: int64): WorkspaceVcsEvidence =
  ## Map a ``GitQueryResult`` into the unified evidence record. The
  ## caller supplies the workspace-relative ``path``, the ``op`` they
  ## asked the M2 query for, the M1 identity digest hex of the
  ## resolving git binary, and the wallclock observation time. The
  ## ``status`` / ``headSha`` / ``isClean`` / ``isPublished`` /
  ## ``diagnostic`` fields are copied byte-identically from the per-VCS
  ## result; the status enum is normalised from ``gqsOk`` →
  ## ``wvesResolved``.
  WorkspaceVcsEvidence(
    vcsKind: wvkGit,
    path: path,
    op: op,
    status: statusFromGit(query.status),
    headSha: query.headSha,
    isClean: query.isClean,
    isPublished: query.isPublished,
    diagnostic: query.diagnostic,
    vcsToolDigestHex: vcsToolDigestHex,
    observedAtUnixMs: observedAtUnixMs)

proc evidenceFor*(query: HgQueryResult; path: string;
                  op: WorkspaceVcsQueryOp;
                  vcsToolDigestHex: string;
                  observedAtUnixMs: int64): WorkspaceVcsEvidence =
  ## Parallel adapter for ``HgQueryResult``. Same field-by-field map
  ## as the git arm; only the ``vcsKind`` discriminator differs.
  WorkspaceVcsEvidence(
    vcsKind: wvkHg,
    path: path,
    op: op,
    status: statusFromHg(query.status),
    headSha: query.headSha,
    isClean: query.isClean,
    isPublished: query.isPublished,
    diagnostic: query.diagnostic,
    vcsToolDigestHex: vcsToolDigestHex,
    observedAtUnixMs: observedAtUnixMs)

# ---- SSZ helpers ---------------------------------------------------

proc toSszText(value: string): SszEvidenceText =
  if value.len > MaxEvidenceTextBytes:
    fail("workspace-vcs evidence text exceeds SSZ bound (" &
      $value.len & " > " & $MaxEvidenceTextBytes & ")")
  var bytes = newSeq[byte](value.len)
  for i, ch in value:
    bytes[i] = byte(ord(ch))
  SszEvidenceText.init(bytes)

proc fromSszText(value: SszEvidenceText): string =
  let raw = value.asSeq()
  result = newString(raw.len)
  for i, b in raw:
    result[i] = char(b)

proc toSsz(value: WorkspaceVcsEvidence): WorkspaceVcsEvidenceSsz =
  WorkspaceVcsEvidenceSsz(
    vcsKind: uint8(ord(value.vcsKind)),
    op: uint8(ord(value.op)),
    status: uint8(ord(value.status)),
    isClean: (if value.isClean: 1'u8 else: 0'u8),
    isPublished: (if value.isPublished: 1'u8 else: 0'u8),
    path: toSszText(value.path),
    headSha: toSszText(value.headSha),
    diagnostic: toSszText(value.diagnostic),
    vcsToolDigestHex: toSszText(value.vcsToolDigestHex),
    observedAtUnixMs: cast[uint64](value.observedAtUnixMs))

proc fromSsz(value: WorkspaceVcsEvidenceSsz): WorkspaceVcsEvidence =
  if value.vcsKind > uint8(ord(high(WorkspaceVcsKind))):
    fail("invalid workspace-vcs evidence vcsKind in SSZ payload: " &
      $value.vcsKind)
  if value.op > uint8(ord(high(WorkspaceVcsQueryOp))):
    fail("invalid workspace-vcs evidence op in SSZ payload: " & $value.op)
  if value.status > uint8(ord(high(WorkspaceVcsEvidenceStatus))):
    fail("invalid workspace-vcs evidence status in SSZ payload: " &
      $value.status)
  if value.isClean > 1'u8:
    fail("invalid workspace-vcs evidence isClean boolean: " & $value.isClean)
  if value.isPublished > 1'u8:
    fail("invalid workspace-vcs evidence isPublished boolean: " &
      $value.isPublished)
  WorkspaceVcsEvidence(
    vcsKind: WorkspaceVcsKind(value.vcsKind),
    path: fromSszText(value.path),
    op: WorkspaceVcsQueryOp(value.op),
    status: WorkspaceVcsEvidenceStatus(value.status),
    headSha: fromSszText(value.headSha),
    isClean: value.isClean == 1'u8,
    isPublished: value.isPublished == 1'u8,
    diagnostic: fromSszText(value.diagnostic),
    vcsToolDigestHex: fromSszText(value.vcsToolDigestHex),
    observedAtUnixMs: cast[int64](value.observedAtUnixMs))

proc encodeSszBody(items: openArray[WorkspaceVcsEvidence]): seq[byte] =
  if items.len > MaxEvidenceListItems:
    fail("workspace-vcs evidence list exceeds SSZ bound (" &
      $items.len & " > " & $MaxEvidenceListItems & ")")
  var wire: WorkspaceVcsEvidenceListSsz
  wire.items = List[WorkspaceVcsEvidenceSsz, MaxEvidenceListItems].init(
    items.toSeq().mapIt(toSsz(it)))
  try:
    SSZ.encode(wire)
  except SszError as err:
    fail("could not SSZ-encode workspace-vcs evidence list: " & err.msg)
  except IOError as err:
    fail("could not write SSZ workspace-vcs evidence payload: " & err.msg)

proc decodeSszBody(payload: openArray[byte]): seq[WorkspaceVcsEvidence] =
  var wire: WorkspaceVcsEvidenceListSsz
  try:
    wire = SSZ.decode(payload, WorkspaceVcsEvidenceListSsz)
  except SszError as err:
    fail("invalid SSZ workspace-vcs evidence payload: " & err.msg)
  except IOError as err:
    fail("could not read SSZ workspace-vcs evidence payload: " & err.msg)
  for item in wire.items.asSeq():
    result.add(fromSsz(item))

# ---- Public binary codec ------------------------------------------

proc toSsz*(items: openArray[WorkspaceVcsEvidence]): seq[byte] =
  ## Encode a list of evidence records into the canonical SSZ envelope.
  ## Layout: ``writeString(magic) || writeU16Le(schemaVersion) ||
  ## writeU32Le(payloadLen) || payloadBytes`` where ``payloadBytes`` is
  ## the SSZ-encoded ``WorkspaceVcsEvidenceListSsz`` body. The string
  ## prefix uses the length-prefixed encoding from
  ## ``repro_core/codec.writeString`` so a reader can locate the
  ## magic without a separate fixed-width header.
  let payload = encodeSszBody(items)
  result = newSeqOfCap[byte](
    4 + WorkspaceVcsEvidenceMagic.len + 2 + 4 + payload.len)
  result.writeString(WorkspaceVcsEvidenceMagic)
  result.writeU16Le(WorkspaceVcsEvidenceSchemaVersion)
  result.writeU32Le(uint32(payload.len))
  for b in payload:
    result.add(b)

proc fromSsz*(bytes: openArray[byte]): seq[WorkspaceVcsEvidence] =
  ## Inverse of ``toSsz``. Validates the envelope (magic, schema
  ## version, declared payload length matches the remaining bytes)
  ## before delegating to the SSZ body decoder. Raises
  ## ``WorkspaceVcsEvidenceCodecError`` on any structural mismatch.
  var pos = 0
  var magic: string
  try:
    magic = readString(bytes, pos)
  except EnvelopeError as err:
    fail("workspace-vcs evidence envelope truncated reading magic: " &
      err.msg)
  if magic != WorkspaceVcsEvidenceMagic:
    fail("workspace-vcs evidence envelope magic mismatch: expected " &
      WorkspaceVcsEvidenceMagic & ", got " & magic)
  var schemaVersion: uint16
  try:
    schemaVersion = readU16Le(bytes, pos)
  except EnvelopeError as err:
    fail("workspace-vcs evidence envelope truncated reading schema version: " &
      err.msg)
  if schemaVersion != WorkspaceVcsEvidenceSchemaVersion:
    fail("unsupported workspace-vcs evidence schema version " &
      $schemaVersion)
  var payloadLen: uint32
  try:
    payloadLen = readU32Le(bytes, pos)
  except EnvelopeError as err:
    fail("workspace-vcs evidence envelope truncated reading payload length: " &
      err.msg)
  if pos + int(payloadLen) != bytes.len:
    fail("workspace-vcs evidence envelope length mismatch (declared " &
      $payloadLen & " body bytes, " & $(bytes.len - pos) & " remaining)")
  if payloadLen == 0:
    return @[]
  var payload = newSeq[byte](int(payloadLen))
  for i in 0 ..< int(payloadLen):
    payload[i] = bytes[pos + i]
  decodeSszBody(payload)

# ---- JSON view (derived from the same record) ---------------------

proc vcsKindTag(kind: WorkspaceVcsKind): string =
  case kind
  of wvkGit: "git"
  of wvkHg: "hg"

proc parseVcsKindTag(tag: string): WorkspaceVcsKind =
  case tag
  of "git": wvkGit
  of "hg": wvkHg
  else:
    fail("unknown workspace-vcs evidence vcsKind tag: " & tag)

proc opTag(op: WorkspaceVcsQueryOp): string =
  case op
  of wvqHeadSha: "head-sha"
  of wvqIsClean: "is-clean"
  of wvqIsPublished: "is-published"

proc parseOpTag(tag: string): WorkspaceVcsQueryOp =
  case tag
  of "head-sha": wvqHeadSha
  of "is-clean": wvqIsClean
  of "is-published": wvqIsPublished
  else:
    fail("unknown workspace-vcs evidence op tag: " & tag)

proc statusTag(status: WorkspaceVcsEvidenceStatus): string =
  case status
  of wvesResolved: "resolved"
  of wvesFailed: "failed"

proc parseStatusTag(tag: string): WorkspaceVcsEvidenceStatus =
  case tag
  of "resolved": wvesResolved
  of "failed": wvesFailed
  else:
    fail("unknown workspace-vcs evidence status tag: " & tag)

proc toJson*(items: openArray[WorkspaceVcsEvidence]): JsonNode =
  ## Derive the JSON inspection view embedded in the build report under
  ## ``"workspaceVcs"``. Field names are stable for downstream tools.
  ## The JSON is a *view*: never use it as a source of truth, always
  ## round-trip through ``toSsz`` for persistence.
  result = newJArray()
  for item in items:
    result.add(%*{
      "vcsKind": vcsKindTag(item.vcsKind),
      "path": item.path,
      "op": opTag(item.op),
      "status": statusTag(item.status),
      "headSha": item.headSha,
      "isClean": item.isClean,
      "isPublished": item.isPublished,
      "diagnostic": item.diagnostic,
      "vcsToolDigestHex": item.vcsToolDigestHex,
      "observedAtUnixMs": item.observedAtUnixMs
    })

proc requireField(node: JsonNode; key: string): JsonNode =
  if node.kind != JObject or key notin node:
    fail("workspace-vcs evidence JSON missing required field: " & key)
  node[key]

proc fromJson*(node: JsonNode): seq[WorkspaceVcsEvidence] =
  ## Inverse of ``toJson``. The round-trip test relies on this proc to
  ## prove that the JSON view loses no information vs. the unified
  ## record.
  if node.kind != JArray:
    fail("workspace-vcs evidence JSON must be an array, got: " & $node.kind)
  for entry in node:
    if entry.kind != JObject:
      fail("workspace-vcs evidence JSON array entry must be an object")
    var rec: WorkspaceVcsEvidence
    rec.vcsKind = parseVcsKindTag(requireField(entry, "vcsKind").getStr())
    rec.path = requireField(entry, "path").getStr()
    rec.op = parseOpTag(requireField(entry, "op").getStr())
    rec.status = parseStatusTag(requireField(entry, "status").getStr())
    rec.headSha = requireField(entry, "headSha").getStr()
    rec.isClean = requireField(entry, "isClean").getBool()
    rec.isPublished = requireField(entry, "isPublished").getBool()
    rec.diagnostic = requireField(entry, "diagnostic").getStr()
    rec.vcsToolDigestHex = requireField(entry, "vcsToolDigestHex").getStr()
    rec.observedAtUnixMs = requireField(entry, "observedAtUnixMs").getBiggestInt()
    result.add(rec)

