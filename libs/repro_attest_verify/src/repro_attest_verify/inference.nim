## What an inference statement is worth: one entry point, two trust
## classes, eleven ways to refuse and one acceptance.
##
## ## The one verifier API
##
## ``evaluateInferenceStatement`` is the only way in. A statement
## produced against a locally minted software-root test hierarchy and one
## produced against a certificate chain reaching an anchor an operator
## installed go through the *same* procedure, in the same order, under
## the same rules. What differs is the trust class the verdict reports
## and the caveat it carries — not the code path, and not the checks.
##
## That is the whole of the "local and cloud through one API" property,
## and it is worth saying why it matters: two evaluators would drift, and
## the one that drifted would be the one nobody runs in production.
##
## ## The trust class is decided by WHICH EVALUATOR ACCEPTS, not by a flag
##
## ``repro_attest_verify/trust`` already carries the separation and it is
## structural rather than configured: ``evaluateProductionChain``
## recognises three critical extension OIDs and takes no parameter by
## which that set could be widened, while
## ``evaluateSoftwareRootTestChain`` recognises one more and **exists
## only in a build compiled with ``-d:reproAttestSoftwareRootTestTrust``**.
##
## This module classifies by trying production FIRST. Three consequences,
## and each is a property rather than an intention:
##
##   1. A chain a production verifier accepts is ``itProviderRooted``. It
##      cannot be relabelled by anything in this file, because production
##      answered first.
##   2. A software-root test hierarchy marks every certificate with a
##      critical extension production does not recognise, so production
##      refuses it at every position whatever the trust store says. It can
##      therefore never be reported as provider-rooted.
##   3. In a build without the define, the second arm **does not exist**,
##      so ``itSoftwareRootTest`` has no reachable input at all and a
##      test-hierarchy statement is refused outright. That is not a
##      degradation to be apologised for; it is the point. Turning the
##      local arm on is not a setting, it is a different binary.
##
## ## The signing key comes from the CERTIFICATE, never from a roster
##
## There is no roster parameter and no key parameter. The key a signature
## is checked under is the subject public key of the chain's leaf — the
## certificate the chain evaluator just accepted. Anything else reopens
## the gap the certificate exists to close: a roster and a chain are two
## statements about who a signer is, and a verifier holding both will
## eventually accept a signature that satisfies one of them.
##
## The key identifier is fixed by ``inferenceSignerKid`` — SHA-256 of the
## leaf's public point — so a signature naming some other identifier is
## refused as *not the certificate's key* rather than by failing to
## verify, and the two are distinguishable in the verdict.
##
## ## Nothing here ever sees a prompt
##
## ``evaluateInferenceStatement`` has no plaintext parameter, no opening
## parameter and no salt parameter, and there is no overload of it that
## does. The ``static`` assertion at the foot of this file says so
## mechanically: adding one stops the build and names the procedure.
##
## A verifier reaches a verdict from the statement, the signature and the
## chain. The request and the response are present only as commitments,
## and a commitment is checked by *being bound*, not by being opened. See
## ``repro_attest/commitment`` for what that construction is worth and
## what it is not — this module does not import it, and the opening
## procedure is therefore not even in scope here.
##
## The signature assertion is the whole of that property and it is not
## decorated with a second one. "This file does not call
## ``openCommitment``" would be an assertion about a name, defeated by a
## rename; "this procedure cannot be handed a plaintext" is an assertion
## about the type, and without a plaintext there is nothing to open.
##
## ## Eight of the eleven fields can only be checked BY the signature, and
## that is why an expectation exists
##
## A verifier holds an independent right-hand side for exactly three
## fields: the challenge it issued itself, the certificate the chain
## evaluator just accepted, and its own clock. For the other eight it has
## none. Presented with a statement naming a model, a verifier has
## nothing to compare that name against — so a mutated model field is
## caught by the signature failing and by nothing else, and every such
## mutation produces the *same* refusal.
##
## That is a real limit and it is recorded rather than dressed up: the
## signature is what binds those eight, one refusal covers all of them,
## and a verdict cannot say which one moved.
##
## ``InferenceExpectation`` is what a verifier does about it when it
## knows. It pins any of the eight by value — the agent it will accept,
## the configuration, the model, the serving stack, the system
## generation, the policy, and the two commitments a reviewer already
## holds — and each pin refuses with a sentence naming its own field. A
## pin is optional; an unpinned field is still bound, still covered by the
## signature, and still unattributable when it moves.
##
## **There is no pin for the nonce, the timestamp or the certificate**,
## and supplying one is refused rather than honoured. Each of those three
## is already decided by a check with its own source of truth, and two
## rules deciding one field is two answers to one question.
##
## ## The order of the checks, which is not cosmetic
##
## Parse, then chain, then the certificate binding, then the signature,
## then the trust class, then the pinned identities, then the nonce, then
## freshness.
##
##   * The statement is parsed first so a document that is not a
##     statement cannot make a verifier evaluate certificates on its
##     behalf.
##   * The chain is evaluated before any signature, because the key comes
##     out of it.
##   * The pins come *after* the signature, so a pin refusal is never a
##     signature failure wearing a field's name.
##
## ## What an accepted statement does NOT establish
##
## Stated here because it is the single most available misreading, and it
## rides every acceptance as a caveat rather than living only in this
## header. An acceptance establishes that a party holding the key in an
## accepted certificate **asserted** these eleven values about one
## exchange, and that nothing in the document has been altered since.
##
## It does not establish that the named model produced the committed
## response, that the named agent ran, or that the named server served
## it. Those are claims about what happened inside a machine, and the only
## thing that could establish them is evidence from that machine's root of
## trust bound to this statement's own bytes. This build has no such
## binding and this module does not pretend to one.
##
## ## Mocking
##
## None. Real ECDSA, real DER, the production chain evaluator.

