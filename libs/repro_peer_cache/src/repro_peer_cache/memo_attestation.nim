## Issuer binding for memoization entries — Distributed-Execution M7
## (`Distributed-Execution-Threat-Model.md` asset A2, the poisoned
## `ActionResultRecord`; deployment-security-architecture.md DET-2).
##
## Before M7 a consumer accepted any peer's memo entry once its fingerprints
## and digests were self-consistent. Self-consistency is exactly what a
## poisoner can manufacture: take a real record, change the outputs, and
## publish it for a popular StrongFingerprint. Nothing said WHO computed it,
## so nothing could be refused, reported or revoked.
##
## An entry now carries an ATTESTATION: the issuer's host id, the short-lived
## leaf it held when it published (`identity.nim`), the issuance time, and an
## ECDSA-P256 signature by that leaf over the exact selector and record:
##
##   "reprobuild/peer-cache/memo-attestation/v1\0"
##   || weak || pathSetDigest || strong || BLAKE3(recordBytes)
##   || u32 n || outputDigest[n] || i64 issuedAt || issuerHostId
##
## A consumer accepts an entry only when
##
##   * the leaf verifies against its OWN trust anchors at the CONSUMER'S
##     clock (a trusted time — never the `issuedAt` the issuer wrote), was
##     signed by the CA of the host it names, and that host is
##     `issuerHostId` (a peer cannot attest as another host);
##   * `issuedAt` lies inside that leaf's validity window;
##   * the leaf's role may publish (`daemon` or `build-worker` — an
##     execution lease never attests: what runs inside a lease is the
##     untrusted code the record describes);
##   * `issuedAt` is not in the future and the issuer is not revoked;
##   * the signature covers exactly the selector that was asked for — so an
##     entry signed for StrongFingerprint S' cannot be served for S.
##
## TRUSTED TIME (Distributed-Execution M7 review, threat model G15). Judging
## the leaf at the attestation's own `issuedAt` let a key stolen inside its
## hour sign backdated entries that verified forever. Judged at the
## consumer's clock, an attestation is good only while its leaf is (at most
## an hour, plus the clock-skew allowance), so a stolen leaf key stops
## producing acceptable entries when the leaf expires — the CRED-1 property
## "a stolen Edge credential expires on its own". The ISSUER keeps its own
## entries servable by re-attesting them with its current leaf when it
## serves them (`reattestIfStale`, wired in `peer_cache_wiring`); a node
## never re-signs an entry another host issued, and does not serve one
## whose attestation has expired (`attestationFresh`), so an honest
## re-server is never reported for serving a stale entry.
##
## Re-serving keeps the original attestation byte for byte; a node never
## re-signs what it fetched. A record published for a strong fingerprint the
## serving peer did not compute is therefore either attested by the host
## that DID compute it (and accepted as that host's), or rejected.

import std/[sets, times]

import blake3

import ./auth
import ./identity
import ./memo_store
import ./pki
import ./secret_key
import ./types

const
  AttestationDomain = "reprobuild/peer-cache/memo-attestation/v1\x00"
  PublishingRoles* = {lrDaemon, lrBuildWorker}

type
  AttestationVerdict* = object
    ok*: bool
    reason*: string
    issuer*: PeerId
    expired*: bool
      ## The ONLY failure was that the issuer's leaf is no longer valid at
      ## the consumer's clock: the entry may well be honest, but its issuer
      ## must re-attest it before anyone accepts it again. Not grounds for
      ## suspicion of the peer that served it.

proc putU32(dst: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): dst.add(byte((v shr uint32(s)) and 0xff))

