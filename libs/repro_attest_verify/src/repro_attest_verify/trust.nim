## Certificate-chain trust: twelve refusals, one acceptance, and two
## evaluators that differ in exactly one thing.
##
## ## The decision
##
## A chain arrives as a list of DER certificates from an untrusted
## machine, leaf first and self-issued root last. ``evaluateChain``
## reads them, walks the links, and answers with a ``ChainVerdict``
## naming the *one* rule that decided. Every rule has its own message,
## produced at exactly one site in this file.
##
## The ``ChainRejection`` VALUES are coarser than the rules, and that is
## worth stating plainly rather than glossing: there are eighteen refusal
## sites and twelve values, because six of the values are produced by two
## rules apiece — an unrecognised critical extension in the chain and in
## the trust store, the two name links, ``cA`` and ``keyCertSign``, a
## link signature and the root's own, the two edges of a validity window,
## and a leaf with no purpose versus a leaf with the wrong one. A caller
## that needs to know WHICH of a pair refused must assert the message,
## not only the value; every test here that cares does exactly that, and
## each also asserts the ABSENCE of its sibling's wording.
##
## That discipline is load-bearing rather than tidy. A negative fixture
## that rejects for the wrong reason is a fixture that would keep
## passing after the rule it was written for is deleted, and a suite of
## those is a suite that measures nothing.
##
## ## The one difference between the two evaluators
##
## RFC 5280 §4.2 is unambiguous: a certificate-using system MUST reject
## a certificate carrying a **critical extension it does not recognise**.
## That rule is the whole of the separation between the two entry points
## below. They share every line of logic; they differ in the set of
## critical extension OIDs they recognise, and nothing else.
##
##   * ``evaluateProductionChain`` recognises ``RecognisedCriticalOids``
##     — a ``const``. It takes **no parameter** by which that set could
##     be widened: not a policy, not a flag, not a file, not an
##     environment variable. There is no configuration of a production
##     verifier under which a certificate carrying an unrecognised
##     critical extension becomes acceptable, because there is no
##     configuration of this function at all.
##
##   * ``evaluateSoftwareRootTestChain`` recognises that set plus one
##     more OID, and **exists only in a build compiled with
##     ``-d:reproAttestSoftwareRootTestTrust``**. In every other build
##     the symbol is absent, so a call to it is a compile error rather
##     than a runtime decision. That is what makes the separation
##     structural: turning it on is not a setting, it is a different
##     binary.
##
## A test hierarchy therefore marks every one of its certificates with a
## critical extension a production build does not recognise. Three
## things follow, and all three are measured rather than asserted:
##
##   1. Production refuses it even when an operator has installed the
##      test root in the trust store by hand, because the refusal is
##      about the certificate's own contents and not about whether
##      anything trusts it.
##   2. The mark cannot be stripped to launder the chain: it lives
##      inside the TBS, so removing it invalidates the signature over
##      it, and the refusal becomes ``crBadSignature`` instead.
##   3. The mark cannot be forged onto a production chain to weaken it
##      either — the same rule refuses that chain too.
##
## ## The trust store is examined, not just consulted
##
## Every supplied anchor is checked for unrecognised critical extensions
## *before* the chain is matched against any of them. A verifier whose
## trust store contains a certificate this build cannot fully evaluate
## refuses, rather than quietly using the anchors it does understand:
## the operator who put it there believed it would be used, and a
## verifier that silently ignores part of its own trust store is
## configured by accident.
##
## ## Nothing degrades into an acceptance
##
## The absence of evidence is never an acceptance here. A chain with no
## revocation data covering its issuer is ``crNoRevocationData``, not "no
## revocations found, therefore fine". A chain that does not reach an
## anchor is ``crUnknownRoot``, not "no anchor said no".
##
## ## Mocking
##
## None. Real DER, real ECDSA-P256 verification.

import std/[strutils]

import ./x509

type
  ChainRejection* = enum
    ## The KIND of rule that decided; six of these are produced by two
    ## rules apiece, so the ``detail`` is what says which. ``crAccepted``
    ## is the only value that is not a refusal.
    crAccepted
    crMalformed
    crTooShort
    crUnrecognisedCriticalExtension
    crNameMismatch
    crNotACertificateAuthority
    crBadSignature
    crUnknownRoot
    crExpired
    crNoRevocationData
    crRevoked
    crWrongEku
    crBackendMismatch

  ChainExpectation* = object
    ## What the caller requires of the leaf, and when it is asking.
    requiredEku*: string
      ## The extended-key-usage OID the leaf must carry — the TCG
      ## attestation-key purpose for an attestation key, the
      ## endorsement-key purpose for an endorsement certificate.
    requiredSubjectAltName*: string
      ## The DNS-form name the leaf must carry, which is how a chain is
      ## bound to the backend it was issued for. A chain minted for one
      ## root of trust and presented in another's report fails here.
    nowSeconds*: int64

  ChainVerdict* = object
    reason*: ChainRejection
    detail*: string
    evaluator*: string
      ## Which evaluator produced this. Carried into the verifier's
      ## finding so a verdict says whose rules it rests on.
    leafDescription*: string
    anchorDescription*: string

