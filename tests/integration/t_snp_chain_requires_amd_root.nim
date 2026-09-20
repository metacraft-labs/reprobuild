## A chain rooted anywhere but the vendor is refused, and it is refused
## because the verifier cannot be told about another root.
##
## ## The claim, and why "it rejects" would not be it
##
## Showing that some other chain is refused is easy and nearly worthless:
## almost any difference produces a refusal, and a gate satisfied by
## "something objected" keeps passing after the rule it was written for
## is deleted. Two things have to be true instead.
##
## **One: the impostor is refused for the root, and for nothing else.**
## The bundle it is given is byte-identical to the vendor's own chain
## except in the bytes that say whose keys these are — same distinguished
## names, same serials, same validity, same extensions with the same
## values, same algorithm identifiers, same lengths. It is internally
## valid: this gate verifies its signatures under its own root, with the
## same RSA implementation the verifier uses, and they verify. It comes
## with a report that its own endorsement key signed, and that verifies
## too. So when the verdict says the root is unknown, there is nothing
## else it could have said.
##
## **Two: no configuration could have accepted it.** This is the half
## that is structural rather than empirical, and it rests on three facts
## a case below asserts mechanically:
##
##   * `evaluateAmdChain` has no anchor parameter. Its whole signature is
##     recorded as a type, and the assignment below fails to compile if a
##     parameter is added, removed or retyped — including an "allowed
##     roots", an options object, or a permissive bool.
##   * the root set is a compile-time constant. A `static` block reads it,
##     which only a `const` can satisfy; a value loaded from a file, an
##     environment variable or a mutable global could not.
##   * the set has exactly three members, and each of the three is
##     re-derived here from the vendor's own published bytes rather than
##     compared against itself.
##
## That last point is the difference between "the pinned key is what the
## source says" and "the pinned key is the vendor's". The gate decodes
## the vendor's published certificate chains and pulls the modulus and
## exponent out of them, and requires the table to agree. A typo in the
## table is red.
##
## ## What the impostor does NOT prove, said plainly
##
## It proves the rule fires. It says nothing about whether the pinned
## keys are the right keys — a verifier pinned to the wrong root would
## pass every case here. The evidence for the keys being right is
## different in kind and lives in `snp_vectors`: the same bytes from the
## vendor's own service and from two unrelated projects that publish
## them, in three-way byte-identical agreement.
##
## ## Mocking
##
## None. The impostor is not a mock; it is a real certificate chain with
## real RSA-4096 and P-384 keys and real signatures. It simply belongs to
## somebody else.

import std/[exitprocs, os, strutils, unittest]

import repro_attest_verify/snp_chain
import repro_attest_verify/snp_report
import repro_attest_verify/x509

include ./attestation_verifier_harness
include ./snp_vectors

var reachedChainKinds: set[AmdChainRejection] = {}

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var f: File
  if open(f, path, fmAppend):
    for k in AmdChainRejection:
      if k in reachedChainKinds: f.writeLine("snp_chain:" & $k)
    f.close()

addExitProc(writeCensus)

proc bytesOfHex(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc base64Decode(text: string): seq[byte] =
  const Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var acc = 0
  var bits = 0
  for c in text:
    if c == '=': break
    let idx = Alphabet.find(c)
    if idx < 0: continue
    acc = (acc shl 6) or idx
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xff)

proc pemCertificates(text: string): seq[seq[byte]] =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    result.add base64Decode(text[b + Begin.len ..< e])
    pos = e + End.len

proc substituteAscii(der: seq[byte]; before, after: string;
                     expected: int): seq[byte] =
  ## Replace every occurrence of one ASCII run with another of the SAME
  ## length, and require the count to be the one the caller declared.
  ##
  ## Same length is what keeps this a substitution rather than a
  ## re-encoding: no DER length moves, so the document that comes out
  ## differs from the vendor's in exactly the characters named here and
  ## in nothing else. The declared count is what stops a mutation from
  ## silently landing in more places, or none, after somebody edits a
  ## fixture.
  doAssert before.len == after.len
  result = der
  var hits = 0
  for i in 0 .. result.len - before.len:
    var match = true
    for j in 0 ..< before.len:
      if result[i + j] != byte(before[j]):
        match = false
        break
    if match:
      inc hits
      for j in 0 ..< after.len: result[i + j] = byte(after[j])
  doAssert hits == expected,
    "expected " & $expected & " occurrence(s) of " & before.escape() &
      " and found " & $hits

proc substituteBytes(der: seq[byte]; before, after: seq[byte];
                     expected: int): seq[byte] =
  doAssert before.len == after.len
  result = der
  var hits = 0
  for i in 0 .. result.len - before.len:
    var match = true
    for j in 0 ..< before.len:
      if result[i + j] != before[j]:
        match = false
        break
    if match:
      inc hits
      for j in 0 ..< after.len: result[i + j] = after[j]
  doAssert hits == expected

proc withBrokenSignature(der: seq[byte]): seq[byte] =
  ## The same certificate with one bit of its signature flipped.
  ##
  ## The signature BIT STRING is the last element of the outer SEQUENCE
  ## and the reader refuses anything after it, so the final byte is a
  ## signature byte by construction. Nothing inside `tbsCertificate`
  ## moves, and that is what makes this input reach the signature rule
  ## instead of a structural one: the names still link, the key is still
  ## the pinned one, the extensions are still the vendor's and every
  ## window is still the window the vendor wrote.
  result = der
  result[^1] = result[^1] xor 0x01'u8

const RemovedTimeBytes = 15
  ## A DER `UTCTime` in the form the vendor writes: `17 0d` and thirteen
  ## characters.

