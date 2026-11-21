## Policy commitments, freshness and proof records
## (`Remix-Registry.md` §"Policy commitments and freshness").
##
## A checkpoint commits to the digest of every policy statement logged up
## to its tree size, as the scope item `policy:<hex>`, and its signed
## `issuedAt` says when the log was current. A client's policy snapshot is
## valid only when the policy list it was handed matches that commitment
## and the checkpoint is fresh, so a source that withholds a revocation is
## caught either as stale or as inconsistent.

import std/[algorithm, strutils]

import ssz_serialization

import ./types
import ./identity
import ./codec
import ./verify
import ./statements
import ./keylog
import ./acceptance
import ./install

const
  PolicySetContext* = "reproos.remix.policy-set.v1"
  PolicyScopePrefix* = "policy:"

type
  ProofRecord* = object
    ## An inclusion proof for one logged record, carried in offline
    ## bundles as entry kind 5.
    recordKind*: RecordKind
    identity*: Digest32
    leafIndex*: uint64
    treeSize*: uint64
    path*: seq[Digest32]

  ProofRecordW = object
    recordKind: uint8
    identity: Digest32
    leafIndex: uint64
    treeSize: uint64
    path: List[Digest32, 64]

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]: return cmp(a[i], b[i])
  0

proc policyCommitment*(statementIds: seq[Digest32]): Digest32 =
  ## Digest of the ascending, de-duplicated policy statement identities.
  var ids = statementIds
  ids.sort(cmpD)
  var flat: seq[byte]
  var prev: Digest32
  for i, d in ids:
    if i > 0 and d == prev: continue
    flat.add d
    prev = d
  domainDigest(PolicySetContext, flat)

proc policyScope*(statementIds: seq[Digest32]): string =
  PolicyScopePrefix & toHex(policyCommitment(statementIds))

proc committedPolicy*(cp: Statement): (bool, string) =
  for s in cp.scope:
    if s.startsWith(PolicyScopePrefix):
      return (true, s[PolicyScopePrefix.len .. ^1])
  (false, "")

proc buildPolicySnapshot*(checkpoint: Envelope; policyStatements: seq[Envelope];
                          principals: seq[Principal]; trust: TrustConfig;
                          now, maxAgeSeconds: int64;
                          allowStaleOffline = false): PolicySnapshot =
  ## Verify a checkpoint, its freshness, and that `policyStatements` is
  ## exactly the set it commits to; each statement must meet quorum.
  let cp = verifyCheckpoint(checkpoint, trust.logKeys)
  let st = decodeStatement(checkpoint.body)
  let (has, committed) = committedPolicy(st)
  if not has:
    refuse(rrForbiddenContent, "checkpoint carries no policy commitment")
  var ids: seq[Digest32]
  for env in policyStatements:
    discard verifyQuorum(env, trust.policyKeys, trust.policyThreshold)
    ids.add statementId(env)
  if toHex(policyCommitment(ids)) != committed:
    refuse(rrDigestMismatch, "policy list does not match the checkpoint's commitment")
  discard cp
  PolicySnapshot(trust: trust, checkpoint: checkpoint,
    policyStatements: policyStatements, principals: principals,
    issuedAt: int64(st.issuedAt), maxAgeSeconds: maxAgeSeconds,
    allowStaleOffline: allowStaleOffline)

proc missingPolicy*(mirror, upstream: seq[Envelope]): seq[Digest32] =
  ## Upstream policy statements the mirror does not carry: each one is
  ## missing-revocation evidence against the mirror.
  var have: seq[Digest32]
  for e in mirror: have.add statementId(e)
  for e in upstream:
    let id = statementId(e)
    if id notin have: result.add id

proc encodeProofRecord*(p: ProofRecord): seq[byte] =
  SSZ.encode(ProofRecordW(recordKind: uint8(ord(p.recordKind)), identity: p.identity,
    leafIndex: p.leafIndex, treeSize: p.treeSize, path: List[Digest32, 64].init(p.path)))

proc decodeProofRecord*(b: openArray[byte]): ProofRecord =
  var w: ProofRecordW
  try:
    w = SSZ.decode(b, ProofRecordW)
  except SerializationError as e:
    refuse(rrMalformed, "proof record: " & e.msg)
  if w.recordKind < 1 or w.recordKind > uint8(ord(RecordKind.high)):
    refuse(rrUnknownVocabulary, "proof record kind")
  ProofRecord(recordKind: RecordKind(w.recordKind), identity: w.identity,
    leafIndex: w.leafIndex, treeSize: w.treeSize, path: asSeq(w.path))