import std/strutils

import repro_attest
import repro_attest/cose
import repro_attest/inference_statement

import ./trust
import ./x509

type
  InferenceTrust* = enum
    ## Whose rules an accepted statement rests on.
    itProviderRooted = "provider-rooted"
      ## The chain was accepted by the production trust evaluator against
      ## an anchor the verifier's operator installed.
    itSoftwareRootTest = "software-root-test"
      ## The chain was accepted only by the software-root test evaluator,
      ## which exists in a test build and in no other. Every verdict that
      ## reaches it says so, in the verdict, not only in a log.

  InferenceOutcome* = enum
    ## ``ioStatementUnreadable`` is not the zero value by accident: the
    ## zero value is a rejection, so a verdict nobody finished refuses.
    ioStatementUnreadable = "statement-unreadable"
    ioChainRefused = "certificate-chain-refused"
    ioCertificateNotBound = "statement-names-another-certificate"
    ioSignerKeyNotTheCertificates = "signature-names-another-key"
    ioSignatureUnreadable = "signature-unreadable"
    ioSignatureDidNotVerify = "signature-did-not-verify"
    ioTrustNotAdmitted = "trust-class-not-admitted"
    ioPinnedFieldDiffers = "statement-does-not-match-a-pinned-field"
    ioUnpinnableField = "a-pin-was-given-for-a-field-decided-elsewhere"
    ioNonceMismatch = "answers-another-challenge"
    ioStale = "outside-the-freshness-window"
    ioAccepted = "accepted"

  InferenceVerdict* = object
    outcome*: InferenceOutcome
    detail*: string
      ## What was compared against what, in one line. Never empty.
    trust*: InferenceTrust
    trustEstablished*: bool
      ## Whether ``trust`` means anything. A verdict that never reached
      ## the chain has no trust class, and a reader that took the enum's
      ## zero value for one would read "provider-rooted" off a rejection.
    chain*: ChainVerdict
    statementDigest*: string
    signer*: string            ## The leaf's key identifier, lower-case hex.
    caveats*: seq[string]

  InferenceExpectation* = array[InferenceField, string]
    ## What a verifier already knows about the statement it is being
    ## shown. An empty entry is no pin.
    ##
    ## Indexed BY the field enum rather than being a record with eight
    ## members, for the reason the statement's own preimage walks the
    ## enum: a field added to ``InferenceField`` gains a pin slot the
    ## moment it compiles, and there is no second list to keep in step.

  InferenceEvaluatorSignature* =
    proc (statementText: string; signature: seq[byte];
          chainDer: seq[string]; anchors: seq[X509Cert]; crls: seq[X509Crl];
          expectedNonceHex: string; expect: InferenceExpectation;
          admitted: set[InferenceTrust];
          nowSeconds: int64; freshnessSeconds: int64): InferenceVerdict
      {.nimcall.}
    ## The whole signature of the evaluator, written out so the
    ## ``static`` assertion below is an equality between two type
    ## expressions rather than a ``not compiles``. A ``not compiles``
    ## passes just as happily on a misspelling as on the property it
    ## meant to assert.