proc withoutNextUpdate(der: seq[byte]): seq[byte] =
  ## The vendor's own revocation list with its `nextUpdate` field
  ## removed and the two enclosing lengths repaired.
  ##
  ## An optional field is the one thing that cannot be produced by
  ## substituting bytes in place, so this is the one fixture here that
  ## re-encodes. It re-encodes exactly two integers — the lengths of the
  ## outer SEQUENCE and of `tbsCertList` — and deletes one TLV; every
  ## other byte, including the signature, is the vendor's. The signature
  ## no longer verifies over the shortened body, which is fine and is
  ## the point: the rule that refuses a list with no next update sits
  ## ABOVE the signature check, so this input reaches it first.
  doAssert der[0] == 0x30'u8 and der[1] == 0x82'u8
  doAssert der[4] == 0x30'u8 and der[5] == 0x82'u8
  var times: seq[int] = @[]
  for i in 0 .. der.len - 2:
    if der[i] == 0x17'u8 and der[i + 1] == 0x0d'u8: times.add i
  doAssert times.len == 2,
    "expected exactly thisUpdate and nextUpdate, found " & $times.len
  let at = times[1]
  result = der[0 ..< at] & der[at + RemovedTimeBytes .. ^1]
  doAssert result.len == der.len - RemovedTimeBytes
  for lenAt in [2, 6]:
    let was = (int(result[lenAt]) shl 8) or int(result[lenAt + 1])
    let now = was - RemovedTimeBytes
    result[lenAt] = byte(now shr 8)
    result[lenAt + 1] = byte(now and 0xff)

var refusalsObserved = 0
  ## See the same counter in the report gate: cases assert their own
  ## delta so a loop that stopped iterating moves a number.

const
  BadSignatureRules*: array[3, string] = [
    "the endorsement certificate does not verify under",
    "the intermediate does not verify under",
    "the root does not verify under its own key"]
  RevocationRules*: array[5, string] = [
    "one is issued by",
    "one states no next update at all",
    "one is not in force until",
    "one stopped being current at",
    "one carries a signature this root did not make"]
  NameLinkRules*: array[2, string] = [
    "the endorsement certificate names",
    "the intermediate names"]
  AuthorityRules*: array[2, string] = [
    "does not carry basicConstraints cA TRUE",
    "has a keyUsage that does not include keyCertSign"]
  WindowRules*: array[2, string] = [
    "is not valid until",
    "stopped being valid at"]
    ## The rules that SHARE a refusal kind, one list per kind.
    ##
    ## Six of the sixteen kinds are produced by more than one rule, so a
    ## case that asserted only the kind would be asserting "one of
    ## these" — which is the shape that has been defeated in this tree
    ## eleven times. Every case below that lands on a shared kind names
    ## which rule it means and requires the others to be absent.

proc assertOneRule(detail: string; rules: openArray[string];
                   want: string) =
  ## `want` is in this detail and no sibling rule sharing its kind is.
  var found = false
  for r in rules:
    if r == want:
      check r in detail
      found = true
    else:
      check r notin detail
  check found

proc assertOnlyRefusal(v: AmdChainVerdict; want: AmdChainRejection) =
  ## The verdict names this rule, and the wording of no other rule
  ## appears in it. Both halves matter: a case that asserted only the
  ## enum would pass on a detail sentence copied from another rule, and
  ## a case that asserted only the message would pass on any refusal
  ## whose sentence happened to contain the fragment.
  inc refusalsObserved
  check not v.isAccepted
  check v.reason == want
  check AmdChainMessage[want] in v.detail
  for other in AmdChainRejection:
    if other == want: continue
    check AmdChainMessage[other] notin v.detail
  reachedChainKinds.incl want

const
  Now = 1_788_220_800'i64   ## 2026-09-01T00:00:00Z; see `snp_vectors`.

let milan = pemCertificates(KdsMilanChainPem)
let genoa = pemCertificates(KdsGenoaChainPem)
let turin = pemCertificates(KdsTurinChainPem)
let vlekChain = pemCertificates(GsgMilanVlekChainPem)

let milanAsk = milan[0]
let milanArk = milan[1]
let turinAsk = turin[0]
let turinArk = turin[1]
let milanCrl = @[bytesOfHex(KdsMilanCrlDerHex)]
let turinCrl = @[bytesOfHex(KdsTurinCrlDerHex)]

let genuineVcek = bytesOfHex(VirteeMilanVcekDerHex)
let turinVcek = bytesOfHex(VirteeTurinVcekDerHex)

let impostorArk = bytesOfHex(ImpostorArkHex)
let impostorAsk = bytesOfHex(ImpostorAskHex)
let impostorVcek = bytesOfHex(ImpostorVcekHex)
let impostorReport = bytesOfHex(ImpostorReportHex)

# ---------------------------------------------------------------------

