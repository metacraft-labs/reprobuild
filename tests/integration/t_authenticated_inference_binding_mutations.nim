## Changing the agent, the configuration, the model, the system, the
## input, the output, the nonce or the certificate invalidates the
## statement — and each of the eight says so in its own words.
##
## ## What this gate is for, and what it is NOT evidence of
##
## Read the header of ``inference_statement_harness.nim`` first. There is
## no inference server, no model registry and no agent identity surface
## anywhere in this workspace; a statement minted here describes an
## exchange that did not happen. **This gate establishes that the binding
## is a binding. It establishes nothing about any inference**, and no
## amount of green here would.
##
## What is genuinely under test is the algebra: eleven fields, each
## length-framed with its own name, covered by one ECDSA signature over
## bytes a verifier reassembles for itself; and, for the eight a verifier
## can pin, a refusal that names the field that moved.
##
## ## Two assertions per axis, because one of them is weaker than it looks
##
## Every axis is checked twice, and the pair is the point.
##
##   1. **The binding.** Mutate the field, keep the ORIGINAL signature,
##      and require the verifier to refuse. This is what "invalidates the
##      statement" means.
##   2. **The attribution.** Mutate the field and RE-SIGN, so the
##      signature is valid and every earlier check passes — then require
##      the refusal that names this field, and only this field. Without
##      this, assertion 1 is satisfied for all eleven axes by one
##      sentence, and a reader could not tell "the model moved" from "a
##      byte moved".
##
## Assertion 2 is why ``InferenceExpectation`` exists, and it is also
## where the honest limit lives: eight of the eleven fields can only be
## attributed when a verifier was told what to expect. That is stated in
## ``repro_attest_verify/inference``'s header and it is measured here.
##
## ## The neighbour values are real substitutions, not edited digits
##
## An axis whose mutation flips a character proves that SHA-256 is a hash.
## Every axis here substitutes a value a real adversary would substitute:
##
##   * ``agent`` — the vendor's published digest for the PREVIOUS release
##     of the same binary. Two real builds of one program.
##   * ``agentConfig`` — the same configuration with its sandbox opened
##     from ``deny-network`` to ``allow-network``.
##   * ``model`` — a different real model artifact's published digest.
##   * ``inferenceServer`` — the same stack at a different quantisation.
##   * ``systemGeneration`` — a manifest for a machine with a different
##     verity root, rendered by the production renderer.
##   * ``policy`` — a different policy document, through the production
##     parser.
##   * ``request`` / ``response`` — commitments to a different prompt and
##     a different answer.
##   * ``nonce`` — a second challenge from the production minter.
##   * ``timestamp`` — an instant outside the freshness window.
##   * ``certificate`` — a SECOND certificate minted for the SAME KEY.
##     The signature verifies under either, so only the certificate
##     binding can refuse it. That is the attack the field exists for and
##     an edited digest would not have posed it.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random source,
## real X.509 DER, real CBOR, real SHA-256, the production chain
## evaluator, the production policy parser and the production verifier.

import std/[strutils, unittest]

import cbor

import repro_attest
import repro_attest/commitment
import repro_attest/cose
import repro_attest/inference_statement
import repro_attest_verify

import ./software_root_test_pki
import ./edge_attestation_harness
import ./inference_statement_harness

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

type
  AxisRow = object
    ## One bound field, its neighbour, and how the verifier is expected
    ## to name it when it moves.
    specAxis: string
      ## The name the verification requirement gives this axis, or the
      ## empty string for a field the requirement does not enumerate.
      ## Eight of the eleven are named there; this column is what holds
      ## the gate to the requirement rather than to itself.
    neighbour: string
    pinnable: bool
    dedicated: InferenceOutcome
      ## The refusal expected from the RE-SIGNED statement. For a
      ## pinnable field that is ``ioPinnedFieldDiffers``; for the three a
      ## verifier decides for itself it is that field's own outcome.