const
  InferenceSignerEku* = "2.999.2.1"
    ## The extended-key-usage OID an inference-signing leaf must carry.
    ##
    ## **A placeholder, and named as one.** This project holds no
    ## registered OID arc, and inventing a purpose under somebody else's
    ## is worse than squatting on the arc ITU-T set aside for examples
    ## and testing. ``2.999.1.1`` is already this tree's software-root
    ## *test marker*; this is deliberately a different sub-arc, because
    ## conflating "what this key is for" with "this hierarchy is a test"
    ## would make one of the two unreadable. A deployment that means this
    ## registers an arc and changes this constant, which changes the
    ## bytes of every certificate — as it should.
    ##
    ## It is an EKU *value*, not a critical extension OID, so it widens
    ## nothing: ``OidExtKeyUsage`` is recognised already and its contents
    ## are compared against this string.

  InferenceSignerNameSuffix* = ".inference-signer"

  InferenceSignerSubjectAltName* =
    "reproos" & InferenceSignerNameSuffix
    ## The DNS-form name the leaf must carry. A certificate minted to
    ## attest a machine and presented to sign statements about an
    ## inference fails here, in the signed certificate, rather than in a
    ## document anyone can rewrite.

  UnpinnableFields*: array[3, InferenceField] =
    [ifNonce, ifTimestamp, ifCertificate]
    ## The three a verifier already decides from its own source of
    ## truth: the challenge it issued, its own clock, and the
    ## certificate the chain evaluator accepted. A pin for any of them
    ## is refused rather than honoured — it would be a second rule
    ## deciding a field that already has one, and the two would
    ## eventually disagree.

  DefaultFreshnessSeconds* = 300'i64

  AssertedIdentitiesCaveat* =
    "an accepted statement establishes that the holder of the key in " &
    "the accepted certificate ASSERTED these values about one exchange; " &
    "it does not establish that the named model produced the committed " &
    "response, that the named agent ran, or that the named server " &
    "served it"

  SoftwareRootTestCaveat* =
    "this verdict rests on a software-root TEST hierarchy, accepted by " &
    "an evaluator that exists only in a build compiled for testing; a " &
    "production build refuses this chain at every certificate in it"

  UnopenedCommitmentsCaveat* =
    "the request and the response are present as commitments and were " &
    "not opened; this verdict says which exchange the statement is " &
    "about and says nothing about what was in it"

proc inferenceSignerKid*(publicPoint: openArray[byte]): seq[byte] =
  ## The one spelling of an inference signer's key identifier: SHA-256 of
  ## the leaf certificate's subject public key point.
  ##
  ## Written once so a producer and a verifier cannot come to disagree
  ## about how a signer is named, and chosen as a digest of the key for
  ## the reason ``quorum``'s is: it cannot be assigned to two keys by
  ## accident.
  var raw = newString(publicPoint.len)
  for i in 0 ..< publicPoint.len: raw[i] = char(publicPoint[i])
  let hex = sha256Hex(raw)
  for i in 0 ..< hex.len div 2:
    result.add byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc certificateDigestOf*(der: string): string =
  ## ``sha256:<hex>`` of a certificate's DER — what a statement's
  ## ``certificate`` field names, spelled the way every other digest in
  ## this chain is.
  DigestPrefix & sha256Hex(der)

proc hexOf(raw: openArray[byte]): string =
  var s = newString(raw.len)
  for i in 0 ..< raw.len: s[i] = char(raw[i])
  bytesToHex(s)

proc classifyChain(chainDer: seq[string]; anchors: seq[X509Cert];
                   crls: seq[X509Crl]; nowSeconds: int64):
                  (bool, InferenceTrust, ChainVerdict) =
  ## Production first, always. See the module header for why the order is
  ## the property rather than a preference.
  let expect = ChainExpectation(
    requiredEku: InferenceSignerEku,
    requiredSubjectAltName: InferenceSignerSubjectAltName,
    nowSeconds: nowSeconds)
  let production = evaluateProductionChain(chainDer, anchors, crls, expect)
  if production.isAccepted:
    return (true, itProviderRooted, production)
  when defined(reproAttestSoftwareRootTestTrust):
    let test = evaluateSoftwareRootTestChain(chainDer, anchors, crls, expect)
    if test.isAccepted:
      return (true, itSoftwareRootTest, test)
  (false, itProviderRooted, production)

