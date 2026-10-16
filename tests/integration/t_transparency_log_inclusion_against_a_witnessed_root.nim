## Transparency-log inclusion: RFC 6962 proofs, checked against a root
## the verifier already held.
##
## ## What this gate is for
##
## The quorum beside it answers "did K rebuilders reach this output?".
## This answers the other half: "is that claim in an append-only record
## whose root I witnessed?" — which is what stops a publisher quietly
## replacing an old claim with a new one.
##
## ## The hashing rules are anchored to the specification, not to the
## ## implementation next door
##
## ``merkleRootOf`` folds a tree level by level; ``rootFromInclusionProof``
## walks one path with RFC 6962's index arithmetic. They are different
## algorithms, so agreement between them is worth something — but both
## call the same two hash helpers, so agreement alone could not catch a
## wrong domain separator. Three roots are therefore computed **in this
## file, straight from the formulas in §2.1**, with the prefix bytes
## written out, and the library is required to reproduce them.
##
## ## Mocking
##
## None. Real SHA-256, real proofs, the production verifier.

import std/[options, strutils, unittest]

import repro_attest
import repro_attest_verify

import ./software_root_test_pki
import ./edge_attestation_harness

include ./attestation_verifier_harness

const
  LogPolicyTemplate = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[measurements.evidence]
min_signatures = 2
known_keys = [@KEYS@]
require_transparency_log = @LOG@

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

proc logPolicy(names: openArray[string]; requireLog: bool):
              AttestationPolicy =
  var quoted: seq[string] = @[]
  for n in names: quoted.add "\"" & n & "\""
  parseAttestationPolicy(
    LogPolicyTemplate.replace("@KEYS@", quoted.join(", "))
                     .replace("@LOG@", (if requireLog: "true" else: "false")),
    "<log-policy>")

proc rawOfHex(hexDigest: string): string =
  result = newString(hexDigest.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hexDigest[2 * i .. 2 * i + 1]))

proc specLeaf(data: string): string =
  ## RFC 6962 §2.1, written out: ``MTH({d0}) = SHA-256(0x00 || d0)``.
  sha256Hex("\x00" & data)

proc specNode(left, right: string): string =
  ## ``SHA-256(0x01 || left || right)``, over the two HASHES.
  sha256Hex("\x01" & rawOfHex(left) & rawOfHex(right))

proc verdictWith(policy: AttestationPolicy; manifestText, bundleText: string;
                 roster: seq[QuorumSigner];
                 roots: seq[WitnessedLogRoot]): Verdict =
  let text = tpm2ReportText()
  let report = parseAttestationReport(text, "<tpm report>")
  var req = verificationRequest(text, policy, some(manifestText))
  req.attestationsText = some(bundleText)
  req.attestationsSource = "<harness attestations>"
  req.signerRoster = roster
  req.witnessedLogRoots = roots
  verifyWithReading(req, report,
    tpmReading(sampleExpectedPcr11(), report.reportData))

