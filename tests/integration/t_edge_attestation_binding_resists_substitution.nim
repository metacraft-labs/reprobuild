## What a rebuilder's signature is a signature FOR: the claim's two
## halves, the edge it names, and every route to a threshold that is not
## K distinct honest signers.
##
## ## What this gate is for
##
## The quorum gate beside it establishes that the threshold answers yes
## at K and no at K-1. That is necessary and it is not sufficient, because
## it never asks what the signed bytes are. Two separate questions are
## left, and both are the kind that a green positive path hides:
##
##   * **Is a signature a statement about BOTH halves of the claim?** The
##     container's header says a signature over the manifest digest alone
##     is a statement about a document with no subject, and one over the
##     configuration fingerprint alone is satisfied by any manifest that
##     configuration ever produced — including the one it produced before
##     a defect was fixed. Asserting that both strings appear in the
##     statement bytes is weaker than it looks: it establishes what the
##     renderer writes, not what the verifier refuses. Every case in the
##     first suite therefore MINTS A REAL SIGNATURE over the degenerate
##     bytes and requires the production verifier to reject it.
##   * **Can a threshold be reached by anything other than K distinct
##     honest signers?** The second suite enumerates the routes: a
##     stranger's signature, a repeat, a signature whose key identifier
##     names a key other than the one that signed it, a signature
##     carrying its own copy of the payload, a signature with no key
##     identifier at all, and a valid signature filed under a verifier
##     identifier the quorum does not read. Each must fail to count, and
##     the ones that indicate tampering must reject rather than quietly
##     lower the count.
##
## The complement is here too, and it is not decoration: an unadmitted
## party's signature must NOT be a defect, or anyone who can append to a
## bundle can deny service by signing it.
##
## ## Why the statements are assembled here rather than asked for
##
## ``signedOverBytes`` signs bytes the case chose. The library offers no
## way to produce a statement with one half missing or with another edge
## kind in it — which is the point — so an attacker's document has to be
## built the way an attacker would build it, from the specification
## rather than from the renderer. A case that could only sign what
## ``edgeStatementBytes`` returns could not test what that function's
## output is worth.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys drawn from the operating system's random
## source, real CBOR, real SHA-256, the production policy parser, the
## production quorum evaluator and the production verdict driver. The
## only thing this file builds that production does not is the attacker's
## side of each exchange.

import std/[options, strutils, unittest]

import cbor

import repro_attest
import repro_attest/cose
import repro_attest_verify

import ./software_root_test_pki
import ./edge_attestation_harness

include ./attestation_verifier_harness

const
  EvidencePolicyTemplate = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[measurements.evidence]
min_signatures = @K@
known_keys = [@KEYS@]
require_transparency_log = @LOG@

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

proc evidencePolicy(k: int; names: openArray[string];
                    requireLog = false): AttestationPolicy =
  var quoted: seq[string] = @[]
  for n in names: quoted.add "\"" & n & "\""
  parseAttestationPolicy(
    EvidencePolicyTemplate
      .replace("@K@", $k)
      .replace("@KEYS@", quoted.join(", "))
      .replace("@LOG@", (if requireLog: "true" else: "false")),
    "<evidence-policy>")

proc verdictFor(policy: AttestationPolicy; manifestText, bundleText: string;
                roster: seq[QuorumSigner];
                roots: seq[WitnessedLogRoot] = @[]): Verdict =
  let text = tpm2ReportText()
  let report = parseAttestationReport(text, "<tpm report>")
  var req = verificationRequest(text, policy, some(manifestText))
  req.attestationsText = some(bundleText)
  req.attestationsSource = "<harness attestations>"
  req.signerRoster = roster
  req.witnessedLogRoots = roots
  verifyWithReading(req, report,
    tpmReading(sampleExpectedPcr11(), report.reportData))

# ---------------------------------------------------------------------
# The attacker's side: a COSE_Sign1 over bytes of the case's choosing
# ---------------------------------------------------------------------