suite "the root set":

  test "t_snp_the_pinned_roots_are_the_vendors_own_published_keys":
    # Re-derived from the vendor's published chains, not compared with
    # themselves. A mistyped digit in the table is red here.
    check AmdRootKeys.len == 3
    var derived = 0
    for (line, pem) in {aplMilan: milan, aplGenoa: genoa, aplTurin: turin}:
      checkpoint $line
      check pem.len == 2
      let ark = parseAmdCertificate(pem[1])
      let pinned = AmdRootKeys[line]
      check ark.keyKind == akRsa4096
      check ark.rsaModulus.len == RsaModulusLen
      check hexOfBytes(ark.rsaModulus) == pinned.modulusHex
      check hexOfBytes(ark.rsaExponent) == pinned.exponentHex
      check ark.subjectCn == pinned.commonName
      check pinned.line == line
      check amdRootFor(ark.rsaModulus, ark.rsaExponent) == ord(line)
      inc derived
    check derived == 3

    # The three are distinct from one another, so "matched a pinned
    # root" is not a statement that one key matches everything.
    for a in AmdProductLine:
      for b in AmdProductLine:
        if a == b: continue
        check AmdRootKeys[a].modulusHex != AmdRootKeys[b].modulusHex
        check AmdRootKeys[a].commonName != AmdRootKeys[b].commonName

  test "t_snp_the_root_set_is_a_compile_time_constant":
    # Only a `const` satisfies a `static` block. A table read from a
    # file, an environment variable or a mutable global could not be
    # evaluated here, so this is a statement about WHEN the roots are
    # fixed and not merely about what they are.
    static:
      doAssert AmdRootKeys.len == 3
      doAssert AmdRootKeys[aplMilan].commonName == "ARK-Milan"
      doAssert AmdRootKeys[aplGenoa].commonName == "ARK-Genoa"
      doAssert AmdRootKeys[aplTurin].commonName == "ARK-Turin"
      doAssert AmdRootKeys[aplMilan].modulusHex.len == 2 * 512
    check ord(high(AmdProductLine)) + 1 == 3

  test "t_snp_the_chain_evaluator_has_no_anchor_parameter":
    # The structural half of this gate's claim.
    #
    # This is an assignment, not a `not compiles(...)`: a negative
    # compile-time assertion passes just as happily on a misspelling as
    # on the property it was written for, whereas this one requires both
    # names to resolve and both types to match exactly. Add a parameter
    # to `evaluateAmdChain` — an anchor, a root set, an options object,
    # a bool — and this file stops compiling, naming the procedure.
    let evaluator: AmdChainSignature = evaluateAmdChain
    check not evaluator.isNil
    # And the type it is pinned to is the one described in prose: three
    # certificates, revocation lists, a clock. Exercised through the
    # pinned variable rather than through the procedure, so the check is
    # about the TYPE and not about the procedure's own name.
    let viaType = evaluator(genuineVcek, milanAsk, milanArk, milanCrl, Now)
    check viaType.isAccepted
    check viaType.rootLine == aplMilan

suite "the vendor's own chains are accepted":

  test "t_snp_a_genuine_chain_is_accepted":
    # The positive control. Without it every refusal below is consistent
    # with a verifier that refuses everything.
    let v = evaluateAmdChain(genuineVcek, milanAsk, milanArk, milanCrl, Now)
    checkpoint v.detail
    check v.isAccepted
    check v.reason == acAccepted
    check v.rootMatched
    check v.rootLine == aplMilan
    check v.revocationConsulted
    reachedChainKinds.incl acAccepted

  test "t_snp_the_vendors_second_signing_key_is_rooted_at_the_same_place":
    # The vendor publishes a second signing certificate for the other
    # kind of endorsement key. Its root is the SAME root — asserted on
    # the bytes — so both kinds of chain are anchored at one key.
    #
    # There is no leaf for this path anywhere public, so what is checked
    # is the two links that exist and nothing is implied about the
    # third. Stated here rather than left for a reader to notice.
    check vlekChain.len == 2
    check hexOfBytes(vlekChain[1]) == hexOfBytes(milanArk)
    let asvk = parseAmdCertificate(vlekChain[0])
    let ark = parseAmdCertificate(vlekChain[1])
    check asvk.subjectCn == "SEV-VLEK-Milan"
    check asvk.issuerCn == "ARK-Milan"
    check asvk.serialHex != parseAmdCertificate(milanAsk).serialHex
    check asvk.signatureVerifiesUnder(ark)
    check amdRootFor(ark.rsaModulus, ark.rsaExponent) == ord(aplMilan)
    check VlekCommonName in EndorsementKeyCommonNames
    check VcekCommonName in EndorsementKeyCommonNames
    check EndorsementKeyCommonNames.len == 2