proc evaluateInferenceStatementImpl(statementText: string;
                                    signature: seq[byte];
                                    chainDer: seq[string];
                                    anchors: seq[X509Cert];
                                    crls: seq[X509Crl];
                                    expectedNonceHex: string;
                                    expect: InferenceExpectation;
                                    admitted: set[InferenceTrust];
                                    nowSeconds: int64;
                                    freshnessSeconds: int64):
                                   InferenceVerdict {.nimcall.} =
  ## The whole decision, in the order the checks have to happen in.
  ##
  ## The order is not cosmetic. The key comes out of the chain, so the
  ## chain is evaluated before any signature can be checked; and the
  ## statement is parsed before the chain, so a document that is not a
  ## statement cannot make a verifier evaluate certificates on its
  ## behalf.
  template no(kind: InferenceOutcome; why: string) =
    result.outcome = kind
    result.detail = why
    return result

  var statement: InferenceStatement
  try:
    statement = parseInferenceStatement(statementText, "the statement")
  except InferenceStatementError as err:
    no(ioStatementUnreadable, err.msg)
  except CatchableError as err:
    no(ioStatementUnreadable, "the statement could not be read: " & err.msg)

  try:
    result.statementDigest = inferenceStatementDigest(statement)
  except CatchableError as err:
    no(ioStatementUnreadable, "the statement has no digest: " & err.msg)

  var
    accepted = false
    trustClass = itProviderRooted
    chainVerdict: ChainVerdict
    chainComplaint = ""
  try:
    (accepted, trustClass, chainVerdict) =
      classifyChain(chainDer, anchors, crls, nowSeconds)
  except CatchableError as err:
    chainComplaint = "the certificate chain could not be evaluated: " & err.msg
  if chainComplaint.len > 0:
    no(ioChainRefused, chainComplaint)
  result.chain = chainVerdict
  if not accepted:
    no(ioChainRefused, "the " & $chainDer.len &
      "-certificate chain was refused by the " & chainVerdict.evaluator &
      " (" & $chainVerdict.reason & "): " & chainVerdict.detail)
  result.trust = trustClass
  result.trustEstablished = true

  # The certificate the chain evaluator accepted, versus the certificate
  # the statement says it was signed under. Without this comparison a
  # statement is bound to a KEY and not to the identity a chain certifies
  # that key as, and a key that appears under two certificates carries
  # whichever one the presenter finds convenient.
  let leafDigest = certificateDigestOf(chainDer[0])
  if leafDigest != statement.certificate:
    no(ioCertificateNotBound, "the statement is signed under the " &
      "certificate " & statement.certificate & " and the chain that was " &
      "accepted presents " & leafDigest &
      "; a statement bound to one certificate is not a statement made " &
      "under another")

  var leaf: X509Cert
  try:
    var der = newSeq[byte](chainDer[0].len)
    for i in 0 ..< chainDer[0].len: der[i] = byte(chainDer[0][i])
    leaf = parseCertificate(der)
  except CatchableError as err:
    no(ioChainRefused, "the accepted leaf certificate will not re-read: " &
      err.msg)

  var point: seq[byte] = @[]
  for b in leaf.publicKey: point.add b
  let key = CoseKey(kid: inferenceSignerKid(point), curve: ccP256,
                    point: point)
  result.signer = hexOf(key.kid)

  var payload = newSeq[byte](statementText.len)
  for i in 0 ..< statementText.len: payload[i] = byte(statementText[i])

  var verified: CoseVerified
  try:
    # DETACHED: the bytes a signature covers are the document this
    # verifier read and validated, so a signature carrying its own copy
    # of the statement is refused rather than judged against it.
    verified = verifyCoseSign1(signature, [key],
                               detachedPayload = payload,
                               detachedPayloadSupplied = true)
  except CoseError as err:
    case err.kind
    of cxeKeyNotFound:
      no(ioSignerKeyNotTheCertificates, "the signature names the key " &
        "identifier " & err.msg & " and the accepted certificate's key is " &
        result.signer & "; a signature by some other key is not this " &
        "certificate speaking")
    of cxeSignatureDidNotVerify:
      no(ioSignatureDidNotVerify, "the signature does not verify over the " &
        "statement this verifier read, under the accepted certificate's " &
        "own key: " & err.msg)
    else:
      no(ioSignatureUnreadable, "the signature is not one this build can " &
        "read: " & err.msg)
  except CatchableError as err:
    no(ioSignatureUnreadable, "the signature could not be evaluated: " &
      err.msg)

  # Detached, so this is the payload the verifier supplied. Compared
  # anyway, for the reason `quorum` compares it: a future change to the
  # detachment discipline must not switch the rule off in silence.
  if verified.payload != payload:
    no(ioSignatureDidNotVerify, "the signature verified over bytes other " &
      "than the statement this verifier is checking")

  if trustClass notin admitted:
    var admittedNames: seq[string] = @[]
    for t in InferenceTrust:
      if t in admitted: admittedNames.add $t
    let admittedText =
      if admittedNames.len == 0: "nothing" else: admittedNames.join(", ")
    no(ioTrustNotAdmitted, "the chain was accepted by the " &
      chainVerdict.evaluator & ", giving trust class " & $trustClass &
      ", and this verifier was asked to admit only " & admittedText)

  # The pins. After the signature, so a refusal here is never a signature
  # failure wearing a field's name; before the nonce, because a statement
  # about the wrong model is wrong whether or not it is fresh.
  for f in InferenceField:
    if expect[f].len == 0: continue
    var unpinnable = false
    for u in UnpinnableFields:
      if u == f: unpinnable = true
    if unpinnable:
      no(ioUnpinnableField, "a pin was given for the statement's " & $f &
        ", which this verifier already decides from its own source of " &
        "truth; two rules deciding one field are two answers to one " &
        "question, so the pin is refused rather than preferred or ignored")
    if fieldOf(statement, f) != expect[f]:
      no(ioPinnedFieldDiffers, "the statement's " & $f & " is " &
        fieldOf(statement, f) & " and this verifier accepts only " &
        expect[f] & "; the signature over this statement is valid, so " &
        "what is refused is what it says and not whether it was altered")

  if statement.nonce != expectedNonceHex:
    no(ioNonceMismatch, "the statement answers the challenge " &
      statement.nonce & " and this verifier issued " & expectedNonceHex &
      "; a statement answering somebody else's challenge is a replay " &
      "however well it is signed")

  var signedAt: int64
  try:
    signedAt = timestampSeconds(statement.timestamp)
  except CatchableError as err:
    no(ioStatementUnreadable, "the timestamp will not re-read: " & err.msg)
  let age = nowSeconds - signedAt
  if age > freshnessSeconds or age < -freshnessSeconds:
    no(ioStale, "the statement is timestamped " & statement.timestamp &
      ", which is " & $age & " seconds from now, and this verifier " &
      "accepts a window of " & $freshnessSeconds & " seconds in either " &
      "direction")

  result.outcome = ioAccepted
  result.detail = "the statement was signed by the key in an accepted " &
    "certificate, names this verifier's own challenge, and binds all " &
    $(int(high(InferenceField)) + 1) & " fields"
  result.caveats.add AssertedIdentitiesCaveat
  result.caveats.add UnopenedCommitmentsCaveat
  if trustClass == itSoftwareRootTest:
    result.caveats.add SoftwareRootTestCaveat

