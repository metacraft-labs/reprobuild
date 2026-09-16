## One emulated attestation, assembled end to end, with one structured
## fault injected — wherever that fault belongs.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right.
##
## ## What a "run" is
##
## Everything four different surfaces need in order to reach a verdict
## about the same attestation: the report document, the policy, the
## measurement manifest, the trust anchors, the revocation lists, the
## challenge this verifier issued, when it issued it and what time it is
## now. Assembled once per fault so the four surfaces are compared on
## identical inputs — a differential test in which the inputs differ is
## a test of the harness.
##
## ## Where each fault is injected, and why that is not arbitrary
##
## ``EmulatorMutation.faultSite`` says whether a fault belongs to the
## evidence or to the verification, and this module reads that answer
## rather than keeping a second list. The six evidence faults are applied
## by the driver, inside bytes a signature covers; the five verification
## faults are applied here, to the document on the wire, to the policy the
## verifier was handed, to the challenge it expects, or to its clock.
##
## ``applyVerificationFault`` is a ``case`` over the whole enum with no
## ``else``, and it ``doAssert``s the site of every arm it acts on. So a
## fault cannot be added without a decision, and a fault cannot be
## claimed here that ``evidence_emulator`` already claims.
##
## ## The manifest is always the HONEST one
##
## It is built from ``emulatedEventLogTemplate(tampered = false)`` on
## every run, including the run whose emulator measures a tampered
## command line. That asymmetry is the measurement fault: the manifest
## says what the image produces and the evidence attests something else.
## A harness that rebuilt the manifest from the mutated template would
## produce two documents that agree, and agreement is what that fault
## exists to break.
##
## ## Mocking
##
## None. The report comes out of the production renderer, or off a real
## socket from the real agent; the policy and the manifest go through
## their own strict parsers.

import std/[options, strutils]

import repro_attest
import repro_attest_verify

import ./evidence_emulator

const
  EmulatorChallenge* = "5a6b7c8d9e0f1a2b3c4d5e6f708192a3" &
                       "b4c5d6e7f8091a2b3c4d5e6f70819200"
    ## 32 bytes, comfortably over the 128-bit floor.
  EmulatorOtherChallenge* = "00112233445566778899aabbccddeeff" &
                            "ffeeddccbbaa99887766554433221100"

  EmulatorGeneration* = "gen-emulated-0001"
  EmulatorFingerprint* = "reproos-attested-uefi:emulated"
  EmulatorVerityRootHash* =
    "7777777777777777777777777777777777777777777777777777777777777777"

  EmulatorTimestamp* = "2026-09-16T09:00:00Z"

  EmulatorChallengeWindowSeconds* = 120

  EmulatorPolicyTemplate* = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = true

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""
    ## The policy a verifier of measured-boot evidence would actually
    ## write: one tier, one backend, the manifest pinned by digest, a
    ## chain required and a challenge window that bites.

type
  EmulatedRun* = object
    mutation*: EmulatorMutation
    reportText*: string
    policyText*: string
    manifestText*: string
    anchorDer*: seq[string]
    crlDer*: seq[string]
    expectedChallengeHex*: string
    challengeIssuedAtMs*: int64
    nowMs*: int64
    distinguisher*: string
      ## A string that must appear in the detail of the check this fault
      ## is declared to trip, and in NO other fault's. For most faults it
      ## is a phrase only one refusal site produces; for the two that
      ## trip the same rule from opposite sides it is a VALUE, because a
      ## phrase could not tell them apart and a gate that could not tell
      ## them apart would keep passing after one of them stopped working.

proc emulatorClaims*(): UnverifiedClaims =
  UnverifiedClaims(
    unverifiedGeneration: EmulatorGeneration,
    unverifiedConfigFingerprint: EmulatorFingerprint,
    unverifiedVerityRootHash: EmulatorVerityRootHash)

proc emulatorManifest*(): AttestedImageManifest =
  ## The manifest the emulated image's build would publish.
  ##
  ## ``pcr11`` is REPLAYED from the template by the library rather than
  ## typed in, so the manifest's two halves cannot disagree by
  ## transcription — and the same template is what the emulator's event
  ## log is written from, so the manifest and the boot are one fact
  ## expressed twice.
  let tmpl = emulatedEventLogTemplate()
  AttestedImageManifest(
    configFingerprint: EmulatorFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("emulated-uki"),
      verityImage: DigestPrefix & sha256Hex("emulated-verity-image"),
      verityRootHash: EmulatorVerityRootHash),
    tpm: @[TpmExpectation(pcr11: replayEventLogTemplate(tmpl),
                          eventLogTemplate: tmpl)])

