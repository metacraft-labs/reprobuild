## The policy is what decides whether a secret is released, and removing
## a manifest from it stops the next release immediately.
##
## ## What this gate proves
##
## The property has two halves, and they are different claims:
##
##   * **A measurement absent from policy yields no release.** The
##     machine attested, the evidence verified, the challenge matched —
##     and what it *measured* is not what the pinned manifest says that
##     image produces. No ciphertext is composed.
##   * **Removing a manifest stops subsequent releases.** The same
##     report, the same reading, the same secret, the same helper. The
##     only thing that changes between the release and the withholding
##     is the policy document, and the gate holds everything else fixed
##     so the attribution is the experiment rather than an assertion
##     about it.
##
## Both are run against a tier that HAS a root of trust, through the
## reading seam a downstream broker with its own reader would use. That
## matters: on the mock tier ``measurement-match`` is inapplicable and
## the first claim would have no input at all — a rule with no reachable
## input, which is the shape these reviews keep finding.
##
## ## And the audit hook, which is the third deliverable
##
## Every decision is recorded, including the ones that release nothing —
## a log containing only the releases cannot answer the question an
## auditor has. The record carries the four things the design names,
## ``(challenge, measurement, policy hash, verdict)``, and the gate
## checks the policy hash *changes* when the policy document does, since
## a digest that were constant would identify nothing.
##
## A sink that cannot write withholds the secret. That is asserted with
## a sink that raises, and the outcome is that the caller gets an
## exception and no ciphertext.
##
## ## Mocking
##
## The *reading* is supplied by the caller, exactly as
## ``attestation_verifier_harness`` supplies it to the six verifier gates
## beside this one, and for the same reason: this build carries no reader
## for tpm2 evidence and the measurement branch is otherwise unreachable.
## Every RULE exercised below is the shipped one. The audit sinks are
## inputs — one collects so a gate can read what was recorded, one
## refuses on purpose — not substitutes for anything.

