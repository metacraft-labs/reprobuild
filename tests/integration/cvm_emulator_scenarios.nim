## One emulated confidential-computing attestation, assembled end to
## end, with one structured fault injected — wherever that fault
## belongs.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right.
##
## ## What a "run" is
##
## Everything four surfaces need in order to reach a verdict about the
## same attestation: the report document, the policy, the measurement
## manifest, the vendor's revocation lists, the challenge this verifier
## issued, when it issued it and what time it is now. Assembled once per
## fault so the surfaces are compared on identical inputs — a
## differential test in which the inputs differ is a test of the
## harness.
##
## ## The baseline is a REJECTION, and that is the point rather than a
## ## shortcoming
##
## Neither confidential-computing chain evaluator in this build can be
## made to accept a chain that does not reach the vendor's own root, in
## any build, by any configuration — see ``cvm_evidence_emulator``'s
## header. So no emulated report here is ever accepted, and a gate that
## only compared accept/reject would be comparing four ways of saying
## no.
##
## What is compared instead is the whole **check vector**: thirteen
## rows, each with its own outcome. Two of them are SKIPPED on every
## run here — the policy states no evidence clause and requires no
## transparency-log inclusion — and of the eleven that are performed,
## every one except the structural rows PASSES: the signature over the
## report verifies under the bundled endorsement key, the measurement
## equals the manifest's expectation, the 64 bound bytes are the ones
## the challenge and the bindings produce, the challenge is fresh and
## the manifest is the one the policy pinned. That is the non-vacuity
## control: a verifier that refused everything would fail those rows
## too.
##
## ``cvmBaselineFailures`` states the structural rows per backend, as a
## value. A build that grew a way to accept one of them would redden
## here, which is the opposite of a gap nobody notices.
##
## ## The manifest is always the HONEST one
##
## It is built from the measurement the CALLER computed with the real
## calculator, on every run, including the run whose emulator reports a
## different one. That asymmetry is the measurement fault.
##
## ## Mocking
##
## None. The report comes out of the production renderer, or off a real
## socket from the real agent; the policy and the manifest go through
## their own strict parsers.

import std/[options, strutils]

import repro_attest
import repro_attest_verify
import repro_attest_verify/tdx_quote

import ./cvm_evidence_emulator

