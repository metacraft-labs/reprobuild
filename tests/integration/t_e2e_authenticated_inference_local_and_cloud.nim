## One verifier, two trust classes: a locally-rooted statement and a
## production-rooted one produce schema-compatible documents and
## deliberately different verdicts.
##
## ## WHAT THE "CLOUD" ARM IS, STATED BEFORE ANYTHING ELSE
##
## **There is no genuine cloud inference statement here and there cannot
## be one.** Producing one requires a private key whose certificate
## chains to a cloud provider's root, and nobody in this workspace holds
## such a key. The arm this gate calls provider-rooted is a second
## software hierarchy, minted here, carrying **no** software-root test
## marker, whose root an operator has installed as a trust anchor.
##
## So what the two arms establish is exactly this and no more:
##
##   * that one procedure, called with the same arguments in the same
##     order, reaches the local arm and the production arm;
##   * that the production trust evaluator — the one with no parameter by
##     which its rules can be widened — **accepts** an unmarked chain and
##     **refuses the local one at every certificate in it**, whatever the
##     trust store says;
##   * that the two statements are schema-compatible field for field; and
##   * that a verifier admitting only one trust class refuses the other.
##
## It establishes **nothing about a cloud**. A reader who wanted "genuine
## cloud evidence" should read the corroboration suite at the foot of this
## file, which is the strongest genuinely-grounded statement available
## here, and then read what it deliberately does not say.
##
## ## The corroboration, and its exact scope
##
## The trust classification rests on one discriminator: a software-root
## test hierarchy marks every certificate with a critical extension a
## production verifier does not recognise, and RFC 5280 §4.2 obliges the
## verifier to refuse it. That is only a discriminator if **real**
## certificates issued by a **real** provider do not happen to carry
## unrecognised critical extensions too.
##
## Six genuine certificates settle it: the provisioning chains inside two
## genuine Intel TDX attestation quotes, fetched live from two unrelated
## operators and already pinned in this tree as fixtures. Every critical
## extension in all six is one the production evaluator recognises; every
## certificate of the marked hierarchy carries one it does not. Both
## halves are asserted, because either alone is satisfied by a predicate
## that always returns the same answer.
##
## What that does NOT establish: those six certificates are not inference
## signers, this gate does not evaluate them as a chain, and no statement
## here is signed under them. It is a fact about the discriminator, not
## about a cloud inference.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random source,
## real X.509 DER, real CBOR, real SHA-256, two genuine Intel quotes, the
## production chain evaluators and the production verifier.

import std/[strutils, unittest]

import repro_attest
import repro_attest/commitment
import repro_attest/inference_statement
import repro_attest_verify
import repro_attest_verify/tdx_quote

import ./software_root_test_pki
import ./edge_attestation_harness
import ./inference_statement_harness
# A SELECTIVE import. `tdx_launch_vectors` exports a `sha256Hex` of its
# own, and a plain import makes every call to the library's one ambiguous
# — including calls inside the shared verifier harness this file includes.
# Naming what is wanted is also a smaller claim on the reader.
from ./tdx_launch_vectors import TdxLaunchVectors, TdxLaunchVector,
                                 TdxLaunchCase

include ./attestation_verifier_harness

static:
  # This gate exercises the software-root test arm of the trust
  # classifier, and that arm exists only in a build that asked for it by
  # name. `evaluateInferenceStatement` compiles either way and simply
  # loses the arm, so without this the gate would build and then fail at
  # run time with a chain refusal that reads like a defect in the
  # verifier rather than like a missing define. The test-edge generator
  # names this file; this is what makes being dropped from that list a
  # compile error instead.
  doAssert defined(reproAttestSoftwareRootTestTrust),
    "this gate must be compiled with -d:reproAttestSoftwareRootTestTrust; " &
    "see needsSoftwareRootTestTrustDefine in the test-edge generator"

# The two genuine quotes come from `tdx_launch_vectors`, which already
# pins each fixture's bytes AND the length of the quote inside it. The
# served file is a fixed-size transport buffer whose tail is padding, so
# a reader that hands the whole file to the parser is refused — correctly
# — for carrying bytes nothing covers. Re-deriving that split here would
# be a second answer to where a quote ends.

type
  Arm = object
    name: string
    marked: bool
    expected: InferenceTrust

let arms = [
  Arm(name: "local software root", marked: true,
      expected: itSoftwareRootTest),
  Arm(name: "production-rooted stand-in", marked: false,
      expected: itProviderRooted)]