proc marker(f: InferenceField): string =
  ## The substring a pinned-field refusal must carry, and that no other
  ## field's refusal may carry. The trailing " is " is load-bearing:
  ## without it "agent" is a substring of "agentConfig" and the two cases
  ## would each be satisfied by the other's message.
  "the statement's " & $f & " is "

suite "an inference statement binds eleven fields, and each has a case":
  setup:
    let now = 1_789_000_000'i64
    let hierarchy = mintHierarchy(now, marked = true)
    let signerKey = newTestKey()
    let signer = mintInferenceSigner(hierarchy, key = signerKey)
    let anchors = anchorsOf(hierarchy)
    let crls = crlsOf(hierarchy)
    let challenge = mintChallenge(now * 1000)
    let otherChallenge = mintChallenge(now * 1000)
    let requestSalt = newCommitmentSalt()
    let responseSalt = newCommitmentSalt()

    # A SECOND certificate for the SAME key. The signature verifies under
    # either, so only the certificate binding can tell them apart.
    let twin = mintInferenceSigner(hierarchy, cn = OtherInferenceSignerCn,
                                   key = signerKey)

    let base = baseStatement(
      sampleManifestDigest(), DigestPrefix & sha256Hex(productionPolicyText()),
      challenge.challengeHex,
      certificateDigestOf(signer.cert.der), now, requestSalt, responseSalt)
    let baseText = renderInferenceStatement(base)
    let baseSignature = signStatement(signerKey, baseText)

    let rows: array[InferenceField, AxisRow] = [
      ifAgent: AxisRow(specAxis: "agent",
        neighbour: DigestPrefix & PreviousAgentBinarySha256,
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifAgentConfig: AxisRow(specAxis: "configuration",
        neighbour: relaxedAgentConfigDigest(),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifModel: AxisRow(specAxis: "model",
        neighbour: DigestPrefix & OtherRealModelWeightsSha256,
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifInferenceServer: AxisRow(specAxis: "",
        neighbour: otherServingStackDigest(),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifSystemGeneration: AxisRow(specAxis: "system",
        neighbour: sampleManifestDigest(OtherVerityRootHash),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifPolicy: AxisRow(specAxis: "",
        neighbour: DigestPrefix &
          sha256Hex(productionPolicyText(sampleManifestDigest(
            OtherVerityRootHash))),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifRequestCommitment: AxisRow(specAxis: "input",
        neighbour: commitTo(cdRequest, requestSalt, OtherRequestPlaintext),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifResponseCommitment: AxisRow(specAxis: "output",
        neighbour: commitTo(cdResponse, responseSalt, OtherResponsePlaintext),
        pinnable: true, dedicated: ioPinnedFieldDiffers),
      ifNonce: AxisRow(specAxis: "nonce",
        neighbour: otherChallenge.challengeHex,
        pinnable: false, dedicated: ioNonceMismatch),
      ifTimestamp: AxisRow(specAxis: "",
        neighbour: timestampOf(now - 10 * 3600),
        pinnable: false, dedicated: ioStale),
      ifCertificate: AxisRow(specAxis: "certificate",
        neighbour: certificateDigestOf(twin.cert.der),
        pinnable: false, dedicated: ioCertificateNotBound)]

    proc judge(text: string; sig: seq[byte];
               expect = default(InferenceExpectation);
               chain = signer.chain): InferenceVerdict =
      evaluateInferenceStatement(text, sig, chain, anchors, crls,
                                 challenge.challengeHex, expect,
                                 {itSoftwareRootTest, itProviderRooted}, now)

  test "the unmutated statement is ACCEPTED — the control every refusal below needs":
    # Without this every case here is satisfied by a verifier that
    # refuses everything, which is the cheapest way to pass a mutation
    # table and the least informative.
    let v = judge(baseText, baseSignature)
    check v.outcome == ioAccepted
    check v.trustEstablished
    check v.trust == itSoftwareRootTest
    check v.statementDigest == inferenceStatementDigest(base)

  test "every neighbour really is a different value — the table is not degenerate":
    for f in InferenceField:
      check rows[f].neighbour.len > 0
      check rows[f].neighbour != fieldOf(base, f)

  test "ASSERTION 1 — mutating any one field invalidates the original signature":
    # Eleven axes, and the eight the requirement names are among them.
    # The signature is the ONLY thing that can refuse here: the mutated
    # statement is presented with the signature over the unmutated one.
    for f in InferenceField:
      let mutated = withField(base, f, rows[f].neighbour)
      let text = renderInferenceStatement(mutated)
      # The framing first: two statements that differ must not share a
      # preimage, or a signature over one WOULD be a signature over the
      # other and the refusal below would be an accident.
      check inferenceStatementPreimage(mutated) !=
            inferenceStatementPreimage(base)
      # For the certificate axis the TWIN chain is presented, so the
      # certificate binding passes and the signature is the only thing
      # left that can refuse. Every other axis keeps the original chain.
      let v = judge(text, baseSignature,
                    chain = (if f == ifCertificate: twin.chain
                             else: signer.chain))
      check v.outcome == ioSignatureDidNotVerify

  test "ASSERTION 2 — a RE-SIGNED mutation is refused, and the refusal names the field":
    for f in InferenceField:
      let mutated = withField(base, f, rows[f].neighbour)
      let text = renderInferenceStatement(mutated)
      let sig = signStatement(signerKey, text)
      var expect = default(InferenceExpectation)
      if rows[f].pinnable:
        expect[f] = fieldOf(base, f)
      let v = judge(text, sig, expect = expect)
      check v.outcome == rows[f].dedicated
      if rows[f].pinnable:
        check marker(f) in v.detail

  test "every field's refusal is its OWN sentence — all eleven, across the pin boundary":
    # Two defeating shapes at once.
    #
    # First: a substring satisfied by two different refusals. "agent" is
    # a substring of "agentConfig", so a case pinning the bare field name
    # would be satisfied by the wrong rule; the marker carries a trailing
    # " is " and N20 proves that is load-bearing.
    #
    # Second, and the reason this case covers ALL ELEVEN rather than only
    # the eight that can be pinned: the eight named axes include the
    # nonce and the certificate, whose refusals come from rules with
    # their own sources of truth and a different message template. "Those
    # templates are obviously different" is exactly the kind of obvious
    # this tree keeps being wrong about, so the distinctness is measured
    # over every ordered pair of the eleven rather than inside two
    # families that never meet.
    var messages: array[InferenceField, string]
    for f in InferenceField:
      let mutated = withField(base, f, rows[f].neighbour)
      let text = renderInferenceStatement(mutated)
      let sig = signStatement(signerKey, text)
      var expect = default(InferenceExpectation)
      if rows[f].pinnable: expect[f] = fieldOf(base, f)
      let v = judge(text, sig, expect = expect)
      check v.outcome == rows[f].dedicated
      messages[f] = v.detail
      check messages[f].len > 0
    for a in InferenceField:
      for b in InferenceField:
        if a == b: continue
        check messages[a] != messages[b]
        if rows[a].pinnable and rows[b].pinnable:
          check marker(a) notin messages[b]

  test "the three refusals a verifier reaches on its OWN are different sentences":
    var seen: seq[string] = @[]
    for f in InferenceField:
      if rows[f].pinnable: continue
      let mutated = withField(base, f, rows[f].neighbour)
      let text = renderInferenceStatement(mutated)
      let sig = signStatement(signerKey, text)
      let v = judge(text, sig)
      check v.outcome == rows[f].dedicated
      check v.detail notin seen
      seen.add v.detail
    check seen.len == 3

  test "the eight axes the requirement names are all covered, and by DIFFERENT fields":
    # The fixture set constrained by its own gate: ``rows`` is indexed by
    # the field enum, so a field added to ``InferenceField`` and not to
    # this table fails to COMPILE. This case closes the other direction —
    # a field silently losing its spec-axis label.
    const RequiredAxes = ["agent", "configuration", "model", "system",
                          "input", "output", "nonce", "certificate"]
    var covered: seq[string] = @[]
    for f in InferenceField:
      if rows[f].specAxis.len == 0: continue
      check rows[f].specAxis notin covered
      covered.add rows[f].specAxis
    check covered.len == RequiredAxes.len
    for axis in RequiredAxes:
      check axis in covered

  test "a pin that MATCHES does not refuse — the pin is a comparison, not a veto":
    for f in InferenceField:
      if not rows[f].pinnable: continue
      var expect = default(InferenceExpectation)
      expect[f] = fieldOf(base, f)
      check judge(baseText, baseSignature, expect = expect).outcome ==
            ioAccepted

  test "a pin for a field the verifier already decides is REFUSED, not honoured":
    # Two rules deciding one field are two answers to one question. All
    # three reachable inputs, because a refusal with one reachable input
    # out of three is a refusal two thirds untested.
    #
    # Driven by the field ENUM against a set spelled out HERE, not by
    # `UnpinnableFields` itself. A case that loops over the very list it
    # is testing cannot see that list lose a member: replacing it with
    # `[ifNonce, ifNonce, ifNonce]` keeps `UnpinnableFields.len == 3`, so
    # the size pin above stays green, and a loop over it would check the
    # nonce three times and never notice that a pin for the timestamp and
    # a pin for the certificate had quietly become honoured — which is
    # the second rule this refusal exists to prevent. Found by review.
    const Unpinnable = [ifNonce, ifTimestamp, ifCertificate]
    for f in InferenceField:
      var wanted = false
      for u in Unpinnable:
        if u == f: wanted = true
      var expect = default(InferenceExpectation)
      expect[f] = fieldOf(base, f)          # even a CORRECT pin is refused
      let v = judge(baseText, baseSignature, expect = expect)
      if wanted:
        check v.outcome == ioUnpinnableField
        check marker(f) notin v.detail
        check ("the statement's " & $f) in v.detail
      else:
        # The complement, so "refused" is not satisfied by a verifier
        # that refuses every pin.
        check v.outcome == ioAccepted
    # And the library's own list is that set, member for member and in
    # order — so the two cannot drift apart without one of them failing.
    check UnpinnableFields.len == Unpinnable.len
    for i in 0 ..< Unpinnable.len:
      check UnpinnableFields[i] == Unpinnable[i]

  test "a pin never answers for the SIGNATURE — the order of the two rules":
    # The verifier's header says the pins are evaluated AFTER the
    # signature, "so a pin refusal is never a signature failure wearing a
    # field's name". Nothing asserted it: every case that sets a pin
    # RE-SIGNS, and every case that keeps the original signature sets NO
    # pin, so the two rules never had anything to say at the same time.
    # Moving the pin block above the signature check would have left this
    # whole gate green while a verdict said "the model is wrong" about a
    # statement that had in fact been ALTERED — an attribution that names
    # a field when the honest answer is "these bytes are not the signed
    # ones". Found by review.
    #
    # So: mutate a pinnable field, keep the ORIGINAL signature, AND pin
    # that same field. Both rules now have something to say; the
    # signature must be the one that speaks.
    for f in InferenceField:
      if not rows[f].pinnable: continue
      let mutated = withField(base, f, rows[f].neighbour)
      let text = renderInferenceStatement(mutated)
      var expect = default(InferenceExpectation)
      expect[f] = fieldOf(base, f)
      let v = judge(text, baseSignature, expect = expect)
      check v.outcome == ioSignatureDidNotVerify
      check marker(f) notin v.detail

  test "the enums have the sizes this file's prose claims":
    # A defect class this tree keeps finding: four sentences saying
    # "eleven checks" above a check for thirteen. Pinned here so the
    # numbers in the headers cannot drift away from the code.
    check int(high(InferenceField)) + 1 == 11
    check int(high(InferenceOutcome)) + 1 == 12
    check UnpinnableFields.len == 3

suite "the framing is what makes eleven adjacent fields unambiguous":
  test "a character moved ACROSS a field boundary changes the preimage":
    # The hazard the length prefixes exist for, posed directly. Without
    # framing these two tuples concatenate to identical bytes.
    let a = InferenceStatement(agent: "ab", agentConfig: "c")
    let b = InferenceStatement(agent: "a", agentConfig: "bc")
    check inferenceStatementPreimage(a) != inferenceStatementPreimage(b)

  test "no two distinct field tuples share a preimage, over a systematic sweep":
    # Every re-splitting of one six-character run across every ADJACENT
    # pair of fields, both parts non-empty. If the framing were dropped,
    # every tuple in this sweep would produce the same bytes for a given
    # pair. The two degenerate splits are excluded deliberately: they
    # produce tuples that a NEIGHBOURING pair also produces, so they
    # would collide honestly and say nothing about framing.
    var seen: seq[string] = @[]
    var count = 0
    for f in InferenceField:
      if f == high(InferenceField): continue
      let g = succ(f)
      for split in 1 .. 5:
        var s = default(InferenceStatement)
        s = withField(s, f, "abcdef"[0 ..< split])
        s = withField(s, g, "abcdef"[split .. ^1])
        let pre = inferenceStatementPreimage(s)
        check pre notin seen
        seen.add pre
        count.inc
    check count == 50

  test "the CONSTRUCTED collision the value length prefix exists to close":
    # This case exists because the sweep above was GREEN under the
    # mutation that deletes every field VALUE's length prefix. The sweep
    # re-splits a plain six-character run, and a plain run contains no
    # field-name prefix, so it cannot construct the collision — it
    # asserts a distinctness that holds either way. That is the same
    # defect the commitment gate's framing case had, in this file, found
    # the same way: by running the mutation rather than by reading it.
    #
    # The real collision puts the NEXT field's own name prefix inside
    # the PREVIOUS field's value. Write s = L(11) & "agentConfig", the
    # fifteen bytes the walk emits before `agentConfig`'s value:
    #
    #   A = (agent "",  agentConfig s & "Z")
    #   B = (agent s,   agentConfig "Z")
    #
    # With the value prefixes deleted both spell
    #   L(5) "agent" s s "Z" …
    # byte for byte: two different statements, one signature.
    proc l(n: int): string =
      result = newString(4)
      result[0] = char((n shr 24) and 0xFF)
      result[1] = char((n shr 16) and 0xFF)
      result[2] = char((n shr 8) and 0xFF)
      result[3] = char(n and 0xFF)
    let s = l(($ifAgentConfig).len) & $ifAgentConfig
    let a = InferenceStatement(agent: "", agentConfig: s & "Z")
    let b = InferenceStatement(agent: s, agentConfig: "Z")

    # The collision is REAL, and this is what stops the assertion below
    # from being vacuous: spell both preimages by hand WITHOUT the value
    # prefixes and require them equal.
    proc unframedValues(st: InferenceStatement): string =
      for f in InferenceField:
        result.add l(($f).len)
        result.add $f
        result.add fieldOf(st, f)
    check unframedValues(a) == unframedValues(b)
    check fieldOf(a, ifAgent) != fieldOf(b, ifAgent)

    # And the shipped construction keeps them apart.
    check inferenceStatementPreimage(a) != inferenceStatementPreimage(b)

  test "the field NAME is carried but is NOT what separates two statements":
    # Measured, not assumed, and recorded as a NEGATIVE: the mutation
    # that deletes the field name from the preimage leaves every case in
    # this gate green, and that is correct rather than a gap. With the
    # enum order fixed and every value length-prefixed, the eleven names
    # are constants at constant positions and carry no information a
    # reader could use to tell two statements apart.
    #
    # So the name is defence in depth and has NO REACHABLE INPUT in this
    # build. What it would buy is separation across format revisions — a
    # future field renamed in place would produce different signed bytes,
    # so a signature under this schema would not be one under that. This
    # build cannot construct such a revision, so that property is
    # demonstrated here against a hand-built preimage rather than against
    # a second schema, and the limit is stated rather than papered over.
    proc l(n: int): string =
      result = newString(4)
      result[0] = char((n shr 24) and 0xFF)
      result[1] = char((n shr 16) and 0xFF)
      result[2] = char((n shr 8) and 0xFF)
      result[3] = char(n and 0xFF)
    let st = InferenceStatement(agent: "x")
    # The names ARE in the shipped preimage.
    for f in InferenceField:
      check (l(($f).len) & $f) in inferenceStatementPreimage(st)
    # Renaming one field in place changes the signed bytes.
    proc withRenamed(renameFrom, renameTo: string): string =
      result = InferenceStatementDomainTag
      result.add l(InferenceStatementSchema.len)
      result.add InferenceStatementSchema
      for f in InferenceField:
        let name = (if $f == renameFrom: renameTo else: $f)
        let value = fieldOf(st, f)
        result.add l(name.len)
        result.add name
        result.add l(value.len)
        result.add value
    check withRenamed("", "") == inferenceStatementPreimage(st)   # control
    check withRenamed("agentConfig", "agentConfigV2") !=
          inferenceStatementPreimage(st)
    # And the honest negative: with the names removed entirely, two
    # statements that differ still differ. Nothing in this gate rests on
    # the name.
    proc namesDropped(x: InferenceStatement): string =
      for f in InferenceField:
        result.add l(fieldOf(x, f).len)
        result.add fieldOf(x, f)
    check namesDropped(InferenceStatement(agent: "x")) !=
          namesDropped(InferenceStatement(model: "x"))

  test "the domain tag and the schema are the preimage's PREFIX, before any field":
    # Found by auditing this file against itself: the case below is
    # titled "the schema is in the preimage" and its body only exercised
    # the PARSER, which is the "a case titled after the claim whose body
    # asserts something weaker" shape. This is the claim the title made.
    let pre = inferenceStatementPreimage(InferenceStatement(agent: "x"))
    check pre.startsWith(InferenceStatementDomainTag)
    let afterTag = pre[InferenceStatementDomainTag.len .. ^1]
    # be32(len schema) then the schema itself, before the first field.
    check afterTag.len > 4
    check int(uint8(afterTag[3])) == InferenceStatementSchema.len
    check afterTag[4 ..< 4 + InferenceStatementSchema.len] ==
          InferenceStatementSchema

  test "a document under another schema is refused at the parser":
    let text = renderInferenceStatement(InferenceStatement(
      agent: DigestPrefix & RealAgentBinarySha256,
      agentConfig: sampleAgentConfigDigest(),
      model: DigestPrefix & RealModelWeightsSha256,
      inferenceServer: servingStackDigest(),
      systemGeneration: sampleManifestDigest(),
      policy: DigestPrefix & sha256Hex(productionPolicyText()),
      requestCommitment: commitTo(cdRequest, newCommitmentSalt(),
                                  RequestPlaintext),
      responseCommitment: commitTo(cdResponse, newCommitmentSalt(),
                                   ResponsePlaintext),
      nonce: HarnessChallenge,
      timestamp: SampleTimestamp,
      certificate: DigestPrefix & sha256Hex("not a certificate")))
    check InferenceStatementSchema in text
    let forged = text.replace(InferenceStatementSchema,
                              "reproos.inference-statement.v2")
    expect InferenceStatementError:
      discard parseInferenceStatement(forged, "the forged statement")

  test "each field's VALUE rule is enforced, and names the field it refused":
    # Without this, `validateField`'s per-field rules have no reachable
    # input: every case in this file supplies well-formed values, so
    # deleting the rules would leave the whole gate green.
    let good = InferenceStatement(
      agent: DigestPrefix & RealAgentBinarySha256,
      agentConfig: sampleAgentConfigDigest(),
      model: DigestPrefix & RealModelWeightsSha256,
      inferenceServer: servingStackDigest(),
      systemGeneration: sampleManifestDigest(),
      policy: DigestPrefix & sha256Hex(productionPolicyText()),
      requestCommitment: commitTo(cdRequest, newCommitmentSalt(),
                                  RequestPlaintext),
      responseCommitment: commitTo(cdResponse, newCommitmentSalt(),
                                   ResponsePlaintext),
      nonce: HarnessChallenge,
      timestamp: SampleTimestamp,
      certificate: DigestPrefix & sha256Hex("not a certificate"))
    discard renderInferenceStatement(good)          # the control
    for f in InferenceField:
      # One bad value per field, of the kind that field's rule exists to
      # refuse, and the refusal must name the field.
      let bad =
        case f
        of ifNonce: "ab"                            # under the 16-byte floor
        of ifTimestamp: "2026-09-11 09:00:00"       # not the one spelling
        else: "not-a-digest"
      var caught = ""
      try:
        discard renderInferenceStatement(withField(good, f, bad))
      except InferenceStatementError as err:
        caught = err.msg
      check caught.len > 0
      check $f in caught
    # The LENGTH ceiling, which is a different rule in the same procedure
    # and had no reachable input either: every bad value above is SHORT,
    # so deleting `value.len > MaxFieldLen` left this case green. The
    # refusal is read by its own wording, because a value that is too
    # long is also not a digest and the digest rule would refuse it in a
    # sentence of its own. Found by review.
    for f in InferenceField:
      var caught = ""
      try:
        discard renderInferenceStatement(
          withField(good, f, repeat('a', MaxFieldLen + 1)))
      except InferenceStatementError as err:
        caught = err.msg
      check caught.len > 0
      check ($f & " is " & $(MaxFieldLen + 1) & " characters") in caught

  test "an unknown field and a missing field are each refused":
    let text = renderInferenceStatement(InferenceStatement(
      agent: DigestPrefix & RealAgentBinarySha256,
      agentConfig: sampleAgentConfigDigest(),
      model: DigestPrefix & RealModelWeightsSha256,
      inferenceServer: servingStackDigest(),
      systemGeneration: sampleManifestDigest(),
      policy: DigestPrefix & sha256Hex(productionPolicyText()),
      requestCommitment: commitTo(cdRequest, newCommitmentSalt(),
                                  RequestPlaintext),
      responseCommitment: commitTo(cdResponse, newCommitmentSalt(),
                                   ResponsePlaintext),
      nonce: HarnessChallenge,
      timestamp: SampleTimestamp,
      certificate: DigestPrefix & sha256Hex("not a certificate")))
    expect InferenceStatementError:
      discard parseInferenceStatement(
        text.replace("\"agent\":", "\"agenT\":"), "the odd statement")
    expect InferenceStatementError:
      discard parseInferenceStatement(
        text.replace("  \"model\"", "  \"extra\": \"x\",\n  \"model\""),
        "the wide statement")

suite "the refusals a mutation table does not reach, reached":
  setup:
    let now = 1_789_000_000'i64
    let hierarchy = mintHierarchy(now, marked = true)
    let signerKey = newTestKey()
    let signer = mintInferenceSigner(hierarchy, key = signerKey)
    let outsiderKey = newTestKey()
    let anchors = anchorsOf(hierarchy)
    let crls = crlsOf(hierarchy)
    let challenge = mintChallenge(now * 1000)
    let base = baseStatement(
      sampleManifestDigest(), DigestPrefix & sha256Hex(productionPolicyText()),
      challenge.challengeHex,
      certificateDigestOf(signer.cert.der), now,
      newCommitmentSalt(), newCommitmentSalt())
    let baseText = renderInferenceStatement(base)

    proc judge(text: string; sig: seq[byte];
               chain = signer.chain): InferenceVerdict =
      evaluateInferenceStatement(text, sig, chain, anchors, crls,
                                 challenge.challengeHex,
                                 default(InferenceExpectation),
                                 {itSoftwareRootTest, itProviderRooted}, now)

  test "a signature by a key the accepted certificate does not carry is NAMED as that":
    # Not "did not verify". An outsider's signature carries the
    # outsider's key identifier, so the verifier never reaches the
    # arithmetic — and a reader who cannot tell "somebody else signed
    # this" from "this was altered" is reading a worse verdict.
    let v = judge(baseText, signStatement(outsiderKey, baseText))
    check v.outcome == ioSignerKeyNotTheCertificates
    check "some other key" in v.detail

  test "a signature by the right key over the WRONG bytes did-not-verify, and says so":
    let other = withField(base, ifAgent, DigestPrefix & PreviousAgentBinarySha256)
    let v = judge(baseText,
                  signStatement(signerKey, renderInferenceStatement(other)))
    check v.outcome == ioSignatureDidNotVerify
    check v.detail != judge(baseText,
                            signStatement(outsiderKey, baseText)).detail

  test "bytes that are not a signature at all are a DEFECT, not a shrug":
    var junk: seq[byte] = @[]
    for c in "this is not CBOR at all": junk.add byte(c)
    let v = judge(baseText, junk)
    check v.outcome == ioSignatureUnreadable

  test "a signature carrying its own ATTACHED copy of the statement is refused":
    # The detachment discipline: the bytes a signature covers are the
    # ones the verifier read and validated. A document that supplies its
    # own payload is choosing what it is compared against.
    var payload: seq[byte] = @[]
    for c in baseText: payload.add byte(c)
    var point: seq[byte] = @[]
    for b in signerKey.pub: point.add b
    let protectedBytes = protectedHeader(inferenceSignerKid(point))
    let tbs = encodeItem(cArray([cText("Signature1"), cBytes(protectedBytes),
                                 cBytes(newSeq[byte]()), cBytes(payload)]))
    let (r, sPart) = signRawEcdsa(signerKey, tbs)
    var sig: seq[byte] = @[]
    for c in r: sig.add byte(c)
    for c in sPart: sig.add byte(c)
    let attached = encodeItem(cTag(CoseSign1Tag,
      cArray([cBytes(protectedBytes), cMap([]), cBytes(payload),
              cBytes(sig)])))
    check judge(baseText, attached).outcome == ioSignatureUnreadable

  test "a document that is not a statement never reaches the certificates":
    let v = judge("{\"schema\": \"something.else.v1\"}",
                  signStatement(signerKey, baseText))
    check v.outcome == ioStatementUnreadable
    check not v.trustEstablished

  test "a chain with no anchor is refused, and the trust class is NOT established":
    let stranger = mintHierarchy(now, marked = true)
    let strangerSigner = mintInferenceSigner(stranger)
    let v = judge(baseText, signStatement(signerKey, baseText),
                  chain = strangerSigner.chain)
    check v.outcome == ioChainRefused
    check not v.trustEstablished

  test "every outcome this gate does not reach is reached by a NAMED neighbour":
    # A census, so the enum cannot grow a member nothing exercises. The
    # two named here are the e2e gate's subject, not this one's.
    var reachedHere: set[InferenceOutcome] = {}
    reachedHere.incl {ioAccepted, ioStatementUnreadable, ioChainRefused,
                      ioCertificateNotBound, ioSignerKeyNotTheCertificates,
                      ioSignatureUnreadable, ioSignatureDidNotVerify,
                      ioPinnedFieldDiffers, ioUnpinnableField,
                      ioNonceMismatch, ioStale}
    var elsewhere: set[InferenceOutcome] = {ioTrustNotAdmitted}
    for o in InferenceOutcome:
      check (o in reachedHere) or (o in elsewhere)
    check card(reachedHere) + card(elsewhere) ==
          int(high(InferenceOutcome)) + 1
