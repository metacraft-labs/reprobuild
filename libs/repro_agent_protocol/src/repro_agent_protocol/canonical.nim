## Canonical CBOR form of the protocol records, and their identities
## (spec §"Encoding and transport").
##
## Records are CBOR maps with text keys in RFC 8949 §4.2.1 core
## deterministic encoding. Identity-bearing records (intent, plan,
## approval, audit) accept no key outside their schema, so one set of bytes
## has one meaning and one identity.
##
## RFC 8949 §4.2.1: https://www.rfc-editor.org/rfc/rfc8949#section-4.2.1

import std/[algorithm, strutils, unicode]

import cbor
import repro_remix/identity as remixIdentity

import ./[types, capabilities]

const
  IntentContext* = "reproos.agent.intent.v1"
  PlanContext* = "reproos.agent.plan.v1"
  ApprovalContext* = "reproos.agent.approval.v1"
  AuditContext* = "reproos.agent.audit.v1"

proc id*(context: string; bytes: openArray[byte]): Digest32 =
  ## `id(context, bytes) = BLAKE3-256(u32le(len(context)) ‖ context ‖
  ## bytes)`: the construction the Remix protocol uses, shared so that the
  ## two families can never produce colliding identities.
  remixIdentity.domainDigest(context, @bytes)

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(ord(c))