const
  CvmChallenge* = "9e8d7c6b5a4938271605f4e3d2c1b0a9" &
                  "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    ## 32 bytes, comfortably over the 128-bit floor.
  CvmOtherChallenge* = "1122334455667788" & "99aabbccddeeff00" &
                       "00ffeeddccbbaa99" & "8877665544332211"

  CvmGeneration* = "gen-emulated-cvm-0001"
  CvmFingerprint* = "reproos-attested-cvm:emulated"
  CvmVerityRootHash* =
    "5555555555555555555555555555555555555555555555555555555555555555"

  CvmTimestamp* = "2026-09-16T09:00:00Z"

  CvmChallengeWindowSeconds* = 120

  SnpPolicyTemplate* = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["sev-snp"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = true

[tcb]
sev-snp.min_tcb = { bootloader = 3, tee = 0, snp = 22, microcode = 213 }
allow_grace_days = 14

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""
    ## The policy an operator of a security-processor fleet would
    ## actually write: one tier, one backend, the manifest pinned by
    ## digest, a chain required, a platform-version floor at the version
    ## the emulated part reports, and a challenge window that bites.

  TdxPolicyTemplate* = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["tdx"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = true

[tcb]
tdx.min_tcb_status = "UpToDate"
allow_grace_days = 14

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

type
  CvmBackendUnderTest* = enum
    cbSnp = "sev-snp"
    cbTdx = "tdx"

  CvmMeasurements* = object
    ## What the CALLER's calculator produced, and therefore what both
    ## the manifest and the emulated evidence are built from. There is
    ## no default: a measurement this module invented would be a
    ## measurement of nothing.
    snpMeasurementHex*: string
    tdxMrtdHex*: string
    tdxRtmrHex*: array[TdxRtMrCount, string]
    ovmfDigest*: string
      ## ``sha256:<hex>`` of the firmware the measurement was computed
      ## over. The manifest records it so a reader can tell which image
      ## the number belongs to.
    vcpus*: int
    vcpuType*: string

  CvmEmulatedRun* = object
    backend*: CvmBackendUnderTest
    mutation*: CvmEmulatorMutation
    reportText*: string
    policyText*: string
    manifestText*: string
    vendorCrlDer*: seq[string]
    expectedChallengeHex*: string
    challengeIssuedAtMs*: int64
    nowMs*: int64
    distinguisher*: string
      ## A string that must appear in the detail of the check this fault
      ## is declared to trip, and in NO other fault's. For the faults
      ## that move a value it IS the value, because a phrase shared with
      ## a neighbouring refusal could not tell them apart.

proc cvmClaims*(): UnverifiedClaims =
  UnverifiedClaims(
    unverifiedGeneration: CvmGeneration,
    unverifiedConfigFingerprint: CvmFingerprint,
    unverifiedVerityRootHash: CvmVerityRootHash)

proc cvmManifest*(backend: CvmBackendUnderTest;
                  m: CvmMeasurements): AttestedImageManifest =
  ## The manifest the emulated image's build would publish.
  result = AttestedImageManifest(
    configFingerprint: CvmFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("emulated-cvm-uki"),
      verityImage: DigestPrefix & sha256Hex("emulated-cvm-verity-image"),
      verityRootHash: CvmVerityRootHash))
  case backend
  of cbSnp:
    result.sevSnp = @[SevSnpExpectation(
      vcpus: m.vcpus, vcpuType: m.vcpuType, ovmf: m.ovmfDigest,
      policy: "0x" & toHex(int(SnpTestGuestPolicy), 8).toLowerAscii,
      measurement: m.snpMeasurementHex)]
  of cbTdx:
    result.tdx = @[TdxExpectation(
      mrtd: m.tdxMrtdHex, rtmr0: m.tdxRtmrHex[0],
      rtmr1: m.tdxRtmrHex[1], rtmr2: m.tdxRtmrHex[2])]

proc cvmManifestText*(backend: CvmBackendUnderTest;
                      m: CvmMeasurements): string =
  renderAttestedImageManifest(cvmManifest(backend, m))

proc cvmManifestDigest*(backend: CvmBackendUnderTest;
                        m: CvmMeasurements): string =
  DigestPrefix & sha256Hex(cvmManifestText(backend, m))

proc cvmPolicyText*(backend: CvmBackendUnderTest; digest: string): string =
  case backend
  of cbSnp: SnpPolicyTemplate.replace("@DIGEST@", digest)
  of cbTdx: TdxPolicyTemplate.replace("@DIGEST@", digest)

# ---------------------------------------------------------------------
# Building the report the emulator would answer with
# ---------------------------------------------------------------------

proc emulatedCvmReportText*(d: AttestationDriver; backend: AttestationBackend;
                            challengeHex: string;
                            bindings = ReportBindings(purpose: bpAttest,
                                                      ephemeralPub: "")):
                           string =
  ## The same two calls the agent makes: compute the 64 bytes from the
  ## challenge and the bindings, hand them to the driver through the
  ## seam's checked entry point, and render the envelope around what
  ## comes back.
  let reportDataHex = reportDataHexFor(bindings, challengeHex)
  let quote = acquireQuote(d, hexToBytes("reportData", reportDataHex))
  renderAttestationReport(attestationReport(backend, CvmTimestamp,
    challengeHex, bindings, quote.evidence, cvmClaims(),
    quote.certificates))

proc replaceJsonString*(doc, key, replacement: string): string =
  ## Replace one string-valued field of a rendered report. A byte edit
  ## of the rendered document rather than a rebuild through the
  ## constructor, because a rebuilt document is a document this build
  ## agrees with.
  let needle = "\"" & key & "\": \""
  let at = doc.find(needle)
  doAssert at >= 0, "the rendered report carries no " & key & " field"
  let valueStart = at + needle.len
  let valueEnd = doc.find('"', valueStart)
  doAssert valueEnd > valueStart, "the " & key & " field is not terminated"
  doc[0 ..< valueStart] & replacement & doc[valueEnd .. ^1]

# ---------------------------------------------------------------------
# The verification-layer faults
# ---------------------------------------------------------------------

proc applyCvmVerificationFault*(run: var CvmEmulatedRun;
                                m: CvmMeasurements) =
  ## The four faults a driver cannot inject, applied to the things a
  ## driver does not own.
  ##
  ## Every arm ``doAssert``s its own site against ``cvmFaultSite``, so
  ## this module and ``cvm_evidence_emulator`` cannot both claim a fault
  ## and neither can disclaim one.
  let f = run.mutation
  case f
  of cemNone, cemMeasurement, cemSignature, cemNonce, cemTcb, cemChain:
    doAssert cvmFaultSite(f) == cfsEvidence,
      $f & " is not this module's to inject"
  of cemPolicy:
    doAssert cvmFaultSite(f) == cfsVerification
    let foreign = DigestPrefix & sha256Hex("a measurement manifest nobody " &
      "distributed")
    doAssert foreign != cvmManifestDigest(run.backend, m)
    run.policyText = cvmPolicyText(run.backend, foreign)
    run.distinguisher = foreign
  of cemTranscript:
    doAssert cvmFaultSite(f) == cfsVerification
    run.reportText = replaceJsonString(run.reportText, "timestamp",
      "the-seventeenth-of-never")
    run.distinguisher = "the-seventeenth-of-never"
  of cemTime:
    doAssert cvmFaultSite(f) == cfsVerification
    run.challengeIssuedAtMs =
      run.nowMs - int64(CvmChallengeWindowSeconds) * 10_000
    # The POLICY side of the refusal rather than the measured age: the
    # command line reads its own clock, so the age it computes is a
    # second or two past the one computed in process.
    run.distinguisher =
      "the policy accepts at most " & $CvmChallengeWindowSeconds & " s"
  of cemReplay:
    doAssert cvmFaultSite(f) == cfsVerification
    run.expectedChallengeHex = CvmOtherChallenge
    run.distinguisher = CvmOtherChallenge

# ---------------------------------------------------------------------
# What each fault must do to a verdict
# ---------------------------------------------------------------------

const
  CvmFaultCount* = 9
    ## The structured faults this fixture set defines, not counting
    ## ``cemNone``. Pinned as a VALUE and checked at run time, next to
    ## the list of spellings: the ``case`` functions already stop a
    ## fault being added without a decision, but a build that does not
    ## compile measures nothing.

  CvmFaultNames*: array[CvmFaultCount, string] = [
    "measurement", "signature", "nonce", "tcb", "chain", "policy",
    "transcript", "time", "replay"]
    ## The nine, spelled out. A name list rather than only a count: a
    ## count is satisfied by any nine values, and renaming one of these
    ## is exactly the change that would leave a count green while the
    ## thing it names had gone.

type
  CvmFaultDetection* = object
    ## What a fault must do to a verdict, STATED rather than derived.
    caught*: bool
      ## ``false`` declares that this fault changes no row of the check
      ## vector in this build. That is an assertion and not a gap: the
      ## gate also requires the evidence bytes to be IDENTICAL to the
      ## unmutated run's, so "nothing happened" is proved rather than
      ## observed.
    check*: VerifierCheck
      ## The check whose DETAIL must carry the distinguisher.
      ## Meaningless when ``caught`` is false.
    adds*: set[VerifierCheck]
      ## The rows this fault adds to the backend's baseline. Empty is a
      ## legitimate answer for a fault that changes WHY a row already
      ## failing fails — ``cemChain`` is exactly that — and the
      ## distinguisher is what proves the change.

proc cvmBaselineFailures*(b: CvmBackendUnderTest): set[VerifierCheck] =
  ## The rows that fail on the UNMUTATED run, which are exactly the
  ## structural ones.
  ##
  ## Stated per backend and as a value, because the two differ and the
  ## difference is a finding rather than an accident: a trust domain's
  ## trusted-computing-base status can only come from vendor documents
  ## signed under the same pinned root the chain cannot reach, so the
  ## floor row has no input either. A security processor's comes out of
  ## the signed report itself, so its floor row passes.
  case b
  of cbSnp: {vcCertificateChain}
  of cbTdx: {vcCertificateChain, vcTcbFloor}

proc cvmExpectedDetection*(b: CvmBackendUnderTest;
                           m: CvmEmulatorMutation): CvmFaultDetection =
  ## A total function over the enum, no ``else``.
  case m
  of cemNone:
    CvmFaultDetection(caught: false, check: vcReportSchema, adds: {})
  of cemMeasurement:
    CvmFaultDetection(caught: true, check: vcMeasurementMatch,
      adds: {vcMeasurementMatch})
  of cemSignature:
    # The reader refuses, so NONE of the facts it would have produced
    # is produced, and every row that would have read one reports that
    # it could not be performed — which a policy that requires it turns
    # into a failure. The set is the fault's signature and is stated in
    # full: a reading that stopped early and left the rows downstream
    # of it untouched would be a verifier answering questions it has no
    # input for.
    case b
    of cbSnp:
      CvmFaultDetection(caught: true, check: vcNativeEvidence,
        adds: {vcNativeEvidence, vcReportDataBinding, vcMeasurementMatch,
               vcTcbFloor})
    of cbTdx:
      CvmFaultDetection(caught: true, check: vcNativeEvidence,
        adds: {vcNativeEvidence, vcReportDataBinding, vcMeasurementMatch})
  of cemNonce:
    CvmFaultDetection(caught: true, check: vcReportDataBinding,
      adds: {vcReportDataBinding})
  of cemTcb:
    case b
    of cbSnp:
      CvmFaultDetection(caught: true, check: vcTcbFloor, adds: {vcTcbFloor})
    of cbTdx:
      # NOTHING in this build catches it, and nothing could: a trust
      # domain's platform version is judged against vendor-signed
      # documents the VERIFIER holds, which are checked under the same
      # pinned root this emulated chain cannot reach. There is no field
      # in the quote a driver could lower. Declared, so it is visible —
      # and the gate proves the declaration by requiring this run's
      # evidence to be byte-identical to the unmutated one's.
      CvmFaultDetection(caught: false, check: vcTcbFloor, adds: {})
  of cemChain:
    # The chain row is ALREADY failing on the baseline. What this fault
    # changes is why: a two-element bundle is refused by the count rule,
    # before the evaluator is called at all, so the marker's wording
    # must be ABSENT from the detail.
    CvmFaultDetection(caught: true, check: vcCertificateChain, adds: {})
  of cemPolicy:
    CvmFaultDetection(caught: true, check: vcManifestPinned,
      adds: {vcManifestPinned})
  of cemTranscript:
    # A report that does not parse fails EVERY check, because
    # `rejectUnparseable` records each one as required and inapplicable
    # rather than leaving any unreached. Spelled out rather than written
    # as a range so a check added to the enum reddens here.
    CvmFaultDetection(caught: true, check: vcReportSchema,
      adds: {vcReportSchema, vcTierAccepted, vcBackendAccepted,
             vcNativeEvidence, vcReportDataBinding, vcChallengeMatch,
             vcChallengeFreshness, vcManifestPinned, vcMeasurementMatch,
             vcCertificateChain, vcTcbFloor, vcEvidenceQuorum,
             vcTransparencyLog})
  of cemTime:
    CvmFaultDetection(caught: true, check: vcChallengeFreshness,
      adds: {vcChallengeFreshness})
  of cemReplay:
    CvmFaultDetection(caught: true, check: vcChallengeMatch,
      adds: {vcChallengeMatch})

proc cvmEvidenceDistinguisher*(b: CvmBackendUnderTest;
                               m: CvmEmulatorMutation): string =
  ## The phrase the evidence-layer faults that do not move a VALUE are
  ## told apart by. Each belongs to exactly one refusal site, and the
  ## gate requires it to be absent from every other fault's detail.
  case m
  of cemSignature:
    case b
    of cbSnp: "the endorsement certificate this report bundles for it"
    of cbTdx: "does not verify under the attestation key the quoting " &
              "enclave vouched for"
  of cemTcb:
    case b
    of cbSnp: "the reported TCB is below the policy's floor"
    of cbTdx: ""
  of cemChain: "and this report bundles 2"
  of cemNone, cemMeasurement, cemNonce: ""
  of cemPolicy, cemTranscript, cemTime, cemReplay: ""

proc cvmDriverFor*(backend: CvmBackendUnderTest; m: CvmMeasurements;
                   mutation: CvmEmulatorMutation;
                   nowSeconds: int64): AttestationDriver =
  ## One emulated machine. Exported so a caller that needs the SAME
  ## instance twice — the gate comparing the daemon's document against
  ## the renderer's — can have it: the trust-domain driver mints its
  ## attestation key per instance, so two instances are two machines and
  ## a byte comparison between them would be a comparison of two
  ## different attestations.
  case backend
  of cbSnp:
    newEmulatedSnpDriver(
      defaultSnpEmulatorScenario(m.snpMeasurementHex, mutation), nowSeconds)
  of cbTdx:
    newEmulatedTdxDriver(
      defaultTdxEmulatorScenario(m.tdxMrtdHex, m.tdxRtmrHex[0],
        m.tdxRtmrHex[1], m.tdxRtmrHex[2], m.tdxRtmrHex[3], mutation),
      nowSeconds)

proc cvmBackendOf*(b: CvmBackendUnderTest): AttestationBackend =
  case b
  of cbSnp: abSevSnp
  of cbTdx: abTdx

proc buildCvmRun*(backend: CvmBackendUnderTest; m: CvmMeasurements;
                  mutation: CvmEmulatorMutation; nowSeconds: int64;
                  reportText = "";
                  withDriver: AttestationDriver = nil): CvmEmulatedRun =
  ## Assemble one run. ``reportText`` may be supplied by a caller that
  ## obtained the document over a socket instead of from the renderer;
  ## the two are required to be identical elsewhere, which is what makes
  ## either acceptable here. ``withDriver`` likewise lets a caller hand
  ## in the instance it already has rather than a second one.
  let nowMs = nowSeconds * 1000
  result.backend = backend
  result.mutation = mutation
  result.nowMs = nowMs
  result.expectedChallengeHex = CvmChallenge
  result.challengeIssuedAtMs = nowMs - 1_000

  let driver =
    (if withDriver != nil: withDriver
     else: cvmDriverFor(backend, m, mutation, nowSeconds))
  result.vendorCrlDer =
    (case backend
     of cbSnp: snpEmulatedCrl(EmulatedSnpDriver(driver))
     of cbTdx: tdxEmulatedCrl(EmulatedTdxDriver(driver)))

  result.reportText =
    (if reportText.len > 0: reportText
     else: emulatedCvmReportText(driver, cvmBackendOf(backend),
       CvmChallenge))
  result.manifestText = cvmManifestText(backend, m)
  result.policyText =
    cvmPolicyText(backend, cvmManifestDigest(backend, m))
  result.distinguisher = cvmEvidenceDistinguisher(backend, mutation)

  if mutation == cemMeasurement:
    # Told apart by VALUE: the measurement this fault produces is one
    # only this fault produces, and no wording could distinguish it
    # from any other complaint about a measurement.
    let report = parseAttestationReport(result.reportText, "<emulated cvm>")
    let reading = readAuthoritativeEvidence(report)
    doAssert reading.inputs.launchMeasurement.isSome
    result.distinguisher = reading.inputs.launchMeasurement.get
  if mutation == cemNonce:
    let report = parseAttestationReport(result.reportText, "<emulated cvm>")
    let reading = readAuthoritativeEvidence(report)
    doAssert reading.inputs.reportDataInEvidence.isSome
    result.distinguisher = reading.inputs.reportDataInEvidence.get

  applyCvmVerificationFault(result, m)

proc cvmVerificationRequestFor*(run: CvmEmulatedRun): VerificationRequest =
  ## The in-process shape of a run. The vendor's revocation lists are
  ## passed as RAW DER, exactly as the command line passes the bytes it
  ## read off a file, so the two surfaces are handed one trust store and
  ## not two spellings of it.
  result = VerificationRequest(
    reportText: run.reportText,
    reportSource: "<emulated cvm report>",
    policy: parseAttestationPolicy(run.policyText, "<emulated cvm policy>"),
    policySource: "<emulated cvm policy>",
    manifestText: some(run.manifestText),
    manifestSource: "<emulated cvm manifest>",
    expectedChallengeHex: run.expectedChallengeHex,
    challengeIssuedAtMs: some(run.challengeIssuedAtMs),
    nowMs: run.nowMs)
  result.vendorRevocationLists = run.vendorCrlDer