proc coseSign1Over*(key: TestKey; payloadBytes: string;
                    kid = newSeq[byte](); attachPayload = false): string =
  ## ``edge_attestation_harness``'s ``signedQuorumProof``, opened up in
  ## the three places an attacker would open it: the bytes signed, the
  ## key identifier claimed, and whether the payload rides along.
  ## Everything else — the Sig_structure of RFC 9052 §4.4, the raw-scalar
  ## ES256 signature of RFC 9053 §2.1 — is assembled the same way and by
  ## hand, so a case here is an independent statement about the same
  ## specification rather than an echo of the verifier.
  let claimedKid = (if kid.len > 0: kid else: kidOf(key))
  let protectedBytes = protectedHeader(claimedKid)
  var payload: seq[byte] = @[]
  for c in payloadBytes: payload.add byte(c)
  let tbs = encodeItem(cArray([cText("Signature1"),
                               cBytes(protectedBytes),
                               cBytes(newSeq[byte]()),
                               cBytes(payload)]))
  let (r, s) = signRawEcdsa(key, tbs)
  var sig: seq[byte] = @[]
  for c in r: sig.add byte(c)
  for c in s: sig.add byte(c)
  let body = (if attachPayload: cBytes(payload) else: cNull())
  let message = encodeItem(cTag(CoseSign1Tag,
    cArray([cBytes(protectedBytes), cMap([]), body, cBytes(sig)])))
  var text = newString(message.len)
  for i in 0 ..< message.len: text[i] = char(message[i])
  bytesToHex(text)

proc entryOver(key: TestKey; payloadBytes: string): EdgeAttestation =
  EdgeAttestation(verifier: QuorumVerifierId,
                  proof: coseSign1Over(key, payloadBytes))

suite "a signature is a signature for BOTH halves of the claim":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let roster = @[signerFor(keyA), signerFor(keyB)]
  let policy = evidencePolicy(2, [signerName(keyA), signerName(keyB)])

  proc rejectsSignaturesOver(bytes: string): Verdict =
    ## Two REAL signatures by two ADMITTED signers over `bytes`. The only
    ## thing wrong with the bundle is what was signed, so a verdict that
    ## accepted it would have accepted it on the strength of those bytes.
    result = verdictFor(policy, manifestText,
      bundleOf(claim, [entryOver(keyA, bytes), entryOver(keyB, bytes)]),
      roster)

  test "a signature over the MANIFEST DIGEST alone does not verify":
    let v = rejectsSignaturesOver(
      "{\"manifest\": \"" & claim.manifestDigest & "\"}\n")
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check v.decision == vdRejected
    check "does not verify under the key its own key identifier names" in
      v.checks[vcEvidenceQuorum].detail

  test "a signature over the CONFIGURATION FINGERPRINT alone does not " &
       "verify":
    let v = rejectsSignaturesOver(
      "{\"configFingerprint\": \"" & claim.configFingerprint & "\"}\n")
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check v.decision == vdRejected

  test "a statement with the CONFIGURATION half swapped does not verify":
    # The same manifest digest under a different configuration: exactly
    # the document a digest-only signature would be satisfied by.
    let swapped = edgeStatementBytes(EdgeClaim(
      configFingerprint: "reproos-attested-uefi:some-other-config",
      manifestDigest: claim.manifestDigest))
    check swapped != statement
    check claim.manifestDigest in swapped
    check rejectsSignaturesOver(swapped).decision == vdRejected

  test "a statement with the MANIFEST half swapped does not verify":
    let other = claimForManifest(sampleManifestText(OtherVerityRootHash),
                                 "<other manifest>")
    let swapped = edgeStatementBytes(EdgeClaim(
      configFingerprint: claim.configFingerprint,
      manifestDigest: other.manifestDigest))
    check swapped != statement
    check claim.configFingerprint in swapped
    check rejectsSignaturesOver(swapped).decision == vdRejected

  test "a signature minted for ANOTHER EDGE KIND is not a signature for " &
       "this one":
    # Byte for byte the statement this verifier checks, with only the
    # `edge` value changed — so nothing but the edge binding can be what
    # refuses it.
    let otherEdge = statement.replace(
      "\"" & MeasurementManifestEdge & "\"", "\"reproos.some-other-edge\"")
    check otherEdge != statement
    check ("\"" & MeasurementManifestEdge & "\"") notin otherEdge
    check claim.configFingerprint in otherEdge
    check claim.manifestDigest in otherEdge
    check rejectsSignaturesOver(otherEdge).decision == vdRejected

  test "a signature minted under another STATEMENT SCHEMA is not one " &
       "either":
    let otherSchema = statement.replace(
      "\"" & EdgeStatementSchema & "\"", "\"reproos.some-other-statement\"")
    check otherSchema != statement
    check rejectsSignaturesOver(otherSchema).decision == vdRejected

  # -- the bundle's own subject, which the signatures do NOT cover -----
  #
  # The statement is derived from the verifier's claim, never from the
  # bundle's `subject`, so a lying subject cannot make a signature
  # verify. It can do something else: a bundle whose subject names a
  # configuration or a manifest OTHER than the one the signatures are
  # about, carried beside signatures that verify perfectly, would be
  # ACCEPTED while telling every human reader something false about what
  # was attested. Both halves of the subject are therefore compared, and
  # each half gets a case — with the signatures made over the REAL
  # statement, so nothing but the subject comparison can be what refuses.

  test "a bundle whose SUBJECT names another configuration is refused, " &
       "even though every signature in it verifies":
    let lying = EdgeClaim(
      configFingerprint: "reproos-attested-uefi:a-configuration-not-run",
      manifestDigest: claim.manifestDigest)
    let v = verdictFor(policy, manifestText,
      bundleOf(lying, [entryOver(keyA, statement),
                       entryOver(keyB, statement)]), roster)
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check v.decision == vdRejected
    check "the attestations name the configuration" in
      v.checks[vcEvidenceQuorum].detail
    check lying.configFingerprint in v.checks[vcEvidenceQuorum].detail

  test "a bundle whose SUBJECT names another manifest is refused, even " &
       "though every signature in it verifies":
    let other = claimForManifest(sampleManifestText(OtherVerityRootHash),
                                 "<other manifest>")
    let lying = EdgeClaim(configFingerprint: claim.configFingerprint,
                          manifestDigest: other.manifestDigest)
    let v = verdictFor(policy, manifestText,
      bundleOf(lying, [entryOver(keyA, statement),
                       entryOver(keyB, statement)]), roster)
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check v.decision == vdRejected
    check "the attestations are about the manifest " & other.manifestDigest in
      v.checks[vcEvidenceQuorum].detail
    # The two refusals are different sentences, so neither case can be
    # satisfied by the other's rule.
    check "the attestations name the configuration" notin
      v.checks[vcEvidenceQuorum].detail