proc toStr*(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

proc hex*(d: Digest32): string =
  for b in d:
    result.add toHex(b, 2).toLowerAscii

proc parseDigestHex*(s: string): Digest32 =
  if s.len != 64:
    refuse(arMalformed, "digest is not 64 hex digits")
  for i in 0 ..< 32:
    try:
      result[i] = byte(parseHexInt(s[2 * i .. 2 * i + 1]))
    except ValueError:
      refuse(arMalformed, "digest is not hex")

# ---------------------------------------------------------------------
# Reading helpers. Every one refuses with `malformed` instead of raising
# a field or conversion error, so a hostile peer always gets a protocol
# refusal.

proc field*(m: CborItem; key: string): CborItem =
  ## The value of text key `key`, or nil.
  if m.isNil or m.kind != ckMap:
    refuse(arMalformed, "expected a map")
  for p in m.entries:
    if p.key.kind == ckText and p.key.text == key:
      return p.val
  nil

proc requireOnlyKeys*(m: CborItem; allowed: openArray[string]) =
  if m.isNil or m.kind != ckMap:
    refuse(arMalformed, "expected a map")
  for p in m.entries:
    if p.key.kind != ckText:
      refuse(arMalformed, "map key is not text")
    if p.key.text notin allowed:
      refuse(arMalformed, "unknown key " & p.key.text.escape)

proc need(m: CborItem; key: string): CborItem =
  result = m.field(key)
  if result.isNil:
    refuse(arMalformed, "missing key " & key.escape)

proc asText*(v: CborItem; what: string): string =
  if v.isNil or v.kind != ckText:
    refuse(arMalformed, what & " is not text")
  if v.text.validateUtf8() != -1:
    refuse(arMalformed, what & " is not UTF-8")
  v.text

proc asBytes*(v: CborItem; what: string): string =
  if v.isNil or v.kind != ckBytes:
    refuse(arMalformed, what & " is not a byte string")
  v.bytes.toStr

proc asUInt*(v: CborItem; what: string): uint64 =
  if v.isNil or v.kind != ckUInt:
    refuse(arMalformed, what & " is not an unsigned integer")
  v.arg

proc asArray*(v: CborItem; what: string; maxLen: int): seq[CborItem] =
  if v.isNil or v.kind != ckArray:
    refuse(arMalformed, what & " is not an array")
  if v.elems.len > maxLen:
    refuse(arBoundsExceeded, what & " has more than " & $maxLen & " entries")
  v.elems

proc asDigest*(v: CborItem; what: string): Digest32 =
  let b = asBytes(v, what)
  if b.len != 32:
    refuse(arMalformed, what & " is not 32 bytes")
  for i in 0 ..< 32:
    result[i] = byte(ord(b[i]))

proc cDigest*(d: Digest32): CborItem = cBytes(d)

proc cmpDigest*(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  0
proc tp*(k: string; v: CborItem): CborPair = cPair(cText(k), v)

proc decodeRecord*(bytes: openArray[byte]): CborItem =
  ## One deterministic CBOR item; a non-deterministic or ill-formed
  ## encoding is `malformed`.
  if bytes.len > MaxFrameBytes:
    refuse(arBoundsExceeded, "record larger than a frame")
  try:
    decodeItem(bytes, DeterministicCborOptions)
  except CborError as e:
    refuse(arMalformed, "CBOR: " & e.msg)

# ---------------------------------------------------------------------
# Grants, operations, intents and plans.

proc encodeGrant*(g: Grant): CborItem = cText($g)

proc decodeGrant*(v: CborItem): Grant =
  parseGrant(asText(v, "grant"))

proc encodeGrants*(gs: seq[Grant]): CborItem =
  var items: seq[CborItem]
  for g in sortedUnique(gs):
    items.add encodeGrant(g)
  cArray(items)

proc decodeGrants*(v: CborItem; what: string; maxLen: int): seq[Grant] =
  for e in asArray(v, what, maxLen):
    result.add decodeGrant(e)
  if result != sortedUnique(result):
    refuse(arMalformed, what & " is not sorted and unique")

proc encodeOperation*(op: Operation): CborItem =
  var args: seq[CborPair]
  for a in op.args:
    args.add tp(a.name, cBytes(a.value.toBytes))
  cMap([tp("kind", cText($op.kind)), tp("target", cText(op.target)),
        tp("args", cMap(args))])

proc decodeOperation*(v: CborItem): Operation =
  v.requireOnlyKeys(["kind", "target", "args"])
  result.kind = parseEnumStrict[OperationKind](
    asText(v.need("kind"), "operation kind"), arUnsupportedFamily)
  result.target = asText(v.need("target"), "operation target")
  let args = v.need("args")
  if args.kind != ckMap:
    refuse(arMalformed, "args is not a map")
  for p in args.entries:
    result.args.add OpArg(name: asText(p.key, "argument name"),
                          value: asBytes(p.val, "argument value"))
  # Deterministic decoding already rejected unsorted or duplicate keys;
  # keep the in-memory order equal to the canonical one.
  result.args.sort(proc (a, b: OpArg): int = cmp(a.name, b.name))

proc encodeIntent*(i: Intent): seq[byte] =
  encodeDeterministic(cMap([
    tp("session", cText(i.sessionId)),
    tp("text", cText(i.text)),
    tp("context", encodeGrants(i.contextItems)),
    tp("capturedAt", cUInt(uint64(max(i.capturedAt, 0))))]))

proc intentId*(i: Intent): Digest32 = id(IntentContext, encodeIntent(i))

proc decodeIntent*(bytes: openArray[byte]): Intent =
  let v = decodeRecord(bytes)
  v.requireOnlyKeys(["session", "text", "context", "capturedAt"])
  result.sessionId = asText(v.need("session"), "intent session")
  result.text = asText(v.need("text"), "intent text")
  if result.text.len > MaxIntentTextBytes:
    refuse(arBoundsExceeded, "intent text")
  result.contextItems = decodeGrants(v.need("context"), "context",
                                     MaxGrantsPerSession)
  result.capturedAt = int64(asUInt(v.need("capturedAt"), "capturedAt"))

proc encodePlanItem*(p: Plan): CborItem =
  var ops: seq[CborItem]
  for op in p.operations:
    ops.add encodeOperation(op)
  var ev = p.evidence
  ev.sort(cmpDigest)
  var evItems: seq[CborItem]
  for i, d in ev:
    if i == 0 or d != ev[i - 1]:
      evItems.add cDigest(d)
  cMap([
    tp("session", cText(p.sessionId)),
    tp("intent", cDigest(p.intentId)),
    tp("base", cText(p.baseGeneration)),
    tp("operations", cArray(ops)),
    tp("capabilities", encodeGrants(p.declaredCapabilities)),
    tp("evidence", cArray(evItems))])

proc encodePlan*(p: Plan): seq[byte] = encodeDeterministic(encodePlanItem(p))

proc planId*(p: Plan): Digest32 =
  ## `PlanId`: the identity of the canonical plan bytes. Grants and
  ## evidence are sets, so their order does not change the identity;
  ## operation order is meaningful and does.
  id(PlanContext, encodePlan(p))

proc decodePlanItem*(v: CborItem): Plan =
  v.requireOnlyKeys(["session", "intent", "base", "operations",
                     "capabilities", "evidence"])
  result.sessionId = asText(v.need("session"), "plan session")
  result.intentId = asDigest(v.need("intent"), "plan intent")
  result.baseGeneration = asText(v.need("base"), "plan base generation")
  for o in asArray(v.need("operations"), "operations", MaxOperationsPerPlan):
    result.operations.add decodeOperation(o)
  result.declaredCapabilities = decodeGrants(v.need("capabilities"),
                                             "capabilities",
                                             MaxGrantsPerSession)
  for e in asArray(v.need("evidence"), "evidence", 256):
    result.evidence.add asDigest(e, "evidence digest")

proc decodePlan*(bytes: openArray[byte]): Plan =
  decodePlanItem(decodeRecord(bytes))

# ---------------------------------------------------------------------
# Approval MAC input.

proc approvalBody*(approvalId: string; sessionId: string; intent: Digest32;
                   plan: Digest32; operations: seq[int]; epoch: uint64;
                   issuedAt, expiresAt: int64): seq[byte] =
  ## The canonical bytes an approval's MAC covers, through
  ## `id(ApprovalContext, …)`.
  var opItems: seq[CborItem]
  for i in operations:
    opItems.add cUInt(uint64(i))
  encodeDeterministic(cMap([
    tp("approval", cText(approvalId)),
    tp("session", cText(sessionId)),
    tp("intent", cDigest(intent)),
    tp("plan", cDigest(plan)),
    tp("operations", cArray(opItems)),
    tp("epoch", cUInt(epoch)),
    tp("issuedAt", cUInt(uint64(max(issuedAt, 0)))),
    tp("expiresAt", cUInt(uint64(max(expiresAt, 0))))]))
