## A test hierarchy cannot satisfy production trust, and the reason is
## structural rather than configured.
##
## ## The claim, and why the usual demonstration is not one
##
## The easy version of this case installs a test root, leaves some flag
## off, observes a rejection and calls it proof. It is not. A rejection
## that happens because a switch defaults to off is a rejection one edit
## away from an acceptance, and the edit is the kind an operator makes
## while debugging at two in the morning.
##
## So this file does the opposite of leaving things off. It turns
## everything *on*:
##
##   * the test hierarchy's root is installed in the verifier's trust
##     store, by hand, as an operator would install a real one;
##   * the verifier is handed that hierarchy's revocation lists, so the
##     revocation question can be asked and answered;
##   * the measurement matches the pinned manifest, the report data is
##     the one the challenge and bindings produce, the challenge is the
##     one this verifier issued, and it is fresh;
##   * and the policy is run in **six** shapes including the most
##     permissive one the schema admits for a measured-boot report —
##     manifests unpinned, certificates not required, challenge not
##     required, age bound waived.
##
## Every one of them rejects, and every one of them rejects for the same
## reason.
##
## ## The three structural legs
##
## Behaviour under six policies is evidence, not proof; something could
## still be a seventh setting away. The three legs below are the proof:
##
##   1. **The symbol is not in this build.** The evaluator that
##      recognises the marker, and the report driver that uses it, are
##      compiled only into a build that asks for them by name. This file
##      is not such a build, and it asserts that a call to either does
##      not compile. Because a typo does not compile either, each of
##      those assertions is paired with one that reads the call's OWN
##      text and requires the callee's spelling to be the constant the
##      library publishes for it — same occurrence, so a typo cannot
##      satisfy the negative half vacuously. Asserting instead that the
##      PRODUCTION spellings compile does not achieve this; it pins the
##      arguments, and a mutation confirmed it leaves a misspelling
##      green.
##   2. **The production evaluator has no lever to pull.** It takes four
##      arguments and none of them is a policy, an allowance or a set of
##      extension identifiers; passing a fifth does not compile. The set
##      it recognises is a ``const``, asserted inside a ``static:`` block
##      — a value the compiler must produce is a value no environment can
##      have contributed to.
##   3. **The policy grammar has no clause for it.** Nine spellings of
##      "trust this root anyway" are fed to the real policy parser and
##      every one of them is refused as a key the schema does not define.
##      A policy document cannot express the thing, so no policy document
##      can be the difference.
##
## ## The positive control
##
## An identical verification, differing only in that the hierarchy is
## minted without the marker, is **accepted** — same manifest, same
## challenge, same evidence reading, same trust store mechanics. Without
## it, every rejection above would also be produced by a verifier that
## rejects everything.
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

const
  PermissivePolicy = """
schema = "reproos.attestation-policy.v1"

# The most permissive document this schema admits for a measured-boot
# report: nothing pinned, nothing required, no age bound.
[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 0
require_challenge = false
"""

proc policyShapes(): seq[(string, AttestationPolicy)] =
  ## Six documents, from the most permissive the schema admits to the
  ## strictest this harness can write.
  let digest = sampleManifestDigest()
  result.add ("most permissive the schema admits",
    parseAttestationPolicy(PermissivePolicy, "<permissive>"))
  result.add ("pinned manifest, certificates optional",
    parseAttestationPolicy(tpmPolicyText(digest), "<pinned>"))
  result.add ("pinned manifest, certificates required",
    parseAttestationPolicy(tpmPolicyText(digest).replace(
      "require_certificates = false", "require_certificates = true"),
      "<pinned-strict>"))
  result.add ("unpinned manifest, certificates required",
    parseAttestationPolicy(PermissivePolicy.replace(
      "require_certificates = false", "require_certificates = true"),
      "<unpinned-strict>"))
  result.add ("challenge required, no age bound",
    parseAttestationPolicy(PermissivePolicy.replace(
      "require_challenge = false", "require_challenge = true"),
      "<challenged>"))
  result.add ("pinned manifest, challenge required, age bound",
    parseAttestationPolicy(tpmPolicyText(digest), "<full>"))

proc verdictFor(h: TestHierarchy; policy: AttestationPolicy): Verdict =
  ## One verification, with everything except the hierarchy held fixed.
  ##
  ## The trust store is the hierarchy's OWN root and the revocation
  ## lists are its own — the operator has done everything the hierarchy
  ## would need to be trusted, short of the thing that cannot be done.
  let text = reportTextWithChain(h.akChain, HarnessChallenge, sampleClaims())
  let report = parseAttestationReport(text, "<software-root report>")
  var req = verificationRequest(text, policy, some(sampleManifestText()),
    challengeHex = HarnessChallenge, issuedAtMs = some(nowMillis),
    nowMs = nowMillis)
  req.trustAnchors = h.anchorsOf
  req.revocationLists = h.crlsOf
  verifyWithReading(req, report,
    tpmReading(sampleExpectedPcr11(), report.reportData))

