## Thirteen chains, twelve of them defective, and each refused by its
## own rule.
##
## ## What this case is worth
##
## A negative fixture that rejects is nearly worthless on its own. What
## makes one worth keeping is the pair of facts around it:
##
##   * the SAME hierarchy with that one defect removed is **accepted**,
##     so the defect is the only thing between this chain and trust; and
##   * the rejection names the rule that made it, so deleting that rule
##     cannot leave the fixture green under a different refusal.
##
## Both are asserted below for every fixture. Reviews of this
## repository have twice found a refusal satisfied by the *wrong* rule — one substring produced
## by two different sites, so removing one left the other emitting
## matching text — and once found a rule with no reachable input at all,
## because an earlier layer refused first and the rule under test was
## never entered. Asserting the exact ``ChainRejection`` of every fixture
## is the measurement that rules both of those out: a fixture that
## reports its own rule is a fixture that reached it.
##
## ## The catalogue constrains itself
##
## ``expectedRejection`` is a total function over ``ChainDefect``, so a
## defect cannot be added without saying what must catch it. The case
## below closes the other direction: the set of rejections the catalogue
## exercises must equal **every** ``ChainRejection`` except the
## acceptance. A rule added to the evaluator with no fixture to reach it
## reddens this file. A fixture table that is not constrained by its
## own gate grows a hole the moment somebody extends what it is a table
## of, and that has happened here before.
##
## ## Nothing degrades into an acceptance
##
## Two of the thirteen are there specifically because "no evidence" is
## the easiest acceptance to write by accident: a trust store that does
## not contain this chain's root, and a verifier holding no revocation
## list for one of its issuers. Neither may be read as "nothing said no".
##
## ## Mocking
##
## None. Every certificate is minted with a real ECDSA-P256 key drawn
## from the operating system's random source, encoded as real X.509 DER,
## and read by the production reader.

import std/[algorithm, strutils, tables, times, unittest]

import repro_attest_verify
import ./software_root_test_pki

let now = getTime().toUnix