suite "one verifier API, two trust classes":
  setup:
    let now = 1_789_000_100'i64
    let challenge = mintChallenge(now * 1000)

    proc run(arm: Arm; admitted = {itSoftwareRootTest, itProviderRooted}):
        tuple[verdict: InferenceVerdict, text: string,
              chain: seq[string], hierarchy: TestHierarchy] =
      ## ONE call site for both arms. A gate with two call sites would
      ## establish that two code paths agree, which is exactly the thing
      ## a single verifier API exists to make unnecessary.
      let h = mintHierarchy(now, marked = arm.marked)
      let key = newTestKey()
      let signer = mintInferenceSigner(h, key = key)
      let statement = baseStatement(
        sampleManifestDigest(),
        DigestPrefix & sha256Hex(productionPolicyText()),
        challenge.challengeHex, certificateDigestOf(signer.cert.der), now,
        newCommitmentSalt(), newCommitmentSalt())
      let text = renderInferenceStatement(statement)
      result = (evaluateInferenceStatement(
                  text, signStatement(key, text), signer.chain,
                  anchorsOf(h), crlsOf(h), challenge.challengeHex,
                  default(InferenceExpectation), admitted, now),
                text, signer.chain, h)

  test "BOTH arms are accepted, and each reports the trust class it earned":
    for arm in arms:
      let r = run(arm)
      check r.verdict.outcome == ioAccepted
      check r.verdict.trustEstablished
      check r.verdict.trust == arm.expected

  test "the local arm SAYS it is a test, and the production arm does not":
    # Visible test trust: in the verdict, not in a log line and not in a
    # comment. An operator reading the verdict has to be told.
    let local = run(arms[0]).verdict
    let rooted = run(arms[1]).verdict
    check SoftwareRootTestCaveat in local.caveats
    check SoftwareRootTestCaveat notin rooted.caveats
    check local.caveats.len == 3
    check rooted.caveats.len == 2
    # And the caveats they SHARE are the ones that are true of both.
    check AssertedIdentitiesCaveat in local.caveats
    check AssertedIdentitiesCaveat in rooted.caveats
    check UnopenedCommitmentsCaveat in local.caveats
    check UnopenedCommitmentsCaveat in rooted.caveats

  test "the PRODUCTION evaluator refuses the local chain, at the rule that names it":
    # This is the structural half, and it is asked of the production
    # function directly rather than inferred from the classification. It
    # takes no anchor-widening parameter, and the anchors it is given
    # here are the test hierarchy's own — so an operator who installed
    # the test root by hand still gets a refusal.
    let r = run(arms[0])
    let v = evaluateProductionChain(
      r.chain, anchorsOf(r.hierarchy), crlsOf(r.hierarchy),
      ChainExpectation(requiredEku: InferenceSignerEku,
                       requiredSubjectAltName: InferenceSignerSubjectAltName,
                       nowSeconds: now))
    check v.reason == crUnrecognisedCriticalExtension
    check v.evaluator == ProductionEvaluatorName

  test "the production evaluator ACCEPTS the unmarked chain — the control":
    # Without this the case above is satisfied by a production evaluator
    # that refuses everything, and the two arms would differ for a reason
    # that has nothing to do with the marker.
    let r = run(arms[1])
    let v = evaluateProductionChain(
      r.chain, anchorsOf(r.hierarchy), crlsOf(r.hierarchy),
      ChainExpectation(requiredEku: InferenceSignerEku,
                       requiredSubjectAltName: InferenceSignerSubjectAltName,
                       nowSeconds: now))
    check v.reason == crAccepted

  test "a verifier admitting only one class refuses the other, both ways round":
    # The class is read out of the phrase that REPORTS it, not looked for
    # anywhere in the sentence. This refusal names BOTH classes — the one
    # the chain earned and the one the verifier was willing to admit — so
    # a bare `$itSoftwareRootTest in detail` is satisfied by either
    # verdict and would stay green with the two swapped. Found by review;
    # it is the "a substring satisfied by two different refusals" shape.
    let localUnderProductionOnly = run(arms[0], admitted = {itProviderRooted})
    check localUnderProductionOnly.verdict.outcome == ioTrustNotAdmitted
    check ("giving trust class " & $itSoftwareRootTest) in
          localUnderProductionOnly.verdict.detail
    check ("admit only " & $itProviderRooted) in
          localUnderProductionOnly.verdict.detail

    let rootedUnderTestOnly = run(arms[1], admitted = {itSoftwareRootTest})
    check rootedUnderTestOnly.verdict.outcome == ioTrustNotAdmitted
    check ("giving trust class " & $itProviderRooted) in
          rootedUnderTestOnly.verdict.detail
    check ("admit only " & $itSoftwareRootTest) in
          rootedUnderTestOnly.verdict.detail

    # Two different sentences, so neither case is satisfied by the other's
    # rule.
    check localUnderProductionOnly.verdict.detail !=
          rootedUnderTestOnly.verdict.detail

  test "a verifier admitting NOTHING refuses both — the empty set is not 'anything'":
    for arm in arms:
      check run(arm, admitted = {}).verdict.outcome == ioTrustNotAdmitted

  test "the two statements are SCHEMA-COMPATIBLE field for field":
    let local = parseInferenceStatement(run(arms[0]).text, "local")
    let rooted = parseInferenceStatement(run(arms[1]).text, "rooted")
    # Same schema, same key set, same field rules — which is what
    # "schema-compatible" has to mean if it is to mean anything.
    check InferenceStatementSchema in run(arms[0]).text
    check InferenceStatementSchema in run(arms[1]).text
    for f in InferenceField:
      validateField(f, fieldOf(local, f))
      validateField(f, fieldOf(rooted, f))
    # And they agree on every field EXCEPT the ones an independent run
    # must differ in: the certificate (different key, different hierarchy)
    # and the two commitments (fresh salts).
    var differing: seq[InferenceField] = @[]
    for f in InferenceField:
      if fieldOf(local, f) != fieldOf(rooted, f): differing.add f
    check differing == @[ifRequestCommitment, ifResponseCommitment,
                         ifCertificate]

  test "the audit record is the same shape on both arms and names the trust class":
    for arm in arms:
      let r = run(arm)
      let record = auditRecordFor(r.verdict, r.text)
      check InferenceAuditRecordSchema in record
      check ("\"trust\": \"" & $arm.expected & "\"") in record
      check "\"verdict\": \"accepted\"" in record
      check RequestPlaintext notin record
      check ResponsePlaintext notin record