proc evaluateInferenceStatement*(statementText: string;
                                 signature: seq[byte];
                                 chainDer: seq[string];
                                 anchors: seq[X509Cert];
                                 crls: seq[X509Crl];
                                 expectedNonceHex: string;
                                 expect: InferenceExpectation;
                                 admitted: set[InferenceTrust];
                                 nowSeconds: int64;
                                 freshnessSeconds = DefaultFreshnessSeconds):
                                InferenceVerdict =
  ## The one entry point. Local-test and provider-rooted statements go
  ## through it identically; see the module header.
  evaluateInferenceStatementImpl(statementText, signature, chainDer, anchors,
                                 crls, expectedNonceHex, expect, admitted,
                                 nowSeconds, freshnessSeconds)

proc isAccepted*(v: InferenceVerdict): bool = v.outcome == ioAccepted

proc auditRecordFor*(v: InferenceVerdict;
                     statementText: string): string =
  ## The audit record a certified-review or security-audit trail keeps.
  ##
  ## It renders from the statement's own fields and the verdict, and it
  ## carries no plaintext because a statement has none to carry. See
  ## ``renderInferenceAuditRecord``.
  renderInferenceAuditRecord(
    parseInferenceStatement(statementText, "the statement"),
    $v.outcome,
    (if v.trustEstablished: $v.trust else: "none"))

static:
  # The structural claim, made mechanically rather than in prose.
  #
  # If anyone adds a parameter to `evaluateInferenceStatement` — a
  # plaintext, an opening, a salt, a "reveal" bool, an options object
  # carrying one — this stops the build and names the procedure. The
  # privacy property is "a verdict is reachable without the plaintext",
  # and a verifier that can be HANDED one is a verifier that will
  # eventually be handed one.
  #
  # It is an equality between two type expressions, both of which must
  # name real things for this module to compile at all.
  doAssert typeof(evaluateInferenceStatementImpl) is InferenceEvaluatorSignature
  doAssert typeof(evaluateInferenceStatement) is InferenceEvaluatorSignature
