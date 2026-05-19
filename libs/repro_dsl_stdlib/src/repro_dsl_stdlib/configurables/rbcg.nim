## Binary RBCG (Reprobuild Configurable Graph) envelope.
##
## Same shape as RBLP/RPRC/RBTP: 4-byte ASCII magic ("RBCG"), u16 LE
## schema version, u32 LE body length, body bytes, then a trailing
## BLAKE3-256 checksum over `magic||version||bodyLen||body`. A
## corrupted envelope (mismatched checksum) is rejected with
## `ECorruptEnvelope`.
##
## Per-node record: scope-derived name, explicit persistent id
## (empty when absent), description (with directives already
## stripped), description source position, value kind, resolved
## value, ordered contributions (priority + value + source site).
##
## CRITICAL: construction ids are NOT serialized. They are an
## in-process identity only. Persistent lookup uses the (explicit id,
## scope-derived name) pair per "Persistent Lookup" in the spec.
##
## Dep edges between nodes are encoded as *serialization-position
## indices* — i.e. the zero-based position of the depended-on node in
## the envelope's node sequence. The decoder rebuilds the in-memory
## dependency list by translating those indices back to whatever
## fresh `ConstructionId` values the load context happens to assign.
## This is what lets us record graph topology without leaking
## in-process identity.

import std/[tables]

import blake3
import repro_core

import ./types
import ./context

const
  RbcgMagic* = "RBCG"
  RbcgCurrentVersion*: uint16 = 2
    ## v1: deps encoded as raw u64 `ConstructionId` (LEAKED in-process
    ##     identity into the persisted envelope; rejected by the spec).
    ## v2: deps encoded as u32 serialization-position indices. v1
    ##     envelopes are not loadable by this build.

  EnvelopeOverhead = 4 + 2 + 4 + 32

# ---------------------------------------------------------------------------
# Value codec
# ---------------------------------------------------------------------------

proc writeValue(outp: var seq[byte]; v: ConfigurableValue) =
  outp.add(byte(ord(v.kind)))
  case v.kind
  of cvkBool: outp.add(if v.boolVal: 1'u8 else: 0'u8)
  of cvkInt: outp.writeU64Le(uint64(v.intVal))
  of cvkString: outp.writeString(v.strVal)
  of cvkBytes:
    outp.writeU32Le(uint32(v.bytesVal.len))
    for b in v.bytesVal: outp.add(b)
  of cvkAny:
    raise newException(ECorruptEnvelope,
      "cvkAny (object-typed) configurables are in-process only and " &
      "cannot be persisted; declare an explicit (de)serialization to " &
      "one of the typed value kinds before persisting")

