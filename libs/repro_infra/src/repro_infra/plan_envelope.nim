## The `RBIP` ("Reprobuild Infra Plan") binary envelope (M69 —
## System-Profile-And-Infra-Apply.md "repro infra plan").
##
## Modelled on the M62 `RBPT` pointer envelope and the M81 `RBEB`
## framing: a 4-byte ASCII magic, a u16 LE schema version, a u32 LE
## body length, the body, and a trailing 32-byte BLAKE3-256 checksum
## over magic+version+bodyLen+body.
##
## A plan is serialized to `<system-state-dir>/plans/<plan-id>.rbip`
## so `repro infra apply` can refer to it by id and detect staleness.
##
## On-disk shape (little-endian throughout):
##
##   offset 0   : magic            4 bytes ASCII "RBIP"
##   offset 4   : schemaVersion    u16 LE
##   offset 6   : bodyLength       u32 LE
##   offset 10  : body             bodyLength bytes
##   trailing   : checksum         32 bytes BLAKE3-256
##
## Body field order (audited, NO extras):
##
##   1. planId                       length-prefixed UTF-8
##   2. createdTimestamp             i64 LE (unix epoch seconds)
##   3. hostIdentity                 length-prefixed UTF-8
##   4. profileDigestHex             length-prefixed UTF-8 (BLAKE3 hex)
##   5. operationCount               u32 LE
##   6. operations[]                 operationCount records, each:
##        a. address                 length-prefixed UTF-8
##        b. kindTag                  length-prefixed UTF-8
##        c. privileged               u8 bool
##        d. action                   length-prefixed UTF-8
##        e. baselineDigestHex        length-prefixed UTF-8
##        f. desiredDigestHex         length-prefixed UTF-8
##        g. summary                  length-prefixed UTF-8
##
## The writer / reader are STRICT — extra body bytes, a bad checksum,
## or an unsupported schema version all fail closed via `EPlanCorrupt`.

import std/[os]

import blake3
import repro_core

import ./errors

const
  PlanMagic* = "RBIP"
  PlanSchemaVersion*: uint16 = 1
  PlanHeaderSize = 4 + 2 + 4
  PlanTrailerSize = 32

type
  PlannedOperationRecord* = object
    ## One operation in a serialized plan.
    address*: string
    kindTag*: string
    privileged*: bool
    action*: string                  ## "create" | "update" | "no-op" | ...
    baselineDigestHex*: string        ## digest the plan observed
    desiredDigestHex*: string
    summary*: string                  ## human line for plan output

  PlanEnvelope* = object
    ## In-memory view of an `RBIP` plan.
    schemaVersion*: uint16
    planId*: string
    createdTimestamp*: int64
    hostIdentity*: string
    profileDigestHex*: string
    operations*: seq[PlannedOperationRecord]

# ---------------------------------------------------------------------------
# Plan-id derivation.
# ---------------------------------------------------------------------------

proc toHexNibblePair(b: byte): string =
  const hex = "0123456789abcdef"
  result = newString(2)
  result[0] = hex[int(b shr 4)]
  result[1] = hex[int(b and 0x0f)]

proc computePlanId*(profileDigestHex, hostIdentity: string;
                    createdTimestamp: int64): string =
  ## Deterministic 32-hex-char plan id derived from the profile
  ## digest, the host, and the creation time. Two plans of the same
  ## profile on the same host at the same second collide — acceptable;
  ## the timestamp has 1-second resolution and the apply re-checks
  ## staleness against live observations anyway.
  var buf: seq[byte]
  buf.writeString("reprobuild.infra.plan.id.v1")
  buf.writeString(profileDigestHex)
  buf.writeString(hostIdentity)
  buf.writeU64Le(uint64(createdTimestamp))
  let d = blake3.digest(buf)
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHexNibblePair(d[i]))

# ---------------------------------------------------------------------------
# Encoding.
# ---------------------------------------------------------------------------

proc encodeBody(env: PlanEnvelope): seq[byte] =
  result.writeString(env.planId)
  result.writeU64Le(uint64(env.createdTimestamp))
  result.writeString(env.hostIdentity)
  result.writeString(env.profileDigestHex)
  result.writeU32Le(uint32(env.operations.len))
  for op in env.operations:
    result.writeString(op.address)
    result.writeString(op.kindTag)
    result.add(if op.privileged: 1'u8 else: 0'u8)
    result.writeString(op.action)
    result.writeString(op.baselineDigestHex)
    result.writeString(op.desiredDigestHex)
    result.writeString(op.summary)

