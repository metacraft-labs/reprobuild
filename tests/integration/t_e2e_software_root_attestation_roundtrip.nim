## A software-root chain, carried in a real report, through the real
## verifier — accepted, and accepted only here.
##
## ## The round trip
##
## The hierarchy is minted fresh, its attestation-key chain is placed in
## a ``reproos.attestation-report.v1`` by the library's own constructor,
## the document is **rendered to bytes and parsed back**, and the chain
## that comes out the other side is compared to the one that went in.
## Nothing is handed to the verifier as a record: the certificates make
## the whole journey through production serialization, base64 and all.
##
## ## Why this file is a different binary
##
## It is compiled with ``-d:reproAttestSoftwareRootTestTrust``, which is
## the only thing that brings the evaluator and the report driver that
## recognise the software-root marker into existence. Its companion —
## the case that proves a production build refuses the same chain — is
## compiled *without* it, and asserts that these very symbols do not
## compile there. The two files are therefore a compiler-enforced pair:
## the difference between accepting this hierarchy and refusing it is
## which binary you are running, not which setting you chose.
##
## ## The test evaluator is not a bypass, and that is measured
##
## The obvious failure mode of a "test trust" path is that it becomes a
## path that accepts anything. Every defect in the catalogue is run
## through it below and every one is still refused, by the same rule that
## refuses it in production — the marker is the *only* thing it treats
## differently. An acceptance that only ever saw a valid chain would be
## no evidence about the rules at all.
##
## ## Keys are per run
##
## Two hierarchies minted in the same process have different roots,
## checked by value. Nothing in this repository carries a private key for
## either.
##
## ## Mocking
##
## None.

import std/[options, os, strutils, times, unittest]

import repro_attest
import repro_attest_verify
import ./software_root_test_pki

include ./attestation_verifier_harness

let nowSeconds = getTime().toUnix
let nowMillis = nowSeconds * 1000

proc strictTpmPolicy(): AttestationPolicy =
  ## Pinned manifest, certificates REQUIRED, challenge required, age
  ## bounded. The chain check is required rather than optional, so its
  ## outcome is load-bearing in both directions.
  parseAttestationPolicy(tpmPolicyText(sampleManifestDigest()).replace(
    "require_certificates = false", "require_certificates = true"),
    "<strict tpm policy>")

proc requestFor(h: TestHierarchy): (VerificationRequest, AttestationReport) =
  let text = reportTextWithChain(h.akChain, HarnessChallenge, sampleClaims())
  let report = parseAttestationReport(text, "<software-root report>")
  var req = verificationRequest(text, strictTpmPolicy(),
    some(sampleManifestText()), challengeHex = HarnessChallenge,
    issuedAtMs = some(nowMillis), nowMs = nowMillis)
  req.trustAnchors = h.anchorsOf
  req.revocationLists = h.crlsOf
  (req, report)

