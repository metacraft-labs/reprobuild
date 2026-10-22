## Signed statements (spec §"Statements", §"Transparency log", §"Quorum").
##
## Every non-author fact about a release, key or log is a statement:
## reviews, vouches, verdicts, revocations, publication, build evidence and
## log checkpoints. This module encodes them canonically, checks quorum for
## policy statements, and turns two conflicting checkpoints into
## self-verifying equivocation evidence.
##
## Who may sign which kind is decided by roles in principals' key logs
## (`keylog.nim`); this module only checks the cryptography and the quorum
## counts it is given.

import ssz_serialization

import ./types
import ./wire
import ./identity
import ./verify
import ./translog

const
  MaxScopeItems* = 256
  MaxEvidence* = 64

type
  StatementKind* = enum
    ## §"Statements"; closed v1 vocabulary.
    skPublication = 1
    skBuildEvidence = 2
    skTestEvidence = 3
    skReview = 4
    skVouch = 5
    skVulnerabilityClaim = 6
    skVerdict = 7
    skRevocation = 8
    skYank = 9
    skModeration = 10
    skKeyRotation = 11
    skKeyRevocation = 12
    skAttestedInference = 13
    skLogCheckpoint = 14

  SubjectKind* = enum
    sbRelease = 1
    sbComposition = 2
    sbOriginal = 3
    sbKey = 4
    sbLog = 5

  Statement* = object
    kind*: StatementKind
    subjectKind*: SubjectKind
    subject*: Digest32
    issuer*: Digest32
      ## `KeyId` of the single key that issues a personal statement (review,
      ## vouch, yank, claim, evidence). Part of the identity, so two people's
      ## identical judgements are two statements. Zero for statements a set
      ## of keys co-signs (policy under quorum, log checkpoints).
    scope*: seq[string]
      ## Kind-specific scope items (reviewed surfaces, platform, lock id),
      ## identifiers, ascending, unique.
    policy*: Digest32
    supersedes*: Digest32
      ## Zero when the statement corrects nothing.
    issuedAt*: uint64
      ## Advisory; ordering comes from the log.
    evidence*: seq[BlobRef]
    treeSize*: uint64
    rootHash*: Digest32
      ## Checkpoint fields; zero for every other kind.
    extensions*: seq[Extension]

  StatementW = object
    kind: uint8
    subjectKind: uint8
    subject: Digest32
    issuer: Digest32
    scope: List[SszName, MaxScopeItems]
    policy: Digest32
    supersedes: Digest32
    issuedAt: uint64
    evidence: List[BlobRefW, MaxEvidence]
    treeSize: uint64
    rootHash: Digest32
    extensions: List[ExtensionW, MaxExtensions]

  Checkpoint* = object
    ## A verified `log-checkpoint`: who signed it and what it commits to.
    logKey*: Digest32
    treeSize*: uint64
    rootHash*: Digest32
    envelope*: Envelope

  EquivocationEvidence* = object
    ## Two checkpoints from one log key that cannot both be honest. Anyone
    ## can re-verify it from the two signed envelopes alone.
    a*, b*: Checkpoint

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc isZero(d: Digest32): bool =
  for b in d:
    if b != 0: return false
  true

proc validateStatement*(st: Statement) =
  for item in st.scope:
    if item.len == 0 or item.len > MaxNameBytes:
      refuse(rrInvalidText, "scope item is empty or too long")
    for c in item:
      if ord(c) < 0x21 or ord(c) > 0x7e:
        refuse(rrInvalidText, "scope item is not printable ASCII")
  for i in 1 ..< st.scope.len:
    if st.scope[i - 1] >= st.scope[i]:
      refuse(rrUnsorted, "scope items are not strictly ascending")
  let isCheckpoint = st.kind == skLogCheckpoint
  if isCheckpoint and st.subjectKind != sbLog:
    refuse(rrForbiddenContent, "a checkpoint's subject must be a log key")
  if not isCheckpoint and (st.treeSize != 0 or not isZero(st.rootHash)):
    refuse(rrNonCanonical, "checkpoint fields on a non-checkpoint statement")
  for e in st.extensions:
    if e.critical:
      refuse(rrUnknownCriticalExtension, "critical extension " & e.id)

proc encodeStatement*(st: Statement): seq[byte] =
  validateStatement(st)
  var scope: seq[SszName]
  for s in st.scope: scope.add SszName.init(bytesOf(s))
  var ev: seq[BlobRefW]
  for b in st.evidence:
    ev.add BlobRefW(id: b.id, mediaType: SszName.init(bytesOf(b.mediaType)), size: b.size)
  var ex: seq[ExtensionW]
  for e in st.extensions:
    ex.add ExtensionW(id: SszName.init(bytesOf(e.id)), critical: e.critical,
                      payload: List[byte, MaxExtensionBytes].init(e.payload))
  if scope.len > MaxScopeItems or ev.len > MaxEvidence or ex.len > MaxExtensions:
    refuse(rrBound, "statement list exceeds its bound")
  SSZ.encode(StatementW(kind: uint8(ord(st.kind)),
    subjectKind: uint8(ord(st.subjectKind)), subject: st.subject,
    issuer: st.issuer, scope: List[SszName, MaxScopeItems].init(scope), policy: st.policy,
    supersedes: st.supersedes, issuedAt: st.issuedAt,
    evidence: List[BlobRefW, MaxEvidence].init(ev), treeSize: st.treeSize,
    rootHash: st.rootHash, extensions: List[ExtensionW, MaxExtensions].init(ex)))

