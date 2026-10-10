## Minting edge attestations: rebuilder signatures and log inclusion
## proofs, built from scratch on every run.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``software_root_test_pki.nim`` follows.
##
## ## What this mints
##
## A ``COSE_Sign1`` over the detached edge statement, in production
## algorithms and production encodings: ES256 over a real Sig_structure,
## with the signature as the two raw P-256 scalars RFC 9053 §2.1
## requires. The bytes go straight into the production verifier.
##
## ## The Sig_structure is built HERE, by hand, from RFC 9052 §4.4
##
## Not by calling ``cose``'s ``sigStructureSign1``. That would make the
## gate agree with the verifier by construction: a defect in how the
## to-be-signed bytes are assembled would produce a signature the
## verifier happily accepted, and every case below would stay green. The
## four-element array is short enough to write out, and writing it out is
## what makes the signature an independent statement about the same
## specification.
##
## ## No key is ever committed
##
## Keys come from ``software_root_test_pki``'s ``newTestKey``, which
## draws every private scalar from the operating system's random source
## at the moment it is called. Nothing is written anywhere and there is
## no fixture file.
##
## ## Mocking
##
## None. Real ECDSA, real CBOR, real SHA-256.

import std/[strutils]

import cbor

import repro_attest
import repro_attest/cose
import repro_attest_verify

import ./software_root_test_pki

const
  Es256Label* = 6'u64
    ## ``-7`` as CBOR encodes it: a negative integer holds ``-1 - arg``.
    ## Written as the wire value rather than reached for through
    ## ``CoseAlgorithmLabel``, so this harness states the algorithm the
    ## specification gives rather than the one the library believes in.

proc kidOf*(key: TestKey): seq[byte] =
  ## A signer's key identifier: SHA-256 of its public point. Any opaque
  ## value would do; a digest of the key is chosen because it cannot be
  ## assigned to two keys by accident.
  var point = newString(key.pub.len)
  for i in 0 ..< key.pub.len: point[i] = char(key.pub[i])
  let hex = sha256Hex(point)
  for i in 0 ..< hex.len div 2:
    result.add byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

const
  HarnessAdmittedFrom* = 0'i64
    ## The window every harness roster entry is admitted for.
    ##
    ## It starts at the epoch for a reason worth stating, because the
    ## number otherwise looks like a field somebody left alone: the
    ## verifier harness beside this one builds its request with
    ## ``nowMs`` at zero, so a window that opened later would make every
    ## pre-existing edge-attestation gate fail with "signer not yet
    ## admitted" — a change in what those gates measure, smuggled in as
    ## a default. The END is stated and `validateRoster` requires it, so
    ## the property that matters (no key is admitted forever) holds
    ## whatever the start is.
  HarnessAdmittedUntil* = 1_900_000_000'i64  ## 2030-03-17T13:46:40Z.
  HarnessNow* = 1_800_000_000'i64            ## 2027-01-15T08:00:00Z.
    ## The instant a gate calling `evaluateQuorum` directly evaluates
    ## at: inside the window above and far from either edge, so a case
    ## that means to exercise rotation has to say so.

proc signerFor*(key: TestKey): QuorumSigner =
  ## The roster entry a verifier's operator would install for this key.
  var point: seq[byte] = @[]
  for b in key.pub: point.add b
  admittedSigner(CoseKey(kid: kidOf(key), curve: ccP256, point: point),
                 HarnessAdmittedFrom, HarnessAdmittedUntil)

proc signerName*(key: TestKey): string = signerNameOf(signerFor(key).key)

proc protectedHeader*(kid: seq[byte]): seq[byte] =
  ## ``{1: -7, 4: <kid>}``, serialized — the bytes a COSE_Sign1 signs
  ## over as well as carries.
  encodeItem(cMap([cPair(cUInt(1'u64), cNegInt(Es256Label)),
                   cPair(cUInt(4'u64), cBytes(kid))]))

proc signedQuorumProof*(key: TestKey; statement: string): string =
  ## One rebuilder's detached ``COSE_Sign1`` over ``statement``, as the
  ## lower-case hex a bundle entry carries.
  let protectedBytes = protectedHeader(kidOf(key))
  var payload: seq[byte] = @[]
  for c in statement: payload.add byte(c)
  # RFC 9052 §4.4: Sig_structure = [ context, body_protected,
  #                                  external_aad, payload ]
  let tbs = encodeItem(cArray([cText("Signature1"),
                               cBytes(protectedBytes),
                               cBytes(newSeq[byte]()),
                               cBytes(payload)]))
  let (r, s) = signRawEcdsa(key, tbs)
  var sig: seq[byte] = @[]
  for c in r: sig.add byte(c)
  for c in s: sig.add byte(c)
  let message = encodeItem(cTag(CoseSign1Tag,
    cArray([cBytes(protectedBytes), cMap([]), cNull(), cBytes(sig)])))
  var text = newString(message.len)
  for i in 0 ..< message.len: text[i] = char(message[i])
  bytesToHex(text)

proc flipLastByte*(hex: string): string =
  ## One bit of one byte of a proof, changed. The smallest edit that
  ## must be detected.
  result = hex
  let last = result[^1]
  result[^1] = (if last == '0': '1' else: '0')

proc inclusionProofHex*(logId: string; leafIndex, treeSize: int;
                        auditPath: seq[string]): string =
  let doc = renderLogInclusionProof(LogInclusionProof(
    logId: logId, leafIndex: leafIndex, treeSize: treeSize,
    auditPath: auditPath))
  bytesToHex(doc)

type
  TestLog* = object
    ## A transparency log, as a list of leaves. Small enough to hold
    ## whole, which is what lets a gate build a real proof rather than
    ## assert against a recorded one.
    logId*: string
    leaves*: seq[string]

proc appendLeaf*(log: var TestLog; leaf: string): int =
  result = log.leaves.len
  log.leaves.add leaf

proc witnessedRoot*(log: TestLog): WitnessedLogRoot =
  ## The root an operator would have witnessed at this tree size.
  WitnessedLogRoot(logId: log.logId, treeSize: log.leaves.len,
                   rootHash: merkleRootOf(log.leaves))

proc proofFor*(log: TestLog; index: int): string =
  inclusionProofHex(log.logId, index, log.leaves.len,
                    inclusionPathFor(log.leaves, index))

proc bundleOf*(claim: EdgeClaim;
               entries: openArray[EdgeAttestation]): string =
  var b = EdgeAttestationBundle(subject: claim)
  for e in entries: b.attestations.add e
  renderEdgeAttestationBundle(b)

proc quorumEntry*(key: TestKey; statement: string): EdgeAttestation =
  EdgeAttestation(verifier: QuorumVerifierId,
                  proof: signedQuorumProof(key, statement))

proc inclusionEntry*(proofHex: string): EdgeAttestation =
  EdgeAttestation(verifier: TransparencyLogVerifierId, proof: proofHex)