suite "RFC 6962, against the specification's own formulas":

  test "the library reproduces roots computed here from §2.1":
    let a = "leaf-a"
    let b = "leaf-b"
    let c = "leaf-c"
    # One leaf: the root IS the leaf hash.
    check merkleRootOf([a]) == specLeaf(a)
    # Two leaves: one interior node.
    check merkleRootOf([a, b]) == specNode(specLeaf(a), specLeaf(b))
    # Three: the odd leaf is promoted, not paired with itself — a tree
    # that duplicated it would produce a different, plausible root.
    check merkleRootOf([a, b, c]) ==
      specNode(specNode(specLeaf(a), specLeaf(b)), specLeaf(c))
    check merkleLeafHash(a) == specLeaf(a)
    check merkleNodeHash(specLeaf(a), specLeaf(b)) ==
      specNode(specLeaf(a), specLeaf(b))

  test "the two domain separators are applied, and they differ":
    # Without the 0x00 prefix a leaf hash is just a hash of its bytes,
    # and the second-preimage the prefixes exist to close reopens.
    check merkleLeafHash("x") != sha256Hex("x")
    let l = merkleLeafHash("x")
    let r = merkleLeafHash("y")
    check merkleNodeHash(l, r) != sha256Hex(rawOfHex(l) & rawOfHex(r))
    check merkleNodeHash(l, r) != merkleLeafHash(rawOfHex(l) & rawOfHex(r))

  test "every leaf of every tree from 1 to 17 proves its own root":
    var leaves: seq[string] = @[]
    for n in 1 .. 17:
      leaves.add "entry-" & $n
      let root = merkleRootOf(leaves)
      for i in 0 ..< leaves.len:
        let path = inclusionPathFor(leaves, i)
        check rootFromInclusionProof(merkleLeafHash(leaves[i]), i,
                                     leaves.len, path) == root

  test "a path that is too short or too long is refused, and each " &
       "refusal says which":
    let leaves = @["a", "b", "c", "d", "e"]
    let path = inclusionPathFor(leaves, 1)
    let leaf = merkleLeafHash(leaves[1])
    check path.len >= 2

    var short = path
    short.setLen(path.len - 1)
    var tooFew = ""
    try:
      discard rootFromInclusionProof(leaf, 1, leaves.len, short)
    except MerkleError as err:
      tooFew = err.msg
    check "too few to reach the root" in tooFew

    var long = path
    long.add merkleLeafHash("intruder")
    var tooMany = ""
    try:
      discard rootFromInclusionProof(leaf, 1, leaves.len, long)
    except MerkleError as err:
      tooMany = err.msg
    check "belong to some other tree" in tooMany
    check tooFew != tooMany

  test "an index outside the tree is refused":
    var msg = ""
    try:
      discard rootFromInclusionProof(merkleLeafHash("a"), 5, 5, @[])
    except MerkleError as err:
      msg = err.msg
    check "outside a tree of 5 leaves" in msg

  test "a proof document carries neither the leaf hash nor a root":
    # Structural, and load-bearing: those are the only two values a
    # proof could use to choose what it is compared against. One comes
    # from the claim, the other from the verifier's own witnessed set.
    for key in InclusionProofKeys:
      check key notin ["leafHash", "root", "rootHash"]
    let withRoot = """{"schema": "reproos.log-inclusion-proof.v1",
      "logId": "l", "leafIndex": 0, "treeSize": 1, "auditPath": [],
      "root": "00"}"""
    var msg = ""
    try:
      discard parseLogInclusionProof(withRoot, "<proof>")
    except EdgeAttestationError as err:
      msg = err.msg
    check "carries the unknown field \"root\"" in msg