proc decodeStatement*(body: openArray[byte]): Statement =
  var w: StatementW
  try:
    w = SSZ.decode(body, StatementW)
  except SerializationError as e:
    refuse(rrMalformed, "statement: " & e.msg)
  if w.kind < 1 or w.kind > uint8(ord(StatementKind.high)):
    refuse(rrUnknownVocabulary, "statement kind " & $w.kind)
  if w.subjectKind < 1 or w.subjectKind > uint8(ord(SubjectKind.high)):
    refuse(rrUnknownVocabulary, "subject kind " & $w.subjectKind)
  result = Statement(kind: StatementKind(w.kind),
    subjectKind: SubjectKind(w.subjectKind), subject: w.subject,
    issuer: w.issuer, policy: w.policy, supersedes: w.supersedes, issuedAt: w.issuedAt,
    treeSize: w.treeSize, rootHash: w.rootHash)
  for s in asSeq(w.scope): result.scope.add strOf(asSeq(s))
  for b in asSeq(w.evidence):
    result.evidence.add BlobRef(id: b.id, mediaType: strOf(asSeq(b.mediaType)), size: b.size)
  for e in asSeq(w.extensions):
    result.extensions.add Extension(id: strOf(asSeq(e.id)), critical: e.critical,
                                    payload: asSeq(e.payload))
  validateStatement(result)
  if encodeStatement(result) != @body:
    refuse(rrNonCanonical, "statement does not re-encode to the same bytes")

proc newStatementEnvelope*(st: Statement): Envelope =
  Envelope(schemaVersion: RemixSchemaVersion, requiredFeatures: 0,
           recordKind: rkStatement, body: encodeStatement(st))

proc statementId*(env: Envelope): Digest32 =
  if env.recordKind != rkStatement:
    refuse(rrUnknownRecordKind, "not a statement envelope")
  envelopeIdentity(env)

# ---------------------------------------------------------------------------
# Quorum (§"Quorum").
# ---------------------------------------------------------------------------

proc verifyQuorum*(env: Envelope; policyKeys: openArray[Digest32];
                   threshold: int): Statement =
  ## A verdict, revocation or moderation statement takes effect only when at
  ## least `threshold` distinct policy keys signed it. Signatures by other
  ## keys are refused rather than ignored, so the evidence is unambiguous.
  if threshold < 1:
    refuse(rrForbiddenContent, "a quorum threshold must be at least one")
  result = decodeStatement(env.body)
  if result.kind notin {skVerdict, skRevocation, skModeration}:
    refuse(rrForbiddenContent, "quorum applies to policy statements only")
  var count = 0
  for s in verifiedSigners(env):
    if s notin policyKeys:
      refuse(rrForbiddenContent, "a policy statement is signed by a non-policy key")
    inc count
  if count < threshold:
    refuse(rrMissingAuthorSignature, "policy quorum not met: " & $count & " of " & $threshold)

# ---------------------------------------------------------------------------
# Checkpoints and equivocation (§"Transparency log").
# ---------------------------------------------------------------------------

proc verifyCheckpoint*(env: Envelope; trustedLogKeys: openArray[Digest32]): Checkpoint =
  ## A checkpoint is valid when it is a canonical `log-checkpoint` statement
  ## about a trusted log key and signed by exactly that key.
  let st = decodeStatement(env.body)
  if st.kind != skLogCheckpoint:
    refuse(rrForbiddenContent, "not a log checkpoint")
  if st.subject notin trustedLogKeys:
    refuse(rrForbiddenContent, "checkpoint from an untrusted log")
  verifySignatures(env, @[st.subject])
  Checkpoint(logKey: st.subject, treeSize: st.treeSize, rootHash: st.rootHash,
             envelope: env)

proc checkConsistency*(a, b: Checkpoint; proof: openArray[Digest32]):
    (bool, EquivocationEvidence) =
  ## True when `a` and `b` (same log, any order) are consistent under
  ## `proof`. Otherwise returns the pair as equivocation evidence. Callers
  ## must pass two checkpoints that each verified with `verifyCheckpoint`.
  if a.logKey != b.logKey:
    refuse(rrForbiddenContent, "checkpoints from different logs")
  var (lo, hi) = (a, b)
  if lo.treeSize > hi.treeSize: swap(lo, hi)
  let ok = verifyConsistency(lo.treeSize, hi.treeSize, lo.rootHash, hi.rootHash, proof)
  (ok, EquivocationEvidence(a: lo, b: hi))

proc verifyEquivocationEvidence*(ev: EquivocationEvidence;
                                 trustedLogKeys: openArray[Digest32]): bool =
  ## Third-party check of evidence: both checkpoints are genuinely signed by
  ## the same log, and they commit to the same size with different roots.
  ## (Different sizes need a failed consistency proof, which is not
  ## self-contained evidence; a log that refuses a proof is refused.)
  let a = verifyCheckpoint(ev.a.envelope, trustedLogKeys)
  let b = verifyCheckpoint(ev.b.envelope, trustedLogKeys)
  a.logKey == b.logKey and a.treeSize == b.treeSize and a.rootHash != b.rootHash