import std/[json, options, os, strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attestation_verifier_harness
include ./provisioning_harness

const
  # 32 bytes, over the 128-bit floor. Distinct from the verifier
  # harness's own challenge so a report built here cannot accidentally
  # satisfy a check by sharing a constant with one built there.
  PolicyChallenge = "5e5e5e5e4d4d4d4d3c3c3c3c2b2b2b2b" &
                    "1a1a1a1a09090909f8f8f8f8e7e7e7e7"

  # A measurement no manifest in this file expects. It is a well-formed
  # register value — 64 lower-case hex characters — so what makes it
  # refused is that it is not the one, not that it is malformed.
  ForeignMeasurement =
    "dead9ea7dead9ea7dead9ea7dead9ea7dead9ea7dead9ea7dead9ea7dead9ea7"

  PolicySecretName = "broker-credential"

proc agreedTpmReport(pubHex: string; challengeHex = PolicyChallenge): string =
  ## A TPM-tier envelope for a key agreement. Built by the real renderer,
  ## which computes the 64 bytes from the challenge and the bindings, so
  ## the envelope agrees with itself by construction rather than by
  ## transcription.
  renderAttestationReport(attestationReport(abTpm2, SampleTimestamp,
    challengeHex,
    ReportBindings(purpose: bpKeyAgreement, ephemeralPub: pubHex),
    "opaque-tpm2-evidence-bytes", sampleClaims()))

proc agreedKey(tag: char): string =
  ## A public key that really has a private half, so a release composed
  ## against it is a release somebody could open. The seed is fixed so a
  ## failure here is reproducible from this file alone.
  bytesToHex(deriveKeyPair(repeat(tag, SeedBytes)).pk)

proc decide(reportText, policyText, measurement: string;
            manifestText: string;
            sink: AuditSink;
            secretName = PolicySecretName;
            challengeHex = PolicyChallenge;
            allowNoRootOfTrust = false;
            allowUnauthenticatedManifest = false): ReleaseOutcome =
  ## One decision, with the reading supplied. Everything a case varies is
  ## a parameter here, so two cases differing in one argument really do
  ## differ in one thing.
  let report = parseAttestationReport(reportText, "<policy gate report>")
  let req = provisionRelease(reportText, policyText, challengeHex,
    secretName = secretName,
    allowNoRootOfTrust = allowNoRootOfTrust,
    allowUnauthenticatedManifest = allowUnauthenticatedManifest,
    manifestText = some(manifestText))
  releaseSecretWithReading(req, report,
    tpmReading(measurement, report.reportData), sink, fixedSeed('p'))

suite "the policy decides whether a secret is released":

  test "t_provision_policy_gate_a_measurement_absent_from_policy_releases_nothing":
    ## The machine attested and the evidence verified. What it measured
    ## is not what the pinned manifest says that image produces, and
    ## that alone is the difference between the two decisions below.
    let manifest = sampleManifestText()
    let policy = tpmPolicyText(sampleManifestDigest())
    let report = agreedTpmReport(agreedKey('k'))

    let accepted = newCollectingSink()
    let released = decide(report, policy, sampleExpectedPcr11(), manifest,
                          accepted)
    check released.decision == rdReleased
    check released.verdict.decision == vdAccepted
    check released.verdict.checks[vcMeasurementMatch].outcome == coPassed
    check released.wrappedSecretBase64.len > 0

    let refused = newCollectingSink()
    let withheld = decide(report, policy, ForeignMeasurement, manifest,
                          refused)
    check withheld.decision == rdWithheld
    check withheld.verdict.decision == vdRejected
    check withheld.verdict.checks[vcMeasurementMatch].outcome == coFailed
    check withheld.wrappedSecretBase64.len == 0
    check withheld.provisionBody.len == 0

    # Everything else was equal: same report, same policy, same manifest,
    # same secret, same seed. The measurement is what moved.
    check released.audit.policyDigest == withheld.audit.policyDigest
    check released.audit.challengeHex == withheld.audit.challengeHex
    check released.audit.ephemeralPubHex == withheld.audit.ephemeralPubHex
    check released.audit.measurement != withheld.audit.measurement
    check withheld.audit.measurement == ForeignMeasurement

  test "t_provision_policy_gate_removing_a_manifest_stops_the_next_release":
    ## Revocation is policy-side: the pin comes out of the document and
    ## the very next release is withheld. Held fixed: the report, the
    ## reading, the manifest, the secret, the name, the seed.
    let manifest = sampleManifestText()
    let measurement = sampleExpectedPcr11()
    let report = agreedTpmReport(agreedKey('m'))

    let pinned = tpmPolicyText(sampleManifestDigest())
    let before = decide(report, pinned, measurement, manifest,
                        newCollectingSink())
    check before.decision == rdReleased
    check before.verdict.checks[vcManifestPinned].outcome == coPassed

    # (a) The pin replaced by someone else's. The manifest this verdict
    # read is no longer one the policy vouches for, and that is a
    # rejection rather than a caveat.
    let otherPin = tpmPolicyText(
      DigestPrefix & repeat("ab", 32))
    let replaced = decide(report, otherPin, measurement, manifest,
                          newCollectingSink())
    check replaced.decision == rdWithheld
    check replaced.verdict.decision == vdRejected
    check replaced.verdict.checks[vcManifestPinned].outcome == coFailed
    check replaced.wrappedSecretBase64.len == 0

    # (b) The pin removed outright. The verdict is still an ACCEPTANCE —
    # every check the policy requires was satisfied — and it is the one
    # whose identity came from a document nothing authenticated, so the
    # release helper withholds it by default. That is the case worth
    # having: "accepted" and "released" are not the same word.
    let unpinned = TpmPolicyTemplate.replace(
      "manifests = [\"@DIGEST@\"]", "manifests = []")
    let dropped = decide(report, unpinned, measurement, manifest,
                         newCollectingSink())
    check dropped.decision == rdWithheld
    check dropped.verdict.decision == vdAcceptedUnpinnedManifest
    check dropped.wrappedSecretBase64.len == 0

    # And it is the OPT-IN that was missing, not the evidence: the same
    # call with the posture declared releases.
    let declared = decide(report, unpinned, measurement, manifest,
                          newCollectingSink(),
                          allowUnauthenticatedManifest = true)
    check declared.decision == rdReleased

    # The three policies are three documents, and the record says which.
    check before.audit.policyDigest != replaced.audit.policyDigest
    check before.audit.policyDigest != dropped.audit.policyDigest
    check replaced.audit.policyDigest != dropped.audit.policyDigest
    check dropped.audit.policyDigest == declared.audit.policyDigest
    check before.audit.policyDigest == policyDigestOf(pinned)
    check before.audit.policyDigest.startsWith(DigestPrefix)

  test "t_provision_policy_gate_every_decision_is_recorded":
    ## The audit hook, and the reason it is a mechanism rather than a
    ## recommendation: a log that contains only the releases cannot
    ## answer the question an auditor has.
    let manifest = sampleManifestText()
    let pinned = tpmPolicyText(sampleManifestDigest())
    let report = agreedTpmReport(agreedKey('a'))
    let sink = newCollectingSink()

    discard decide(report, pinned, sampleExpectedPcr11(), manifest, sink)
    discard decide(report, pinned, ForeignMeasurement, manifest, sink)
    discard decide(report, pinned, sampleExpectedPcr11(), manifest, sink,
                   challengeHex = OtherChallenge)

    check sink.records.len == 3
    check sink.records[0].decision == rdReleased
    check sink.records[1].decision == rdWithheld
    check sink.records[2].decision == rdWithheld

    # Every field the design names is filled on BOTH branches, and none
    # of them is the type's zero value.
    for rec in sink.records:
      check rec.challengeHex.len >= 32
      check rec.measurement.len > 0
      check rec.policyDigest.startsWith(DigestPrefix)
      check rec.secretName == PolicySecretName
      check rec.ephemeralPubHex.len == EphemeralPublicKeyBytes * 2
      check rec.reason.len > 0
      let line = parseJson(renderAuditRecord(rec))
      check line["schema"].getStr == AttestationAuditSchema
      check line["decision"].getStr == $rec.decision
      check line["verdict"].getStr == $rec.verdict
      check line["measurement"].getStr == rec.measurement
      check line["policyDigest"].getStr == rec.policyDigest

    # The three reasons are three reasons. A single sentence covering
    # every withholding would tell an auditor nothing.
    check sink.records[0].reason != sink.records[1].reason
    check sink.records[1].reason != sink.records[2].reason
    check sink.records[2].reason.contains($vcChallengeMatch)

    # And the file sink really appends, one line per decision.
    let dir = volatileScratch("audit")
    defer: removeDir(dir)
    let logPath = dir / "release-audit.jsonl"
    let fileSink = newFileAuditSink(logPath)
    check fileSink.path == logPath
    discard decide(report, pinned, sampleExpectedPcr11(), manifest, fileSink)
    discard decide(report, pinned, ForeignMeasurement, manifest, fileSink)
    let lines = readFile(logPath).strip.splitLines
    check lines.len == 2
    check parseJson(lines[0])["decision"].getStr == $rdReleased
    check parseJson(lines[1])["decision"].getStr == $rdWithheld

  test "t_provision_policy_gate_a_decision_nobody_can_record_releases_nothing":
    let manifest = sampleManifestText()
    let pinned = tpmPolicyText(sampleManifestDigest())
    let report = agreedTpmReport(agreedKey('r'))

    # A sink that raises. The decision WAS a release — the same inputs
    # release against a collecting sink — and the secret does not leave
    # this call anyway.
    let control = decide(report, pinned, sampleExpectedPcr11(), manifest,
                         newCollectingSink())
    check control.decision == rdReleased

    let refusing = newRefusingSink()
    var raised = ""
    try:
      discard decide(report, pinned, sampleExpectedPcr11(), manifest,
                     refusing)
    except ReleaseError as err:
      raised = err.msg
    check raised.len > 0
    check refusing.calls == 1

    # No sink at all is refused before anything is verified.
    expect ReleaseError:
      discard releaseSecret(
        provisionRelease(report, pinned, PolicyChallenge), nil,
        fixedSeed('n'))

    # A sink that is a sink in type only. The base method raises rather
    # than discarding, so an embedding caller that subclassed `AuditSink`
    # and forgot the one method it has gets a refusal instead of a silent
    # release nobody logged.
    expect ReleaseError:
      discard releaseSecret(
        provisionRelease(report, pinned, PolicyChallenge), AuditSink(),
        fixedSeed('b'))

    # And the file sink will not be built without somewhere to append.
    expect ReleaseError: discard newFileAuditSink("")

  test "t_provision_policy_gate_a_release_needs_more_than_an_acceptance":
    ## The three release-side rules, each with its own input, and each
    ## reaching a DIFFERENT withholding reason. Two refusals sharing one
    ## sentence would be one refusal wearing two names.
    let manifest = sampleManifestText()
    let pinned = tpmPolicyText(sampleManifestDigest())
    let measurement = sampleExpectedPcr11()

    # (1) A report whose purpose binds no key. It verifies perfectly.
    let attestOnly = tpm2ReportText(PolicyChallenge)
    let noKey = decide(attestOnly, pinned, measurement, manifest,
                       newCollectingSink())
    check noKey.decision == rdWithheld
    check noKey.verdict.decision == vdAccepted
    check noKey.audit.ephemeralPubHex == ""
    check noKey.audit.reason.contains($bpKeyAgreement)

    # (2) A challenge this verifier did not issue. The policy here
    # requires one, so the verdict is a rejection too — but the release
    # helper reads the CHECK rather than the decision, which is what
    # makes it independent of the policy.
    let report = agreedTpmReport(agreedKey('c'))
    let wrongChallenge = decide(report, pinned, measurement, manifest,
                                newCollectingSink(),
                                challengeHex = OtherChallenge)
    check wrongChallenge.decision == rdWithheld
    check wrongChallenge.verdict.checks[vcChallengeMatch].outcome == coFailed
    check wrongChallenge.audit.reason.contains($vcChallengeMatch)

    # (3) A tier with no root of trust. A genuine acceptance, and not a
    # release without the opt-in that names what it gives up.
    let mockReport = renderAttestationReport(attestationReport(
      abMock, SampleTimestamp, PolicyChallenge,
      ReportBindings(purpose: bpKeyAgreement, ephemeralPub: agreedKey('d')),
      renderMockEvidence(reportDataHexFor(
        ReportBindings(purpose: bpKeyAgreement, ephemeralPub: agreedKey('d')),
        PolicyChallenge)),
      sampleClaims(), some(mockCertificateChain())))
    let rootless = releaseSecret(
      provisionRelease(mockReport, MockDevPolicy, PolicyChallenge,
                       secretName = PolicySecretName),
      newCollectingSink(), fixedSeed('q'))
    check rootless.verdict.decision == vdAcceptedNoRootOfTrust
    check rootless.decision == rdWithheld
    let optedIn = releaseSecret(
      provisionRelease(mockReport, MockDevPolicy, PolicyChallenge,
                       secretName = PolicySecretName,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('q'))
    check optedIn.decision == rdReleased

    # Four withholdings, four distinct reasons.
    var reasons: seq[string] = @[]
    for o in [noKey, wrongChallenge, rootless]:
      check o.audit.reason notin reasons
      reasons.add o.audit.reason
    check reasons.len == 3

  test "t_provision_policy_gate_a_verifier_that_issued_no_challenge_releases_nothing":
    ## The release-side challenge rule, with the input it needs.
    ##
    ## It had none. Under a policy that REQUIRES a challenge, a mismatch
    ## is already a rejection, and `withheldReason` then lists
    ## `challenge-match` among the failed checks — so deleting the
    ## release-side clause left a different refusal producing a reason
    ## containing the same words. Measured: GREEN on both gates.
    ##
    ## The input that separates them is a verifier that issued NO
    ## challenge under a policy that does not require one. Every check
    ## the policy requires is then satisfied, the verdict is an
    ## ACCEPTANCE — and a release must still not happen, because
    ## freshness is the whole of what separates a live instance from a
    ## recording of one.
    let manifest = sampleManifestText()
    # The parser refuses an age bound on a challenge the policy does not
    # require — there would be nothing to measure the age of — and it
    # refuses the key's absence too, so zero (which is how the schema
    # spells "no age bound") moves with it.
    let lax = tpmPolicyText(sampleManifestDigest()).replace(
      "max_challenge_age_seconds = 120\nrequire_challenge = true",
      "max_challenge_age_seconds = 0\nrequire_challenge = false")
    let report = agreedTpmReport(agreedKey('f'))

    let unchallenged = decide(report, lax, sampleExpectedPcr11(), manifest,
                              newCollectingSink(), challengeHex = "")
    check unchallenged.verdict.decision == vdAccepted
    check unchallenged.verdict.checks[vcChallengeMatch].outcome == coSkipped
    check unchallenged.decision == rdWithheld
    check unchallenged.wrappedSecretBase64.len == 0
    check unchallenged.audit.reason.contains($vcChallengeMatch)
    check unchallenged.audit.reason.contains("freshness")

    # The control, one argument apart: the same report, the same lax
    # policy, with the challenge this verifier actually issued.
    let challenged = decide(report, lax, sampleExpectedPcr11(), manifest,
                            newCollectingSink())
    check challenged.verdict.checks[vcChallengeMatch].outcome == coPassed
    check challenged.decision == rdReleased

  test "t_provision_policy_gate_every_withholding_has_its_own_sentence":
    ## `withheldReason`'s four arms, called directly, because one of them
    ## cannot be reached any other way: `releasesUnder(vdAccepted)` is
    ## unconditionally true, so a withholding never reaches that arm.
    ## Collapsing all four to one sentence was GREEN on both gates until
    ## this case existed.
    var req = provisionRelease(agreedTpmReport(agreedKey('g')),
                               tpmPolicyText(sampleManifestDigest()),
                               PolicyChallenge)
    var sentences: seq[string] = @[]
    for d in [vdRejected, vdAcceptedNoRootOfTrust,
              vdAcceptedUnpinnedManifest, vdAccepted]:
      var v: Verdict
      v.decision = d
      let s = withheldReason(v, req)
      check s.len > 0
      for prior in sentences:
        check not (s in prior)
        check not (prior in s)
      sentences.add s
    check sentences.len == 4
    check sentences[0].contains("the checks that failed are")
    check sentences[1].contains("nothing about a machine")
    check sentences[2].contains("pinned *nothing* about".replace("*", ""))
    check sentences[3].contains("that is a defect")

  test "t_provision_policy_gate_refuses_a_decision_it_could_not_record_honestly":
    ## What the helper will not even decide about, as distinct from what
    ## it withholds. Each of these would put nonsense in an audit log.
    let pinned = tpmPolicyText(sampleManifestDigest())
    let report = agreedTpmReport(agreedKey('e'))
    let sink = newCollectingSink()

    # No policy document: the record's `policyDigest` would identify
    # nothing.
    var req = provisionRelease(report, pinned, PolicyChallenge)
    req.policyText = ""
    expect ReleaseError: discard releaseSecret(req, sink, fixedSeed('x'))

    # No secret.
    req = provisionRelease(report, pinned, PolicyChallenge, secret = "")
    expect ReleaseError: discard releaseSecret(req, sink, fixedSeed('x'))

    # A name that could not become a file.
    req = provisionRelease(report, pinned, PolicyChallenge,
                           secretName = "../escape")
    expect ProvisionError: discard releaseSecret(req, sink, fixedSeed('x'))

    # None of them reached a decision, so none of them was recorded.
    check sink.records.len == 0

  test "t_provision_policy_gate_an_unparseable_report_is_still_a_recorded_decision":
    ## The path that has no reading at all. It must still produce a
    ## verdict, a record and no ciphertext — a decision that fell off the
    ## end of the function would be a release nobody logged.
    let sink = newCollectingSink()
    let outcome = releaseSecret(
      provisionRelease("{ not a report }", MockDevPolicy, PolicyChallenge,
                       secretName = PolicySecretName),
      sink, fixedSeed('u'))
    check outcome.decision == rdWithheld
    check outcome.verdict.decision == vdRejected
    check outcome.wrappedSecretBase64.len == 0
    check sink.records.len == 1
    check sink.records[0].measurement == NoMeasurement
    check sink.records[0].ephemeralPubHex == ""
    check sink.records[0].policyDigest == policyDigestOf(MockDevPolicy)
