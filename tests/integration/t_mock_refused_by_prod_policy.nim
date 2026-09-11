## A policy cannot both admit the mock tier and pin production
## measurements — and the refusal is at parse time.
##
## ## Why this is a configuration error and not a runtime outcome
##
## Pinning manifest digests says "the machine must measure exactly this
## image". ``allow_mock`` admits a backend that takes no launch
## measurement at all. Put them in one document and the measurement
## comparison is *skipped* for every mock report that arrives, so the pin
## decides nothing while the document reads as though it decides
## everything.
##
## The last case in this file measures that rather than asserting it: it
## verifies a real mock report under the development policy and shows
## ``measurement-match`` reported as **skipped**. That is the fact the
## parse-time refusal exists because of, and it is why refusing the
## combination per report would be too late — a fleet running under such
## a policy would look verified for as long as nobody read a verdict.
##
## ## What each polarity is for
##
## Refusing the combination proves nothing on its own: a parser that
## refused every policy would pass it. So each half is shown to parse
## alone — ``allow_mock`` with no pins, and pins with no ``allow_mock`` —
## and only their conjunction is refused.
##
## ## Mocking
##
## None.

import std/[options, strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attestation_verifier_harness

proc mockPolicyPinning(digest: string): string =
  doAssert MockDevPolicy.count("manifests = []") == 1
  MockDevPolicy.replace("manifests = []",
                        "manifests = [\"" & digest & "\"]")

suite "allow_mock and pinned production manifests are a configuration error":

  test "the two halves each parse on their own":
    # The control. Without it, every refusal below could be a parser
    # that refuses everything it is shown.
    let devOnly = parseAttestationPolicy(MockDevPolicy, "<dev>")
    check devOnly.allowMock
    check not devOnly.pinsManifests

    let pinnedOnly = parseAttestationPolicy(productionPolicyText(), "<prod>")
    check not pinnedOnly.allowMock
    check pinnedOnly.pinsManifests

  test "their conjunction is refused, at parse time, with no report in sight":
    var raised = false
    var message = ""
    try:
      discard parseAttestationPolicy(mockPolicyPinning(sampleManifestDigest()),
                                     "<mock-and-pinned>")
    except PolicyError as err:
      raised = true
      message = err.msg
    check raised
    check "accept.allow_mock is true and measurements.manifests pins" in message
    check "the comparison is skipped and the pin decides" in message

  test "it is the conjunction and not the count: one pin is enough":
    var raised = false
    try:
      discard parseAttestationPolicy(
        mockPolicyPinning(DigestPrefix & sha256Hex("some other manifest")),
        "<mock-and-one-pin>")
    except PolicyError:
      raised = true
    check raised

  test "a mock report under a production policy is refused at runtime too":
    # The parse-time refusal is about a policy an operator wrote. This is
    # the separate question of what happens to a mock report that reaches
    # a policy which never allowed the tier: it is rejected, and the
    # measurement check FAILS rather than being skipped, because the skip
    # was never authorised.
    let prod = parseAttestationPolicy(productionPolicyText(), "<prod>")
    let v = verifyAttestationReport(verificationRequest(
      mockReportText(), prod, some(sampleManifestText())))
    check v.decision == vdRejected
    check v.checks[vcTierAccepted].outcome == coFailed
    check "does not set accept.allow_mock" in v.checks[vcTierAccepted].detail
    check v.checks[vcMeasurementMatch].outcome == coFailed
    check v.checks[vcMeasurementMatch].required
    check v.checks[vcBackendAccepted].outcome == coFailed

  test "the fact the refusal exists because of, measured":
    # Under a policy that DOES allow the mock tier, the measurement
    # comparison is skipped — the mock backend attests no launch
    # measurement, so there is nothing to compare a pinned manifest
    # against. This is what makes `allow_mock` plus pinned manifests a
    # document that lies about its own strictness.
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(
      mockReportText(), dev, some(sampleManifestText())))
    check v.decision == vdAcceptedNoRootOfTrust
    check v.checks[vcMeasurementMatch].outcome == coSkipped
    check not v.checks[vcMeasurementMatch].required
    check "carries no launch measurement" in
      v.checks[vcMeasurementMatch].detail
    # And the verdict says so out loud, twice: in the row and again in
    # the caveats, so a reader who skims the decision still meets it.
    var caveatNamesTheSkip = false
    for c in v.caveats:
      if "without performing the measurement-match check" in c:
        caveatNamesTheSkip = true
    check caveatNamesTheSkip

  test "a mock verdict is never the unqualified acceptance":
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    let v = verifyAttestationReport(verificationRequest(
      mockReportText(), dev, some(sampleManifestText())))
    check v.decision != vdAccepted
    check v.decision == vdAcceptedNoRootOfTrust
    check v.decision.isAcceptance
    check MockCaveat in v.caveats
    # The caveat's CONTENT, pinned as literals rather than only by the
    # name of the constant that produced it: a caveat asserted against
    # its own constant says whatever that constant is changed to say.
    check "no root of trust" in MockCaveat
    check "nothing about the machine that sent them" in MockCaveat
    check "authenticated by nothing but the fact that it was supplied" in
      UnpinnedManifestCaveat
    check "accepted-without-a-root-of-trust" in renderVerdictText(v)
    # Nothing was established about a machine: no identity is claimed,
    # because no measurement matched.
    check not v.hasIdentity