suite "a software root cannot satisfy production trust":

  test "the marked hierarchy is refused under every policy shape":
    let h = mintHierarchy(nowSeconds, marked = true)
    for (label, policy) in policyShapes():
      let v = verdictFor(h, policy)
      checkpoint(label & " -> " & $v.decision)
      check not v.decision.isAcceptance
      check v.checks[vcCertificateChain].outcome == coFailed
      checkpoint(v.checks[vcCertificateChain].detail)
      check $crUnrecognisedCriticalExtension in
        v.checks[vcCertificateChain].detail
      check SoftwareRootMarkerTestOid in v.checks[vcCertificateChain].detail
      # And the chain is the ONLY thing wrong: everything else about
      # this report matches, which is the premise the claim rests on.
      check v.failedChecks == @[vcCertificateChain]

  test "the same verification accepts when the mark is the only change":
    ## The positive control. Identical in every respect except that the
    ## hierarchy carries no marker.
    let h = mintHierarchy(nowSeconds, marked = false)
    for (label, policy) in policyShapes():
      let v = verdictFor(h, policy)
      checkpoint(label & " -> " & $v.decision & " failed: " & $v.failedChecks)
      check v.decision.isAcceptance
      check v.checks[vcCertificateChain].outcome == coPassed

  test "a marked certificate in the trust store refuses the whole store":
    ## The operator's own hand: an unrelated, perfectly good chain, and a
    ## trust store into which a test root has been dropped. The store is
    ## refused rather than partly used, and by a DIFFERENT rule site from
    ## the one the chain trips — each with wording the other cannot
    ## produce.
    let good = mintHierarchy(nowSeconds, marked = false)
    let testRoots = mintHierarchy(nowSeconds, marked = true)
    let viaStore = evaluateProductionChain(good.akChain,
      good.anchorsOf & testRoots.anchorsOf, good.crlsOf,
      akExpectation(nowSeconds))
    checkpoint("store: " & $viaStore.reason & ": " & viaStore.detail)
    check viaStore.reason == crUnrecognisedCriticalExtension
    check "configured by accident" in viaStore.detail
    check "Its issuer said to refuse the certificate" notin viaStore.detail

    let viaChain = evaluateProductionChain(testRoots.akChain,
      testRoots.anchorsOf, testRoots.crlsOf, akExpectation(nowSeconds))
    checkpoint("chain: " & $viaChain.reason & ": " & viaChain.detail)
    check viaChain.reason == crUnrecognisedCriticalExtension
    check "Its issuer said to refuse the certificate" in viaChain.detail
    check "configured by accident" notin viaChain.detail

    # Without the test root in it, the same store accepts the same chain.
    check evaluateProductionChain(good.akChain, good.anchorsOf, good.crlsOf,
      akExpectation(nowSeconds)).isAccepted

  test "every certificate of the hierarchy carries the mark":
    ## The refusal is not a property of the leaf. Root, intermediate,
    ## endorsement, platform and attestation key each carry it, so there
    ## is no position in a chain at which a test certificate is invisible.
    let h = mintHierarchy(nowSeconds, marked = true)
    let plain = mintHierarchy(nowSeconds, marked = false)
    for (name, marked, unmarked) in [
        ("root", h.root.der, plain.root.der),
        ("intermediate", h.intermediate.der, plain.intermediate.der),
        ("attestation key", h.ak.der, plain.ak.der),
        ("endorsement key", h.ek.der, plain.ek.der),
        ("platform", h.platform.der, plain.platform.der)]:
      checkpoint(name)
      check SoftwareRootMarkerTestOid in parseCertText(marked).criticalOids
      check SoftwareRootMarkerTestOid notin
        parseCertText(unmarked).criticalOids

  test "the evaluator that would accept it is not in this build":
    ## Structural leg 1. Compiled without the software-root test trust
    ## define, so neither symbol exists.
    ##
    ## The trap this case has to avoid: from inside a build that LACKS a
    ## symbol, a name that does not exist and a name that was never
    ## spelled right are the same thing, so `not compiles(foo(...))` is
    ## satisfied by a typo just as happily as by the real absence.
    ## Pairing it with `compiles(...)` on the production spelling does not
    ## help — that pins the ARGUMENT expressions, not the name under test,
    ## and a mutation confirmed it leaves this case green.
    ##
    ## So the spelling and the absence are asserted about the SAME
    ## occurrence, by a template that reads the call's own text. Splitting
    ## them across two lines would leave a typo on the `compiles` line
    ## vacuous again, and that too was measured.
    template mustNotCompile(symbol: string; call: untyped) =
      check astToStr(call).startsWith(symbol & "(")
      check not compiles(call)

    let h = mintHierarchy(nowSeconds, marked = true)
    let chain = h.akChain
    let anchors = h.anchorsOf
    let crls = h.crlsOf
    let expect = akExpectation(nowSeconds)
    check compiles(evaluateProductionChain(chain, anchors, crls, expect))
    mustNotCompile(SoftwareRootTestChainSymbol,
      evaluateSoftwareRootTestChain(chain, anchors, crls, expect))

    let text = reportTextWithChain(chain, HarnessChallenge, sampleClaims())
    let report = parseAttestationReport(text, "<software-root report>")
    var req = verificationRequest(text, mockPolicy(), none(string))
    let reading = tpmReading(sampleExpectedPcr11(), report.reportData)
    check compiles(verifyWithReading(req, report, reading))
    mustNotCompile(SoftwareRootTestReportSymbol,
      verifySoftwareRootTestReport(req, report, reading))

  test "the production evaluator has no argument that could widen it":
    ## Structural leg 2. Four arguments, none of them a policy; and the
    ## set of critical extensions it recognises is a compile-time
    ## constant, which is what the ``static:`` block establishes — a
    ## value the compiler had to produce cannot have been read from an
    ## environment variable, a file or a flag.
    static:
      doAssert RecognisedCriticalOids.len == 3
      doAssert OidBasicConstraints in RecognisedCriticalOids
      doAssert OidKeyUsage in RecognisedCriticalOids
      doAssert OidExtKeyUsage in RecognisedCriticalOids
      doAssert "2.999.1.1" notin RecognisedCriticalOids
    let h = mintHierarchy(nowSeconds, marked = true)
    let chain = h.akChain
    let anchors = h.anchorsOf
    let crls = h.crlsOf
    let expect = akExpectation(nowSeconds)
    let extra = @[SoftwareRootMarkerTestOid]
    check compiles(evaluateProductionChain(chain, anchors, crls, expect))
    check not compiles(
      evaluateProductionChain(chain, anchors, crls, expect, extra))

  test "no environment variable moves the answer, byte for byte":
    ## The behavioural half of leg 2, because "there is no such variable"
    ## is worth measuring as well as arguing. Eight plausible spellings
    ## are set, and the refusal is compared for BYTE equality rather than
    ## for outcome — a gate that only compared the decision would miss a
    ## verifier that had quietly changed its mind about why.
    let h = mintHierarchy(nowSeconds, marked = true)
    let policy = parseAttestationPolicy(PermissivePolicy, "<permissive>")
    let before = verdictFor(h, policy).checks[vcCertificateChain].detail
    const Names = [
      "REPRO_ATTEST_ALLOW_SOFTWARE_ROOT",
      "REPRO_ATTEST_TEST_TRUST",
      "REPRO_ATTEST_SOFTWARE_ROOT_TEST_TRUST",
      "REPROBUILD_ATTEST_ALLOW_TEST_ROOTS",
      "REPRO_ATTEST_RECOGNISED_CRITICAL_OIDS",
      "REPRO_ATTEST_INSECURE",
      "REPRO_TRUST_ANY_ROOT",
      "REPROOS_ATTEST_DEV_MODE"]
    for name in Names:
      putEnv(name, "1")
    for name in Names:
      putEnv(name, "true")
    putEnv("REPRO_ATTEST_RECOGNISED_CRITICAL_OIDS",
           SoftwareRootMarkerTestOid)
    let after = verdictFor(h, policy).checks[vcCertificateChain].detail
    for name in Names:
      delEnv(name)
    check before.len > 0
    # The two runs mint nothing in common except the hierarchy, so the
    # details are the same bytes iff nothing in the environment reached
    # the decision.
    check after == before

  test "no policy document can name a trust anchor or widen the set":
    ## Structural leg 3. The schema defines no clause for this, and the
    ## parser refuses a clause it does not define rather than ignoring
    ## it — so the nine spellings below are not "unsupported", they are
    ## unspellable.
    const Clauses = [
      "\n[accept]\nsoftware_roots = [\"anything\"]\n",
      "\n[accept]\ntrust_anchors = [\"anything\"]\n",
      "\n[accept]\nallow_software_roots = true\n",
      "\n[accept]\nrecognised_critical_extensions = [\"2.999.1.1\"]\n",
      "\n[trust]\nanchors = [\"anything\"]\n",
      "\n[trust]\nallow_test_roots = true\n",
      "\n[measurements]\nallow_software_root = true\n",
      "\n[measurements]\nextra_critical_oids = [\"2.999.1.1\"]\n",
      "\n[freshness]\nignore_unknown_critical_extensions = true\n"]
    for clause in Clauses:
      checkpoint(clause.strip())
      var refused = false
      try:
        discard parseAttestationPolicy(PermissivePolicy & clause, "<widened>")
      except PolicyError as err:
        refused = true
        checkpoint(err.msg)
        check ("is not part of" in err.msg) or ("is set twice" in err.msg)
      check refused
    # And the unmodified document, which differs only by the absence of
    # the clause, parses — so the refusals above are about the clause.
    check parseAttestationPolicy(PermissivePolicy, "<permissive>").tiers ==
      @[atTpm]