proc readValue(buf: openArray[byte]; pos: var int): ConfigurableValue =
  if pos >= buf.len:
    raise newException(ECorruptEnvelope, "truncated value kind")
  let raw = buf[pos]; inc pos
  if raw > byte(ord(cvkAny)):
    raise newException(ECorruptEnvelope,
      "unknown value kind " & $raw)
  let kind = ConfigurableValueKind(raw)
  case kind
  of cvkAny:
    raise newException(ECorruptEnvelope,
      "cvkAny is in-process only and must not appear in a persisted " &
      "envelope")
  of cvkBool:
    if pos >= buf.len:
      raise newException(ECorruptEnvelope, "truncated bool")
    let b = buf[pos]; inc pos
    if b > 1'u8: raise newException(ECorruptEnvelope,
      "invalid bool " & $b)
    cvBool(b == 1'u8)
  of cvkInt:
    cvInt(int64(readU64Le(buf, pos)))
  of cvkString:
    cvString(readString(buf, pos))
  of cvkBytes:
    let n = int(readU32Le(buf, pos))
    if pos + n > buf.len:
      raise newException(ECorruptEnvelope, "truncated bytes")
    var raw = newSeq[byte](n)
    for i in 0 ..< n:
      raw[i] = buf[pos + i]
    pos += n
    cvBytes(raw)

# ---------------------------------------------------------------------------
# Site codec
# ---------------------------------------------------------------------------

proc writeSite(outp: var seq[byte]; s: SourceSite) =
  outp.writeString(s.file)
  outp.writeU32Le(uint32(s.line))
  outp.writeU32Le(uint32(s.column))
  outp.add(byte(ord(s.kind)))

proc readSite(buf: openArray[byte]; pos: var int): SourceSite =
  result.file = readString(buf, pos)
  result.line = int(readU32Le(buf, pos))
  result.column = int(readU32Le(buf, pos))
  if pos >= buf.len:
    raise newException(ECorruptEnvelope, "truncated site kind")
  let raw = buf[pos]; inc pos
  if raw > byte(ord(ckForce)):
    raise newException(ECorruptEnvelope, "invalid site kind " & $raw)
  result.kind = ContributionKind(raw)

# ---------------------------------------------------------------------------
# Contribution codec
# ---------------------------------------------------------------------------

proc writeContribution(outp: var seq[byte]; c: Contribution) =
  outp.add(byte(ord(c.priority)))
  outp.writeValue(c.value)
  outp.writeSite(c.site)

proc readContribution(buf: openArray[byte]; pos: var int): Contribution =
  if pos >= buf.len:
    raise newException(ECorruptEnvelope, "truncated priority")
  let raw = buf[pos]; inc pos
  if raw > byte(ord(prForce)):
    raise newException(ECorruptEnvelope, "invalid priority " & $raw)
  result.priority = ContributionPriority(raw)
  result.value = readValue(buf, pos)
  result.site = readSite(buf, pos)

# ---------------------------------------------------------------------------
# Node codec
# ---------------------------------------------------------------------------

proc writeNode(outp: var seq[byte]; n: ConfigurableNode;
               serPos: Table[ConstructionId, uint32]) =
  outp.writeString(n.scopeDerivedName)
  outp.writeString(n.explicitId)
  outp.writeString(n.description)
  outp.writeString(n.descriptionFile)
  outp.writeU32Le(uint32(n.descriptionLine))
  outp.writeU32Le(uint32(n.descriptionColumn))
  outp.add(byte(ord(n.valueKind)))
  outp.add(byte(ord(n.mergeRule)))
  outp.writeValue(n.resolvedVal)
  outp.writeU32Le(uint32(n.contributions.len))
  for c in n.contributions: outp.writeContribution(c)
  outp.writeU32Le(uint32(n.deps.len))
  for d in n.deps:
    # Translate the in-process construction id to the depended-on
    # node's position in *this envelope's* node sequence. Construction
    # ids themselves never reach the byte stream.
    if not serPos.hasKey(d):
      raise newException(ECorruptEnvelope,
        "dependency on construction id " & $uint64(d) &
        " which is not part of the serialized node set")
    outp.writeU32Le(serPos[d])

proc readNodeShallow(buf: openArray[byte]; pos: var int;
                     depPositions: var seq[uint32]):
                     ConfigurableNode =
  ## Decode a node from the envelope, returning its data and the list
  ## of serialization-position indices that describe its deps. The
  ## caller must convert those indices back to construction ids once
  ## all nodes in the envelope have been allocated.
  result = ConfigurableNode()
  result.scopeDerivedName = readString(buf, pos)
  result.explicitId = readString(buf, pos)
  result.description = readString(buf, pos)
  result.descriptionFile = readString(buf, pos)
  result.descriptionLine = int(readU32Le(buf, pos))
  result.descriptionColumn = int(readU32Le(buf, pos))
  if pos >= buf.len: raise newException(ECorruptEnvelope, "truncated kind")
  let vk = buf[pos]; inc pos
  if vk > byte(ord(cvkAny)):
    raise newException(ECorruptEnvelope, "invalid value kind " & $vk)
  result.valueKind = ConfigurableValueKind(vk)
  if pos >= buf.len: raise newException(ECorruptEnvelope,
    "truncated merge rule")
  let mr = buf[pos]; inc pos
  if mr > byte(ord(cmrMapUnion)):
    raise newException(ECorruptEnvelope, "invalid merge rule " & $mr)
  result.mergeRule = CollectionMergeRule(mr)
  result.resolvedVal = readValue(buf, pos)
  let cc = int(readU32Le(buf, pos))
  result.contributions = newSeq[Contribution](cc)
  for i in 0 ..< cc:
    result.contributions[i] = readContribution(buf, pos)
  let dc = int(readU32Le(buf, pos))
  depPositions = newSeq[uint32](dc)
  for i in 0 ..< dc:
    depPositions[i] = readU32Le(buf, pos)
  result.deps = @[]  # filled in by the second pass
  result.resolved = true

# ---------------------------------------------------------------------------
# Envelope encode/decode
# ---------------------------------------------------------------------------

proc encodeBody(ctx: ConfigContext): seq[byte] =
  result.writeU16Le(RbcgCurrentVersion)
  result.writeU32Le(uint32(ctx.nodes.len))
  # Build the (construction id -> serialization position) map up
  # front so the per-node writer can translate dep edges without
  # leaking any raw construction id into the byte stream.
  var serPos = initTable[ConstructionId, uint32]()
  for i, n in ctx.nodes:
    serPos[n.id] = uint32(i)
  for n in ctx.nodes:
    writeNode(result, n, serPos)

proc encodeRbcg*(ctx: ConfigContext): seq[byte] =
  ## Serialize a finalized context as an RBCG envelope. Raises
  ## `ENotFinalized` when the context is still open.
  if ctx == nil:
    raise newException(ECorruptEnvelope, "cannot encode nil context")
  if ctx.state != ccsFinalized:
    raise newException(ENotFinalized,
      "RBCG envelopes can only be encoded from a finalized context")
  let body = encodeBody(ctx)
  result = newSeqOfCap[byte](EnvelopeOverhead + body.len)
  for ch in RbcgMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbcgCurrentVersion)
  result.writeU32Le(uint32(body.len))
  result.add(body)
  let checksum = blake3.digest(result)
  for b in checksum: result.add(b)