proc encodePlan*(env: PlanEnvelope): seq[byte] =
  ## Serialize a plan to RBIP bytes. Deterministic for a fixed input.
  let body = encodeBody(env)
  result = newSeqOfCap[byte](PlanHeaderSize + body.len + PlanTrailerSize)
  for ch in PlanMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(PlanSchemaVersion)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

# ---------------------------------------------------------------------------
# Decoding.
# ---------------------------------------------------------------------------

proc decodePlanBytes*(bytes: openArray[byte];
                      filePath = "<memory>"): PlanEnvelope =
  ## Strict reader: validates magic / version / body-length bounds
  ## and the trailing BLAKE3 checksum BEFORE returning any field.
  if bytes.len < PlanHeaderSize + PlanTrailerSize:
    raisePlanCorrupt("envelope",
      filePath & ": file is too short to be an RBIP plan")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(PlanMagic[i])):
      raisePlanCorrupt("magic", filePath & ": expected '" & PlanMagic & "'")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != PlanSchemaVersion:
    raisePlanCorrupt("schemaVersion",
      filePath & ": unsupported RBIP schema version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + PlanTrailerSize != bytes.len:
    raisePlanCorrupt("bodyLength",
      filePath & ": declared body length " & $bodyLen &
      " disagrees with file size " & $bytes.len)
  let bodyEnd = pos + bodyLen
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raisePlanCorrupt("trailingChecksum",
        filePath & ": BLAKE3-256 trailing checksum mismatch")
  result.schemaVersion = version
  result.planId = readString(bytes, pos)
  result.createdTimestamp = int64(readU64Le(bytes, pos))
  result.hostIdentity = readString(bytes, pos)
  result.profileDigestHex = readString(bytes, pos)
  let opCount = int(readU32Le(bytes, pos))
  if opCount < 0 or pos + opCount > bytes.len:
    raisePlanCorrupt("operationCount",
      filePath & ": implausible operation count " & $opCount)
  for _ in 0 ..< opCount:
    var rec: PlannedOperationRecord
    rec.address = readString(bytes, pos)
    rec.kindTag = readString(bytes, pos)
    if pos >= bytes.len:
      raisePlanCorrupt("operations", filePath & ": truncated operation record")
    rec.privileged = bytes[pos] != 0
    inc pos
    rec.action = readString(bytes, pos)
    rec.baselineDigestHex = readString(bytes, pos)
    rec.desiredDigestHex = readString(bytes, pos)
    rec.summary = readString(bytes, pos)
    result.operations.add(rec)
  if pos != bodyEnd:
    raisePlanCorrupt("body",
      filePath & ": trailing " & $(bodyEnd - pos) &
      " bytes after the audited field set (extras are forbidden)")

# ---------------------------------------------------------------------------
# File I/O.
# ---------------------------------------------------------------------------

proc writePlanFile*(planFilePath: string; env: PlanEnvelope) =
  ## Atomically write the plan via the standard tmp-then-rename.
  let bytes = encodePlan(env)
  let parent = parentDir(planFilePath)
  if parent.len > 0:
    createDir(parent)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let tmp = planFilePath & ".tmp"
  writeFile(tmp, s)
  if fileExists(planFilePath):
    removeFile(planFilePath)
  moveFile(tmp, planFilePath)

proc readPlanFile*(planFilePath: string): PlanEnvelope =
  if not fileExists(planFilePath):
    raisePlanCorrupt("file", planFilePath & ": no such plan file")
  let raw = readFile(planFilePath)
  var bytes = newSeq[byte](raw.len)
  for i, ch in raw:
    bytes[i] = byte(ord(ch))
  decodePlanBytes(bytes, planFilePath)

# ---------------------------------------------------------------------------
# Plan-summary helpers.
# ---------------------------------------------------------------------------

proc privilegedOperations*(env: PlanEnvelope): seq[PlannedOperationRecord] =
  for op in env.operations:
    if op.privileged:
      result.add(op)

proc effectiveOperations*(env: PlanEnvelope): seq[PlannedOperationRecord] =
  ## Operations that would actually mutate the world (not a no-op).
  for op in env.operations:
    if op.action != "no-op":
      result.add(op)
