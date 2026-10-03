## The K-of-N quorum over edge attestations, exercised from both sides
## of its own threshold.
##
## ## What this gate is for
##
## A measurement manifest is the output of a build-graph edge. This gate
## attaches attestations to that edge, and asks the production verifier
## what they are worth.
##
## The threshold is tested **at K and at K-1**, in the same fixture with
## one signature removed, because a quorum check that only ever sees a
## satisfied threshold is a check that has never been asked to say no.
## Three further cases attack the count from directions a bare
## "count the signatures" implementation gets wrong: a signer nobody
## admitted, one admitted signer voting twice, and a forged signature
## sitting beside enough honest ones to reach K.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random source,
## real CBOR, the production policy parser, the production quorum
## evaluator and the production verdict driver.

import std/[options, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_cli_support/attest as cli_attest

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

proc evidencePolicyText(k: int; names: openArray[string];
                        requireLog = false): string =
  var quoted: seq[string] = @[]
  for n in names: quoted.add "\"" & n & "\""
  EvidencePolicyTemplate
    .replace("@K@", $k)
    .replace("@KEYS@", quoted.join(", "))
    .replace("@LOG@", (if requireLog: "true" else: "false"))

proc evidencePolicy(k: int; names: openArray[string];
                    requireLog = false): AttestationPolicy =
  parseAttestationPolicy(evidencePolicyText(k, names, requireLog),
                         "<evidence-policy>")

proc evidenceVerdict(policy: AttestationPolicy; manifestText: string;
                     bundleText: string; roster: seq[QuorumSigner];
                     roots: seq[WitnessedLogRoot] = @[];
                     bundleSupplied = true): Verdict =
  ## A full verdict through the production driver, over the TPM-tier
  ## embedding seam — the only tier whose measurement can match, which
  ## is what an evidence-backed acceptance has to rest on.
  let text = tpm2ReportText()
  let report = parseAttestationReport(text, "<tpm report>")
  var req = verificationRequest(text, policy, some(manifestText))
  if bundleSupplied:
    req.attestationsText = some(bundleText)
  req.attestationsSource = "<harness attestations>"
  req.signerRoster = roster
  req.witnessedLogRoots = roots
  verifyWithReading(req, report,
    tpmReading(sampleExpectedPcr11(), report.reportData))

suite "edge attestations on the measurement manifest: K-of-N":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<harness manifest>")
  let statement = edgeStatementBytes(claim)

  # Three admitted rebuilders and one party nobody admitted. Minted
  # fresh, so nothing here is a recorded signature that could keep
  # verifying after the thing it signs has changed.
  let keyA = newTestKey()
  let keyB = newTestKey()
  let keyC = newTestKey()
  let outsider = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB), signerName(keyC)]
  let roster = @[signerFor(keyA), signerFor(keyB), signerFor(keyC)]

  test "the claim binds the configuration AND the manifest, and the " &
       "statement names the edge":
    # A signature over one of the two halves alone would be satisfied by
    # a document it was never about; both are in the signed bytes.
    check claim.configFingerprint == SampleFingerprint
    check claim.manifestDigest == sampleManifestDigest()
    check ("\"" & MeasurementManifestEdge & "\"") in statement
    check SampleFingerprint in statement
    check sampleManifestDigest() in statement
    # And the claim comes from the manifest's OWN bytes: a manifest
    # whose verity root differs is a different claim.
    let other = claimForManifest(sampleManifestText(OtherVerityRootHash),
                                 "<other>")
    check other.manifestDigest != claim.manifestDigest

  test "K signatures from distinct admitted signers is an acceptance, " &
       "and K-1 of the same fixture is a rejection":
    let policy = evidencePolicy(2, admitted)
    let atK = bundleOf(claim, [quorumEntry(keyA, statement),
                               quorumEntry(keyB, statement)])
    let below = bundleOf(claim, [quorumEntry(keyA, statement)])

    let accepted = evidenceVerdict(policy, manifestText, atK, roster)
    check accepted.checks[vcEvidenceQuorum].outcome == coPassed
    check accepted.decision == vdAcceptedEvidenceBackedManifest
    check ord(cli_attest.attestExitCodeFor(accepted.decision)) == 5

    let rejected = evidenceVerdict(policy, manifestText, below, roster)
    check rejected.checks[vcEvidenceQuorum].outcome == coFailed
    check rejected.decision == vdRejected
    check ord(cli_attest.attestExitCodeFor(rejected.decision)) == 1
    check "1 valid signature(s) from admitted signers" in
      rejected.checks[vcEvidenceQuorum].detail
    check "the policy requires 2 of the 3 it admits" in
      rejected.checks[vcEvidenceQuorum].detail

  test "a signature by a key the policy does not admit contributes " &
       "nothing, and is not treated as a defect":
    let policy = evidencePolicy(2, admitted)
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(outsider, statement)])
    let bundle = parseEdgeAttestationBundle(bundleText, "<bundle>")
    let ev = evaluateQuorum(bundle, claim, roster, HarnessNow)
    check ev.countedSigners == @[signerName(keyA)]
    check ev.defects.len == 0
    check ev.entries[1].outcome == qeoNotAnAdmittedSigner

    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdRejected
    check "1 valid signature(s)" in v.checks[vcEvidenceQuorum].detail

  test "one admitted signer voting twice is counted once":
    # The whole content of "distinct signer" at the level a signature
    # can support. Without it a single compromised rebuilder reaches any
    # threshold by repetition.
    let policy = evidencePolicy(2, admitted)
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(keyA, statement)])
    let bundle = parseEdgeAttestationBundle(bundleText, "<bundle>")
    let ev = evaluateQuorum(bundle, claim, roster, HarnessNow)
    check ev.countedSigners.len == 1
    check ev.entries[1].outcome == qeoAlreadyCounted
    check ev.defects.len == 0

    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdRejected
    check "a quorum counts signers, not signatures" notin
      v.checks[vcEvidenceQuorum].detail   # the count is what rejects
    check "1 valid signature(s)" in v.checks[vcEvidenceQuorum].detail

  test "a forged signature rejects even when K honest ones are present":
    # The reading a forger wants is "two good ones, so it passed". A
    # count that ignored the third would give it to them.
    let policy = evidencePolicy(2, admitted)
    var forged = quorumEntry(keyC, statement)
    forged.proof = flipLastByte(forged.proof)
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(keyB, statement),
                                      forged])
    let bundle = parseEdgeAttestationBundle(bundleText, "<bundle>")
    let ev = evaluateQuorum(bundle, claim, roster, HarnessNow)
    check ev.countedSigners.len == 2          # the threshold IS reached
    check ev.defects.len == 1                 # and it still rejects
    check ev.entries[2].outcome == qeoSignatureDidNotVerify

    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdRejected
    check "a threshold reached beside a forgery is a threshold an " &
      "attacker chose" in v.checks[vcEvidenceQuorum].detail

  test "a bundle about another manifest is refused by name":
    let policy = evidencePolicy(2, admitted)
    let otherClaim = claimForManifest(
      sampleManifestText(OtherVerityRootHash), "<other manifest>")
    let otherStatement = edgeStatementBytes(otherClaim)
    let bundleText = bundleOf(otherClaim,
      [quorumEntry(keyA, otherStatement), quorumEntry(keyB, otherStatement)])
    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdRejected
    check "the attestations are about the manifest " &
      otherClaim.manifestDigest in v.checks[vcEvidenceQuorum].detail

  test "the admitted set and the roster must name the same signers, " &
       "and each direction has its own refusal":
    # A fixture set constrained by its own gate: adding a signer to the
    # policy and not to the verifier must redden, and so must the
    # reverse.
    let statementBundle = bundleOf(claim, [quorumEntry(keyA, statement),
                                           quorumEntry(keyB, statement)])

    let widerPolicy = evidencePolicy(2,
      [signerName(keyA), signerName(keyB), signerName(keyC),
       signerName(outsider)])
    let missing = evidenceVerdict(widerPolicy, manifestText,
                                  statementBundle, roster)
    check missing.decision == vdRejected
    check "this verifier holds no public key for it" in
      missing.checks[vcEvidenceQuorum].detail
    check signerName(outsider) in missing.checks[vcEvidenceQuorum].detail

    let narrowerPolicy = evidencePolicy(2,
      [signerName(keyA), signerName(keyB)])
    let extra = evidenceVerdict(narrowerPolicy, manifestText,
                                statementBundle, roster)
    check extra.decision == vdRejected
    check "the policy admits no such signer" in
      extra.checks[vcEvidenceQuorum].detail
    check signerName(keyC) in extra.checks[vcEvidenceQuorum].detail

    # The two refusals are different sentences, so a case asserting one
    # cannot be satisfied by the other.
    check missing.checks[vcEvidenceQuorum].detail !=
      extra.checks[vcEvidenceQuorum].detail

  test "attestations supplied under a policy with no evidence clause " &
       "are a rejection, not a pass and not a shrug":
    let policy = tpmPolicy()          # pins a digest, states no evidence
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(keyB, statement)])
    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check v.decision == vdRejected
    check "evidence that was carried and never evaluated must not be " &
      "mistaken for evidence that was satisfied" in
      v.checks[vcEvidenceQuorum].detail

  test "a policy that accepts evidence and gets none says so":
    let policy = evidencePolicy(2, admitted)
    let v = evidenceVerdict(policy, manifestText, "", roster,
                            bundleSupplied = false)
    check v.checks[vcEvidenceQuorum].outcome == coFailed
    check "no edge attestations were supplied" in
      v.checks[vcEvidenceQuorum].detail

  test "with no evidence clause and no bundle the check is skipped, and " &
       "the unpinned decision it used to reach is unchanged":
    # The regression this new decision value could have caused: the old
    # hollow acceptance must still be reachable and must still be the
    # one a policy with no evidence clause gets.
    var noPin = tpmPolicy()
    noPin.measurements.manifests = @[]
    let v = evidenceVerdict(noPin, manifestText, "", @[],
                            bundleSupplied = false)
    check v.checks[vcEvidenceQuorum].outcome == coSkipped
    check v.decision == vdAcceptedUnpinnedManifest
    check ord(cli_attest.attestExitCodeFor(v.decision)) == 4
    check UnpinnedManifestCaveat in v.caveats

  test "an evidence-backed acceptance states what a quorum does not " &
       "establish, and drops the caveat that is no longer true":
    let policy = evidencePolicy(2, admitted)
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(keyB, statement)])
    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdAcceptedEvidenceBackedManifest
    check DistinctSignerCaveat in v.caveats
    # "authenticated by nothing but the fact that it was supplied" is
    # false of this verdict, and saying it anyway would be the same
    # class of error as omitting it when it is true.
    check UnpinnedManifestCaveat notin v.caveats
    check v.hasIdentity
    check v.identity.manifestDigest == claim.manifestDigest

  test "the two hollow-acceptance predicates are mutually exclusive":
    let policy = evidencePolicy(2, admitted)
    let bundleText = bundleOf(claim, [quorumEntry(keyA, statement),
                                      quorumEntry(keyB, statement)])
    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check identityRestsOnEvidenceBackedManifest(v.checks)
    check not identityRestsOnUnauthenticatedManifest(v.checks)

  test "a proof for a verifier this build does not implement is carried, " &
       "not counted, and named":
    let policy = evidencePolicy(2, admitted)
    let bundleText = bundleOf(claim,
      [quorumEntry(keyA, statement), quorumEntry(keyB, statement),
       EdgeAttestation(verifier: "zk-rebuild-proof.v9", proof: "aabb")])
    let v = evidenceVerdict(policy, manifestText, bundleText, roster)
    check v.decision == vdAcceptedEvidenceBackedManifest
    var named = false
    for c in v.caveats:
      if "zk-rebuild-proof.v9" in c: named = true
    check named

  test "every exit code this command can return is distinct, and the " &
       "new one is 5":
    var seen: seq[int] = @[]
    for d in VerdictDecision:
      let code = ord(cli_attest.attestExitCodeFor(d))
      check code notin seen
      seen.add code
    check ord(cli_attest.attestExitCodeFor(
      vdAcceptedEvidenceBackedManifest)) == 5

