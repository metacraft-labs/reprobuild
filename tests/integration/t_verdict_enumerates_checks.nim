## A verdict names every check it performed, and a check that was
## skipped is reported as skipped.
##
## ## Why this gate is written the way it is
##
## "The verifier reported everything" is the easiest claim in this
## codebase to make and the hardest to hold. A gate that verified one
## report and looked for eleven rows would stay green under a driver that
## recorded a skipped check as a pass, under a driver that silently
## dropped a check for one backend, and under a verdict type that let an
## early failure decide the outcome and made the remaining rows
## decoration.
##
## So the properties below are asserted about the *mechanism*, not about
## one transcript:
##
##   1. **The zero value of every enum is the unsafe-to-assume one.** A
##      record nobody wrote is ``not-reached``; a finding nobody filled
##      in is ``violated``; a decision nobody computed is ``rejected``.
##      The ordinals are pinned as literals, because "the first member"
##      is a property a reorder changes silently.
##   2. **The rule that turns a finding into an outcome is exhaustive and
##      one-way.** All six ``(kind, required)`` combinations are checked,
##      and the cross product is walked to establish that ``coPassed`` is
##      reachable from ``fkSatisfied`` and from nothing else. There is no
##      path from "could not be performed" to "passed".
##   3. **No single check can be dropped.** Every position in the enum is
##      cleared in turn, and each one alone turns an accepted verdict into
##      a rejection.
##   4. **The same check, the same report, two policies.** Whether a
##      check that could not be performed is a skip or a failure is
##      decided by the policy and not by the check, which is shown by
##      changing only the policy.
##   5. **The claims cannot move the decision.** A report whose claims
##      contradict the manifest reaches the same verdict, and the
##      disagreement is reported where it cannot be mistaken for a
##      finding.
##   6. **The package boundary the verifier exists for.** The compiled
##      module closure of this library is walked and refused an edge into
##      the attestation agent.
##
## ## Mocking
##
## None. The reading supplied to the embedding seam in the TPM cases is
## the caller's own, which is what that seam is: a downstream broker
## bringing a reader this build does not carry. The verdict records whose
## reading it was and caveats it, and those two facts are asserted here.

import std/[options, os, strutils, tables, unittest]

import repro_attest
import repro_attest_verify

include ./attestation_verifier_harness

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

proc countChecks(): int =
  for chk in VerifierCheck: inc result

proc renderedRows(text: string): Table[string, string] =
  ## The rows of the rendered verdict's `checks:` table, and ONLY those —
  ## one table, and each check named in it once.
  ##
  ## Scoped deliberately. Asserting that a check's name appears somewhere
  ## in the rendered text is satisfied by the caveats section, which names
  ## every skipped check — so a renderer that dropped the skipped rows
  ## from the table would stay green. That mutation was run, and it did.
  ##
  ## Scoping alone is not enough, which was also measured. A table is a
  ## last-writer-wins map, so a renderer that emitted a row twice, or a
  ## second `checks:` block further down the document, would have the
  ## assertions below read its *last* answer while an operator reading
  ## top-down met its first. Three mutations exploited exactly that and
  ## stayed green: every row emitted twice, the whole table emitted
  ## twice, and a table of eleven `passed` rows followed by a truthful
  ## block appended after the caveats. So a repeated row and a second
  ## table are REFUSED here rather than collapsed — the same refusal
  ## ``Verdict.record`` makes for a check answered twice, and for the
  ## same reason: the second answer would silently replace the first.
  result = initTable[string, string]()
  var inChecks = false
  var tablesSeen = 0
  for line in text.splitLines:
    if line == "checks:":
      inChecks = true
      inc tablesSeen
      doAssert tablesSeen == 1,
        "the rendered verdict opens a second `checks:` table; a document " &
          "with two of them can show an operator one answer and this " &
          "parser another"
      continue
    if not inChecks: continue
    if not line.startsWith("  "):
      inChecks = false
      continue
    let fields = line.strip().splitWhitespace()
    if fields.len >= 2:
      doAssert fields[0] notin result,
        "the rendered verdict names the check " & fields[0] & " twice in " &
          "its table; whichever row is read second would silently replace " &
          "the row an operator reads first"
      result[fields[0]] = fields[1]

# `tpmReading` and `tpmVerdict` — the embedding seam this gate drives —
# live in the shared harness above, because a second gate drives the same
# seam and two spellings of "what a caller-supplied reading looks like"
# would be two opinions about it.