suite "the impostor":

  test "t_snp_the_impostor_is_structurally_the_vendors_chain":
    # Measured, so that "identical except for the keys" is a number and
    # not an assurance.
    let gArk = parseAmdCertificate(milanArk)
    let gAsk = parseAmdCertificate(milanAsk)
    let gVcek = parseAmdCertificate(genuineVcek)
    let iArk = parseAmdCertificate(impostorArk)
    let iAsk = parseAmdCertificate(impostorAsk)
    let iVcek = parseAmdCertificate(impostorVcek)

    for (g, i) in {gArk: iArk, gAsk: iAsk, gVcek: iVcek}:
      check g.der.len == i.der.len
      check hexOfBytes(g.subjectDn) == hexOfBytes(i.subjectDn)
      check hexOfBytes(g.issuerDn) == hexOfBytes(i.issuerDn)
      check g.serialHex == i.serialHex
      check g.notBefore == i.notBefore
      check g.notAfter == i.notAfter
      check g.keyKind == i.keyKind
      check g.extensions.len == i.extensions.len
      for k in 0 ..< g.extensions.len:
        check g.extensions[k].oid == i.extensions[k].oid
        check g.extensions[k].critical == i.extensions[k].critical
      check g.isCa == i.isCa
      check g.keyUsage == i.keyUsage
    # The leaf keeps the vendor's platform version and part identity, so
    # the impostor could pass every binding check there is.
    check iVcek.productName == gVcek.productName
    check (iVcek.blSpl, iVcek.teeSpl, iVcek.snpSpl, iVcek.ucodeSpl) ==
      (gVcek.blSpl, gVcek.teeSpl, gVcek.snpSpl, gVcek.ucodeSpl)
    check hexOfBytes(iVcek.hwId) == hexOfBytes(gVcek.hwId)
    check iVcek.hwId.len == HwIdLen
    # And the keys really are different keys.
    check hexOfBytes(iArk.rsaModulus) != hexOfBytes(gArk.rsaModulus)
    check hexOfBytes(iAsk.rsaModulus) != hexOfBytes(gAsk.rsaModulus)
    check hexOfBytes(iVcek.ecPoint) != hexOfBytes(gVcek.ecPoint)

  test "t_snp_the_impostor_is_internally_valid":
    # If the impostor were merely broken, refusing it would say nothing.
    # Every link is verified here with the same RSA implementation the
    # verifier uses, under the impostor's OWN root.
    let iArk = parseAmdCertificate(impostorArk)
    let iAsk = parseAmdCertificate(impostorAsk)
    let iVcek = parseAmdCertificate(impostorVcek)
    check iArk.signatureVerifiesUnder(iArk)
    check iAsk.signatureVerifiesUnder(iArk)
    check iVcek.signatureVerifiesUnder(iAsk)
    # …and the report it comes with verifies under its endorsement key.
    let report = parseSnpReport(impostorReport)
    check verifyReportSignature(report, iVcek.ecPoint)
    # The same report does NOT verify under the genuine part's key, and
    # the genuine report does not verify under the impostor's — so the
    # two bundles are two, and neither borrows from the other.
    let gVcek = parseAmdCertificate(genuineVcek)
    check not verifyReportSignature(report, gVcek.ecPoint)
    let genuineReport = parseSnpReport(bytesOfHex(VirteeMilanReportHex))
    check not verifyReportSignature(genuineReport, iVcek.ecPoint)
    # Only the signature field moved.
    check hexOfBytes(report.signedBytes) ==
      hexOfBytes(genuineReport.signedBytes)
    check hexOfBytes(report.chipId) == hexOfBytes(genuineReport.chipId)
    check hexOfBytes(report.measurement) ==
      hexOfBytes(genuineReport.measurement)

  test "t_snp_the_impostor_chain_is_refused_for_its_root_and_nothing_else":
    # THE case.
    let v = evaluateAmdChain(impostorVcek, impostorAsk, impostorArk,
                             milanCrl, Now)
    checkpoint v.detail
    check not v.isAccepted
    assertOnlyRefusal(v, acRootIsNotAmd)
    check not v.rootMatched
    check not v.revocationConsulted
    # Everything the refusal is NOT about, stated as values rather than
    # left to the message: the chain links, the certificates are inside
    # their windows, the leaf is the right kind of document.
    let iVcek = parseAmdCertificate(impostorVcek)
    let iAsk = parseAmdCertificate(impostorAsk)
    let iArk = parseAmdCertificate(impostorArk)
    check hexOfBytes(iVcek.issuerDn) == hexOfBytes(iAsk.subjectDn)
    check hexOfBytes(iAsk.issuerDn) == hexOfBytes(iArk.subjectDn)
    check hexOfBytes(iArk.issuerDn) == hexOfBytes(iArk.subjectDn)
    check iArk.isCa and iAsk.isCa
    check Now >= iVcek.notBefore and Now < iVcek.notAfter
    check Now >= iAsk.notBefore and Now < iAsk.notAfter
    check Now >= iArk.notBefore and Now < iArk.notAfter
    check iVcek.subjectCn == VcekCommonName
    check amdRootFor(iArk.rsaModulus, iArk.rsaExponent) < 0

  test "t_snp_the_root_rule_fires_whichever_parts_are_genuine":
    # The impostor root under genuine lower links, and genuine root
    # under impostor lower links. The first is still the root rule; the
    # second is a DIFFERENT rule, which is what says the two are two.
    let a = evaluateAmdChain(genuineVcek, milanAsk, impostorArk,
                             milanCrl, Now)
    checkpoint a.detail
    assertOnlyRefusal(a, acRootIsNotAmd)

    let b = evaluateAmdChain(impostorVcek, impostorAsk, milanArk,
                             milanCrl, Now)
    checkpoint b.detail
    assertOnlyRefusal(b, acBadSignature)
    check b.rootMatched          # the root WAS recognised, this time
    check b.rootLine == aplMilan

suite "other roots, including the vendor's other ones":

  test "t_snp_a_different_generation_of_the_same_vendor_does_not_substitute":
    # A real vendor root, correctly pinned, correctly signed — and still
    # not the root this chain descends from.
    let v = evaluateAmdChain(genuineVcek, milanAsk, turinArk, turinCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acNameMismatch)
    let w = evaluateAmdChain(turinVcek, turinAsk, milanArk, milanCrl, Now)
    checkpoint w.detail
    check not w.isAccepted

  test "t_snp_a_pinned_key_under_a_different_name_is_refused":
    # The vendor's real root key, in a certificate that calls itself the
    # other generation's root. The two names are the same length, so the
    # document is otherwise untouched. Without this rule a genuine root
    # could be presented as a different one, and a chain would be
    # accepted under a generation it has nothing to do with.
    let ark = substituteAscii(milanArk, "ARK-Milan", "ARK-Turin", 2)
    let ask = substituteAscii(milanAsk, "ARK-Milan", "ARK-Turin", 1)
    check ark.len == milanArk.len
    let v = evaluateAmdChain(genuineVcek, ask, ark, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acRootNameDisagreesWithKey)
    check v.rootMatched
    check v.rootLine == aplMilan

  test "t_snp_a_root_that_is_not_self_issued_is_refused":
    # Only the root's ISSUER is renamed, so it still carries the name
    # the intermediate points at and still holds a pinned key.
    let ark = substituteAscii(milanArk, "ARK-Milan", "ARK-Turin", 2)
    # Put the subject back: the issuer is the first of the two Names in
    # a certificate body, the subject the second.
    var patched = milanArk
    var replaced = 0
    for i in 0 .. patched.len - 9:
      var hit = true
      for j in 0 ..< 9:
        if patched[i + j] != byte("ARK-Milan"[j]): hit = false
      if hit:
        inc replaced
        if replaced == 1:
          for j in 0 ..< 9: patched[i + j] = byte("ARK-Turin"[j])
    check replaced == 2
    check ark.len == patched.len
    let v = evaluateAmdChain(genuineVcek, milanAsk, patched, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acNotSelfIssued)