proc attestationMessage*(entry: MemoEntry): seq[byte] =
  for ch in AttestationDomain: result.add(byte(ord(ch)))
  for b in bytes(entry.weakFingerprint): result.add(b)
  for b in bytes(entry.pathSetDigest): result.add(b)
  for b in bytes(entry.strongFingerprint): result.add(b)
  for b in blake3.digest(entry.recordBytes): result.add(b)
  result.putU32(uint32(entry.outputDigests.len))
  for d in entry.outputDigests:
    for b in bytes(d): result.add(b)
  for shift in countup(0, 56, 8):
    result.add(byte((cast[uint64](entry.issuedAtUnix) shr uint64(shift)) and
      0xff'u64))
  for b in bytes(entry.issuerHostId): result.add(b)

proc attest*(entry: var MemoEntry; leaf: LeafCredential; now = 0'i64) =
  ## Signs `entry` as `leaf`'s host. Raises `IdentityError` for a role that
  ## may not publish.
  if leaf.role notin PublishingRoles:
    raise newException(IdentityError,
      "a " & $leaf.role & " leaf may not attest memo entries")
  entry.issuerHostId = leaf.hostId
  entry.issuerLeafDer = leaf.cert.certDer
  entry.issuedAtUnix = if now == 0: getTime().toUnix else: now
  var sig: SignatureBytes
  withKeypair(leaf.key, kp):
    sig = signMessage(kp, attestationMessage(entry))
  entry.issuerSignature = newSeq[byte](sig.len)
  for i, b in sig: entry.issuerSignature[i] = b

proc verifyAttestation*(entry: MemoEntry; anchors: TrustAnchorSet;
                        revoked: HashSet[PeerId]; now = 0'i64):
                        AttestationVerdict =
  ## See the module doc. Never raises.
  let at = if now == 0: getTime().toUnix else: now
  if entry.issuerLeafDer.len == 0 or entry.issuerSignature.len != 64:
    return AttestationVerdict(ok: false,
      reason: "the entry carries no issuer attestation")
  if entry.issuedAtUnix > at + LeafClockSkewSeconds:
    return AttestationVerdict(ok: false,
      reason: "the attestation is dated in the future")
  # The leaf is judged at the CONSUMER's clock (see "Trusted time").
  let leaf =
    try: verifyLeaf(entry.issuerLeafDer, anchors, at)
    except CatchableError as err:
      VerifiedLeaf(ok: false, reason: err.msg)
  if not leaf.ok:
    # Was it only the clock? Re-check at the attestation's own time: if the
    # leaf verifies there, the entry is stale rather than forged.
    let atIssue =
      try: verifyLeaf(entry.issuerLeafDer, anchors, entry.issuedAtUnix)
      except CatchableError: VerifiedLeaf(ok: false)
    if atIssue.ok and at > atIssue.notAfter:
      return AttestationVerdict(ok: false, expired: true,
        reason: "the issuer's attestation expired at " & $atIssue.notAfter &
          " (consumer clock " & $at & "); its issuer must re-attest it")
    return AttestationVerdict(ok: false,
      reason: "issuer leaf refused: " & leaf.reason)
  if entry.issuedAtUnix + LeafClockSkewSeconds < leaf.notBefore or
      entry.issuedAtUnix - LeafClockSkewSeconds > leaf.notAfter:
    return AttestationVerdict(ok: false,
      reason: "the attestation is dated outside its leaf's validity window")
  if leaf.hostId != entry.issuerHostId:
    return AttestationVerdict(ok: false,
      reason: "the attestation names issuer " & $entry.issuerHostId &
        " but its leaf belongs to host " & $leaf.hostId)
  if leaf.role notin PublishingRoles:
    return AttestationVerdict(ok: false,
      reason: "a " & $leaf.role & " leaf may not attest memo entries")
  if leaf.hostId in revoked:
    return AttestationVerdict(ok: false,
      reason: "issuer " & $leaf.hostId & " is revoked")
  var sig: SignatureBytes
  for i in 0 ..< 64: sig[i] = entry.issuerSignature[i]
  if not verifySignature(leaf.leafPublicKey, attestationMessage(entry), sig):
    return AttestationVerdict(ok: false,
      reason: "the issuer signature does not cover this selector and record")
  AttestationVerdict(ok: true, issuer: leaf.hostId)

proc attestationFresh*(entry: MemoEntry; now = 0'i64;
                       margin = 0'i64): bool =
  ## Whether `entry`'s issuer leaf is still valid at `now` + `margin` (by its
  ## own validity window; the signature is not checked). A node serves an
  ## entry another host issued only while this holds.
  if entry.issuerLeafDer.len == 0:
    return false
  let at = if now == 0: getTime().toUnix else: now
  try:
    let window = certValidityWindow(entry.issuerLeafDer)
    at + margin < window.notAfter + LeafClockSkewSeconds
  except CatchableError:
    false

proc reattestIfStale*(entry: var MemoEntry; leaf: LeafCredential;
                      now = 0'i64): bool =
  ## Re-signs `entry` with `leaf` when `entry` was issued by `leaf`'s own
  ## host and its attestation leaf has less than `LeafRenewMarginSeconds`
  ## left. Returns whether it re-signed. An entry another host issued is
  ## never touched (re-signing would claim its computation as ours).
  if entry.issuerHostId != leaf.hostId or leaf.role notin PublishingRoles:
    return false
  if not leaf.key.available:
    return false
  if attestationFresh(entry, now, LeafRenewMarginSeconds):
    return false
  attest(entry, leaf, now)
  true
