## Signing and offline verification of Remix manifest envelopes.
##
## Normative source: `reprobuild-pm/spec/Remix-Protocol.md` §"Envelope",
## Invariants I-10 (offline verifiability) and I-13 (authorship is decided
## by signatures). Algorithm 1 is ECDSA-P256 with raw `r‖s` and RFC 6979
## nonces, implemented by the in-tree BearSSL binding that the binary
## cache and the deploy agent already use (spec OD-2).
##
## What this module decides is narrow on purpose: that the manifest is
## well-formed and that every listed author's key signed this exact
## release identity. Whether an author's key is *trusted* — current in its
## key log, not revoked, not inside a compromise window — is a policy
## decision made against the key log and transparency proofs, which later
## milestones add. `verifyManifestEnvelope` therefore returns the author
## key ids so that policy can be applied to them.

import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./types
import ./identity
import ./codec

type
  VerifiedManifest* = object
    id*: ReleaseId
    manifest*: Manifest
    authors*: seq[KeyId]
      ## Every author key, each with a verified signature over `id`.

proc keyIdOf*(kp: PeerKeypair): KeyId =
  keyId(saEcdsaP256, kp.publicKey)

proc signEnvelope*(env: var Envelope; kp: PeerKeypair) =
  ## Add (or replace) this key's signature over the record identity.
  let id = recordIdentity(ReleaseContext, env.schemaVersion,
                          env.requiredFeatures, env.recordKind, env.body)
  let sig = peerAuth.signMessage(kp, signingMessage(id))
  let kid = Digest32(keyIdOf(kp))
  var kept: seq[Signature]
  for s in env.signatures:
    if s.keyId != kid:
      kept.add s
  kept.add Signature(keyId: kid, algorithm: saEcdsaP256,
                     publicKey: @(kp.publicKey), value: @sig)
  sortSignatures(kept)
  env.signatures = kept

proc verifyManifestEnvelope*(env: Envelope): VerifiedManifest =
  ## Decode the body and check every signature. Refuses when a signature's
  ## key does not hash to its `keyId`, when a signature does not verify,
  ## when a signer is not a listed author, or when a listed author has not
  ## signed. A non-author signature is refused rather than ignored so that
  ## one set of bytes has one meaning.
  if env.recordKind != rkManifest:
    refuse(rrUnknownRecordKind, "not a manifest envelope")
  let m = decodeManifest(env.body)
  let id = releaseId(env)
  let msg = signingMessage(Digest32(id))
  var signed: seq[Digest32]
  for s in env.signatures:
    if Digest32(keyId(s.algorithm, s.publicKey)) != s.keyId:
      refuse(rrKeyMismatch, "signature key does not hash to its keyId")
    case s.algorithm
    of saEcdsaP256:
      var pk: PublicKeyBytes
      var sv: SignatureBytes
      for i in 0 ..< pk.len: pk[i] = s.publicKey[i]
      for i in 0 ..< sv.len: sv[i] = s.value[i]
      if not peerAuth.verifySignature(pk, msg, sv):
        refuse(rrBadSignature, "signature by " & $KeyId(s.keyId) & " does not verify")
    if s.keyId notin m.authors:
      refuse(rrForbiddenContent, "signature by a key the manifest does not list as author")
    signed.add s.keyId
  for a in m.authors:
    if a notin signed:
      refuse(rrMissingAuthorSignature, "author " & $KeyId(a) & " has not signed")
  result.id = id
  result.manifest = m
  for a in m.authors:
    result.authors.add KeyId(a)

proc decodeAndVerify*(bytes: openArray[byte]): VerifiedManifest =
  ## The whole offline path from bytes: frame, wrapper, body, signatures.
  verifyManifestEnvelope(decodeEnvelope(bytes))