suite "the rest of the chain's rules, each on its own input":

  test "t_snp_an_element_that_is_not_a_vendor_certificate_is_refused":
    # The algorithm identifier is compared byte for byte, so one byte of
    # the object identifier is enough — and the refusal must SAY which
    # rule, because a generic parse failure would hide it.
    var patched = milanArk
    # 1.2.840.113549.1.1.10 -> …1.11 (sha512WithRSA), same length.
    let before = bytesOfHex("2a864886f70d01010a")
    let after = bytesOfHex("2a864886f70d01010b")
    patched = substituteBytes(patched, before, after, 2)
    let v = evaluateAmdChain(genuineVcek, milanAsk, patched, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acMalformed)
    check "RSASSA-PSS" in v.detail
    # …and the two admitted spellings really are two, and exactly two.
    check admittedPssAlgorithmIdentifiers().len == 2
    check hexOfBytes(admittedPssAlgorithmIdentifiers()[0]) !=
      hexOfBytes(admittedPssAlgorithmIdentifiers()[1])
    check isAdmittedPssAlgorithm(admittedPssAlgorithmIdentifiers()[0])
    check isAdmittedPssAlgorithm(admittedPssAlgorithmIdentifiers()[1])
    check not isAdmittedPssAlgorithm(bytesOfHex("3000"))
    var truncated = admittedPssAlgorithmIdentifiers()[0]
    truncated.setLen(truncated.len - 1)
    check not isAdmittedPssAlgorithm(truncated)

  test "t_snp_a_critical_extension_this_build_cannot_act_on_is_refused":
    # The root carries a CRITICAL key-usage extension. Renaming its
    # object identifier to one this build does not recognise — same
    # length, still critical — is exactly the situation RFC 5280 §4.2
    # says to refuse rather than ignore.
    let before = bytesOfHex("0603551d0f")     # 2.5.29.15, keyUsage
    let after = bytesOfHex("0603551d10")      # 2.5.29.16, not recognised
    let patched = substituteBytes(milanArk, before, after, 1)
    let v = evaluateAmdChain(genuineVcek, milanAsk, patched, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acUnrecognisedCriticalExtension)
    check RecognisedAmdCriticalOids.len == 2
    check OidBasicConstraints in RecognisedAmdCriticalOids
    check OidKeyUsage in RecognisedAmdCriticalOids

  test "t_snp_a_key_of_the_wrong_kind_for_its_position_is_refused":
    let before = refusalsObserved
    let v = evaluateAmdChain(milanAsk, milanAsk, milanArk, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acWrongKeyType)
    let w = evaluateAmdChain(genuineVcek, genuineVcek, milanArk,
                             milanCrl, Now)
    checkpoint w.detail
    assertOnlyRefusal(w, acWrongKeyType)
    check refusalsObserved - before == 2

  test "t_snp_a_leaf_that_is_not_an_endorsement_key_is_refused":
    let before = refusalsObserved
    let patched = substituteAscii(genuineVcek, "SEV-VCEK", "SEV-XXXX", 1)
    let v = evaluateAmdChain(patched, milanAsk, milanArk, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acLeafIsNotAnEndorsementKey)
    check refusalsObserved - before == 1

  test "t_snp_a_leaf_with_no_platform_version_is_refused":
    let seenBefore = refusalsObserved
    # The object identifier of one of the four version components,
    # renamed to one the vendor uses only on a later generation. Same
    # length, still a well-formed extension, simply not one of the four
    # this build compares: …3704.1.3.8 (microcode) -> …3704.1.3.9.
    let before = bytesOfHex("060a2b060104019c78010308")
    let after = bytesOfHex("060a2b060104019c78010309")
    let patched = substituteBytes(genuineVcek, before, after, 1)
    let v = evaluateAmdChain(patched, milanAsk, milanArk, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acLeafCarriesNoPlatformVersion)
    check refusalsObserved - seenBefore == 1

  test "t_snp_a_leaf_with_no_usable_chip_identity_is_refused":
    # A real vendor certificate, for a real part of a later generation,
    # whose chip identity is 8 bytes rather than 64. This build binds a
    # report to a part by that identity and cannot do it with 8 bytes,
    # so it refuses instead of binding to a prefix.
    #
    # That is a genuine limitation of this build and not a property of
    # the certificate: later parts are not supported here, and this is
    # where a reader finds that out.
    let cert = parseAmdCertificate(turinVcek)
    check cert.subjectCn == VcekCommonName
    check cert.productName == "Turin"
    check cert.hwId.len == 8
    check cert.hwId.len != HwIdLen
    let v = evaluateAmdChain(turinVcek, turinAsk, turinArk, turinCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acLeafCarriesNoChipIdentity)

  test "t_snp_an_issuer_without_the_authority_to_issue_is_refused":
    let seenBefore = refusalsObserved
    # basicConstraints cA, TRUE -> FALSE. One byte, inside the signed
    # body, so the signature would break too — but this rule is reached
    # first, which is the point of checking structure before arithmetic.
    # BasicConstraints ::= SEQUENCE { cA BOOLEAN, pathLen INTEGER }
    let before = bytesOfHex("30060101ff020100")
    let after = bytesOfHex("3006010100020100")
    let patched = substituteBytes(milanAsk, before, after, 1)
    let v = evaluateAmdChain(genuineVcek, patched, milanArk, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acNotACertificateAuthority)
    check refusalsObserved - seenBefore == 1

  test "t_snp_a_chain_outside_its_validity_window_is_refused":
    let before = refusalsObserved
    # Before the root existed, and after the endorsement expires.
    let early = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                 milanCrl, 1_500_000_000'i64)
    checkpoint early.detail
    assertOnlyRefusal(early, acExpired)
    assertOneRule(early.detail, WindowRules, "is not valid until")
    let late = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                milanCrl, 2_000_000_000'i64)
    checkpoint late.detail
    assertOnlyRefusal(late, acExpired)
    assertOneRule(late.detail, WindowRules, "stopped being valid at")
    check refusalsObserved - before == 2

  test "t_snp_both_validity_edges_are_pinned_at_adjacent_instants":
    # A single case far from a boundary passes under `<` and under `<=`
    # alike, which is why the grace window three files over is pinned at
    # four adjacent instants. The certificate window deserves the same
    # treatment and did not have it: with only the two far-away clocks
    # above, turning `nowSeconds >= c.notAfter` into `>` left every gate
    # green.
    #
    # The instants come from the certificate, not from this file. On the
    # accepting side of each edge the verdict is NOT an acceptance —
    # 2023 and 2030 are both outside the vendor revocation list's own
    # window — so what is asserted there is that the refusal is not the
    # WINDOW's. That is the property the edge owns.
    let leaf = parseAmdCertificate(genuineVcek)
    check leaf.notBefore < leaf.notAfter
    proc reasonAt(at: int64): AmdChainRejection =
      evaluateAmdChain(genuineVcek, milanAsk, milanArk, milanCrl, at).reason
    # notBefore: the first instant the certificate is usable.
    check reasonAt(leaf.notBefore - 1) == acExpired
    check reasonAt(leaf.notBefore) != acExpired
    # notAfter: the first instant it is not.
    check reasonAt(leaf.notAfter - 1) != acExpired
    check reasonAt(leaf.notAfter) == acExpired
    check reasonAt(leaf.notAfter + 1) == acExpired
    # And the two refusals really are the two different rules.
    let early = evaluateAmdChain(genuineVcek, milanAsk, milanArk, milanCrl,
                                 leaf.notBefore - 1)
    assertOneRule(early.detail, WindowRules, "is not valid until")
    let late = evaluateAmdChain(genuineVcek, milanAsk, milanArk, milanCrl,
                                leaf.notAfter)
    assertOneRule(late.detail, WindowRules, "stopped being valid at")

  test "t_snp_each_signature_in_the_chain_is_checked_on_its_own_input":
    # Three links, three rules, one refusal kind — so a case that
    # asserted `acBadSignature` and stopped would be asserting "one of
    # these three". Each link is broken ALONE, in the one place that
    # breaks a signature and nothing else: the last byte of the
    # signature BIT STRING, which is outside the signed body.
    #
    # Two of these three had no input at all before this case. Deleting
    # the endorsement certificate's signature check, or the root's
    # self-signature check, left all three gates green.
    let seenBefore = refusalsObserved
    let leaf = evaluateAmdChain(withBrokenSignature(genuineVcek), milanAsk,
                                milanArk, milanCrl, Now)
    checkpoint leaf.detail
    assertOnlyRefusal(leaf, acBadSignature)
    assertOneRule(leaf.detail, BadSignatureRules,
                  "the endorsement certificate does not verify under")

    let mid = evaluateAmdChain(genuineVcek, withBrokenSignature(milanAsk),
                               milanArk, milanCrl, Now)
    checkpoint mid.detail
    assertOnlyRefusal(mid, acBadSignature)
    assertOneRule(mid.detail, BadSignatureRules,
                  "the intermediate does not verify under")

    let root = evaluateAmdChain(genuineVcek, milanAsk,
                                withBrokenSignature(milanArk), milanCrl, Now)
    checkpoint root.detail
    assertOnlyRefusal(root, acBadSignature)
    assertOneRule(root.detail, BadSignatureRules,
                  "the root does not verify under its own key")
    check refusalsObserved - seenBefore == 3

    # Each input differs from the genuine one in exactly one byte, and
    # that byte is in the signature — so nothing structural moved and
    # the root is still the pinned one.
    for (good, bad) in {genuineVcek: withBrokenSignature(genuineVcek),
                        milanAsk: withBrokenSignature(milanAsk),
                        milanArk: withBrokenSignature(milanArk)}:
      check good.len == bad.len
      var differing = 0
      for i in 0 ..< good.len:
        if good[i] != bad[i]: inc differing
      check differing == 1
      let g = parseAmdCertificate(good)
      let b = parseAmdCertificate(bad)
      check hexOfBytes(g.tbs) == hexOfBytes(b.tbs)
    check root.rootMatched
    check root.rootLine == aplMilan

  test "t_snp_the_leaf_must_name_the_intermediate_it_is_handed":
    # The other half of the name link. The case above it crosses the
    # intermediate and the root; this one crosses the endorsement
    # certificate and the intermediate, with two genuine vendor
    # certificates of a different generation. Without it the rule that
    # links the leaf to the intermediate had no input: deleting it left
    # every gate green, because the only chain that reached it was one
    # whose leaf already named its intermediate.
    let v = evaluateAmdChain(genuineVcek, turinAsk, turinArk, turinCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acNameMismatch)
    assertOneRule(v.detail, NameLinkRules, "the endorsement certificate names")
    check parseAmdCertificate(genuineVcek).issuerCn == "SEV-Milan"
    check parseAmdCertificate(turinAsk).subjectCn == "SEV-Turin"

  test "t_snp_an_issuer_whose_key_may_not_sign_certificates_is_refused":
    # The second half of the authority rule. `basicConstraints cA` and
    # `keyUsage keyCertSign` are two different statements and this build
    # requires both; only the first had an input. The vendor's
    # intermediate carries `03 02 01 04` — keyCertSign alone — and this
    # replaces it with `03 02 01 80`, digitalSignature, the same length
    # and still critical, still an extension this build recognises.
    let seenBefore = refusalsObserved
    let before = bytesOfHex("0603551d0f0101ff040403020104")
    let after = bytesOfHex("0603551d0f0101ff040403020180")
    let patched = substituteBytes(milanAsk, before, after, 1)
    check patched.len == milanAsk.len
    let v = evaluateAmdChain(genuineVcek, patched, milanArk, milanCrl, Now)
    checkpoint v.detail
    assertOnlyRefusal(v, acNotACertificateAuthority)
    assertOneRule(v.detail, AuthorityRules,
                  "has a keyUsage that does not include keyCertSign")
    # …and the cA half of the same kind names the OTHER rule.
    let cAPatched = substituteBytes(milanAsk, bytesOfHex("30060101ff020100"),
                                    bytesOfHex("3006010100020100"), 1)
    let w = evaluateAmdChain(genuineVcek, cAPatched, milanArk, milanCrl, Now)
    checkpoint w.detail
    assertOnlyRefusal(w, acNotACertificateAuthority)
    assertOneRule(w.detail, AuthorityRules,
                  "does not carry basicConstraints cA TRUE")
    check refusalsObserved - seenBefore == 2

  test "t_snp_a_chain_with_no_current_revocation_list_is_refused":
    # Seven ways to have no answer, all of which are the same answer —
    # and the point of this case is that they are SEVEN and the verdict
    # says which.
    #
    # Five of them are conditions inside the loop that picks a covering
    # list, and until this gate named them they were indistinguishable:
    # one refusal, one sentence, five rules. Deleting the issuer check,
    # the next-update check or the has-a-next-update check left every
    # gate green, because the list each of those cases supplied was set
    # aside by the SIGNATURE check below them instead. A kind is not a
    # rule; the sentence is.
    let none = evaluateAmdChain(genuineVcek, milanAsk, milanArk, @[], Now)
    checkpoint none.detail
    assertOnlyRefusal(none, acNoRevocationData)
    check "0 did not read" in none.detail
    for r in RevocationRules: check r notin none.detail

    let junk = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                @[bytesOfHex("3003020101")], Now)
    checkpoint junk.detail
    assertOnlyRefusal(junk, acNoRevocationData)
    check "1 did not read" in junk.detail
    for r in RevocationRules: check r notin junk.detail

    # The vendor's own list, consulted before it comes into force. The
    # certificates are all still valid at this instant, so the only
    # thing missing is a current answer about revocation.
    let stale = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                 milanCrl, 1_700_000_000'i64)
    checkpoint stale.detail
    assertOnlyRefusal(stale, acNoRevocationData)
    assertOneRule(stale.detail, RevocationRules, "one is not in force until")

    # …and the other end of the same list's window, which is a
    # DIFFERENT rule and had no input at all before this line. The
    # vendor's list stops being current in 2026; the endorsement
    # certificate is good until 2030, so there is an interval in which
    # every certificate is valid and the only thing out of date is the
    # revocation answer.
    let expired = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                   milanCrl, 1_800_000_000'i64)
    checkpoint expired.detail
    assertOnlyRefusal(expired, acNoRevocationData)
    assertOneRule(expired.detail, RevocationRules,
                  "one stopped being current at")
    let published = parseAmdCrl(milanCrl[0])
    check 1_800_000_000'i64 >= published.nextUpdate
    check 1_800_000_000'i64 < parseAmdCertificate(genuineVcek).notAfter

    # A list that states no next update at all says nothing about
    # whether it is still current, and that is its own rule too.
    let openEnded = withoutNextUpdate(milanCrl[0])
    let unread = parseAmdCrl(openEnded)
    check not unread.hasNextUpdate
    check unread.issuerCn == "ARK-Milan"
    check hexOfBytes(unread.issuerDn) == hexOfBytes(published.issuerDn)
    check unread.thisUpdate == published.thisUpdate
    let openVerdict = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                       @[openEnded], Now)
    checkpoint openVerdict.detail
    assertOnlyRefusal(openVerdict, acNoRevocationData)
    assertOneRule(openVerdict.detail, RevocationRules,
                  "one states no next update at all")

    # A list issued by somebody else is not an answer either, even
    # though it reads perfectly well and is inside its own window.
    let wrongIssuer = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
      @[bytesOfHex(KdsTurinCrlDerHex)], Now)
    checkpoint wrongIssuer.detail
    assertOnlyRefusal(wrongIssuer, acNoRevocationData)
    assertOneRule(wrongIssuer.detail, RevocationRules, "one is issued by")
    check "ARK-Turin" in wrongIssuer.detail

    # And the case the others cannot reach: a list that names the right
    # issuer, is inside its own window, reads perfectly, and whose
    # SIGNATURE is wrong.
    var tampered = milanCrl[0]
    let sigByte = tampered.len - 1
    tampered[sigByte] = tampered[sigByte] xor 0x01'u8
    let parsed = parseAmdCrl(tampered)
    check parsed.issuerCn == "ARK-Milan"
    check hexOfBytes(parsed.issuerDn) ==
      hexOfBytes(parseAmdCertificate(milanArk).subjectDn)
    check parsed.hasNextUpdate
    check Now >= parsed.thisUpdate and Now < parsed.nextUpdate
    check not parsed.signatureVerifiesUnder(parseAmdCertificate(milanArk))
    let forged = evaluateAmdChain(genuineVcek, milanAsk, milanArk,
                                  @[tampered], Now)
    checkpoint forged.detail
    assertOnlyRefusal(forged, acNoRevocationData)
    check "0 did not read" in forged.detail
    assertOneRule(forged.detail, RevocationRules,
                  "one carries a signature this root did not make")

    # The five sentences are five: no one of them is a substring of
    # another, which is what lets the assertions above mean one rule.
    for a in RevocationRules:
      for b in RevocationRules:
        if a == b: continue
        check a notin b