suite "every route to a threshold that is not K distinct honest signers":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let keyC = newTestKey()
  let outsider = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB), signerName(keyC)]
  let roster = @[signerFor(keyA), signerFor(keyB), signerFor(keyC)]

  test "K-1 honest signatures plus one UNADMITTED signer do not reach K":
    let v = verdictFor(evidencePolicy(3, admitted), manifestText,
      bundleOf(claim, [quorumEntry(keyA, statement),
                       quorumEntry(keyB, statement),
                       quorumEntry(outsider, statement)]), roster)
    check v.decision == vdRejected
    check "2 valid signature(s) from admitted signers" in
      v.checks[vcEvidenceQuorum].detail

  test "K-1 honest signatures plus one REPEAT do not reach K":
    let v = verdictFor(evidencePolicy(3, admitted), manifestText,
      bundleOf(claim, [quorumEntry(keyA, statement),
                       quorumEntry(keyB, statement),
                       quorumEntry(keyA, statement)]), roster)
    check v.decision == vdRejected
    check "2 valid signature(s) from admitted signers" in
      v.checks[vcEvidenceQuorum].detail

  test "one key repeated any number of times reaches no threshold at all":
    for k in 2 .. 3:
      var entries: seq[EdgeAttestation] = @[]
      for _ in 0 ..< k + 2: entries.add quorumEntry(keyA, statement)
      let v = verdictFor(evidencePolicy(k, admitted), manifestText,
                         bundleOf(claim, entries), roster)
      check v.decision == vdRejected
      check "1 valid signature(s) from admitted signers" in
        v.checks[vcEvidenceQuorum].detail

  test "a forgery rejects at every K the honest signatures alone would " &
       "satisfy":
    for k in 2 .. 3:
      var forged = quorumEntry(keyC, statement)
      forged.proof = flipLastByte(forged.proof)
      var entries = @[quorumEntry(keyA, statement),
                      quorumEntry(keyB, statement)]
      if k == 3: entries.add quorumEntry(keyC, statement)
      entries.add forged
      let v = verdictFor(evidencePolicy(k, admitted), manifestText,
                         bundleOf(claim, entries), roster)
      check v.decision == vdRejected
      check "a threshold reached beside a forgery" in
        v.checks[vcEvidenceQuorum].detail

  test "an UNADMITTED party cannot deny a bundle that reaches K by " &
       "signing it":
    # The complement of the row above, and the reason the two outcomes
    # are kept apart: if a stranger's signature were a defect, appending
    # one to a published bundle would be a denial of service.
    let v = verdictFor(evidencePolicy(2, admitted), manifestText,
      bundleOf(claim, [quorumEntry(keyA, statement),
                       quorumEntry(keyB, statement),
                       quorumEntry(outsider, statement)]), roster)
    check v.decision == vdAcceptedEvidenceBackedManifest

  test "a signature whose KEY IDENTIFIER names a key other than the one " &
       "that signed is a defect":
    # Key-distinctness rests entirely on the identifier naming the key
    # that signed. A signature that borrows an admitted signer's
    # identifier must not be counted as that signer, and must not be
    # waived as a stranger either.
    let borrowed = coseSign1Over(outsider, statement, kid = kidOf(keyC))
    let v = verdictFor(evidencePolicy(3, admitted), manifestText,
      bundleOf(claim, [quorumEntry(keyA, statement),
                       quorumEntry(keyB, statement),
                       EdgeAttestation(verifier: QuorumVerifierId,
                                       proof: borrowed)]), roster)
    check v.decision == vdRejected
    check "does not verify under the key its own key identifier names" in
      v.checks[vcEvidenceQuorum].detail

  test "a signature that carries its OWN COPY of the payload is a defect":
    # The payload is detached precisely so the bundle cannot supply the
    # bytes its signatures are judged against. A document that supplied
    # them anyway must be refused rather than judged against them.
    let attached = coseSign1Over(keyA, statement, attachPayload = true)
    let v = verdictFor(evidencePolicy(2, admitted), manifestText,
      bundleOf(claim, [EdgeAttestation(verifier: QuorumVerifierId,
                                       proof: attached),
                       quorumEntry(keyB, statement),
                       quorumEntry(keyC, statement)]), roster)
    check v.decision == vdRejected
    check "is not a signature this build can read" in
      v.checks[vcEvidenceQuorum].detail

  test "a signature with NO key identifier is a defect, not a non-vote":
    # `cxeNoKeyIdentifier` is not `cxeKeyNotFound`, and the distinction
    # is load-bearing: an anonymous signature that was merely "not
    # admitted" would be a free way to stay under the defect threshold.
    let protectedBytes = encodeItem(cMap([cPair(cUInt(1'u64),
                                                cNegInt(Es256Label))]))
    var payload: seq[byte] = @[]
    for c in statement: payload.add byte(c)
    let tbs = encodeItem(cArray([cText("Signature1"),
                                 cBytes(protectedBytes),
                                 cBytes(newSeq[byte]()),
                                 cBytes(payload)]))
    let (r, s) = signRawEcdsa(keyA, tbs)
    var sig: seq[byte] = @[]
    for c in r: sig.add byte(c)
    for c in s: sig.add byte(c)
    let message = encodeItem(cTag(CoseSign1Tag,
      cArray([cBytes(protectedBytes), cMap([]), cNull(), cBytes(sig)])))
    var text = newString(message.len)
    for i in 0 ..< message.len: text[i] = char(message[i])
    let v = verdictFor(evidencePolicy(2, admitted), manifestText,
      bundleOf(claim, [EdgeAttestation(verifier: QuorumVerifierId,
                                       proof: bytesToHex(text)),
                       quorumEntry(keyB, statement),
                       quorumEntry(keyC, statement)]), roster)
    check v.decision == vdRejected

  test "a valid signature filed under another verifier identifier is not " &
       "counted, and is NAMED":
    # Only `signed-quorum.v1` entries are counted. An entry the quorum
    # does not read must not vote — and must not vanish either.
    var mislabelled = quorumEntry(keyB, statement)
    mislabelled.verifier = "signed-quorum.v2"
    let v = verdictFor(evidencePolicy(2, admitted), manifestText,
      bundleOf(claim, [quorumEntry(keyA, statement), mislabelled]), roster)
    check v.decision == vdRejected
    check "1 valid signature(s) from admitted signers" in
      v.checks[vcEvidenceQuorum].detail
    var named = false
    for c in v.caveats:
      if "signed-quorum.v2" in c: named = true
    check named

suite "a proof is checked against a root that came from somewhere else":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB)]
  let roster = @[signerFor(keyA), signerFor(keyB)]
  let quorum = [quorumEntry(keyA, statement), quorumEntry(keyB, statement)]

  var log = TestLog(logId: "reproos-claims-a")
  discard log.appendLeaf("unrelated-entry-0")
  let claimIndex = log.appendLeaf(statement)
  discard log.appendLeaf("unrelated-entry-2")
  let root = witnessedRoot(log)

  proc logVerdict(requireLog: bool; proofHex: string;
                  roots: seq[WitnessedLogRoot]): Verdict =
    verdictFor(evidencePolicy(2, admitted, requireLog = requireLog),
      manifestText, bundleOf(claim, @quorum & @[inclusionEntry(proofHex)]),
      roster, roots)

  test "a proof pointing at the WRONG INDEX of the right tree is refused":
    let wrong = inclusionProofHex(log.logId, 0, log.leaves.len,
                                  inclusionPathFor(log.leaves, claimIndex))
    let v = logVerdict(true, wrong, @[root])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check v.decision == vdRejected

  test "a witnessed root that is not the tree's root refuses a real proof":
    let bad = WitnessedLogRoot(logId: log.logId, treeSize: log.leaves.len,
      rootHash: "00" & root.rootHash[2 .. ^1])
    let v = logVerdict(true, proofFor(log, claimIndex), @[bad])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "recomputes the root" in v.checks[vcTransparencyLog].detail

  test "a proof relabelled for ANOTHER LOG is refused, not re-witnessed":
    let other = inclusionProofHex("reproos-claims-b", claimIndex,
      log.leaves.len, inclusionPathFor(log.leaves, claimIndex))
    let v = logVerdict(true, other, @[root])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "holds no witnessed root for that log" in
      v.checks[vcTransparencyLog].detail

  test "the unverified-age caveat rides EVERY acceptance that rests on a " &
       "proof, required or not":
    # The time-lock the design describes cannot be evaluated here, so the
    # caveat is the whole of what an operator is told. A verdict that
    # rested on a proof and did not carry it would be the honest-absence
    # shape at its most expensive.
    for requireLog in [false, true]:
      let v = logVerdict(requireLog, proofFor(log, claimIndex), @[root])
      check v.decision == vdAcceptedEvidenceBackedManifest
      check UnverifiedLogAgeCaveat in v.caveats

