## A nested TLV is bounded by its PARENT, not by the buffer it sits in.
##
## ## The defect this is about
##
## `x509.nim`'s reader used to bound every TLV by the whole certificate.
## That is correct only at the top level. One level down it means an
## extension may declare a length that reaches past the end of the
## extensions SEQUENCE containing it, and the reader will READ it: the
## cursor lands past the list's end, the `while` that walks the list
## exits, and every extension after the overrunning one is silently
## dropped while the parse reports success.
##
## Nothing is forged by that today — the bytes the overrun reaches into
## are still inside the signed TBS, so an attacker cannot put anything
## there that the issuer did not sign. What it does is make the reader
## disagree with the signer about what the certificate SAYS, and the
## fields it drops are `basicConstraints` and `keyUsage`. A module whose
## own documentation opens by calling itself strict, and which lists its
## refusals by name, does not get to read that and call it a parse.
##
## ## Why the fixture inflates TWO length fields, not one
##
## Inflating only the extension's own TLV length is caught already, by
## the reader's `bytes follow the value of <oid>` check — the cursor
## finishes the extension's real contents short of the inflated end. A
## fixture refused by a neighbouring rule proves nothing about the rule
## it was written for, and reviews of this repository have twice found
## exactly that: one substring produced by two different refusal sites.
##
## So the fixture inflates the extension's TLV length AND the `extnValue`
## OCTET STRING length inside it, by the same amount. The extension then
## parses cleanly within its own declared span, every neighbouring check
## passes, and the ONE thing wrong with it is that the span reaches past
## its parent. The case below asserts which refusal fires, and asserts
## that it is none of the neighbours.
##
## ## The twin
##
## Every negative fixture here has an accepted twin minted from the same
## specification with `firstExtensionOverrunsListBy` at zero. The two
## certificates differ in two length bytes and in nothing else, so the
## refusal is attributable to the overrun. The twin also carries the
## assertion that gives the defect its stakes: in the accepted
## certificate the extensions AFTER the overrunning one are present, and
## those are the ones the defective certificate would have dropped.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random source,
## real X.509 DER, read by the production reader.

import std/[strutils, times, unittest]

import repro_attest_verify
import ./software_root_test_pki

let now = getTime().toUnix
const Day = 86_400'i64

proc baseOptions(cn: string): CertOptions =
  CertOptions(
    subjectCn: cn, serial: randomSerial(),
    notBefore: now - Day, notAfter: now + 365 * Day,
    isCa: true, keyUsageBits: @[5, 6])

proc mintWithOverrun(overrun: int): string =
  let key = newTestKey()
  var opts = baseOptions("der nesting fixture")
  opts.withOverrunTestExtension = true
  opts.firstExtensionOverrunsListBy = overrun
  mintCert(key, key, opts).der

proc mintTruncated(tail: seq[byte]): string =
  let key = newTestKey()
  var opts = baseOptions("der nesting fixture")
  opts.withTruncatedExtension = true
  opts.truncatedExtensionTail = tail
  mintCert(key, key, opts).der

proc toBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = byte(text[i])

proc refusalFor(der: string): string =
  try:
    discard parseCertificate(toBytes(der))
    ""
  except X509Error as e:
    e.msg

const
  # The refusal this file is about, and every refusal that sits close
  # enough to it to be mistaken for it. The second list is asserted
  # ABSENT, because "it refused" and "it refused for this reason" are
  # different measurements and only the second one is evidence.
  ParentBoundRefusal = "past the end of the structure that contains it"
  NeighbouringRefusals = [
    "bytes follow the value of",
    "bytes follow the extension list",
    "bytes follow the extension block",
    "and only ",                   # the whole-buffer bound
    "the encoding ends where",     # the whole-buffer bound, tag/length
    "appears twice",
    "expected tag",
  ]