proc emulatorManifestText*(): string =
  renderAttestedImageManifest(emulatorManifest())

proc emulatorManifestDigest*(): string =
  DigestPrefix & sha256Hex(emulatorManifestText())

proc emulatorPolicyText*(digest = emulatorManifestDigest()): string =
  EmulatorPolicyTemplate.replace("@DIGEST@", digest)

# ---------------------------------------------------------------------
# Building the report the emulator would answer with
# ---------------------------------------------------------------------

proc emulatedReportText*(d: EmulatedTpm2Driver; challengeHex: string;
                         bindings = ReportBindings(purpose: bpAttest,
                                                   ephemeralPub: "")): string =
  ## The same two calls the agent makes: compute the 64 bytes from the
  ## challenge and the bindings, hand them to the driver through the
  ## seam's checked entry point, and render the envelope around what
  ## comes back.
  let reportDataHex = reportDataHexFor(bindings, challengeHex)
  let quote = acquireQuote(d, hexToBytes("reportData", reportDataHex))
  renderAttestationReport(attestationReport(abTpm2, EmulatorTimestamp,
    challengeHex, bindings, quote.evidence, emulatorClaims(),
    quote.certificates))

proc replaceJsonString(doc, key, replacement: string): string =
  ## Replace one string-valued field of a rendered report.
  ##
  ## This is what an active party on the wire can do: change bytes. It is
  ## deliberately a byte edit of the rendered document rather than a
  ## rebuild through the constructor, because a rebuilt document is a
  ## document this build agrees with, and the point of a transcript fault
  ## is a document it does not.
  let needle = "\"" & key & "\": \""
  let at = doc.find(needle)
  doAssert at >= 0, "the rendered report carries no " & key & " field"
  let valueStart = at + needle.len
  let valueEnd = doc.find('"', valueStart)
  doAssert valueEnd > valueStart, "the " & key & " field is not terminated"
  doc[0 ..< valueStart] & replacement & doc[valueEnd .. ^1]

proc substituteEphemeralKey*(reportText: string): tuple[text, bound: string] =
  ## Re-issue the envelope claiming a DIFFERENT ephemeral public key.
  ##
  ## The envelope stays internally consistent — its ``reportData`` is
  ## recomputed for the substituted key, so the parser accepts it — while
  ## the evidence inside still carries the bytes the instance actually
  ## bound. That is the whole of the fault: a key agreement whose
  ## published key is not the key the hardware spoke for, which is how a
  ## secret gets encrypted to an attacker's key under a genuine quote.
  ##
  ## Returns the document and the 64 bytes the ENVELOPE now claims, which
  ## is the value that tells this fault apart from a mutated nonce.
  let report = parseAttestationReport(reportText, "<emulated report>")
  let substituted = ReportBindings(
    purpose: report.bindings.purpose,
    ephemeralPub: sha256Hex("an attacker's ephemeral key"))
  doAssert substituted.ephemeralPub != report.bindings.ephemeralPub
  let text = renderAttestationReport(attestationReport(
    report.backend, EmulatorTimestamp, report.challenge, substituted,
    authoritativeEvidence(report), report.claims,
    (if report.hasBundledCertificates:
       some(report.certificatesForCrossCheck)
     else: none(seq[string]))))
  (text, reportDataHexFor(substituted, report.challenge))

# ---------------------------------------------------------------------
# The verification-layer faults
# ---------------------------------------------------------------------

