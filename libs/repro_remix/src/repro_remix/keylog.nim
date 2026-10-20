## Principal key logs (spec §"Key logs", §"Roles").
##
## A principal's keys are a hash chain of signed `rkKeyLogEntry` records.
## `replayKeyLog` checks the chain and produces, for every key the
## principal ever held, the transparency-log positions where it became
## active, stopped being active, and — if revoked — from which position its
## signatures are void. `keyActiveAt` is the question acceptance asks.
##
## Positions come from the transparency log: each entry is replayed with
## the log index at which it was included, and the replay refuses entries
## whose positions go backwards. Rotation (`add-key` then `remove-key`)
## never rewrites history: a key's past signatures are judged at the
## position they were logged.

import std/[algorithm, tables]

import ssz_serialization

import ./types
import ./identity
import ./verify
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  MaxRecoveryKeys* = 16

type
  Role* = enum
    ## §"Roles"; closed v1 vocabulary. Bit `ord(role)` in the role mask.
    roleAuthor = 0
    roleMaintainer = 1
    roleRegistry = 2
    roleBuilder = 3
    roleReviewer = 4
    roleVulnerabilityVerifier = 5
    roleAttestedInference = 6
    rolePolicy = 7

  KeyLogOp* = enum
    klGenesis = 1
    klAddKey = 2
    klRemoveKey = 3
    klRevokeKey = 4
    klSetRecovery = 5

  KeyLogEntry* = object
    principal*: Digest32
      ## Zero in the genesis entry; the genesis `KeyId` afterwards.
    sequence*: uint64
    previous*: Digest32
      ## Identity of the previous entry; zero for genesis.
    operation*: KeyLogOp
    algorithm*: SignatureAlgorithm
    publicKey*: seq[byte]
    roles*: set[Role]
    target*: Digest32
    compromisedFrom*: uint64
    recoveryKeys*: seq[Digest32]
    recoveryThreshold*: uint8

  KeyLogEntryW = object
    principal: Digest32
    sequence: uint64
    previous: Digest32
    operation: uint8
    algorithm: uint8
    publicKey: List[byte, MaxPublicKeyBytes]
    roles: uint16
    target: Digest32
    compromisedFrom: uint64
    recoveryKeys: List[Digest32, MaxRecoveryKeys]
    recoveryThreshold: uint8

  KeyHistory* = object
    keyId*: Digest32
    publicKey*: seq[byte]
    roles*: set[Role]
    addedAt*: uint64
    removedAt*: uint64
      ## `high(uint64)` while still active.
    revoked*: bool
    compromisedFrom*: uint64

  Principal* = object
    id*: Digest32
    keys*: Table[Digest32, KeyHistory]
    recoveryKeys*: seq[Digest32]
    recoveryThreshold*: int
    head*: Digest32
      ## Identity of the last replayed entry.
    sequence*: uint64

const NotRemoved = high(uint64)