proc decodeRbcgPayload(buf: openArray[byte]): seq[ConfigurableNode] =
  var pos = 0
  let version = readU16Le(buf, pos)
  if version != RbcgCurrentVersion:
    raise newException(ESchemaVersionMismatch,
      "RBCG schema version " & $version & " is not supported by this " &
      "build (expected " & $RbcgCurrentVersion & ")")
  let nodeCount = int(readU32Le(buf, pos))
  result = newSeq[ConfigurableNode](nodeCount)
  var allDepPositions = newSeq[seq[uint32]](nodeCount)
  for i in 0 ..< nodeCount:
    var depPositions: seq[uint32]
    result[i] = readNodeShallow(buf, pos, depPositions)
    allDepPositions[i] = depPositions
  if pos != buf.len:
    raise newException(ECorruptEnvelope,
      "trailing bytes after RBCG body")
  # Resolve dep edges. The persisted envelope encodes deps as
  # *serialization-position indices*; we translate them to construction
  # ids assigned by whatever load context owns these nodes (here, the
  # node's own position in the freshly-decoded sequence stands in for
  # its construction id, mirroring how `decodeRbcg` later promotes
  # nodes into a context).
  for i in 0 ..< nodeCount:
    let positions = allDepPositions[i]
    var deps = newSeq[ConstructionId](positions.len)
    for j, p in positions:
      if int(p) >= nodeCount:
        raise newException(ECorruptEnvelope,
          "dependency serialization-position " & $p &
          " is out of range (node count " & $nodeCount & ")")
      # The id field is filled in by the caller (see decodeRbcg) when
      # nodes are promoted into a context. Until then, we record the
      # serialization position as a placeholder construction id; both
      # `decodeRbcg` and `decodeRbcgInto` re-key the deps below.
      deps[j] = ConstructionId(p)
    result[i].deps = deps