suite "negative certificate-chain fixtures":

  test "every defect is refused, and by the rule it was written for":
    ## The heart of the file. For each fixture: the production evaluator
    ## must return exactly the rejection the catalogue names, and the
    ## detail must name the certificate or the store it is about.
    for defect in ChainDefect:
      let f = mintFixture(defect, now)
      let v = evaluateProductionChain(f.chain, f.anchors, f.crls, f.expect)
      checkpoint("defect " & $defect & " -> " & $v.reason & ": " & v.detail)
      check v.reason == expectedRejection(defect)
      check v.detail.len > 0
      check v.evaluator == ProductionEvaluatorName
      if defect == cdNone:
        check v.isAccepted
      else:
        check not v.isAccepted

  test "the base hierarchy the defects are cut from is accepted":
    ## The positive half, without which every assertion above is
    ## satisfied by an evaluator that returns a refusal unconditionally.
    ## A rejection is only evidence about a rule when the same code
    ## accepts something.
    let base = mintFixture(cdNone, now)
    let v = evaluateProductionChain(base.chain, base.anchors, base.crls,
                                    base.expect)
    check v.isAccepted
    check v.reason == crAccepted
    check "reaches the trust anchor" in v.detail

  test "the catalogue exercises every rejection this build can produce":
    ## Shape guard. Adding a ``ChainRejection`` without a fixture that
    ## reaches it, or deleting a fixture, reddens here — so the table
    ## cannot quietly stop being a table of everything.
    var reached: seq[string] = @[]
    for defect in ChainDefect:
      let reason = expectedRejection(defect)
      if reason == crAccepted: continue
      let name = $reason
      check name notin reached      # two defects sharing one rule would
                                    # leave a third rule unexercised
      reached.add name
    var everything: seq[string] = @[]
    for reason in ChainRejection:
      if reason == crAccepted: continue
      everything.add $reason
    reached.sort()
    everything.sort()
    checkpoint("exercised: " & reached.join(", "))
    checkpoint("declared:  " & everything.join(", "))
    check reached == everything

  test "each refusal's wording is produced by one rule and no other":
    ## A lesson this repository's reviews have paid for, applied as a
    ## measurement rather than repeated as advice. Every fixture's detail is
    ## matched against a phrase chosen to belong to its rule alone, and
    ## then against every OTHER fixture's detail — which must not carry
    ## it. A phrase two refusals can produce is a phrase that survives
    ## the deletion of either.
    const Phrases = {
      cdMalformedEncoding: "did not read as a certificate",
      cdSingleElement: "needs at least a leaf",
      cdSoftwareRootMarker:
        "Its issuer said to refuse the certificate",
      cdBrokenNameLink: "are not links of one chain",
      cdIssuerIsNotACa: "was never authorised to issue anything",
      cdForgedSignature: "did not sign them",
      cdRootNotInTrustStore: "is trusted by nothing",
      cdLeafOutOfWindow: "stopped being valid at",
      cdRevocationListMissing: "an unasked question is not an answer of no",
      cdLeafRevoked: "names as revoked at",
      cdEndorsementCertificateInsteadOfAttestationKey:
        "is not evidence for another",
      cdMintedForAnotherBackend: "says nothing about evidence produced by another"
    }.toTable
    var details: seq[(ChainDefect, string)] = @[]
    for defect in ChainDefect:
      if defect == cdNone: continue
      let f = mintFixture(defect, now)
      details.add (defect,
        evaluateProductionChain(f.chain, f.anchors, f.crls, f.expect).detail)
    for (defect, detail) in details:
      let phrase = Phrases[defect]
      checkpoint($defect & " must say " & phrase.escape())
      check phrase in detail
      for (other, otherDetail) in details:
        if other == defect: continue
        checkpoint($other & " must NOT say " & phrase.escape())
        check phrase notin otherDetail

  test "an expired certificate is refused on both edges of its window":
    ## The bound is tested from outside it in both directions, not with
    ## a value that sits inside. A window check written as `<=` where it
    ## should be `<` passes every test that only ever asks about the
    ## middle.
    let h = mintHierarchy(now, marked = false)
    let anchors = h.anchorsOf
    let leaf = parseCertText(h.ak.der)
    # Revocation lists wide enough to cover both edges of the leaf's
    # window, so the instants below are decided by the window rule and
    # not by a list that happened to expire first.
    let wideCrls = @[
      parseCrlText(mintCrl(h.root.key, h.root.subjectName,
        leaf.notBefore - 10, leaf.notAfter + 10, [])),
      parseCrlText(mintCrl(h.intermediate.key, h.intermediate.subjectName,
        leaf.notBefore - 10, leaf.notAfter + 10, []))]
    for (label, instant) in [("one second before notBefore", leaf.notBefore - 1),
                             ("exactly notAfter", leaf.notAfter)]:
      var expect = akExpectation(instant)
      let v = evaluateProductionChain(h.akChain, anchors, wideCrls, expect)
      checkpoint(label & " -> " & $v.reason & ": " & v.detail)
      check v.reason == crExpired
    for (label, instant) in [("exactly notBefore", leaf.notBefore),
                             ("one second before notAfter", leaf.notAfter - 1)]:
      # Both anchor and intermediate must also be in window at these
      # instants, and they are: their windows contain the leaf's.
      var expect = akExpectation(instant)
      let v = evaluateProductionChain(h.akChain, anchors, wideCrls, expect)
      checkpoint(label & " -> " & $v.reason & ": " & v.detail)
      check v.isAccepted

  test "a chain is bound to its root by public key and not by name alone":
    ## A trust store matched by Name would be satisfied by anyone who can
    ## spell the root's subject. The substitute below carries the right
    ## Name and the wrong key.
    let h = mintHierarchy(now, marked = false)
    let impostorKey = newTestKey()
    let impostorRoot = mintCert(impostorKey, impostorKey, CertOptions(
      subjectCn: RootCn, serial: randomSerial(),
      notBefore: now - 30 * 86_400, notAfter: now + 3650 * 86_400,
      isCa: true, keyUsageBits: @[5, 6]))
    check parseCertText(impostorRoot.der).subjectDn ==
      parseCertText(h.root.der).subjectDn
    let v = evaluateProductionChain(h.akChain, @[parseCertText(impostorRoot.der)],
                                    h.crlsOf, akExpectation(now))
    checkpoint($v.reason & ": " & v.detail)
    check v.reason == crUnknownRoot

  test "the endorsement and platform certificates are what they claim":
    ## The hierarchy mints more than a chain: the two certificates a
    ## machine's manufacturer and integrator issue are here too, and
    ## each carries its own TCG purpose. Checked by value, because a
    ## certificate whose purpose nothing reads is a field.
    let h = mintHierarchy(now, marked = false)
    let ek = parseCertText(h.ek.der)
    let platform = parseCertText(h.platform.der)
    let ak = parseCertText(h.ak.der)
    check ek.extKeyUsage == @[OidTcgEkCertificate]
    check platform.extKeyUsage == @[OidTcgPlatformCertificate]
    check ak.extKeyUsage == @[OidTcgAikCertificate]
    check ek.extKeyUsage != ak.extKeyUsage
    check platform.extKeyUsage != ak.extKeyUsage
    # And each chains to the same root under its own purpose.
    for (chain, eku) in [(h.ekChain, OidTcgEkCertificate),
                         (h.platformChain, OidTcgPlatformCertificate),
                         (h.akChain, OidTcgAikCertificate)]:
      var expect = akExpectation(now)
      expect.requiredEku = eku
      let v = evaluateProductionChain(chain, h.anchorsOf, h.crlsOf, expect)
      checkpoint($eku & " -> " & $v.reason & ": " & v.detail)
      check v.isAccepted

  test "withholding one piece of evidence changes the answer, and says so":
    ## Honest-absence probes. Each removes ONE thing the evaluator reads
    ## and nothing else, and each must produce a DIFFERENT refusal from
    ## the others — a gate whose text does not move when its input
    ## disappears is a gate reading something else.
    let h = mintHierarchy(now, marked = false)
    let full = evaluateProductionChain(h.akChain, h.anchorsOf, h.crlsOf,
                                       akExpectation(now))
    check full.isAccepted
    let noAnchors = evaluateProductionChain(h.akChain, newSeq[X509Cert](),
                                            h.crlsOf, akExpectation(now))
    check noAnchors.reason == crUnknownRoot
    let noCrls = evaluateProductionChain(h.akChain, h.anchorsOf,
                                         newSeq[X509Crl](), akExpectation(now))
    check noCrls.reason == crNoRevocationData
    let emptyChain = newSeq[string]()
    let noChain = evaluateProductionChain(emptyChain, h.anchorsOf, h.crlsOf,
                                          akExpectation(now))
    check noChain.reason == crTooShort
    var noEku = akExpectation(now)
    noEku.requiredEku = OidTcgEkCertificate
    check evaluateProductionChain(h.akChain, h.anchorsOf, h.crlsOf,
                                  noEku).reason == crWrongEku
    var texts = @[full.detail, noAnchors.detail, noCrls.detail,
                  noChain.detail]
    for i in 0 ..< texts.len:
      for j in (i + 1) ..< texts.len:
        check texts[i] != texts[j]

  test "a marked certificate cannot be laundered by stripping the mark":
    ## Three certificates, differing in one field and one splice.
    ##
    ## The mark lives inside the signed body. An attacker holding a
    ## marked certificate can remove it — and then holds a body its
    ## issuer never signed, because the signature covers the body that
    ## carried the mark. So the refusal MOVES from the mark to the
    ## signature rather than disappearing, and that is what makes the
    ## mark a constraint rather than a naming convention.
    ##
    ## The unmarked twin is minted with the issuer's real key, which an
    ## attacker does not have, and is accepted — the positive half,
    ## without which "the marked one is refused" is satisfied by an
    ## evaluator that refuses everything.
    let h = mintHierarchy(now, marked = false)
    let leafKey = newTestKey()
    let serial = randomSerial()
    let window = (now - 86_400'i64, now + 365 * 86_400'i64)
    proc leafOptions(marked: bool): CertOptions =
      CertOptions(
        subjectCn: AkCn, issuerName: h.intermediate.subjectName,
        serial: serial, notBefore: window[0], notAfter: window[1],
        keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
        sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)],
        marked: marked)
    let markedLeaf = mintCert(leafKey, h.intermediate.key, leafOptions(true))
    let plainLeaf = mintCert(leafKey, h.intermediate.key, leafOptions(false))

    let markedCert = parseCertText(markedLeaf.der)
    let plainCert = parseCertText(plainLeaf.der)
    check SoftwareRootMarkerTestOid in markedCert.criticalOids
    check SoftwareRootMarkerTestOid notin plainCert.criticalOids
    check markedCert.serialHex == plainCert.serialHex
    check markedCert.subjectDn == plainCert.subjectDn

    let marked = evaluateProductionChain(
      @[markedLeaf.der, h.intermediate.der, h.root.der],
      h.anchorsOf, h.crlsOf, akExpectation(now))
    checkpoint("marked: " & $marked.reason & ": " & marked.detail)
    check marked.reason == crUnrecognisedCriticalExtension
    check SoftwareRootMarkerTestOid in marked.detail

    let plain = evaluateProductionChain(
      @[plainLeaf.der, h.intermediate.der, h.root.der],
      h.anchorsOf, h.crlsOf, akExpectation(now))
    checkpoint("unmarked twin: " & $plain.reason & ": " & plain.detail)
    check plain.isAccepted

    # The laundering: the unmarked body, carrying the signature its
    # issuer made over the MARKED one. Every other field is identical,
    # so nothing but the missing extension distinguishes the bodies.
    let laundered = recombine(plainCert.tbs, markedCert.signature)
    let after = evaluateProductionChain(
      @[laundered, h.intermediate.der, h.root.der],
      h.anchorsOf, h.crlsOf, akExpectation(now))
    checkpoint("laundered: " & $after.reason & ": " & after.detail)
    check after.reason == crBadSignature
    check SoftwareRootMarkerTestOid notin
      parseCertText(laundered).criticalOids

  test "every way a revocation list can fail to cover reaches the refusal":
    ## Shape guard against a rule with no reachable input. The list
    ## search has six filters, and a filter nothing exercises is a
    ## filter that can be deleted without reddening anything. Each is
    ## given an input here, and the positive control — a list that
    ## passes all six — is accepted, so the refusals are about the
    ## filters rather than about the search never succeeding.
    let h = mintHierarchy(now, marked = false)
    let interName = h.intermediate.subjectName
    let stranger = mintHierarchy(now, marked = false)
    proc withIntermediateCrl(crl: string): ChainRejection =
      evaluateProductionChain(h.akChain, h.anchorsOf,
        @[h.crlsOf[0], parseCrlText(crl)], akExpectation(now)).reason
    let good = mintCrl(h.intermediate.key, interName,
                       now - 86_400, now + 30 * 86_400, [])
    check withIntermediateCrl(good) == crAccepted
    checkpoint("no list at all")
    check evaluateProductionChain(h.akChain, h.anchorsOf, @[h.crlsOf[0]],
      akExpectation(now)).reason == crNoRevocationData
    checkpoint("a list issued by somebody else")
    check withIntermediateCrl(mintCrl(stranger.intermediate.key,
      stranger.intermediate.subjectName, now - 86_400, now + 30 * 86_400,
      [])) == crNoRevocationData
    checkpoint("a list carrying the right name and the wrong signature")
    check withIntermediateCrl(mintCrl(stranger.intermediate.key, interName,
      now - 86_400, now + 30 * 86_400, [])) == crNoRevocationData
    checkpoint("a list whose window has passed")
    check withIntermediateCrl(mintCrl(h.intermediate.key, interName,
      now - 60 * 86_400, now - 30 * 86_400, [])) == crNoRevocationData
    checkpoint("a list whose window has not begun")
    check withIntermediateCrl(mintCrl(h.intermediate.key, interName,
      now + 30 * 86_400, now + 60 * 86_400, [])) == crNoRevocationData
    checkpoint("a list with no nextUpdate")
    check withIntermediateCrl(mintCrlWithoutNextUpdate(h.intermediate.key,
      interName, now - 86_400)) == crNoRevocationData
    # And the good list still works after all of that, so the search is
    # not simply broken.
    check withIntermediateCrl(good) == crAccepted

  test "three further rules are given the input that reaches them":
    ## Each of these sits behind an earlier rule that the catalogue's
    ## fixtures trip first, so without a case of its own none of them
    ## would ever run. Each is reached here, and each carries wording no
    ## other rule produces.
    let h = mintHierarchy(now, marked = false)

    checkpoint("a leaf that states no extended key usage at all")
    let noEkuLeaf = mintCert(newTestKey(), h.intermediate.key, CertOptions(
      subjectCn: AkCn, issuerName: h.intermediate.subjectName,
      serial: randomSerial(), notBefore: now - 86_400,
      notAfter: now + 365 * 86_400, keyUsageBits: @[0],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)]))
    let noEku = evaluateProductionChain(
      @[noEkuLeaf.der, h.intermediate.der, h.root.der],
      h.anchorsOf, h.crlsOf, akExpectation(now))
    checkpoint(noEku.detail)
    check noEku.reason == crWrongEku
    check "states no extended key usage at all" in noEku.detail

    checkpoint("a chain whose last element is not self-issued")
    let truncated = evaluateProductionChain(
      @[h.ak.der, h.intermediate.der], h.anchorsOf, h.crlsOf,
      akExpectation(now))
    checkpoint(truncated.detail)
    check truncated.reason == crNameMismatch
    check "not the self-issued root a chain ends in" in truncated.detail
    check "are not links of one chain" notin truncated.detail

    checkpoint("an issuer flagged cA and not permitted to sign certificates")
    let interKey = newTestKey()
    let weakInter = mintCert(interKey, h.root.key, CertOptions(
      subjectCn: IntermediateCn, issuerName: h.root.subjectName,
      serial: randomSerial(), notBefore: now - 20 * 86_400,
      notAfter: now + 1825 * 86_400, isCa: true, keyUsageBits: @[6]))
    let weakLeaf = mintCert(newTestKey(), interKey, CertOptions(
      subjectCn: AkCn, issuerName: weakInter.subjectName,
      serial: randomSerial(), notBefore: now - 86_400,
      notAfter: now + 365 * 86_400, keyUsageBits: @[0],
      eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)]))
    let weak = evaluateProductionChain(
      @[weakLeaf.der, weakInter.der, h.root.der], h.anchorsOf,
      @[h.crlsOf[0], parseCrlText(mintCrl(interKey, weakInter.subjectName,
        now - 86_400, now + 30 * 86_400, []))], akExpectation(now))
    checkpoint(weak.detail)
    check weak.reason == crNotACertificateAuthority
    check "does not include keyCertSign" in weak.detail
    check "was never authorised to issue anything" notin weak.detail

  test "the reader refuses encodings that are not DER":
    ## The chain evaluator's malformed arm is reached by a truncation in
    ## the catalogue; these reach the reader's own refusals, which sit
    ## underneath it. Each names what it refused.
    let h = mintHierarchy(now, marked = false)
    proc refusal(der: string): string =
      try:
        discard parseCertText(der)
        return ""
      except X509Error as err:
        return err.msg
    check refusal(h.ak.der) == ""            # the unmodified certificate
    checkpoint("bytes after the outer SEQUENCE")
    let trailing = refusal(h.ak.der & "\x00")
    checkpoint(trailing)
    check "follow the outer SEQUENCE" in trailing
    checkpoint("an indefinite length")
    var indefinite = h.ak.der
    indefinite[1] = char(0x80'u8)
    let indefiniteMsg = refusal(indefinite)
    checkpoint(indefiniteMsg)
    check "BER and not DER" in indefiniteMsg
    check indefiniteMsg != trailing

  test "the reader's refusals are reached rather than merely written":
    ## A refusal with no reachable input is code nothing proves runs. The
    ## chain evaluator's rules are each reached by a fixture above; the
    ## READER's are not reached by any of them, because a chain minted by
    ## a correct encoder never trips one. So each is given an input here.
    ##
    ## Two kinds of input, and neither needs an encoder that emits bad
    ## DER on purpose: a short hand-written blob for the refusals that
    ## fire on the first few bytes, and a SAME-LENGTH byte splice into a
    ## genuine certificate for the ones that sit deeper in the grammar.
    ## Each refusal's phrase is then required to be absent from every
    ## OTHER refusal's message, so no two of them hide behind one string.
    let h = mintHierarchy(now, marked = false)
    proc certRefusal(der: string): string =
      try:
        discard parseCertText(der)
        return ""
      except X509Error as err:
        return err.msg
    proc crlRefusal(der: string): string =
      try:
        discard parseCrlText(der)
        return ""
      except X509Error as err:
        return err.msg

    proc spliced(needle, replacement: string): string =
      ## One same-length substitution into the genuine attestation-key
      ## certificate, so no enclosing length has to be repaired and the
      ## only thing that changed is the field under test.
      doAssert needle.len == replacement.len
      let i = h.ak.der.find(needle)
      doAssert i >= 0, "the byte pattern under test is not in this certificate"
      result = h.ak.der
      for j in 0 ..< replacement.len: result[i + j] = replacement[j]

    # The first UTCTime in the certificate is notBefore: tag 0x17, length
    # 13, twelve digits and a 'Z'.
    let timeAt = h.ak.der.find("\x17\x0d")
    check timeAt >= 0
    proc withTime(edit: proc (s: var string)): string =
      result = h.ak.der
      edit(result)

    var probes: seq[(string, string, string)] = @[]
    proc probe(label, message, phrase: string) =
      probes.add (label, message, phrase)

    probe("no bytes at all", certRefusal(""), "certificate: zero bytes")
    probe("larger than this reader reads",
          certRefusal(repeat('\x30', MaxCertificateBytes + 1)),
          "at most " & $MaxCertificateBytes & " are read")
    probe("a tag with no length", certRefusal("\x30"),
          "ends where a length was expected")
    probe("an empty outer SEQUENCE", certRefusal("\x30\x00"),
          "ends where a tag was expected")
    probe("an outer element that is not a SEQUENCE", certRefusal("\x31\x00"),
          "certificate: expected tag 0x30 and found 0x31")
    probe("a five-byte length", certRefusal("\x30\x85\x01\x02\x03\x04\x05"),
          "a length of 5 bytes")
    probe("a length that runs off the end",
          certRefusal("\x30\x83\x01\x02"),
          "ends inside a long-form length")
    probe("a short length written long",
          certRefusal("\x30\x81\x05\x01\x02\x03\x04\x05"),
          "DER requires the short one")
    probe("a length with a leading zero byte",
          certRefusal("\x30\x83\x00\x00\x90" & repeat('\x00', 0x90)),
          "redundant leading zero")
    probe("a version that is not v3",
          certRefusal(spliced("\xa0\x03\x02\x01\x02", "\xa0\x03\x02\x01\x01")),
          "the version is not v3")
    probe("no version at all",
          certRefusal(spliced("\xa0\x03\x02\x01\x02", "\x02\x03\x02\x01\x02")),
          "no version is present")
    probe("a signature algorithm that is not ecdsa-with-SHA256",
          certRefusal(spliced("\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02",
                              "\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x03")),
          "this build verifies only ecdsa-with-SHA256")
    probe("a named curve that is not prime256v1",
          certRefusal(spliced("\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07",
                              "\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x08")),
          "this build reads only prime256v1")
    probe("a public key that is not an uncompressed point",
          certRefusal(spliced("\x03\x42\x00\x04", "\x03\x42\x00\x05")),
          "does not begin 0x04")
    probe("criticality written as an explicit FALSE",
          certRefusal(spliced("\x01\x01\xff", "\x01\x01\x00")),
          "DER writes TRUE as 0xFF and omits FALSE")
    probe("a UTCTime that does not end in Z",
          certRefusal(withTime(proc (s: var string) =
            s[timeAt + 14] = 'q')),
          "not 13 characters ending in Z")
    probe("a UTCTime naming no instant",
          certRefusal(withTime(proc (s: var string) =
            s[timeAt + 4] = '9'
            s[timeAt + 5] = '9')),
          "names no instant")
    probe("the same extension twice",
          certRefusal(mintCert(newTestKey(), h.intermediate.key, CertOptions(
            subjectCn: AkCn, issuerName: h.intermediate.subjectName,
            serial: randomSerial(), notBefore: now - 86_400,
            notAfter: now + 365 * 86_400, keyUsageBits: @[0],
            eku: @[OidTcgAikCertificate],
            duplicateFirstExtension: true)).der),
          "appears twice")
    probe("a revocation list of no bytes", crlRefusal(""),
          "revocation list: zero bytes")
    probe("a revocation list that is not a SEQUENCE", crlRefusal("\x31\x00"),
          "revocation list: expected tag 0x30")

    for (label, message, phrase) in probes:
      checkpoint(label & " -> " & message)
      check message.len > 0
      check phrase in message
    # No two of these refusals answer to one another's phrase, so deleting
    # any one of them cannot leave another standing in for it.
    for (label, message, phrase) in probes:
      for (otherLabel, otherMessage, _) in probes:
        if otherLabel == label: continue
        if phrase in otherMessage:
          checkpoint(label & "'s phrase " & phrase.escape() &
            " is also produced by " & otherLabel)
        check phrase notin otherMessage
    # The unmodified certificate still reads, so the refusals above are
    # about the edits and not about the reader having stopped working.
    check certRefusal(h.ak.der) == ""
    check crlRefusal(h.rootCrl) == ""

  test "a root whose self-signature is forged is refused as that":
    ## Found by mutation rather than by design: deleting the rule that
    ## verifies the root's own signature left every case in this file
    ## green, because nothing reached it. The certificate below carries
    ## the genuine root's body — so it has the anchor's Name and the
    ## anchor's public key, and matches the trust store — with another
    ## root's signature on it. Every earlier rule passes; this one does
    ## not.
    let h = mintHierarchy(now, marked = false)
    let stranger = mintHierarchy(now, marked = false)
    let genuine = parseCertText(h.root.der)
    let forged = recombine(genuine.tbs,
                           parseCertText(stranger.root.der).signature)
    let parsed = parseCertText(forged)
    check parsed.subjectDn == genuine.subjectDn
    check parsed.publicKey == genuine.publicKey
    check parsed.signature != genuine.signature
    let v = evaluateProductionChain(@[h.ak.der, h.intermediate.der, forged],
      h.anchorsOf, h.crlsOf, akExpectation(now))
    checkpoint($v.reason & ": " & v.detail)
    check v.reason == crBadSignature
    check "not the self-signed certificate it is shaped like" in v.detail
    check "did not sign them" notin v.detail
    # And the same chain with the genuine root is accepted, so the
    # forgery is the only difference.
    check evaluateProductionChain(h.akChain, h.anchorsOf, h.crlsOf,
      akExpectation(now)).isAccepted