suite "DER nesting is bounded by the parent":

  test "an extension overrunning its SEQUENCE is refused, and by that bound":
    ## The heart of the file.
    let der = mintWithOverrun(8)
    var raised = ""
    try:
      discard parseCertificate(toBytes(der))
      raised = ""
    except X509Error as e:
      raised = e.msg
    checkpoint("refusal: " & raised)
    check raised.len > 0
    check ParentBoundRefusal in raised
    # It is the EXTENSION that overran, and the message says so, so this
    # cannot be some other structure's overrun passing for this one.
    # Pinned with the word that FOLLOWS it: bare `"extension" in raised`
    # is also satisfied by a refusal naming the "extensions" SEQUENCE,
    # which is the very structure this case has to be distinguished from.
    check "extension: declares" in raised
    for neighbour in NeighbouringRefusals:
      checkpoint("must not be: " & neighbour)
      check neighbour notin raised

  test "the same certificate without the overrun is read, and read WHOLE":
    ## The twin. Two length bytes apart from the fixture above.
    let der = mintWithOverrun(0)
    let cert = parseCertificate(toBytes(der))
    # The unrecognised testing extension is recorded, not refused.
    var sawTestOid = false
    for ext in cert.extensions:
      if ext.oid == ExtensionOverrunTestOid: sawTestOid = true
    check sawTestOid
    # And — this is the defect's stakes — the extensions that FOLLOW it
    # are present. These are exactly the ones the overrunning twin drops.
    check cert.hasBasicConstraints
    check cert.isCa
    check cert.hasKeyUsage
    check kuKeyCertSign in cert.keyUsage
    check cert.extensions.len >= 3

  test "the overrun is refused at every distance past the parent's end":
    ## A bound tested at one value is a bound tested at one value. One
    ## byte past the end is the boundary case the off-by-one lives at.
    for overrun in [1, 2, 8, 32]:
      let der = mintWithOverrun(overrun)
      var raised = ""
      try:
        discard parseCertificate(toBytes(der))
      except X509Error as e:
        raised = e.msg
      checkpoint("overrun " & $overrun & " -> " & raised)
      check ParentBoundRefusal in raised

  test "a TLV asked for AT the parent's end is refused there, not read on":
    ## The tag-position guard, and it needs its own input or it is a rule
    ## with no reachable input — which the first mutation pass over this
    ## file found it to be.
    ##
    ## An extension holding only its OID leaves the reader asking for the
    ## extnValue TLV at exactly the parent's end. Unguarded, the tag it
    ## reads is the first byte of the NEXT extension. The certificate is
    ## refused either way — the cursor cannot then land on the parent's
    ## end, so `bytes follow the value of` catches it — so what this guard
    ## changes is the DIAGNOSIS and not the verdict, and this case says so
    ## rather than letting the file imply a fail-open that is not there.
    ## It is still worth having: "this extension has nothing after its
    ## OID" is true, and "expected an OCTET STRING and found a SEQUENCE"
    ## is a sentence about a byte belonging to a different structure.
    let raised = refusalFor(mintTruncated(@[]))
    checkpoint("refusal: " & raised)
    check "the enclosing structure ends where a tag was expected" in raised
    check "expected tag" notin raised
    check "bytes follow the value of" notin raised

  test "a TLV whose LENGTH byte is outside the parent is refused there":
    ## The length-position guard, same shape one byte later. Here the
    ## unguarded reader does worse than misdiagnose: the next extension's
    ## `0x30` is read as a length of 48, and 48 bytes belonging to a
    ## sibling are taken as this extension's extnValue — which even
    ## passes the OCTET STRING tag check, because the truncated tail IS
    ## an `0x04`. Only the trailing-bytes check downstream stops it.
    let raised = refusalFor(mintTruncated(@[0x04'u8]))
    checkpoint("refusal: " & raised)
    check "the enclosing structure ends where a length was expected" in raised
    check "the encoding ends where a length was expected" notin raised
    check "bytes follow the value of" notin raised

  test "a LONG-FORM length's continuation bytes are inside the parent too":
    ## One byte later again, and this position was MISSED by the first
    ## version of the parent bound: the tag, the first length byte and the
    ## content end were all bounded by the parent, and the long form's
    ## CONTINUATION bytes were still bounded by the whole buffer. So a
    ## truncated extension ending in `0x04 0x82` read the two bytes that
    ## follow it — the next extension's — as its own length.
    ##
    ## Both continuations are asserted, because they misdiagnose in two
    ## different directions and the one-byte form is the worse of the two:
    ##
    ##   `0x04 0x82` -> "declares 12303 content bytes and only 117 remain",
    ##     a number read out of a sibling structure;
    ##   `0x04 0x81` -> "the length 48 is written in the long form, and DER
    ##     requires the short one", which ACCUSES THIS EXTENSION OF A DER
    ##     MINIMAL-ENCODING VIOLATION IT DID NOT COMMIT. The 48 is the next
    ##     extension's `0x30`.
    ##
    ## Neither is a fail-open — the content-end checks downstream still
    ## refuse the certificate — and this case says so rather than implying
    ## one. What it pins is the same thing the two cases above pin: which
    ## rule the reader names when it refuses.
    for tail in [@[0x04'u8, 0x82'u8], @[0x04'u8, 0x81'u8]]:
      let raised = refusalFor(mintTruncated(tail))
      checkpoint("tail " & $tail & " -> " & raised)
      check "the enclosing structure ends inside a long-form length" in raised
      # The two messages the unguarded reader produced instead, each
      # asserted absent so a regression cannot pass by refusing at all.
      check "and only " notin raised
      check "requires the short one" notin raised
      check "the encoding ends inside a long-form length" notin raised

  test "the extension WRAPPER cannot overrun the TBS either":
    ## The [3] wrapper is the last element of the TBS, so `t != tbsNode.fin`
    ## downstream already notices when it overruns — which is exactly why
    ## this needs its own case. A bound whose every input is caught one
    ## layer up is a bound nothing measures, and the first mutation pass
    ## over this file found this call site GREEN under `buf.len` for that
    ## reason.
    ##
    ## What the bound changes here is which rule speaks and what it says.
    ## Unbounded, the wrapper is read, `readExtensions` finds the honest
    ## list inside it ending short of the wrapper's declared end, and the
    ## refusal is `bytes follow the extension list` — a sentence about the
    ## list, when the thing that is wrong is the wrapper. Bounded, the
    ## wrapper is refused where it overruns.
    let key = newTestKey()
    var opts = baseOptions("der nesting fixture")
    opts.extensionWrapperOverrunsTbsBy = 4
    let raised = refusalFor(mintCert(key, key, opts).der)
    checkpoint("refusal: " & raised)
    check ParentBoundRefusal in raised
    check "extensions" in raised
    check "bytes follow the extension list" notin raised

  test "a certificate with no overrun at all is still read":
    ## The negative control that stops the whole file from passing
    ## because the reader refuses everything. Without it, a `parseCertificate`
    ## that raised unconditionally would satisfy the three cases above.
    let h = mintHierarchy(now, marked = false)
    let cert = parseCertificate(toBytes(h.ak.der))
    check cert.subjectCn == AkCn
    check cert.extensions.len > 0
    for ext in cert.extensions:
      check ext.oid != ExtensionOverrunTestOid

  test "the parent bound is a bound, not a rejection of all nesting":
    ## The complement of the case above, one level deeper: the accepted
    ## twin's own nested structures — the Name inside the issuer, the
    ## algorithm inside the SubjectPublicKeyInfo, the purposes inside an
    ## extKeyUsage — are all read through the same bounded reader. If the
    ## bound were off by one in the other direction, a correct
    ## certificate would stop parsing, and these are the fields that
    ## would go first.
    let h = mintHierarchy(now, marked = false)
    let ak = parseCertificate(toBytes(h.ak.der))
    check ak.issuerCn == IntermediateCn
    check ak.subjectCn == AkCn
    check ak.extKeyUsage.len == 1
    check ak.extKeyUsage[0] == OidTcgAikCertificate
    check ak.sanDnsNames.len == 1
    check ak.publicKey[0] == 0x04'u8