suite "the evidence clause is refused when it cannot bite":

  let keyA = newTestKey()
  let keyB = newTestKey()
  let names = [signerName(keyA), signerName(keyB)]

  proc refusal(text: string): string =
    try:
      discard parseAttestationPolicy(text, "<policy>")
      return ""
    except PolicyError as err:
      return err.msg

  test "a threshold of one is not a quorum":
    let msg = refusal(evidencePolicyText(1, names))
    check "a quorum is at least 2 signatures" in msg

  test "a threshold above the admitted set can never be reached":
    let msg = refusal(evidencePolicyText(3, names))
    check "the threshold can never be reached" in msg

  test "an empty admitted set is refused":
    let msg = refusal(evidencePolicyText(2, []))
    check "known_keys is empty" in msg

  test "a repeated signer would overstate N":
    let msg = refusal(evidencePolicyText(2, [names[0], names[0]]))
    check "states a larger N than it admits" in msg

  test "a signer named by anything but a key identifier is refused":
    let msg = refusal(evidencePolicyText(2, [names[0], "rebuilder-b.pem"]))
    check "is the KEY that is admitted, not a file that might hold one" in
      msg

  test "an evidence clause beside allow_mock decides nothing, and is " &
       "refused for it":
    let text = evidencePolicyText(2, names)
      .replace("tiers = [\"tpm\"]", "tiers = [\"mock\"]")
      .replace("backends = [\"tpm2\"]", "backends = [\"mock\"]")
      .replace("allow_mock = false", "allow_mock = true")
    let msg = refusal(text)
    # Pinned on the clause's OWN sentence, not on the shared closing
    # phrase: the allow_mock-beside-a-pinned-digest refusal ends the
    # same way, and a case satisfied by either would not be a case
    # about this one.
    check "[measurements.evidence] admits a manifest on the strength " &
      "of rebuilder signatures" in msg

  test "a well-formed clause parses into the values it states":
    let p = evidencePolicy(2, names, requireLog = true)
    check p.acceptsEvidence
    check p.requiresTransparencyLog
    check p.measurements.evidence.minSignatures == 2
    check p.measurements.evidence.knownKeys.len == 2
    # And a policy with no clause at all answers no to both, so the
    # predicates are not true by default.
    check not tpmPolicy().acceptsEvidence
    check not tpmPolicy().requiresTransparencyLog