proc rolesToMask(r: set[Role]): uint16 =
  for x in r: result = result or (1'u16 shl ord(x))

proc maskToRoles(m: uint16): set[Role] =
  for x in Role:
    if (m and (1'u16 shl ord(x))) != 0: result.incl x
  if (m and not rolesToMask(result)) != 0:
    refuse(rrUnknownVocabulary, "unknown role bits " & $m)

proc isZero(d: Digest32): bool =
  for b in d:
    if b != 0: return false
  true

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]: return cmp(a[i], b[i])
  0

proc encodeKeyLogEntry*(e: KeyLogEntry): seq[byte] =
  for i in 1 ..< e.recoveryKeys.len:
    if cmpD(e.recoveryKeys[i - 1], e.recoveryKeys[i]) >= 0:
      refuse(rrUnsorted, "recovery keys are not strictly ascending")
  if int(e.recoveryThreshold) > e.recoveryKeys.len:
    refuse(rrForbiddenContent, "recovery threshold exceeds the recovery keys")
  if e.recoveryKeys.len > MaxRecoveryKeys:
    refuse(rrBound, "too many recovery keys")
  if e.publicKey.len > MaxPublicKeyBytes:
    refuse(rrBound, "public key too long")
  # Key fields exist only on operations that introduce a key; elsewhere they
  # are written as zero/empty so each entry has exactly one encoding.
  let introducesKey = e.operation in {klGenesis, klAddKey}
  if not introducesKey and (e.publicKey.len != 0 or e.roles != {}):
    refuse(rrNonCanonical, "key fields on an operation that introduces no key")
  if introducesKey and e.publicKey.len != 65:
    refuse(rrMalformed, "an ECDSA-P256 key must be 65 bytes")
  SSZ.encode(KeyLogEntryW(principal: e.principal, sequence: e.sequence,
    previous: e.previous, operation: uint8(ord(e.operation)),
    algorithm: (if introducesKey: uint8(ord(e.algorithm)) else: 0'u8),
    publicKey: List[byte, MaxPublicKeyBytes].init(e.publicKey),
    roles: rolesToMask(e.roles), target: e.target,
    compromisedFrom: e.compromisedFrom,
    recoveryKeys: List[Digest32, MaxRecoveryKeys].init(e.recoveryKeys),
    recoveryThreshold: e.recoveryThreshold))

proc decodeKeyLogEntry*(body: openArray[byte]): KeyLogEntry =
  var w: KeyLogEntryW
  try:
    w = SSZ.decode(body, KeyLogEntryW)
  except SerializationError as e:
    refuse(rrMalformed, "key-log entry: " & e.msg)
  if w.operation < 1 or w.operation > uint8(ord(KeyLogOp.high)):
    refuse(rrUnknownVocabulary, "key-log operation " & $w.operation)
  let introducesKey = KeyLogOp(w.operation) in {klGenesis, klAddKey}
  if introducesKey and w.algorithm != uint8(ord(saEcdsaP256)):
    refuse(rrUnknownAlgorithm, "key algorithm " & $w.algorithm)
  if not introducesKey and w.algorithm != 0:
    refuse(rrNonCanonical, "an algorithm on an operation that introduces no key")
  result = KeyLogEntry(principal: w.principal, sequence: w.sequence,
    previous: w.previous, operation: KeyLogOp(w.operation),
    algorithm: saEcdsaP256, publicKey: asSeq(w.publicKey),
    roles: maskToRoles(w.roles), target: w.target,
    compromisedFrom: w.compromisedFrom, recoveryKeys: asSeq(w.recoveryKeys),
    recoveryThreshold: w.recoveryThreshold)
  if encodeKeyLogEntry(result) != @body:
    refuse(rrNonCanonical, "key-log entry does not re-encode to the same bytes")

proc newKeyLogEnvelope*(e: KeyLogEntry): Envelope =
  Envelope(schemaVersion: RemixSchemaVersion, requiredFeatures: 0,
           recordKind: rkKeyLogEntry, body: encodeKeyLogEntry(e))

proc activeAt(h: KeyHistory; pos: uint64): bool =
  pos >= h.addedAt and pos < h.removedAt and (not h.revoked or pos < h.compromisedFrom)

proc keyActiveAt*(p: Principal; key: Digest32; pos: uint64; anyOf: set[Role]): bool =
  ## Whether `key` could sign, in one of `anyOf` roles, a record logged at
  ## transparency-log position `pos`.
  if key notin p.keys: return false
  let h = p.keys[key]
  h.activeAt(pos) and (h.roles * anyOf) != {}

proc replayKeyLog*(entries: openArray[(Envelope, uint64)]): Principal =
  ## Replay `(entry envelope, log position)` pairs in sequence order.
  ## Refuses a broken chain, a position that goes backwards, an entry not
  ## signed by an active key or a recovery quorum, or an operation that
  ## names a key the principal does not hold.
  if entries.len == 0:
    refuse(rrMalformed, "an empty key log")
  var lastPos = 0'u64
  for i, (env, pos) in entries:
    if env.recordKind != rkKeyLogEntry:
      refuse(rrUnknownRecordKind, "not a key-log entry")
    let e = decodeKeyLogEntry(env.body)
    let signers = verifiedSigners(env)
    if i > 0 and pos < lastPos:
      refuse(rrNonCanonical, "key-log positions go backwards")
    lastPos = pos
    if e.sequence != uint64(i):
      refuse(rrNonCanonical, "key-log sequence " & $e.sequence & " at entry " & $i)
    let id = envelopeIdentity(env)
    if i == 0:
      if e.operation != klGenesis or not isZero(e.principal) or not isZero(e.previous):
        refuse(rrMalformed, "the first key-log entry must be a genesis entry")
      let kid = Digest32(keyId(e.algorithm, e.publicKey))
      if signers != @[kid]:
        refuse(rrMissingAuthorSignature, "genesis must be signed by its own key, alone")
      result.id = kid
      result.keys[kid] = KeyHistory(keyId: kid, publicKey: e.publicKey,
        roles: e.roles, addedAt: pos, removedAt: NotRemoved)
      result.recoveryKeys = e.recoveryKeys
      result.recoveryThreshold = int(e.recoveryThreshold)
    else:
      if e.principal != result.id or e.previous != result.head:
        refuse(rrNonCanonical, "key-log entry does not extend this principal's chain")
      # Authorised by an active key, or by a recovery quorum.
      var active, recovery = 0
      for s in signers:
        if result.keys.hasKey(s) and result.keys[s].activeAt(pos):
          inc active
        elif s in result.recoveryKeys:
          inc recovery
        else:
          refuse(rrForbiddenContent, "key-log entry signed by a key the principal does not control")
      if active == 0 and (result.recoveryThreshold == 0 or recovery < result.recoveryThreshold):
        refuse(rrMissingAuthorSignature, "key-log entry lacks an active key or recovery quorum")
      case e.operation
      of klGenesis:
        refuse(rrMalformed, "a second genesis entry")
      of klAddKey:
        let kid = Digest32(keyId(e.algorithm, e.publicKey))
        if result.keys.hasKey(kid):
          refuse(rrDuplicate, "key added twice")
        result.keys[kid] = KeyHistory(keyId: kid, publicKey: e.publicKey,
          roles: e.roles, addedAt: pos, removedAt: NotRemoved)
      of klRemoveKey, klRevokeKey:
        if not result.keys.hasKey(e.target) or result.keys[e.target].removedAt != NotRemoved:
          refuse(rrDanglingReference, "removing a key that is not active")
        result.keys[e.target].removedAt = pos
        if e.operation == klRevokeKey:
          result.keys[e.target].revoked = true
          result.keys[e.target].compromisedFrom = e.compromisedFrom
      of klSetRecovery:
        result.recoveryKeys = e.recoveryKeys
        result.recoveryThreshold = int(e.recoveryThreshold)
    result.head = id
    result.sequence = e.sequence

proc entrySigned*(e: KeyLogEntry; signers: openArray[PeerKeypair]): Envelope =
  ## Convenience for tools and tests: build and sign an entry.
  result = newKeyLogEnvelope(e)
  for k in signers:
    result.signEnvelope(k)

proc activeKeys*(p: Principal; pos: uint64): seq[Digest32] =
  for k, h in p.keys:
    if h.activeAt(pos): result.add k
  result.sort(cmpD)