proc applyVerificationFault*(run: var EmulatedRun) =
  ## The five faults a driver cannot inject, applied to the things a
  ## driver does not own.
  ##
  ## Every arm ``doAssert``s its own site against ``faultSite``, so this
  ## module and ``evidence_emulator`` cannot both claim a fault and
  ## neither can disclaim one.
  let m = run.mutation
  case m
  of emNone, emSignature, emChain, emMeasurement, emEventLog, emTcb,
     emNonce:
    doAssert faultSite(m) == fsEvidence,
      $m & " is not this module's to inject"
  of emPolicy:
    doAssert faultSite(m) == fsVerification
    # A policy pinning a manifest digest that is not the digest of the
    # manifest this verifier holds. Nothing about the machine changed;
    # the operator's own document is not the one they named in advance.
    let foreign = DigestPrefix & sha256Hex("a measurement manifest nobody " &
      "distributed")
    doAssert foreign != emulatorManifestDigest()
    run.policyText = emulatorPolicyText(foreign)
    run.distinguisher = foreign
  of emEphemeralKey:
    doAssert faultSite(m) == fsVerification
    let substituted = substituteEphemeralKey(run.reportText)
    run.reportText = substituted.text
    run.distinguisher = substituted.bound
  of emTranscript:
    doAssert faultSite(m) == fsVerification
    # The document is altered in transit. One field, chosen because the
    # envelope's own validator has a rule about it, so the fault lands on
    # the schema check and not on any of the four that read evidence.
    run.reportText = replaceJsonString(run.reportText, "timestamp",
      "the-seventeenth-of-never")
    run.distinguisher = "the-seventeenth-of-never"
  of emTime:
    doAssert faultSite(m) == fsVerification
    # The challenge is older than the policy's window by an order of
    # magnitude. The report is perfect and answers a question nobody is
    # still asking.
    run.challengeIssuedAtMs =
      run.nowMs - int64(EmulatorChallengeWindowSeconds) * 10_000
    # The distinguisher is the POLICY side of the refusal rather than the
    # measured age: the command line reads its own clock, so the age it
    # computes is a second or two past the one computed in process, and a
    # gate pinned to that number would be pinned to a race.
    run.distinguisher =
      "the policy accepts at most " & $EmulatorChallengeWindowSeconds & " s"
  of emReplay:
    doAssert faultSite(m) == fsVerification
    # A genuine report, replayed at a verifier that issued a different
    # challenge. Nothing in the document is wrong; it is an answer to
    # somebody else's question.
    run.expectedChallengeHex = EmulatorOtherChallenge
    run.distinguisher = EmulatorOtherChallenge

# ---------------------------------------------------------------------
# What each fault must trip
# ---------------------------------------------------------------------

const
  EmulatorFaultCount* = 11
    ## The structured faults this fixture set defines, not counting
    ## ``emNone``.
    ##
    ## Pinned as a VALUE and checked at run time, next to a list of the
    ## eleven spellings. The ``case`` functions below already stop a fault
    ## being added without a decision — but a build that does not compile
    ## measures nothing, so the enum is also constrained by something that
    ## can go red rather than only by something that can fail to build.

  EmulatorFaultNames*: array[EmulatorFaultCount, string] = [
    "signature", "chain", "measurement", "event-log", "tcb", "policy",
    "nonce", "ephemeral-key", "transcript", "time", "replay"]
    ## The eleven, spelled out. A name list rather than only a count: a
    ## count is satisfied by any eleven values, and renaming one of these
    ## is exactly the change that would leave a count green while the
    ## thing it names had gone.

type
  FaultDetection* = object
    ## What a fault must do to a verdict.
    caught*: bool
      ## ``false`` declares that NOTHING in this build catches it. That is
      ## an assertion and not a gap left open: a build that grew a rule
      ## for it would redden here and force the declaration to be
      ## corrected, which is the opposite of an absence nobody notices.
    check*: VerifierCheck
      ## The check that must FAIL. Meaningless when ``caught`` is false.
    failing*: set[VerifierCheck]
      ## Every check that must fail, as a value. The knock-on failures
      ## are part of the fault's signature: a reading that stops early
      ## leaves the checks downstream of it unable to be performed, and a
      ## gate that asserted only the first one would not notice the
      ## verifier starting to perform them anyway.

proc expectedDetection*(m: EmulatorMutation): FaultDetection =
  ## A total function over the enum, no ``else``.
  ##
  ## The ``failing`` sets are stated rather than derived, because they
  ## are the claim: "the signature fault trips the native-evidence check
  ## and takes the two checks that read its output with it" is a
  ## different statement from "something went wrong".
  case m
  of emNone:
    FaultDetection(caught: false, check: vcReportSchema, failing: {})
  of emTcb:
    # NOTHING in this build catches it. The tpm2 backend reports no
    # vendor trusted computing base, the policy grammar has no key for a
    # firmware-version floor, and `checkTcbFloor` is inapplicable for
    # this backend by construction. Declared, so it is visible.
    FaultDetection(caught: false, check: vcTcbFloor, failing: {})
  of emSignature:
    FaultDetection(caught: true, check: vcNativeEvidence,
      failing: {vcNativeEvidence, vcMeasurementMatch})
  of emChain:
    FaultDetection(caught: true, check: vcCertificateChain,
      failing: {vcCertificateChain})
  of emMeasurement:
    FaultDetection(caught: true, check: vcMeasurementMatch,
      failing: {vcMeasurementMatch})
  of emEventLog:
    FaultDetection(caught: true, check: vcNativeEvidence,
      failing: {vcNativeEvidence, vcMeasurementMatch})
  of emPolicy:
    FaultDetection(caught: true, check: vcManifestPinned,
      failing: {vcManifestPinned})
  of emNonce:
    FaultDetection(caught: true, check: vcReportDataBinding,
      failing: {vcReportDataBinding})
  of emEphemeralKey:
    FaultDetection(caught: true, check: vcReportDataBinding,
      failing: {vcReportDataBinding})
  of emTranscript:
    FaultDetection(caught: true, check: vcReportSchema,
      failing: {vcReportSchema, vcTierAccepted, vcBackendAccepted,
                vcNativeEvidence, vcReportDataBinding, vcChallengeMatch,
                vcChallengeFreshness, vcManifestPinned, vcMeasurementMatch,
                vcCertificateChain, vcTcbFloor})
  of emTime:
    FaultDetection(caught: true, check: vcChallengeFreshness,
      failing: {vcChallengeFreshness})
  of emReplay:
    FaultDetection(caught: true, check: vcChallengeMatch,
      failing: {vcChallengeMatch})