suite "inclusion proofs through the verifier":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<harness manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB)]
  let roster = @[signerFor(keyA), signerFor(keyB)]
  let quorum = [quorumEntry(keyA, statement), quorumEntry(keyB, statement)]

  # A log that already held other entries when this claim was appended.
  var log = TestLog(logId: "reproos-claims-a")
  discard log.appendLeaf("unrelated-entry-0")
  discard log.appendLeaf("unrelated-entry-1")
  let claimIndex = log.appendLeaf(statement)
  discard log.appendLeaf("unrelated-entry-3")
  let root = witnessedRoot(log)
  let goodProof = proofFor(log, claimIndex)

  test "a real proof against a witnessed root is accepted, and the " &
       "verdict says what it does not establish":
    let policy = logPolicy(admitted, requireLog = true)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(goodProof)])
    let v = verdictWith(policy, manifestText, bundleText, roster, @[root])
    check v.checks[vcTransparencyLog].outcome == coPassed
    check v.decision == vdAcceptedEvidenceBackedManifest
    check log.logId in v.checks[vcTransparencyLog].detail
    # A witnessed root carries no signed time, so the time-lock the
    # design describes cannot be applied here, and the verdict says so
    # rather than leaving a reader to assume it was.
    check UnverifiedLogAgeCaveat in v.caveats

  test "a proof for somebody else's claim recomputes a different root":
    let policy = logPolicy(admitted, requireLog = true)
    let otherClaim = claimForManifest(
      sampleManifestText(OtherVerityRootHash), "<other manifest>")
    var otherLog = TestLog(logId: "reproos-claims-a")
    discard otherLog.appendLeaf("unrelated-entry-0")
    let otherIndex = otherLog.appendLeaf(edgeStatementBytes(otherClaim))
    let otherRoot = witnessedRoot(otherLog)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(proofFor(otherLog, otherIndex))])
    let v = verdictWith(policy, manifestText, bundleText, roster,
                        @[otherRoot])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check v.decision == vdRejected
    check "either this claim is not the one that was logged" in
      v.checks[vcTransparencyLog].detail

  test "a log this verifier has never witnessed is a question it " &
       "cannot ask":
    let policy = logPolicy(admitted, requireLog = true)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(goodProof)])
    let v = verdictWith(policy, manifestText, bundleText, roster, @[])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "holds no witnessed root for that log" in
      v.checks[vcTransparencyLog].detail
    check "the question cannot be asked here at all" in
      v.checks[vcTransparencyLog].detail

  test "a proof about a tree size this verifier has not witnessed needs " &
       "a consistency proof, and is refused for the want of one":
    let policy = logPolicy(admitted, requireLog = true)
    var later = log
    discard later.appendLeaf("entry-appended-after-the-witness")
    let staleRoot = WitnessedLogRoot(logId: log.logId,
      treeSize: log.leaves.len, rootHash: root.rootHash)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(proofFor(later, claimIndex))])
    let v = verdictWith(policy, manifestText, bundleText, roster,
                        @[staleRoot])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "relating two tree sizes needs a consistency proof, which " &
      "this build neither carries nor evaluates" in
      v.checks[vcTransparencyLog].detail

  test "a policy that requires inclusion and gets none rejects":
    let policy = logPolicy(admitted, requireLog = true)
    let bundleText = bundleOf(claim, quorum)
    let v = verdictWith(policy, manifestText, bundleText, roster, @[root])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check v.decision == vdRejected
    check "carry no " & TransparencyLogVerifierId & " entry" in
      v.checks[vcTransparencyLog].detail

  test "a proof that ARRIVED is judged even when the policy does not " &
       "require one":
    # The same rule a bundled certificate chain gets: a proof that was
    # carried and not looked at is worse than one that never came.
    let policy = logPolicy(admitted, requireLog = false)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(goodProof)])

    let good = verdictWith(policy, manifestText, bundleText, roster, @[root])
    check good.checks[vcTransparencyLog].outcome == coPassed
    check good.decision == vdAcceptedEvidenceBackedManifest

    # …and the same proof with no witnessed root behind it rejects,
    # under a policy that never asked for inclusion at all.
    let unwitnessed = verdictWith(policy, manifestText, bundleText,
                                  roster, @[])
    check unwitnessed.checks[vcTransparencyLog].outcome == coFailed
    check unwitnessed.decision == vdRejected

  test "with no proof and no requirement the check is skipped, and the " &
       "skip is stated on the acceptance":
    let policy = logPolicy(admitted, requireLog = false)
    let bundleText = bundleOf(claim, quorum)
    let v = verdictWith(policy, manifestText, bundleText, roster, @[])
    check v.checks[vcTransparencyLog].outcome == coSkipped
    check v.decision == vdAcceptedEvidenceBackedManifest
    var stated = false
    for c in v.caveats:
      if "transparency-log check" in c: stated = true
    check stated

  test "a proof with no manifest to be about is a violation, not a skip":
    # The `required` flag governs only what an INAPPLICABLE finding
    # means, so "a proof that arrived is always judged" has to be
    # carried by the finding. This is the path where it would be
    # easiest to reach for the flag instead.
    let policy = logPolicy(admitted, requireLog = false)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(goodProof)])
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, none(string))
    req.attestationsText = some(bundleText)
    req.attestationsSource = "<harness attestations>"
    req.signerRoster = roster
    req.witnessedLogRoots = @[root]
    let v = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "holds no measurement manifest, so it does not know which " &
      "leaf to look for" in v.checks[vcTransparencyLog].detail

  test "a malformed proof is a defect and not a shrug":
    let policy = logPolicy(admitted, requireLog = false)
    let bundleText = bundleOf(claim,
      @quorum & @[inclusionEntry(bytesToHex("not a proof document"))])
    let v = verdictWith(policy, manifestText, bundleText, roster, @[root])
    check v.checks[vcTransparencyLog].outcome == coFailed
    check "is not an inclusion proof this build reads" in
      v.checks[vcTransparencyLog].detail