suite "the discriminator the trust classification rests on, against genuine bytes":
  setup:
    let genuineCerts = block:
      var acc: seq[seq[byte]] = @[]
      for v in TdxLaunchVectors:
        let quoteText = v.quote[0 ..< v.documentBytes]
        var raw = newSeq[byte](quoteText.len)
        for i in 0 ..< quoteText.len: raw[i] = byte(quoteText[i])
        for der in parseTdxQuote(raw).pckChain: acc.add der
      acc

  test "the corpus really is six genuine certificates from two unrelated quotes":
    # Degeneracy check first. Six certificates of which three are
    # duplicates would make the sweep below a sweep over three.
    check genuineCerts.len == 6
    var subjects: seq[string] = @[]
    for der in genuineCerts: subjects.add parseCertificate(der).subjectCn
    var distinct3 = 0
    for i, s in subjects:
      var first = true
      for j in 0 ..< i:
        if subjects[j] == s: first = false
      if first: distinct3.inc
    # Two operators' chains share Intel's own root and platform
    # authority, so three distinct subjects is what a genuine pair looks
    # like; fewer would mean one quote was read twice.
    check distinct3 >= 3

  test "NO genuine certificate carries a critical extension production does not know":
    for der in genuineCerts:
      let cert = parseCertificate(der)
      for ext in cert.extensions:
        if not ext.critical: continue
        var recognised = false
        for oid in RecognisedCriticalOids:
          if oid == ext.oid: recognised = true
        check recognised

  test "EVERY certificate of a marked hierarchy carries one — the other half":
    # Without this the case above is satisfied by a predicate that always
    # says "recognised", and the discriminator would be untested in the
    # direction that matters.
    let h = mintHierarchy(1_789_000_100'i64, marked = true)
    let signer = mintInferenceSigner(h)
    for der in signer.chain:
      var raw = newSeq[byte](der.len)
      for i in 0 ..< der.len: raw[i] = byte(der[i])
      let cert = parseCertificate(raw)
      var unrecognised = 0
      for ext in cert.extensions:
        if not ext.critical: continue
        var recognised = false
        for oid in RecognisedCriticalOids:
          if oid == ext.oid: recognised = true
        if not recognised: unrecognised.inc
      check unrecognised == 1

  test "and an UNMARKED hierarchy carries none, so the mark is the difference":
    let h = mintHierarchy(1_789_000_100'i64, marked = false)
    let signer = mintInferenceSigner(h)
    for der in signer.chain:
      var raw = newSeq[byte](der.len)
      for i in 0 ..< der.len: raw[i] = byte(der[i])
      for ext in parseCertificate(raw).extensions:
        if not ext.critical: continue
        var recognised = false
        for oid in RecognisedCriticalOids:
          if oid == ext.oid: recognised = true
        check recognised