suite "the declared bounds are reachable refusals, not decoration":

  # Every bound in this chain is written as a named constant with a
  # paragraph saying why it exists. A bound no input can reach says the
  # same thing and enforces nothing, and the only way to tell the two
  # apart is to hand it the input it claims to refuse.

  test "a policy admitting more signers than are read is refused":
    var keys: seq[string] = @[]
    for i in 0 .. MaxKnownKeys:        # one more than the bound
      keys.add "\"" & align($i, 4, '0') & "\""
    let text = EvidencePolicyTemplate
      .replace("@K@", "2")
      .replace("@KEYS@", keys.join(", "))
      .replace("@LOG@", "false")
    var msg = ""
    try:
      discard parseAttestationPolicy(text, "<policy>")
    except PolicyError as err:
      msg = err.msg
    check "signers; at most " & $MaxKnownKeys & " are read" in msg

  test "a bundle carrying more attestations than are read is refused":
    # Assembled by hand: the renderer validates before it writes, so a
    # document over the bound cannot be produced through it.
    var entries: seq[string] = @[]
    for i in 0 .. MaxAttestations:
      entries.add "    {\n      \"verifier\": \"x.v1\",\n" &
        "      \"proof\": \"aabb\"\n    }"
    let doc = "{\n  \"schema\": \"" & EdgeAttestationsSchema & "\",\n" &
      "  \"subject\": {\n    \"configFingerprint\": \"c\",\n" &
      "    \"manifest\": \"" & DigestPrefix & repeat("a", 64) & "\"\n" &
      "  },\n  \"attestations\": [\n" & entries.join(",\n") & "\n  ]\n}\n"
    check doc.len < MaxBundleBytes          # the OTHER bound is not what bites
    var msg = ""
    try:
      discard parseEdgeAttestationBundle(doc, "<bundle>")
    except EdgeAttestationError as err:
      msg = err.msg
    check "entries and at most " & $MaxAttestations & " are read" in msg

  test "an inclusion proof with a longer audit path than is evaluated is " &
       "refused":
    var path: seq[string] = @[]
    for i in 0 .. MaxAuditPathElements:
      path.add merkleLeafHash("filler-" & $i)
    let doc = renderLogInclusionProof(LogInclusionProof(
      logId: "l", leafIndex: 0, treeSize: 2, auditPath: path))
    var msg = ""
    try:
      discard parseLogInclusionProof(doc, "<proof>")
    except EdgeAttestationError as err:
      msg = err.msg
    check "hashes and at most " & $MaxAuditPathElements &
      " are evaluated" in msg

  test "a signer roster larger than is evaluated is refused":
    var roster: seq[QuorumSigner] = @[]
    for i in 0 .. MaxRoster:
      roster.add signerFor(newTestKey())
    var msg = ""
    try:
      validateRoster(roster)
    except RosterError as err:
      msg = err.msg
    check "keys and at most " & $MaxRoster & " are evaluated" in msg