const
  RecognisedCriticalOids*: array[3, string] = [
    OidBasicConstraints, OidKeyUsage, OidExtKeyUsage]
    ## The critical extensions this build acts on, and therefore the
    ## only ones it may let a certificate carry as critical. Marking an
    ## extension critical is the issuer saying "refuse this certificate
    ## if you cannot enforce this"; honouring that is the whole of the
    ## rule.

  ProductionEvaluatorName* = "production trust evaluator"

  SoftwareRootTestChainSymbol* = "evaluateSoftwareRootTestChain"
    ## The NAME of the evaluator that a build without
    ## ``-d:reproAttestSoftwareRootTestTrust`` does not have.
    ##
    ## Spelled here, where EVERY build can read it, for one reason: a
    ## build that lacks a symbol cannot tell a correct ``not compiles``
    ## assertion about it from a misspelled one, because a misspelling
    ## does not compile either. A case that asserts the absence of this
    ## evaluator pins the spelling against this constant first, and is
    ## then asserting something about the real symbol rather than about a
    ## typo. The build that HAS the symbol asserts the same equality from
    ## the other side, below.

  AttestationKeyNameSuffix* = ".attestation-key"
    ## A leaf is bound to its backend by a subject alternative name of
    ## ``<backend>`` & this suffix. The binding is in the signed
    ## certificate rather than in the report, so a chain cannot be
    ## carried from one backend's report to another's.

proc requiredSubjectAltNameFor*(backend: string): string =
  backend & AttestationKeyNameSuffix

proc refuse(reason: ChainRejection; detail: string;
            evaluator: string): ChainVerdict =
  ChainVerdict(reason: reason, detail: detail, evaluator: evaluator)

proc isAccepted*(v: ChainVerdict): bool = v.reason == crAccepted

