## Offline release acceptance (spec §"Acceptance").
##
## A release is accepted when (1) its manifest verifies, (2) it is
## included in a trusted log at a verified checkpoint, (3) at its log
## position every author key is active with the author or maintainer role,
## (4) no author key was revoked with a compromise window covering that
## position, and (5) no blocking policy statement applies.
##
## Everything here runs offline from bytes a client already holds:
## an export bundle, a checkpoint, an inclusion proof and key logs.

import std/tables

import ./types
import ./identity
import ./verify
import ./translog
import ./statements
import ./keylog

type
  TrustConfig* = object
    logKeys*: seq[Digest32]
    policyKeys*: seq[Digest32]
    policyThreshold*: int

  LoggedRecord* = object
    envelopeBytes*: seq[byte]
    index*: uint64
      ## Leaf position in the log.
    proof*: seq[Digest32]
      ## Inclusion proof against `checkpoint`.

  AcceptanceInput* = object
    release*: LoggedRecord
    checkpoint*: Envelope
    principals*: seq[Principal]
      ## Replayed key logs of every author.
    policyStatements*: seq[Envelope]
      ## Verdicts / revocations / moderation; quorum-checked here.

  Decision* = object
    accepted*: bool
    id*: ReleaseId
    reason*: RemixRefusal
    detail*: string

proc includedAt*(rec: LoggedRecord; recordKind: RecordKind; identity: Digest32;
                 cp: Checkpoint): bool =
  let leaf = hashLeaf(logLeaf(recordKind, identity, rec.envelopeBytes))
  verifyInclusion(leaf, rec.index, cp.treeSize, rec.proof, cp.rootHash)

proc acceptRelease*(input: AcceptanceInput; trust: TrustConfig): Decision =
  ## Never raises for a policy outcome: a refusal is a `Decision` with the
  ## reason, so callers can show why. Malformed input still raises.
  template deny(r: RemixRefusal; d: string) =
    return Decision(accepted: false, id: result.id, reason: r, detail: d)

  # 1. The manifest.
  let v = decodeAndVerify(input.release.envelopeBytes)
  result.id = v.id

  # 2. Inclusion in a trusted log.
  let cp = verifyCheckpoint(input.checkpoint, trust.logKeys)
  if not input.release.includedAt(rkManifest, Digest32(v.id), cp):
    deny(rrNotLogged, "inclusion proof does not verify against the checkpoint")
  let pos = input.release.index

  # 3 and 4. Author keys active at that position, not revoked over it.
  for author in v.manifest.authors:
    var holders = 0
    for p in input.principals:
      if p.keys.hasKey(author): inc holders
    if holders > 1:
      deny(rrForbiddenContent, "author key " & $KeyId(author) &
           " appears in more than one principal's key log")
    var found = false
    for p in input.principals:
      if p.keys.hasKey(author):
        found = true
        let h = p.keys[author]
        if h.revoked and pos >= h.compromisedFrom:
          deny(rrRevokedKey, "author key " & $KeyId(author) &
               " was revoked with a compromise window covering position " & $pos)
        if not p.keyActiveAt(author, pos, {roleAuthor, roleMaintainer}):
          deny(rrInactiveKey, "author key " & $KeyId(author) &
               " was not an active author key at position " & $pos)
    if not found:
      deny(rrMissingAuthorSignature, "no key log for author " & $KeyId(author))

  # 5. Blocking policy statements under quorum.
  for env in input.policyStatements:
    let st = verifyQuorum(env, trust.policyKeys, trust.policyThreshold)
    if st.kind in {skVerdict, skRevocation} and st.subjectKind == sbRelease and
       st.subject == Digest32(v.id) and "block" in st.scope:
      deny(rrBlockedByPolicy, "a quorum-signed policy statement blocks this release")

  result.accepted = true