proc evidenceDistinguisher*(m: EmulatorMutation): string =
  ## The phrase the evidence-layer faults are told apart by. Each belongs
  ## to exactly one refusal site in the libraries, and the gate requires
  ## it to be absent from every other fault's detail.
  case m
  of emSignature: "does not verify under the public key of the leaf"
  of emChain: "these certificates are not links of one chain"
  of emMeasurement: "the manifest's tpm expectations are"
  of emEventLog: "does not reproduce the register digest"
  of emNonce: "" ## Supplied by value; see ``buildRun``.
  of emNone, emTcb: ""
  of emPolicy, emEphemeralKey, emTranscript, emTime, emReplay: ""

proc buildRun*(d: EmulatedTpm2Driver; mutation: EmulatorMutation;
               nowMs: int64;
               reportText = ""): EmulatedRun =
  ## Assemble one run. ``reportText`` may be supplied by a caller that
  ## obtained the document over a socket instead of from the renderer;
  ## the two are required to be identical elsewhere, which is what makes
  ## either acceptable here.
  result.mutation = mutation
  result.reportText =
    (if reportText.len > 0: reportText
     elif mutation == emEphemeralKey:
       # The ephemeral-key fault is a fault about a KEY AGREEMENT, and
       # the envelope refuses a key under the plain attest purpose — so
       # this run has to start from an agreement rather than from an
       # attestation with a key bolted on, which would be refused by the
       # binding discipline before the fault could be reached.
       emulatedReportText(d, EmulatorChallenge, ReportBindings(
         purpose: bpKeyAgreement,
         ephemeralPub: sha256Hex("the instance's own ephemeral key")))
     else: emulatedReportText(d, EmulatorChallenge))
  result.policyText = emulatorPolicyText()
  result.manifestText = emulatorManifestText()
  result.anchorDer = @[d.emulatedAnchorDer]
  result.crlDer = d.emulatedCrlDer
  result.expectedChallengeHex = EmulatorChallenge
  result.challengeIssuedAtMs = nowMs - 1_000
  result.nowMs = nowMs
  result.distinguisher = evidenceDistinguisher(mutation)
  if mutation == emNonce:
    # Told apart from the ephemeral-key fault by VALUE, because both trip
    # the same rule and its wording cannot distinguish them: one moves
    # the bytes inside the evidence and the other moves the bytes the
    # envelope claims, and the refusal names both. The value below is the
    # one only this fault produces.
    let report = parseAttestationReport(result.reportText, "<emulated>")
    result.distinguisher =
      bytesToHex(qualifyingData(tpm2EvidenceQuote(
        parseTpm2Evidence(authoritativeEvidence(report)))))
  applyVerificationFault(result)

proc verificationRequestFor*(run: EmulatedRun): VerificationRequest =
  ## The in-process shape of a run. The anchors and the revocation lists
  ## are parsed from DER here, exactly as the CLI parses them from files,
  ## so the two surfaces are handed the same trust store and not two
  ## spellings of one.
  result = VerificationRequest(
    reportText: run.reportText,
    reportSource: "<emulated report>",
    policy: parseAttestationPolicy(run.policyText, "<emulated policy>"),
    policySource: "<emulated policy>",
    manifestText: some(run.manifestText),
    manifestSource: "<emulated manifest>",
    expectedChallengeHex: run.expectedChallengeHex,
    challengeIssuedAtMs: some(run.challengeIssuedAtMs),
    nowMs: run.nowMs)
  for der in run.anchorDer: result.trustAnchors.add parseCertificateBytes(der)
  for der in run.crlDer: result.revocationLists.add parseCrlBytes(der)