suite "a verdict enumerates every check, and a skip is never a pass":

  # -- 1. the zero values ---------------------------------------------

  test "the zero value of every enum is the fail-closed one":
    # Pinned as literal ordinals. "The first member" is a property a
    # reorder changes without a word, and every fail-closed default in
    # this module rests on it.
    check ord(coNotReached) == 0
    check ord(fkViolated) == 0
    check ord(vdRejected) == 0
    check $coNotReached == "not-reached"
    check $vdRejected == "rejected"

  test "a verdict nobody wrote rejects, and every row says not-reached":
    var v: Verdict
    for chk in VerifierCheck:
      check v.checks[chk].outcome == coNotReached
      check not v.checks[chk].performed
    check decisionFor(v.checks, atCvm) == vdRejected
    check decisionFor(v.checks, atMock) == vdRejected
    check decisionFor(v.checks, atTpm) == vdRejected
    v.seal(atCvm)
    check v.decision == vdRejected

  # -- 2. the outcome rule --------------------------------------------

  test "the six combinations of finding and requirement":
    proc rec(kind: FindingKind; required: bool): CheckRecord =
      CheckRecord(performed: true, kind: kind, required: required,
                  detail: "x")
    check rec(fkSatisfied, true).outcome == coPassed
    check rec(fkSatisfied, false).outcome == coPassed
    check rec(fkViolated, true).outcome == coFailed
    check rec(fkViolated, false).outcome == coFailed
    # The two that carry the whole honesty story.
    check rec(fkInapplicable, true).outcome == coFailed
    check rec(fkInapplicable, false).outcome == coSkipped

  test "coPassed is reachable from fkSatisfied and from nothing else":
    # The cross product, walked rather than enumerated by hand, so a
    # third finding kind added later cannot quietly acquire a path to a
    # pass.
    for kind in FindingKind:
      for required in [false, true]:
        for performed in [false, true]:
          let rec = CheckRecord(performed: performed, kind: kind,
                                required: required, detail: "x")
          if rec.outcome == coPassed:
            check performed
            check kind == fkSatisfied

  test "a skipped check is never spelled as a passed one":
    for kind in FindingKind:
      for required in [false, true]:
        let rec = CheckRecord(performed: true, kind: kind,
                              required: required, detail: "x")
        if rec.outcome == coSkipped:
          check kind == fkInapplicable
          check not required

  test "record refuses a finding with no explanation, and a second answer":
    var v: Verdict
    expect VerdictError:
      v.record(vcReportSchema, true, CheckFinding(kind: fkSatisfied,
                                                  detail: ""))
    v.record(vcReportSchema, true, satisfied("ok"))
    expect VerdictError:
      v.record(vcReportSchema, true, satisfied("ok again"))

  # -- 3. no check can be dropped -------------------------------------

  test "clearing any single check turns an acceptance into a rejection":
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let accepted = verifyAttestationReport(verificationRequest(
      mockReportText(), dev, some(sampleManifestText())))
    check accepted.decision.isAcceptance
    var cleared = 0
    for chk in VerifierCheck:
      var v = accepted
      v.checks[chk] = CheckRecord()
      check decisionFor(v.checks, atMock) == vdRejected
      inc cleared
    check cleared == countChecks()
    check cleared == 11

  # -- the two acceptances, and their rows ----------------------------

  test "an accepted mock verdict carries a row for every check, in order":
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(
      mockReportText(), dev, some(sampleManifestText())))
    check v.decision == vdAcceptedNoRootOfTrust
    var seen = 0
    for chk in VerifierCheck:
      check v.checks[chk].performed
      check v.checks[chk].outcome != coNotReached
      check v.checks[chk].detail.len > 0
      inc seen
    check seen == 11

    let text = renderVerdictText(v)
    let json = renderVerdictJson(v)
    # The TABLE, not the document: each row named, each carrying the
    # outcome its record holds, and exactly eleven of them.
    let rows = renderedRows(text)
    check rows.len == 11
    for chk in VerifierCheck:
      check rows.hasKey($chk)
      if rows.hasKey($chk):
        check rows[$chk] == $v.checks[chk].outcome
      check ("\"check\": \"" & $chk & "\"") in json
    check json.count("\"check\":") == 11
    check text.count("not-reached") == 0
    check json.count("\"not-reached\"") == 0

  test "the rows that are skipped say skipped, and say why":
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(
      mockReportText(), dev, some(sampleManifestText())))
    let skipped = v.skippedChecks
    # Three, and each for a reason the policy authorised: no manifest is
    # pinned, the mock backend measures nothing, and no chain is
    # required of it beyond being the published non-genuine one.
    check vcManifestPinned in skipped
    check vcMeasurementMatch in skipped
    check vcTcbFloor in skipped
    let rows = renderedRows(renderVerdictText(v))
    for chk in skipped:
      check v.checks[chk].kind == fkInapplicable
      check not v.checks[chk].required
      check v.checks[chk].outcome == coSkipped
      check v.checks[chk].outcome != coPassed
      # …and the rendering says so too, in the row rather than only in
      # the caveat beneath it.
      check rows.hasKey($chk)
      if rows.hasKey($chk): check rows[$chk] == "skipped"
    check v.failedChecks.len == 0
    check v.checksWith(coPassed).len + skipped.len == 11

  # -- 4. the same check, the same report, two policies ---------------

  test "whether a skip is a skip is the policy's to say, not the check's":
    # `certificate-chain` on a report that bundles no chain. One report,
    # two policies, and the finding underneath is the same
    # `fkInapplicable` in both: only `required` moves.
    let noChain = tpm2ReportText()          # tpm2 reports bundle none here
    let lenient = parseAttestationPolicy(tpmPolicyText(), "<lenient>")
    doAssert tpmPolicyText().count("require_certificates = false") == 1
    let strict = parseAttestationPolicy(
      tpmPolicyText().replace("require_certificates = false",
                              "require_certificates = true"), "<strict>")

    let report = parseAttestationReport(noChain, "<tpm report>")
    let reading = tpmReading(sampleExpectedPcr11(), report.reportData)

    var reqA = verificationRequest(noChain, lenient, some(sampleManifestText()))
    let vLenient = verifyWithReading(reqA, report, reading)
    check vLenient.checks[vcCertificateChain].outcome == coSkipped
    check not vLenient.checks[vcCertificateChain].required
    check vLenient.decision == vdAccepted

    var reqB = verificationRequest(noChain, strict, some(sampleManifestText()))
    let vStrict = verifyWithReading(reqB, report, reading)
    check vStrict.checks[vcCertificateChain].outcome == coFailed
    check vStrict.checks[vcCertificateChain].required
    check vStrict.decision == vdRejected
    # …and it is the check's OWN branch that refuses, not merely the
    # requirement flag turning a skip into a failure. Both spell
    # `coFailed`, so without this the branch was removable in silence.
    check vStrict.checks[vcCertificateChain].kind == fkViolated
    check "the policy requires a bundled certificate chain" in
      vStrict.checks[vcCertificateChain].detail

  test "a required check that could not be performed fails, and says so":
    # `challenge-freshness` under a policy that sets a window, with no
    # issuance instant supplied. The finding is `fkInapplicable` and the
    # outcome is a FAILURE: a window a verifier cannot apply is not a
    # window it may waive.
    let policy = parseAttestationPolicy(tpmPolicyText(), "<tpm>")
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, some(sampleManifestText()),
      issuedAtMs = none(int64))
    let v = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))
    check v.checks[vcChallengeFreshness].kind == fkInapplicable
    check v.checks[vcChallengeFreshness].required
    check v.checks[vcChallengeFreshness].outcome == coFailed
    check "not told when the challenge was issued" in
      v.checks[vcChallengeFreshness].detail
    check v.decision == vdRejected

  # -- a full, unqualified acceptance ---------------------------------

  test "a matching launch measurement establishes an identity":
    let policy = tpmPolicy()
    let v = tpmVerdict(sampleExpectedPcr11(), sampleManifestText(), policy)
    check v.decision == vdAccepted
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.checks[vcManifestPinned].outcome == coPassed
    check v.hasIdentity
    # Taken from the MANIFEST, which is the only place §5.3 lets it come
    # from.
    check v.identity.configFingerprint == sampleManifest().configFingerprint
    check v.identity.verityRootHash ==
      sampleManifest().imageOutputs.verityRootHash
    check v.identity.manifestDigest == sampleManifestDigest()
    check "establishes:" in renderVerdictText(v)

  test "a launch measurement the manifest does not contain is refused":
    let policy = tpmPolicy()
    let wrong =
      "0000000000000000000000000000000000000000000000000000000000000000"
    let v = tpmVerdict(wrong, sampleManifestText(), policy)
    check v.checks[vcMeasurementMatch].outcome == coFailed
    check wrong in v.checks[vcMeasurementMatch].detail
    check v.decision == vdRejected
    check not v.hasIdentity

  test "a launch measurement with no manifest to compare it to fails":
    # The branch below this one — "the manifest computed no expectation"
    # — would also refuse, so without this case the two were
    # indistinguishable and the clearer message was removable.
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, none(string))
    let v = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))
    check v.checks[vcMeasurementMatch].outcome == coFailed
    check "was given no measurement manifest" in
      v.checks[vcMeasurementMatch].detail
    check v.checks[vcManifestPinned].outcome == coFailed
    check v.decision == vdRejected

  test "a manifest the policy does not pin is refused":
    # Same measurement, same report, a manifest the policy's digest list
    # does not name. The comparison still matches — and the verdict is a
    # rejection, because the document it matched against is not one this
    # verifier was told to trust.
    let policy = tpmPolicy(sampleManifestDigest(OtherVerityRootHash))
    let v = tpmVerdict(sampleExpectedPcr11(), sampleManifestText(), policy)
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.checks[vcManifestPinned].outcome == coFailed
    check "does not pin" in v.checks[vcManifestPinned].detail
    check v.decision == vdRejected
    check not v.hasIdentity

  test "an outside reader is named in the verdict and earns a caveat":
    let policy = tpmPolicy()
    let v = tpmVerdict(sampleExpectedPcr11(), sampleManifestText(), policy)
    var caveated = false
    for c in v.caveats:
      if "downstream tpm2 reader" in c and "not a reader this build" in c:
        caveated = true
    check caveated

  test "a reading cannot re-write the envelope it is a reading of":
    # The embedding seam hands in five facts a reader produces. Tier,
    # backend, challenge and bindings are re-projected from the report,
    # so a reading that disagrees about them changes nothing.
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var reading = tpmReading(sampleExpectedPcr11(), report.reportData)
    reading.inputs.tier = atCvm
    reading.inputs.backend = abSevSnp
    reading.inputs.challengeHex = OtherChallenge
    var req = verificationRequest(text, policy, some(sampleManifestText()))
    let v = verifyWithReading(req, report, reading)
    check v.decision == vdAccepted
    check "tpm2" in v.checks[vcBackendAccepted].detail
    check "sev-snp" notin v.checks[vcBackendAccepted].detail
    check v.checks[vcChallengeMatch].outcome == coPassed

  test "a report edited after parsing is still put through the schema":
    # `verifyAttestationReport` reaches the driver with a report its own
    # parser accepted, so the schema row would be a check that cannot
    # fail if it were inherited rather than performed. This is the other
    # entry point: a record edited after parsing, which is what an
    # embedding caller can hand in.
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    var report = parseAttestationReport(text, "<tpm report>")
    let reading = tpmReading(sampleExpectedPcr11(), report.reportData)
    report.reportData = repeat('0', report.reportData.len)
    var req = verificationRequest(text, policy, some(sampleManifestText()))
    let v = verifyWithReading(req, report, reading)
    check v.checks[vcReportSchema].outcome == coFailed
    check "disagrees with itself" in v.checks[vcReportSchema].detail
    check v.decision == vdRejected
    # And every other row still answers, so the enumeration survives a
    # failure in the first check.
    for chk in VerifierCheck:
      check v.checks[chk].outcome != coNotReached

  test "an anonymous reading is refused":
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, some(sampleManifestText()))
    var reading = tpmReading(sampleExpectedPcr11(), report.reportData,
                             reader = "")
    expect VerdictError:
      discard verifyWithReading(req, report, reading)

  # -- the checks whose failing branch nothing else reaches -----------

  test "a backend this build cannot read is refused, not skipped":
    let prod = parseAttestationPolicy(productionPolicyText(), "<prod>")
    let v = verifyAttestationReport(verificationRequest(
      sevSnpReportText(), prod, some(sampleManifestText())))
    check v.checks[vcNativeEvidence].outcome == coFailed
    check v.checks[vcNativeEvidence].kind == fkViolated
    check "carries no reader for" in v.checks[vcNativeEvidence].detail
    check "a verdict on evidence nothing read" in
      v.checks[vcNativeEvidence].detail
    check v.decision == vdRejected
    # The tier and the backend are ACCEPTED by this policy, so nothing
    # but the unreadable evidence decided it.
    check v.checks[vcTierAccepted].outcome == coPassed
    check v.checks[vcBackendAccepted].outcome == coPassed

  test "mock evidence that does not verify is refused":
    # The mock reader's failing branch: a mock-backend envelope whose
    # evidence is not a `reproos.mock-evidence.v1` document at all.
    let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
    let text = renderAttestationReport(attestationReport(abMock,
      "2026-09-11T09:00:00Z", HarnessChallenge, bindings,
      "this is not mock evidence", sampleClaims()))
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(text, dev,
      some(sampleManifestText())))
    check v.checks[vcNativeEvidence].outcome == coFailed
    check "did not verify" in v.checks[vcNativeEvidence].detail
    check v.decision == vdRejected
    # The report data could not be checked against the signed bytes
    # either, and that is a FAILURE rather than a waiver.
    check v.checks[vcReportDataBinding].kind == fkInapplicable
    check v.checks[vcReportDataBinding].required
    check v.checks[vcReportDataBinding].outcome == coFailed

  test "a reader that finds no report data cannot support a verdict":
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var reading = tpmReading(sampleExpectedPcr11(), report.reportData)
    reading.inputs.reportDataInEvidence = none(string)
    var req = verificationRequest(text, policy, some(sampleManifestText()))
    let v = verifyWithReading(req, report, reading)
    check v.checks[vcReportDataBinding].kind == fkInapplicable
    check v.checks[vcReportDataBinding].required
    check v.checks[vcReportDataBinding].outcome == coFailed
    check "located no report data" in v.checks[vcReportDataBinding].detail
    check v.decision == vdRejected

  test "verifying with no challenge at all is a failure, not a waiver":
    let policy = tpmPolicy()
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, some(sampleManifestText()),
      challengeHex = "")
    let v = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))
    check v.checks[vcChallengeMatch].kind == fkInapplicable
    check v.checks[vcChallengeMatch].required
    check v.checks[vcChallengeMatch].outcome == coFailed
    check "no challenge to match" in v.checks[vcChallengeMatch].detail
    check v.decision == vdRejected

  test "the SEV-SNP TCB floor bites, component by component":
    let prod = parseAttestationPolicy(productionPolicyText(), "<prod>")
    let text = sevSnpReportText()
    let report = parseAttestationReport(text, "<snp report>")

    proc snpVerdict(tcb: SevSnpTcbMinimum): Verdict =
      var inputs: AuthoritativeInputs
      inputs.readerName = "downstream snp reader"
      inputs.reportDataInEvidence = some(report.reportData)
      inputs.sevSnpTcb = some(tcb)
      var req = verificationRequest(text, prod, some(sampleManifestText()))
      verifyWithReading(req, report, EvidenceReading(
        finding: satisfied("a report signed by the vendor's key"),
        inputs: inputs))

    # The policy's floor is bootloader 4, tee 0, snp 22, microcode 213.
    let atFloor = SevSnpTcbMinimum(bootloader: 4, tee: 0, snp: 22,
                                   microcode: 213)
    check snpVerdict(atFloor).checks[vcTcbFloor].outcome == coPassed
    check snpVerdict(SevSnpTcbMinimum(bootloader: 9, tee: 3, snp: 30,
      microcode: 255)).checks[vcTcbFloor].outcome == coPassed

    for below in [SevSnpTcbMinimum(bootloader: 3, tee: 0, snp: 22,
                                   microcode: 213),
                  SevSnpTcbMinimum(bootloader: 4, tee: 0, snp: 21,
                                   microcode: 213),
                  SevSnpTcbMinimum(bootloader: 4, tee: 0, snp: 22,
                                   microcode: 212)]:
      let v = snpVerdict(below)
      check v.checks[vcTcbFloor].outcome == coFailed
      check "below the policy's floor" in v.checks[vcTcbFloor].detail
      check v.decision == vdRejected

    # And a CVM report whose reader supplied no TCB at all fails rather
    # than skipping, because the tier requires the check.
    var noTcb: AuthoritativeInputs
    noTcb.readerName = "downstream snp reader"
    noTcb.reportDataInEvidence = some(report.reportData)
    var req = verificationRequest(text, prod, some(sampleManifestText()))
    let v = verifyWithReading(req, report, EvidenceReading(
      finding: satisfied("signed"), inputs: noTcb))
    check v.checks[vcTcbFloor].kind == fkInapplicable
    check v.checks[vcTcbFloor].required
    check v.checks[vcTcbFloor].outcome == coFailed

  test "the mock chain description refuses each way a chain can lie":
    proc described(chain: seq[string]): CheckFinding =
      describeMockChain(AuthoritativeInputs(bundledCertificates: true,
                                            certificates: chain))
    let real = mockCertificateChain()
    # The control: the published chain is accepted, and the finding says
    # what it is worth.
    check described(real).kind == fkSatisfied
    check "vouches for nothing" in described(real).detail
    # A chain of one. The published non-genuine chain is a leaf, an
    # intermediate and a self-signed root; anything shorter is not it.
    check described(@[real[0]]).kind == fkViolated
    check "element(s)" in described(@[real[0]]).detail
    # An element that is not in the mock certificate format at all.
    check described(@[real[0], "-----BEGIN CERTIFICATE-----\n"]).kind ==
      fkViolated
    # A chain whose root has stopped saying it is not a trust anchor.
    var renamed = real
    renamed[^1] = renamed[^1].replace(NonAnchorMarker, "AMD-SEV-Root-CA")
    check described(renamed).kind == fkViolated
    check "does not name itself" in described(renamed).detail

  test "the non-anchor marker is a literal, and the backend still says it":
    # A check that compares a value against the constant that produced
    # it passes however that constant is renamed. So the verifier holds
    # its own literal, and the agreement between the two is what is
    # asserted.
    check NonAnchorMarker == "NOT-A-TRUST-ANCHOR"
    check MockCertificateMarker == "reproos.mock-certificate.v1"
    check NonAnchorMarker in MockRootName
    check MockCertificateSchema == MockCertificateMarker

  # -- 5. the claims cannot move a decision ---------------------------

  test "claims that contradict the manifest change nothing but the notes":
    let policy = tpmPolicy()
    let honest = tpmVerdict(sampleExpectedPcr11(), sampleManifestText(),
                            policy)
    check honest.decision == vdAccepted

    let lyingText = tpm2ReportText(claims = UnverifiedClaims(
      unverifiedGeneration: "gen-i-made-up",
      unverifiedConfigFingerprint: "not-the-manifests-fingerprint",
      unverifiedVerityRootHash: OtherVerityRootHash))
    let report = parseAttestationReport(lyingText, "<lying claims>")
    var req = verificationRequest(lyingText, policy,
                                  some(sampleManifestText()))
    let v = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))

    # Same decision, and the same identity — which comes from the
    # manifest, not from what the machine said about itself.
    check v.decision == vdAccepted
    check v.identity.verityRootHash == SampleVerityRootHash
    check v.identity.verityRootHash != OtherVerityRootHash
    check v.identity.configFingerprint == sampleManifest().configFingerprint
    for chk in VerifierCheck:
      check v.checks[chk].outcome == honest.checks[chk].outcome

    # And the disagreement is reported, where it cannot be mistaken for
    # a finding.
    var sawDisagreement = false
    for note in v.claimNotes:
      if "DISAGREES" in note: sawDisagreement = true
      check note.startsWith("unverified ")
    check sawDisagreement
    check "no part of this verdict rests on them" in renderVerdictText(v)

  # -- an unparseable report still enumerates ------------------------

  test "a report that does not parse still answers every check":
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(
      "{ not a report }", dev, some(sampleManifestText())))
    check v.decision == vdRejected
    for chk in VerifierCheck:
      check v.checks[chk].performed
      check v.checks[chk].outcome == coFailed
    check v.checks[vcReportSchema].kind == fkViolated
    check v.checks[vcTierAccepted].kind == fkInapplicable
    check renderVerdictJson(v).count("\"check\":") == 11

  # -- 6. the package boundary ---------------------------------------

  test "the verifier's module closure reaches the schemas, not the agent":
    let libs = RepoRoot / "libs"
    let entry = libs / "repro_attest_verify" / "src" / "repro_attest_verify.nim"
    check fileExists(entry)
    let closure = moduleClosure(libs, entry)

    # The positive control FIRST. A walker that resolved nothing would
    # return one entry and satisfy every negative below it.
    var names: seq[string] = @[]
    for path in closure: names.add path.extractFilename
    for wanted in ["policy.nim", "verdict.nim", "evidence.nim",
                   "challenge.nim", "verify.nim", "repro_attest.nim",
                   "report.nim", "manifest.nim", "binding.nim",
                   "driver.nim", "mock_backend.nim", "measurement.nim"]:
      check wanted in names
    check closure.len >= 13

    # The boundary this library exists for: the agent sits inside every
    # attested trusted computing base, and a verdict must not come to
    # depend on its internals.
    for path in closure:
      check "repro_attest_agent" notin path

    # And the verifier proper opens no socket: `fetch` is the command
    # line's, and nothing under `verify` reaches it.
    for path in closure:
      check path.extractFilename != "fetch.nim"