proc decodeEnvelopeNodes(buf: openArray[byte]): seq[ConfigurableNode] =
  ## Validate the envelope header + checksum and return the node list
  ## in serialization order. Each node's `deps` initially holds the
  ## *serialization-position indices* of its dependencies as raw
  ## `ConstructionId` values — callers must re-key them to whatever
  ## ids the load context assigns.
  if buf.len < EnvelopeOverhead:
    raise newException(ECorruptEnvelope, "RBCG envelope too short")
  for i in 0 ..< 4:
    if buf[i] != byte(ord(RbcgMagic[i])):
      raise newException(ECorruptEnvelope, "unknown RBCG magic")
  var pos = 4
  let version = readU16Le(buf, pos)
  if version != RbcgCurrentVersion:
    raise newException(ESchemaVersionMismatch,
      "RBCG envelope version " & $version & " is not supported by " &
      "this build (expected " & $RbcgCurrentVersion & "); regenerate " &
      "the persisted graph")
  let bodyLen = int(readU32Le(buf, pos))
  if pos + bodyLen + 32 != buf.len:
    raise newException(ECorruptEnvelope,
      "RBCG envelope length mismatch")
  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  # Verify trailing checksum.
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd: prefix.add(buf[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if buf[bodyEnd + i] != expected[i]:
      raise newException(ECorruptEnvelope,
        "RBCG checksum mismatch (corrupted envelope)")
  # NOTE: we re-read the version + body length from the body itself
  # because `encodeBody` includes them. This duplicates the envelope
  # header inside the body — historic shape, mirrors RBLP.
  var bodyView: seq[byte] = newSeq[byte](bodyLen)
  for i in 0 ..< bodyLen: bodyView[i] = buf[bodyStart + i]
  result = decodeRbcgPayload(bodyView)

proc decodeRbcgInto*(ctx: ConfigContext; buf: openArray[byte]) =
  ## Decode an RBCG envelope into the persisted-entry tables of
  ## `ctx`. The current declarations in `ctx` may then resolve via
  ## the persistent-lookup algorithm during `allocConfigurable`.
  let nodes = decodeEnvelopeNodes(buf)
  # `decodeRbcgPayload` left each node's `deps` filled with the
  # *serialization-position indices* of its dependencies (encoded as
  # ConstructionId values). For persisted-entry storage this is fine:
  # the persistent-lookup path consults `contributions` and
  # `resolvedVal`, not raw dep ids. When a caller wants the real
  # graph (via `decodeRbcg`) we re-key the deps to match the load
  # context's freshly assigned construction ids below.
  for n in nodes:
    let key =
      if n.explicitId.len > 0: n.explicitId
      else: n.scopeDerivedName
    if key.len == 0: continue
    if ctx.persistedEntries.hasKey(key):
      raise newException(ECorruptEnvelope,
        "duplicate persisted key " & key)
    ctx.persistedEntries[key] = n
    if n.scopeDerivedName.len > 0:
      ctx.persistedByScope[n.scopeDerivedName] = key

proc decodeRbcg*(buf: openArray[byte]): ConfigContext =
  ## Decode an RBCG envelope and return a NEW finalized context whose
  ## node list mirrors the persisted graph 1:1, preserving the
  ## envelope's node ordering. Useful for inspecting a persisted file
  ## directly (e.g. for `repro home why`); not used in the normal
  ## "load + re-evaluate" path which goes through `decodeRbcgInto`.
  let nodes = decodeEnvelopeNodes(buf)
  result = newConfigContext()
  # Promote nodes in their envelope-ordered serialization positions
  # so the construction ids the load context assigns line up with
  # the dep indices already stored in each node. (This is the only
  # place the load context's construction-id assignment happens to
  # match the serialization position 1:1; that is an internal
  # convenience and is NOT visible in the on-disk encoding.)
  for i, n in nodes:
    let id = ConstructionId(i)
    n.id = id
    result.nodes.add(n)
    if n.scopeDerivedName.len > 0:
      result.byScope[n.scopeDerivedName] = id
    if n.explicitId.len > 0:
      result.byExplicitId[n.explicitId] = id
  # Also expose them through persistedEntries for parity with
  # `decodeRbcgInto`-based consumers (e.g. tools that walk both
  # tables).
  for n in nodes:
    let key =
      if n.explicitId.len > 0: n.explicitId
      else: n.scopeDerivedName
    if key.len == 0: continue
    result.persistedEntries[key] = n
    if n.scopeDerivedName.len > 0:
      result.persistedByScope[n.scopeDerivedName] = key
  result.state = ccsFinalized