suite "the chain as the verifier reaches it":

  test "t_snp_a_bundled_vendor_chain_reaches_the_verdict_unchanged":
    # `verify.nim`'s confidential-computing arm is the only caller of
    # `evaluateAmdChain` outside these gates, and it had no input at
    # all: making it report "satisfied" whatever the chain verdict said
    # left this gate, the two verdict gates and the whole rest of the
    # tree green. A rule wired where nothing runs it is a rule the
    # program does not have.
    #
    # The chain travels the way an instance would send it — inside a
    # report envelope, base64, decoded by the envelope reader — and the
    # revocation lists travel beside it on the request, because they are
    # the verifier's to hold and not the instance's to supply. There is
    # no anchor on the request and this case cannot add one.
    proc asString(der: seq[byte]): string =
      result = newString(der.len)
      for i in 0 ..< der.len: result[i] = char(der[i])

    proc verdictFor(chain: seq[seq[byte]];
                    crls: seq[seq[byte]]): Verdict =
      var certs: seq[string] = @[]
      for der in chain: certs.add asString(der)
      let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
      let text = renderAttestationReport(attestationReport(abSevSnp,
        SampleTimestamp, HarnessChallenge, bindings,
        "opaque-snp-evidence-bytes", sampleClaims(), some(certs)))
      let report = parseAttestationReport(text, "<snp report>")
      var req = verificationRequest(text,
        parseAttestationPolicy(productionPolicyText(), "<prod>"),
        some(sampleManifestText()), issuedAtMs = some(Now * 1000),
        nowMs = Now * 1000)
      for der in crls: req.vendorRevocationLists.add asString(der)
      var inputs: AuthoritativeInputs
      inputs.readerName = "downstream snp reader"
      inputs.reportDataInEvidence = some(report.reportData)
      verifyWithReading(req, report, EvidenceReading(
        finding: satisfied("a report signed by the vendor's key"),
        inputs: inputs))

    let genuine = verdictFor(@[genuineVcek, milanAsk, milanArk], milanCrl)
    checkpoint genuine.checks[vcCertificateChain].detail
    check genuine.checks[vcCertificateChain].outcome == coPassed
    check genuine.checks[vcCertificateChain].required
    check AmdChainMessage[acAccepted] in
      genuine.checks[vcCertificateChain].detail
    check "Milan" in genuine.checks[vcCertificateChain].detail

    # The same envelope with the impostor's chain in it, refused for the
    # root and named as such in the verdict a caller reads.
    let impostor = verdictFor(@[impostorVcek, impostorAsk, impostorArk],
                              milanCrl)
    checkpoint impostor.checks[vcCertificateChain].detail
    check impostor.checks[vcCertificateChain].outcome == coFailed
    check AmdChainMessage[acRootIsNotAmd] in
      impostor.checks[vcCertificateChain].detail
    check vcCertificateChain in impostor.failedChecks

    # The revocation lists really are consulted through this path: the
    # genuine chain with none supplied is refused, and for that reason.
    let unanswered = verdictFor(@[genuineVcek, milanAsk, milanArk], @[])
    checkpoint unanswered.checks[vcCertificateChain].detail
    check unanswered.checks[vcCertificateChain].outcome == coFailed
    check AmdChainMessage[acNoRevocationData] in
      unanswered.checks[vcCertificateChain].detail

    # And the count is checked before anything is indexed, so a bundle
    # of the wrong size is a refusal rather than a read off the end.
    # BOTH directions, because a check for "too few" alone silently
    # ignores whatever a caller appends: with only the short case,
    # relaxing the count to `<` was green.
    let short = verdictFor(@[genuineVcek, milanAsk], milanCrl)
    checkpoint short.checks[vcCertificateChain].detail
    check short.checks[vcCertificateChain].outcome == coFailed
    check "bundles 2" in short.checks[vcCertificateChain].detail
    let long = verdictFor(@[genuineVcek, milanAsk, milanArk, milanArk],
                          milanCrl)
    checkpoint long.checks[vcCertificateChain].detail
    check long.checks[vcCertificateChain].outcome == coFailed
    check "bundles 4" in long.checks[vcCertificateChain].detail
    # The first three of that bundle ARE the genuine chain, so a reader
    # that took the first `AmdChainElements` and dropped the rest would
    # have accepted it.
    check genuine.checks[vcCertificateChain].outcome == coPassed
    check AmdChainElements == 3