proc sameName(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc unrecognisedCriticalOid(cert: X509Cert; recognised: openArray[string]):
    string =
  for oid in cert.criticalOids:
    if oid notin recognised: return oid
  ""

proc evaluateChain(chainDer: openArray[string];
                   anchors: openArray[X509Cert];
                   crls: openArray[X509Crl];
                   expect: ChainExpectation;
                   recognised: openArray[string];
                   evaluator: string): ChainVerdict =
  ## The whole decision. Not exported: the two entry points below are
  ## the only ways in, and they differ only in ``recognised``.
  template no(reason: ChainRejection; detail: string) =
    return refuse(reason, detail, evaluator)

  if chainDer.len < 2:
    no(crTooShort, "this chain carries " & $chainDer.len &
      " certificate(s); a chain that is to be checked against a trust " &
      "store needs at least a leaf and the root it claims to descend from")

  var chain: seq[X509Cert] = @[]
  for i, der in chainDer:
    var bytes = newSeq[byte](der.len)
    for j in 0 ..< der.len: bytes[j] = byte(der[j])
    try:
      chain.add parseCertificate(bytes)
    except X509Error as err:
      no(crMalformed, "element " & $i & " of this chain did not read as a " &
        "certificate: " & err.msg)

  result.leafDescription = describeName(chain[0].subjectDn, chain[0].subjectCn)

  # RFC 5280 §4.2, applied to the chain AND to the trust store. See the
  # module header for why the store is examined too.
  for i, cert in chain:
    let oid = unrecognisedCriticalOid(cert, recognised)
    if oid.len > 0:
      no(crUnrecognisedCriticalExtension, "element " & $i &
        " of this chain (" & describeName(cert.subjectDn, cert.subjectCn) &
        ") marks the extension " & oid & " CRITICAL, and this build does " &
        "not recognise it. Its issuer said to refuse the certificate " &
        "rather than ignore the constraint, and that is what this is")
  for i, anchor in anchors:
    let oid = unrecognisedCriticalOid(anchor, recognised)
    if oid.len > 0:
      no(crUnrecognisedCriticalExtension, "trust anchor " & $i & " (" &
        describeName(anchor.subjectDn, anchor.subjectCn) &
        ") marks the extension " & oid & " CRITICAL, and this build does " &
        "not recognise it; a verifier that quietly skipped part of its " &
        "own trust store would be configured by accident")

  # Link the chain by name before checking any signature, so a chain
  # that is not a chain is refused as that rather than as a bad
  # signature — two different defects with two different remedies.
  for i in 0 ..< chain.high:
    if not sameName(chain[i].issuerDn, chain[i + 1].subjectDn):
      no(crNameMismatch, "element " & $i & " of this chain names its " &
        "issuer " & describeName(chain[i].issuerDn, chain[i].issuerCn) &
        " and element " & $(i + 1) & " is " &
        describeName(chain[i + 1].subjectDn, chain[i + 1].subjectCn) &
        "; these certificates are not links of one chain")
  let root = chain[^1]
  if not sameName(root.issuerDn, root.subjectDn):
    no(crNameMismatch, "the last element of this chain is issued by " &
      describeName(root.issuerDn, root.issuerCn) &
      " and is therefore not the self-issued root a chain ends in")

  for i in 1 ..< chain.len:
    if not chain[i].isCa:
      no(crNotACertificateAuthority, "element " & $i & " of this chain (" &
        describeName(chain[i].subjectDn, chain[i].subjectCn) &
        ") issued the element below it and does not carry basicConstraints " &
        "cA TRUE, so it was never authorised to issue anything")
    if chain[i].hasKeyUsage and kuKeyCertSign notin chain[i].keyUsage:
      no(crNotACertificateAuthority, "element " & $i & " of this chain (" &
        describeName(chain[i].subjectDn, chain[i].subjectCn) &
        ") issued the element below it and its keyUsage does not include " &
        "keyCertSign")

  for i in 0 ..< chain.high:
    if not chain[i].signatureVerifiesUnder(chain[i + 1].publicKey):
      no(crBadSignature, "element " & $i & " of this chain does not verify " &
        "under the public key of element " & $(i + 1) & " (" &
        describeName(chain[i + 1].subjectDn, chain[i + 1].subjectCn) &
        "); whatever these bytes are, element " & $(i + 1) &
        " did not sign them")
  if not root.signatureVerifiesUnder(root.publicKey):
    no(crBadSignature, "the root of this chain does not verify under its " &
      "own public key, so it is not the self-signed certificate it is " &
      "shaped like")

  # Reaching an anchor. Matched by Name AND public key: a Name match
  # alone lets anyone who can spell the root's subject present a
  # different key under it.
  var anchorIndex = -1
  for i, anchor in anchors:
    if sameName(anchor.subjectDn, root.subjectDn) and
       anchor.publicKey == root.publicKey:
      anchorIndex = i
      break
  if anchorIndex < 0:
    no(crUnknownRoot, "this chain ends at " &
      describeName(root.subjectDn, root.subjectCn) &
      " and no certificate in this verifier's trust store of " &
      $anchors.len & " anchor(s) has that name and that public key; a " &
      "chain that reaches no anchor is trusted by nothing, whatever it " &
      "says about itself")
  result.anchorDescription = describeName(anchors[anchorIndex].subjectDn,
                                          anchors[anchorIndex].subjectCn)

  for i, cert in chain:
    if expect.nowSeconds < cert.notBefore:
      no(crExpired, "element " & $i & " of this chain (" &
        describeName(cert.subjectDn, cert.subjectCn) &
        ") is not valid until " & $cert.notBefore &
        " and this verification is being made at " & $expect.nowSeconds)
    if expect.nowSeconds >= cert.notAfter:
      no(crExpired, "element " & $i & " of this chain (" &
        describeName(cert.subjectDn, cert.subjectCn) &
        ") stopped being valid at " & $cert.notAfter &
        " and this verification is being made at " & $expect.nowSeconds)

  # Revocation. Required for every issuer in the chain: a missing list
  # is a question that was not asked, and an unasked question is not an
  # answer of "not revoked".
  for i in 0 ..< chain.high:
    let issuer = chain[i + 1]
    var covering = -1
    for j, crl in crls:
      if not sameName(crl.issuerDn, issuer.subjectDn): continue
      if not crl.signatureVerifiesUnder(issuer.publicKey): continue
      if not crl.hasNextUpdate: continue
      if expect.nowSeconds < crl.thisUpdate: continue
      if expect.nowSeconds >= crl.nextUpdate: continue
      covering = j
      break
    if covering < 0:
      no(crNoRevocationData, "this verifier holds no current revocation " &
        "list issued by " & describeName(issuer.subjectDn, issuer.subjectCn) &
        " and signed by it, so whether element " & $i &
        " of this chain has been revoked was never asked; an unasked " &
        "question is not an answer of no")
    for entry in crls[covering].revoked:
      if entry.serialHex == chain[i].serialHex:
        no(crRevoked, "element " & $i & " of this chain has serial number " &
          chain[i].serialHex & ", which its issuer's current revocation " &
          "list names as revoked at " & $entry.revokedAt)

  let leaf = chain[0]
  if expect.requiredEku.len > 0:
    if not leaf.hasExtKeyUsage:
      no(crWrongEku, "the leaf of this chain states no extended key usage " &
        "at all, and this verification requires " & expect.requiredEku)
    if expect.requiredEku notin leaf.extKeyUsage:
      no(crWrongEku, "the leaf of this chain is certified for " &
        leaf.extKeyUsage.join(", ") & " and this verification requires " &
        expect.requiredEku & "; a certificate issued for one purpose is " &
        "not evidence for another")
  if expect.requiredSubjectAltName.len > 0 and
     expect.requiredSubjectAltName notin leaf.sanDnsNames:
    no(crBackendMismatch, "the leaf of this chain carries the name(s) " &
      (if leaf.sanDnsNames.len == 0: "<none>"
       else: leaf.sanDnsNames.join(", ")) &
      " and this report needs a chain issued for " &
      expect.requiredSubjectAltName & "; a chain minted for one root of " &
      "trust says nothing about evidence produced by another")

  result.reason = crAccepted
  result.evaluator = evaluator
  result.detail = "this chain of " & $chain.len & " certificate(s) links " &
    "by name, verifies link by link, reaches the trust anchor " &
    result.anchorDescription & ", is inside its validity window, is not " &
    "named by its issuers' current revocation lists, and its leaf is " &
    "certified for " & expect.requiredEku & " under the name " &
    expect.requiredSubjectAltName

type
  ChainEvaluator* = proc (chainDer: seq[string]; anchors: seq[X509Cert];
                          crls: seq[X509Crl];
                          expect: ChainExpectation): ChainVerdict {.nimcall.}
    ## The shape both entry points have. Named so the verifier's driver
    ## can be written once; there is no registry and nothing installs
    ## one, because the only two values of this type that exist are the
    ## two procedures below.

proc evaluateProductionChain*(chainDer: seq[string];
                              anchors: seq[X509Cert];
                              crls: seq[X509Crl];
                              expect: ChainExpectation): ChainVerdict =
  ## The production decision.
  ##
  ## Note what this signature does not have: there is no policy
  ## argument, no allowance argument, and no set of extension OIDs. The
  ## set of critical extensions a production verifier recognises is a
  ## property of the build, so no document, flag or environment can
  ## widen it.
  evaluateChain(chainDer, anchors, crls, expect, RecognisedCriticalOids,
                ProductionEvaluatorName)

when defined(reproAttestSoftwareRootTestTrust):
  const
    SoftwareRootMarkerOid* = "2.999.1.1"
      ## The critical extension every certificate of a software-root
      ## test hierarchy carries.
      ##
      ## ``2.999`` is the arc ITU-T set aside for examples and testing,
      ## usable without registration — so this marker squats on nobody's
      ## namespace and reads, to anyone who decodes it, as exactly what
      ## it is.

    SoftwareRootEvaluatorName* = "software-root test trust evaluator"

    TestRecognisedCriticalOids* = [
      OidBasicConstraints, OidKeyUsage, OidExtKeyUsage,
      SoftwareRootMarkerOid]

  proc evaluateSoftwareRootTestChain*(chainDer: seq[string];
                                      anchors: seq[X509Cert];
                                      crls: seq[X509Crl];
                                      expect: ChainExpectation):
      ChainVerdict =
    ## The same twelve rules, against an evaluator that additionally
    ## recognises the software-root marker.
    ##
    ## This procedure is compiled only into a build that asked for it by
    ## name. It is not reachable from a production binary by any
    ## configuration, because it is not *in* one.
    evaluateChain(chainDer, anchors, crls, expect,
                  TestRecognisedCriticalOids, SoftwareRootEvaluatorName)

  static:
    # The other side of the pin described on ``SoftwareRootTestChainSymbol``.
    # Renaming the procedure without renaming the constant stops this
    # build; renaming both reddens the case that asserts the symbol's
    # absence, because that case still spells the old name.
    doAssert declared(evaluateSoftwareRootTestChain)
    doAssert astToStr(evaluateSoftwareRootTestChain) ==
      SoftwareRootTestChainSymbol