suite "software-root attestation round trip":

  test "the chain survives production serialization byte for byte":
    ## The certificates are base64'd into the document by the library and
    ## decoded out of it by the parser. If either side were lossy the
    ## verifier would be judging different bytes from the ones minted.
    let h = mintHierarchy(nowSeconds, marked = true)
    let text = reportTextWithChain(h.akChain, HarnessChallenge,
                                   sampleClaims())
    let report = parseAttestationReport(text, "<software-root report>")
    let carried = report.certificatesForCrossCheck
    check carried.len == 3
    check carried == h.akChain
    check report.hasBundledCertificates
    # And the document really is a document: it round-trips through the
    # renderer unchanged, so what was parsed is what was written.
    check renderAttestationReport(report) == text
    # A single flipped byte anywhere in the chain must change what comes
    # out, or the comparison above proves nothing about the transport.
    var tampered = h.akChain
    tampered[0][10] = char(byte(tampered[0][10]) xor 0x01'u8)
    let tamperedText = reportTextWithChain(tampered, HarnessChallenge,
                                           sampleClaims())
    check tamperedText != text
    check parseAttestationReport(tamperedText,
      "<tampered>").certificatesForCrossCheck != carried

  test "the test evaluator accepts the chain and production refuses it":
    ## The whole separation in one case. One request, two drivers.
    let h = mintHierarchy(nowSeconds, marked = true)
    let (req, report) = requestFor(h)
    let reading = tpmReading(sampleExpectedPcr11(), report.reportData)

    let underTest = verifySoftwareRootTestReport(req, report, reading)
    checkpoint("test policy: " & $underTest.decision & " failed: " &
      $underTest.failedChecks)
    checkpoint(underTest.checks[vcCertificateChain].detail)
    check underTest.decision.isAcceptance
    check underTest.checks[vcCertificateChain].outcome == coPassed
    check SoftwareRootEvaluatorName in
      underTest.checks[vcCertificateChain].detail

    let underProduction = verifyWithReading(req, report, reading)
    checkpoint("production: " & $underProduction.decision & " failed: " &
      $underProduction.failedChecks)
    check not underProduction.decision.isAcceptance
    check underProduction.failedChecks == @[vcCertificateChain]
    check SoftwareRootMarkerTestOid in
      underProduction.checks[vcCertificateChain].detail
    check ProductionEvaluatorName in
      underProduction.checks[vcCertificateChain].detail

    # The two verdicts differ in exactly one row, so nothing else about
    # the test driver is doing the work.
    for chk in VerifierCheck:
      if chk == vcCertificateChain: continue
      check underTest.checks[chk].outcome == underProduction.checks[chk].outcome

  test "the two evaluators differ on the marker and on nothing else":
    ## Every defect in the catalogue, run through the test evaluator.
    ## Only the marker changes its answer; every other rule refuses
    ## exactly as it does in production.
    for defect in ChainDefect:
      let f = mintFixture(defect, nowSeconds)
      let production = evaluateProductionChain(f.chain, f.anchors, f.crls,
                                               f.expect)
      let underTest = evaluateSoftwareRootTestChain(f.chain, f.anchors,
                                                    f.crls, f.expect)
      checkpoint($defect & ": production " & $production.reason &
        ", test " & $underTest.reason)
      check production.reason == expectedRejection(defect)
      if defect == cdSoftwareRootMarker:
        check production.reason == crUnrecognisedCriticalExtension
        # The wording the CHAIN rule alone emits. The trust-store rule
        # produces the same enum value, and this fixture must not be
        # satisfiable by it.
        check "Its issuer said to refuse the certificate" in production.detail
        check "configured by accident" notin production.detail
        check underTest.reason == crAccepted
      else:
        check underTest.reason == production.reason
      check underTest.evaluator == SoftwareRootEvaluatorName
      check production.evaluator == ProductionEvaluatorName

  test "the test evaluator still enforces the whole chain":
    ## Spelled out separately from the loop above, because "a test trust
    ## path that accepts anything" is the failure this arrangement
    ## would be worst at noticing. A marked hierarchy with a second thing wrong
    ## is refused even by the evaluator that forgives the mark.
    let h = mintHierarchy(nowSeconds, marked = true)
    let good = evaluateSoftwareRootTestChain(h.akChain, h.anchorsOf,
                                             h.crlsOf, akExpectation(nowSeconds))
    check good.isAccepted
    let noAnchor = evaluateSoftwareRootTestChain(h.akChain,
      newSeq[X509Cert](), h.crlsOf, akExpectation(nowSeconds))
    check noAnchor.reason == crUnknownRoot
    let noCrl = evaluateSoftwareRootTestChain(h.akChain, h.anchorsOf,
      newSeq[X509Crl](), akExpectation(nowSeconds))
    check noCrl.reason == crNoRevocationData
    let expired = evaluateSoftwareRootTestChain(h.akChain, h.anchorsOf,
      h.crlsOf, akExpectation(nowSeconds + 400 * 86_400))
    check expired.reason == crExpired
    var wrongBackend = akExpectation(nowSeconds)
    wrongBackend.requiredSubjectAltName =
      requiredSubjectAltNameFor(OtherBackendName)
    check evaluateSoftwareRootTestChain(h.akChain, h.anchorsOf, h.crlsOf,
      wrongBackend).reason == crBackendMismatch

  test "the endorsement and platform certificates chain under test policy":
    ## The hierarchy is a hierarchy, not one chain: the certificates a
    ## manufacturer and an integrator would issue are minted too, and
    ## each is accepted under its own purpose and refused under another.
    let h = mintHierarchy(nowSeconds, marked = true)
    for (name, chain, ownEku, foreignEku) in [
        ("endorsement", h.ekChain, OidTcgEkCertificate,
         OidTcgAikCertificate),
        ("platform", h.platformChain, OidTcgPlatformCertificate,
         OidTcgEkCertificate),
        ("attestation key", h.akChain, OidTcgAikCertificate,
         OidTcgPlatformCertificate)]:
      var own = akExpectation(nowSeconds)
      own.requiredEku = ownEku
      var foreign = akExpectation(nowSeconds)
      foreign.requiredEku = foreignEku
      checkpoint(name)
      check evaluateSoftwareRootTestChain(chain, h.anchorsOf, h.crlsOf,
        own).isAccepted
      check evaluateSoftwareRootTestChain(chain, h.anchorsOf, h.crlsOf,
        foreign).reason == crWrongEku

  test "the hierarchy is minted per run and committed nowhere":
    ## Two hierarchies from one process share no key. A fixture PKI whose
    ## keys were baked in would produce the same root twice, and a root
    ## whose private key is in a repository is a root somebody else can
    ## issue under.
    let first = mintHierarchy(nowSeconds, marked = true)
    let second = mintHierarchy(nowSeconds, marked = true)
    check first.root.key.pub != second.root.key.pub
    check first.intermediate.key.pub != second.intermediate.key.pub
    check first.ak.key.pub != second.ak.key.pub
    check first.root.der != second.root.der
    # Same names, different keys — so the difference is the key material
    # and not the template.
    check parseCertText(first.root.der).subjectDn ==
      parseCertText(second.root.der).subjectDn
    # Neither hierarchy's chain is trusted by the other's store.
    check evaluateSoftwareRootTestChain(first.akChain, second.anchorsOf,
      first.crlsOf, akExpectation(nowSeconds)).reason == crUnknownRoot

  test "the marker is a real critical extension under the testing arc":
    ## Pinned by value on both sides of the seam. The minting side writes
    ## a literal and the evaluating side recognises a literal, and this
    ## case is where the two are required to be the same string — so a
    ## rename on either side reddens rather than silently agreeing with
    ## itself.
    check SoftwareRootMarkerTestOid == SoftwareRootMarkerOid
    check SoftwareRootMarkerOid == "2.999.1.1"
    check SoftwareRootMarkerOid notin RecognisedCriticalOids
    check SoftwareRootMarkerOid in TestRecognisedCriticalOids
    for oid in RecognisedCriticalOids:
      check oid in TestRecognisedCriticalOids
    check TestRecognisedCriticalOids.len == RecognisedCriticalOids.len + 1
    let h = mintHierarchy(nowSeconds, marked = true)
    let root = parseCertText(h.root.der)
    check SoftwareRootMarkerOid in root.criticalOids
    # And it is written as DER, decoded by the production reader — the
    # dotted string above is what those bytes mean and not a label
    # beside them.
    var found = false
    for ext in root.extensions:
      if ext.oid == SoftwareRootMarkerOid:
        found = true
        check ext.critical
        check MarkerText in cast[string](ext.value)
    check found