suite "snp chain refusal coverage":

  test "t_snp_chain_every_refusal_kind_but_one_is_reached":
    # `acRevoked` is the exception, and it is named rather than quietly
    # dropped from a total.
    #
    # Reaching it needs a revocation list that (a) is signed by a pinned
    # root and (b) names the intermediate's serial.
    #
    # Two of the vendor's three published lists name nothing. The THIRD
    # one does: the Genoa list revokes serial 020001, an intermediate
    # the vendor has since replaced — the Genoa chain it serves today
    # carries 020002 — and no project publishes a certificate with the
    # revoked serial. So condition (a) is satisfied by a real list,
    # condition (b) is satisfied by a real list, and the two cannot be
    # satisfied TOGETHER without holding the vendor's private key.
    #
    # That is a rule with a reachable input in production and none that
    # can be manufactured offline, which is a different thing from a
    # rule nothing can ever reach, and the difference is why the rule
    # stays rather than being deleted to make a number look better.
    #
    # The half that CAN be checked offline is checked below on both
    # lists, so the serial reader is given something to read and not
    # only run over nothing.
    var unreached: seq[string] = @[]
    var count = 0
    for k in AmdChainRejection:
      inc count
      if k notin reachedChainKinds: unreached.add $k
    check count == 16
    if unreached.len > 0:
      checkpoint("never reached: " & unreached.join(", "))
    check unreached == @["acRevoked"]
    check card(reachedChainKinds) == 15

    let crl = parseAmdCrl(bytesOfHex(KdsMilanCrlDerHex))
    check crl.issuerCn == "ARK-Milan"
    check crl.hasNextUpdate
    check crl.revokedSerials.len == 0
    check parseAmdCertificate(milanAsk).serialHex == "010001"

    # The list that is NOT empty, which is what says the serial reader
    # reads serials rather than always producing nothing. This is a real
    # vendor list with a real entry in it, and it is the reason the
    # sentence above says "two of the three" instead of "all three".
    let genoaCrl = parseAmdCrl(bytesOfHex(KdsGenoaCrlDerHex))
    check genoaCrl.issuerCn == "ARK-Genoa"
    check genoaCrl.hasNextUpdate
    check genoaCrl.revokedSerials == @["020001"]
    # …and it does not name the intermediate the vendor serves with it,
    # which is why it cannot be turned into an input for the rule.
    let genoaAsk = parseAmdCertificate(genoa[0])
    check genoaAsk.subjectCn == "SEV-Genoa"
    check genoaAsk.serialHex == "020002"
    check genoaAsk.serialHex notin genoaCrl.revokedSerials
    let turinCrlParsed = parseAmdCrl(bytesOfHex(KdsTurinCrlDerHex))
    check turinCrlParsed.revokedSerials.len == 0
