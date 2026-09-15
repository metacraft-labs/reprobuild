## A strict DER reader for the two documents a certificate chain is made
## of: X.509 v3 certificates and X.509 v2 certificate revocation lists.
##
## ## Why hand-written, and why this narrow
##
## A verifier reads certificates an untrusted machine handed it. The
## surface a general-purpose ASN.1 library exposes is therefore attack
## surface, and almost none of it is needed: every certificate in this
## chain is ECDSA-P256 signed with SHA-256, every name is a DER Name, and
## every extension this build acts on is one of five. So the reader below
## admits exactly that and refuses everything else **by name**, rather
## than parsing a wider grammar and then discovering one layer up that it
## cannot act on what it parsed.
##
## The refusals are the point. In order:
##
##   * a length in non-minimal form, or the indefinite form — both are
##     BER and neither is DER, and a reader that accepts them accepts two
##     encodings of one certificate, which is two serial numbers for one
##     revocation check;
##   * trailing bytes after the outer SEQUENCE;
##   * a version that is not v3 (certificates) or v2 (CRLs) — an
##     extension block means nothing in v1, so a v1 certificate carrying
##     one is a certificate whose constraints a reader would silently
##     drop;
##   * a subject public key that is not an uncompressed P-256 point;
##   * a signature algorithm that is not ``ecdsa-with-SHA256``;
##   * a repeated extension OID, because RFC 5280 §4.2 forbids it and a
##     second ``basicConstraints`` is how a chain says two things about
##     whether it may issue.
##
## ## What this module does NOT decide
##
## Nothing here decides whether a certificate is *trusted*. This module
## turns bytes into facts — names, windows, key usages, extension OIDs
## and whether a signature verifies under a given key — and `trust.nim`
## decides what those facts are worth. In particular a **critical
## extension this build does not recognise is recorded, not refused**:
## which OIDs are recognised is a property of the evaluator, and the
## whole of this library's trust separation rests on two evaluators
## recognising different sets.
##
## ## Mocking
##
## None. Real DER in, real ECDSA-P256 verification through BearSSL out.

import std/[strutils, times]

import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi

const
  P256PointLen* = 65
    ## An uncompressed P-256 point: ``0x04 || X(32) || Y(32)``.

type
  X509Error* = object of CatchableError
    ## Raised for any certificate or CRL this reader will not read. The
    ## message says which field and why, because the reader of it is
    ## debugging a chain somebody else minted.

  KeyUsageBit* = enum
    ## RFC 5280 §4.2.1.3, in wire-bit order: bit 0 is the most
    ## significant bit of the first BIT STRING byte.
    kuDigitalSignature, kuNonRepudiation, kuKeyEncipherment,
    kuDataEncipherment, kuKeyAgreement, kuKeyCertSign, kuCrlSign,
    kuEncipherOnly, kuDecipherOnly

  X509Extension* = object
    oid*: string            ## Dotted decimal.
    critical*: bool
    value*: seq[byte]       ## The contents of the extnValue OCTET STRING.

  X509Cert* = object
    der*: seq[byte]
    tbs*: seq[byte]
      ## The exact bytes the signature covers, lifted verbatim. A
      ## re-serialisation is this reader's opinion of the certificate,
      ## and verifying a signature against an opinion is how a decoder
      ## bug becomes a forgery oracle.
    serialHex*: string
    issuerDn*: seq[byte]    ## The Name SEQUENCE, tag and length included.
    subjectDn*: seq[byte]
    issuerCn*: string
    subjectCn*: string
    notBefore*: int64
    notAfter*: int64
    publicKey*: array[P256PointLen, byte]
    signature*: seq[byte]   ## DER ``ECDSA-Sig-Value``.
    isCa*: bool
    hasBasicConstraints*: bool
    hasKeyUsage*: bool
    keyUsage*: set[KeyUsageBit]
    extKeyUsage*: seq[string]
    hasExtKeyUsage*: bool
    sanDnsNames*: seq[string]
    extensions*: seq[X509Extension]

  X509RevokedEntry* = object
    serialHex*: string
    revokedAt*: int64

  X509Crl* = object
    der*: seq[byte]
    tbs*: seq[byte]
    issuerDn*: seq[byte]
    issuerCn*: string
    thisUpdate*: int64
    nextUpdate*: int64
    hasNextUpdate*: bool
    revoked*: seq[X509RevokedEntry]
    signature*: seq[byte]

const
  OidEcPublicKey* = "1.2.840.10045.2.1"
  OidPrime256v1* = "1.2.840.10045.3.1.7"
  OidEcdsaWithSha256* = "1.2.840.10045.4.3.2"

  OidCommonName* = "2.5.4.3"
  OidBasicConstraints* = "2.5.29.19"
  OidKeyUsage* = "2.5.29.15"
  OidSubjectAltName* = "2.5.29.17"
  OidExtKeyUsage* = "2.5.29.37"
  OidCrlNumber* = "2.5.29.20"

  OidTcgEkCertificate* = "2.23.133.8.1"
    ## ``tcg-kp-EKCertificate``. TCG's own arc, used unchanged: a test
    ## PKI that invented its own extended-key-usage values would be a
    ## PKI whose certificates a production reader has never had to
    ## classify.
  OidTcgPlatformCertificate* = "2.23.133.8.2"
  OidTcgAikCertificate* = "2.23.133.8.3"

  MaxCertificateBytes* = 16_384
  MaxCrlBytes* = 262_144
  MaxExtensions* = 32
  MaxRevokedEntries* = 4_096
  MaxOidArcs* = 16

# ---------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------

const
  TagBoolean = 0x01'u8
  TagInteger = 0x02'u8
  TagBitString = 0x03'u8
  TagOctetString = 0x04'u8
  TagOid = 0x06'u8
  TagUtf8String = 0x0c'u8
  TagPrintableString = 0x13'u8
  TagIa5String = 0x16'u8
  TagUtcTime = 0x17'u8
  TagGeneralizedTime = 0x18'u8
  TagSequence = 0x30'u8
  TagSet = 0x31'u8
  TagContext0 = 0xa0'u8
  TagContext3 = 0xa3'u8
  TagSanDnsName = 0x82'u8   ## ``[2] IMPLICIT IA5String``.

type
  DerNode = object
    tag: byte
    contentStart: int
    contentLen: int
    fin: int                ## Index one past the whole TLV.

proc fail(msg: string) {.noreturn.} =
  raise newException(X509Error, msg)

proc readTlv(buf: openArray[byte]; pos: var int; what: string): DerNode =
  ## One TLV, in DER and not in BER.
  ##
  ## The two refusals worth naming: the indefinite form (``0x80``) has no
  ## place in DER at all, and a long form that could have been short —
  ## ``0x81 0x05`` for a length of five — is a second spelling of the
  ## same certificate. Two spellings of one certificate is two serial
  ## numbers for one revocation check, so both are refused here rather
  ## than normalised away.
  if pos >= buf.len:
    fail(what & ": the encoding ends where a tag was expected")
  result.tag = buf[pos]
  inc pos
  if pos >= buf.len:
    fail(what & ": the encoding ends where a length was expected")
  let first = buf[pos]
  inc pos
  if first == 0x80'u8:
    fail(what & ": an indefinite-length encoding, which is BER and not DER")
  if (first and 0x80'u8) == 0:
    result.contentLen = int(first)
  else:
    let n = int(first and 0x7f'u8)
    if n > 4:
      fail(what & ": a length of " & $n &
        " bytes; this reader reads at most four")
    if pos + n > buf.len:
      fail(what & ": the encoding ends inside a long-form length")
    var value = 0
    for i in 0 ..< n:
      value = (value shl 8) or int(buf[pos + i])
    if value < 0x80:
      fail(what & ": the length " & $value &
        " is written in the long form, and DER requires the short one")
    if n > 1 and buf[pos] == 0:
      fail(what & ": a long-form length with a redundant leading zero")
    pos += n
    result.contentLen = value
  result.contentStart = pos
  if result.contentStart + result.contentLen > buf.len:
    fail(what & ": declares " & $result.contentLen &
      " content bytes and only " & $(buf.len - result.contentStart) &
      " remain")
  result.fin = result.contentStart + result.contentLen
  pos = result.fin

proc expectTag(node: DerNode; tag: byte; what: string) =
  if node.tag != tag:
    fail(what & ": expected tag 0x" & toHex(int(tag), 2) & " and found 0x" &
      toHex(int(node.tag), 2))

proc slice(buf: openArray[byte]; start, stop: int): seq[byte] =
  result = newSeq[byte](stop - start)
  for i in 0 ..< result.len:
    result[i] = buf[start + i]

proc oidToString(buf: openArray[byte]; node: DerNode; what: string): string =
  ## An OBJECT IDENTIFIER as dotted decimal.
  ##
  ## The first subidentifier packs two arcs, and the packing is NOT
  ## ``40 * a + b`` in general: for ``a = 2`` the second arc is
  ## unbounded, which is exactly the case that matters here — the
  ## registration-free ``2.999`` arc ITU-T set aside for examples and
  ## testing encodes as a two-byte subidentifier and would come out as
  ## nonsense under the simplified rule.
  if node.contentLen == 0:
    fail(what & ": an empty OBJECT IDENTIFIER")
  var arcs: seq[uint64] = @[]
  var acc = 0'u64
  var started = false
  var shifted = false
  for i in 0 ..< node.contentLen:
    let b = buf[node.contentStart + i]
    if not started and b == 0x80'u8:
      fail(what & ": an OBJECT IDENTIFIER subidentifier with a redundant " &
        "leading zero byte")
    started = true
    if acc > (high(uint64) shr 7):
      fail(what & ": an OBJECT IDENTIFIER arc wider than 64 bits")
    acc = (acc shl 7) or uint64(b and 0x7f'u8)
    shifted = true
    if (b and 0x80'u8) == 0:
      if arcs.len >= MaxOidArcs:
        fail(what & ": an OBJECT IDENTIFIER of more than " & $MaxOidArcs &
          " arcs")
      arcs.add acc
      acc = 0
      started = false
  if started:
    fail(what & ": an OBJECT IDENTIFIER ending mid-subidentifier")
  if not shifted or arcs.len == 0:
    fail(what & ": an OBJECT IDENTIFIER with no arcs")
  let head = arcs[0]
  var parts: seq[string] = @[]
  if head < 40:
    parts.add "0"
    parts.add $head
  elif head < 80:
    parts.add "1"
    parts.add $(head - 40)
  else:
    parts.add "2"
    parts.add $(head - 80)
  for i in 1 ..< arcs.len:
    parts.add $arcs[i]
  parts.join(".")

proc parseDerTime(buf: openArray[byte]; node: DerNode; what: string): int64 =
  ## ``UTCTime`` or ``GeneralizedTime``, both in the Z form RFC 5280
  ## requires. A local-time offset is refused rather than assumed to be
  ## UTC: a validity window read in the wrong zone is a window that
  ## silently moves.
  var text = ""
  for i in 0 ..< node.contentLen:
    text.add char(buf[node.contentStart + i])
  var year, month, day, hour, minute, second: int
  if node.tag == TagUtcTime:
    if text.len != 13 or text[^1] != 'Z':
      fail(what & ": a UTCTime that is not 13 characters ending in Z: " &
        text.escape())
    let yy = parseInt(text[0 .. 1])
    year = (if yy >= 50: 1900 + yy else: 2000 + yy)
    month = parseInt(text[2 .. 3]); day = parseInt(text[4 .. 5])
    hour = parseInt(text[6 .. 7]); minute = parseInt(text[8 .. 9])
    second = parseInt(text[10 .. 11])
  elif node.tag == TagGeneralizedTime:
    if text.len != 15 or text[^1] != 'Z':
      fail(what & ": a GeneralizedTime that is not 15 characters ending " &
        "in Z: " & text.escape())
    year = parseInt(text[0 .. 3])
    month = parseInt(text[4 .. 5]); day = parseInt(text[6 .. 7])
    hour = parseInt(text[8 .. 9]); minute = parseInt(text[10 .. 11])
    second = parseInt(text[12 .. 13])
  else:
    fail(what & ": expected a UTCTime or a GeneralizedTime and found tag " &
      "0x" & toHex(int(node.tag), 2))
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or
     minute > 59 or second > 60:
    fail(what & ": a time that names no instant: " & text.escape())
  let dt = dateTime(year, Month(month), MonthdayRange(day),
                    HourRange(hour), MinuteRange(minute),
                    SecondRange(second), zone = utc())
  dt.toTime.toUnix

proc commonNameOf(buf: openArray[byte]; dnStart, dnEnd: int): string =
  ## The first ``CN`` attribute of a Name, or ``""``. Advisory: it
  ## reaches diagnostics, never a decision. Every decision that involves
  ## a name compares the DER Name bytes, because two distinct Names can
  ## share a CN.
  var pos = dnStart
  let outer = readTlv(buf, pos, "Name")
  if outer.tag != TagSequence: return ""
  var rdnPos = outer.contentStart
  while rdnPos < outer.fin and rdnPos < dnEnd:
    let rdn = readTlv(buf, rdnPos, "RelativeDistinguishedName")
    if rdn.tag != TagSet: continue
    var atvPos = rdn.contentStart
    while atvPos < rdn.fin:
      let atv = readTlv(buf, atvPos, "AttributeTypeAndValue")
      if atv.tag != TagSequence: continue
      var p = atv.contentStart
      let oidNode = readTlv(buf, p, "attribute type")
      if oidNode.tag != TagOid: continue
      if oidToString(buf, oidNode, "attribute type") != OidCommonName:
        continue
      if p >= atv.fin: continue
      let valueNode = readTlv(buf, p, "attribute value")
      if valueNode.tag notin {TagUtf8String, TagPrintableString}: continue
      var s = ""
      for i in 0 ..< valueNode.contentLen:
        s.add char(buf[valueNode.contentStart + i])
      return s
  ""

proc readAlgorithmEcdsaSha256(buf: openArray[byte]; node: DerNode;
                              what: string) =
  expectTag(node, TagSequence, what)
  var p = node.contentStart
  let oidNode = readTlv(buf, p, what & " algorithm")
  expectTag(oidNode, TagOid, what & " algorithm")
  let oid = oidToString(buf, oidNode, what & " algorithm")
  if oid != OidEcdsaWithSha256:
    fail(what & ": the signature algorithm is " & oid &
      " and this build verifies only ecdsa-with-SHA256 (" &
      OidEcdsaWithSha256 & ")")
  if p != node.fin:
    fail(what & ": ecdsa-with-SHA256 carries no parameters, and " &
      $(node.fin - p) & " bytes follow the algorithm identifier")

proc readSignatureBits(buf: openArray[byte]; node: DerNode;
                       what: string): seq[byte] =
  expectTag(node, TagBitString, what & " signature")
  if node.contentLen < 2:
    fail(what & ": the signature BIT STRING carries no value")
  if buf[node.contentStart] != 0:
    fail(what & ": the signature BIT STRING declares " &
      $int(buf[node.contentStart]) & " unused bits; a DER signature has none")
  slice(buf, node.contentStart + 1, node.fin)

proc readSpki(buf: openArray[byte]; node: DerNode;
              key: var array[P256PointLen, byte]) =
  expectTag(node, TagSequence, "SubjectPublicKeyInfo")
  var p = node.contentStart
  let algNode = readTlv(buf, p, "SubjectPublicKeyInfo algorithm")
  expectTag(algNode, TagSequence, "SubjectPublicKeyInfo algorithm")
  var ap = algNode.contentStart
  let algOidNode = readTlv(buf, ap, "public key algorithm")
  let algOid = oidToString(buf, algOidNode, "public key algorithm")
  if algOid != OidEcPublicKey:
    fail("SubjectPublicKeyInfo: the key algorithm is " & algOid &
      " and this build reads only id-ecPublicKey (" & OidEcPublicKey & ")")
  if ap >= algNode.fin:
    fail("SubjectPublicKeyInfo: id-ecPublicKey with no named curve")
  let curveNode = readTlv(buf, ap, "named curve")
  let curveOid = oidToString(buf, curveNode, "named curve")
  if curveOid != OidPrime256v1:
    fail("SubjectPublicKeyInfo: the named curve is " & curveOid &
      " and this build reads only prime256v1 (" & OidPrime256v1 & ")")
  if ap != algNode.fin:
    fail("SubjectPublicKeyInfo: bytes follow the named curve")
  let bitNode = readTlv(buf, p, "subjectPublicKey")
  expectTag(bitNode, TagBitString, "subjectPublicKey")
  if bitNode.contentLen != P256PointLen + 1:
    fail("SubjectPublicKeyInfo: the public key is " &
      $(bitNode.contentLen - 1) & " bytes; an uncompressed P-256 point is " &
      $P256PointLen)
  if buf[bitNode.contentStart] != 0:
    fail("SubjectPublicKeyInfo: the key BIT STRING declares unused bits")
  if buf[bitNode.contentStart + 1] != 0x04'u8:
    fail("SubjectPublicKeyInfo: the point does not begin 0x04, so it is " &
      "not in the uncompressed form this build reads")
  for i in 0 ..< P256PointLen:
    key[i] = buf[bitNode.contentStart + 1 + i]
  if p != node.fin:
    fail("SubjectPublicKeyInfo: bytes follow the subjectPublicKey")

proc readExtensions(buf: openArray[byte]; node: DerNode;
                    cert: var X509Cert) =
  ## The ``[3] EXPLICIT Extensions`` block, recorded rather than judged.
  expectTag(node, TagContext3, "extensions")
  var p = node.contentStart
  let listNode = readTlv(buf, p, "extensions")
  expectTag(listNode, TagSequence, "extensions")
  if p != node.fin:
    fail("extensions: bytes follow the extension list")
  var seen: seq[string] = @[]
  var extPos = listNode.contentStart
  while extPos < listNode.fin:
    let extNode = readTlv(buf, extPos, "extension")
    expectTag(extNode, TagSequence, "extension")
    var q = extNode.contentStart
    let oidNode = readTlv(buf, q, "extension identifier")
    expectTag(oidNode, TagOid, "extension identifier")
    var ext = X509Extension(oid: oidToString(buf, oidNode,
      "extension identifier"))
    if ext.oid in seen:
      fail("extensions: the extension " & ext.oid &
        " appears twice, and RFC 5280 gives no rule saying which one " &
        "would apply")
    seen.add ext.oid
    if cert.extensions.len >= MaxExtensions:
      fail("extensions: more than " & $MaxExtensions & " are carried")
    if q < extNode.fin and buf[q] == TagBoolean:
      let critNode = readTlv(buf, q, "extension criticality")
      if critNode.contentLen != 1:
        fail("extensions: the criticality of " & ext.oid & " is not one byte")
      let raw = buf[critNode.contentStart]
      if raw != 0xff'u8:
        fail("extensions: the criticality of " & ext.oid & " is 0x" &
          toHex(int(raw), 2) & "; DER writes TRUE as 0xFF and omits FALSE")
      ext.critical = true
    let valueNode = readTlv(buf, q, "extension value")
    expectTag(valueNode, TagOctetString, "extension value")
    if q != extNode.fin:
      fail("extensions: bytes follow the value of " & ext.oid)
    ext.value = slice(buf, valueNode.contentStart, valueNode.fin)
    cert.extensions.add ext
  # Now interpret the five this build acts on.
  for ext in cert.extensions:
    if ext.oid == OidBasicConstraints:
      cert.hasBasicConstraints = true
      var p2 = 0
      let bc = readTlv(ext.value, p2, "basicConstraints")
      expectTag(bc, TagSequence, "basicConstraints")
      if bc.contentLen > 0:
        var q2 = bc.contentStart
        if ext.value[q2] == TagBoolean:
          let b = readTlv(ext.value, q2, "basicConstraints cA")
          if b.contentLen != 1:
            fail("basicConstraints: cA is not one byte")
          cert.isCa = ext.value[b.contentStart] != 0
    elif ext.oid == OidKeyUsage:
      cert.hasKeyUsage = true
      var p2 = 0
      let ku = readTlv(ext.value, p2, "keyUsage")
      expectTag(ku, TagBitString, "keyUsage")
      if ku.contentLen < 1:
        fail("keyUsage: an empty BIT STRING")
      let unused = int(ext.value[ku.contentStart])
      if unused > 7:
        fail("keyUsage: " & $unused & " unused bits")
      let bits = (ku.contentLen - 1) * 8 - unused
      for bit in 0 ..< bits:
        let b = ext.value[ku.contentStart + 1 + (bit div 8)]
        if (int(b) and (0x80 shr (bit mod 8))) != 0:
          if bit <= ord(high(KeyUsageBit)):
            cert.keyUsage.incl KeyUsageBit(bit)
    elif ext.oid == OidExtKeyUsage:
      cert.hasExtKeyUsage = true
      var p2 = 0
      let eku = readTlv(ext.value, p2, "extKeyUsage")
      expectTag(eku, TagSequence, "extKeyUsage")
      var q2 = eku.contentStart
      while q2 < eku.fin:
        let o = readTlv(ext.value, q2, "extKeyUsage purpose")
        expectTag(o, TagOid, "extKeyUsage purpose")
        cert.extKeyUsage.add oidToString(ext.value, o, "extKeyUsage purpose")
    elif ext.oid == OidSubjectAltName:
      var p2 = 0
      let san = readTlv(ext.value, p2, "subjectAltName")
      expectTag(san, TagSequence, "subjectAltName")
      var q2 = san.contentStart
      while q2 < san.fin:
        let g = readTlv(ext.value, q2, "GeneralName")
        if g.tag == TagSanDnsName or g.tag == TagIa5String:
          var s = ""
          for i in 0 ..< g.contentLen:
            s.add char(ext.value[g.contentStart + i])
          cert.sanDnsNames.add s

proc parseCertificate*(der: openArray[byte]): X509Cert =
  ## One X.509 v3 certificate.
  if der.len == 0:
    fail("certificate: zero bytes")
  if der.len > MaxCertificateBytes:
    fail("certificate: " & $der.len & " bytes; at most " &
      $MaxCertificateBytes & " are read")
  result.der = slice(der, 0, der.len)
  var pos = 0
  let outer = readTlv(der, pos, "certificate")
  expectTag(outer, TagSequence, "certificate")
  if pos != der.len:
    fail("certificate: " & $(der.len - pos) &
      " bytes follow the outer SEQUENCE")
  var p = outer.contentStart
  let tbsStart = p
  let tbsNode = readTlv(der, p, "tbsCertificate")
  expectTag(tbsNode, TagSequence, "tbsCertificate")
  result.tbs = slice(der, tbsStart, tbsNode.fin)
  let algNode = readTlv(der, p, "certificate")
  readAlgorithmEcdsaSha256(der, algNode, "certificate")
  let sigNode = readTlv(der, p, "certificate")
  result.signature = readSignatureBits(der, sigNode, "certificate")
  if p != outer.fin:
    fail("certificate: bytes follow the signature")

  var t = tbsNode.contentStart
  if t < tbsNode.fin and der[t] == TagContext0:
    let vNode = readTlv(der, t, "version")
    var vp = vNode.contentStart
    let vInt = readTlv(der, vp, "version")
    expectTag(vInt, TagInteger, "version")
    if vInt.contentLen != 1 or der[vInt.contentStart] != 2'u8:
      fail("tbsCertificate: the version is not v3; an extension block " &
        "means nothing in an earlier version, so a certificate that " &
        "carries constraints under one would have them silently dropped")
    if vp != vNode.fin:
      fail("tbsCertificate: bytes follow the version")
  else:
    fail("tbsCertificate: no version is present, so this is a v1 " &
      "certificate; this build reads v3 only")
  let serialNode = readTlv(der, t, "serialNumber")
  expectTag(serialNode, TagInteger, "serialNumber")
  if serialNode.contentLen == 0 or serialNode.contentLen > 20:
    fail("tbsCertificate: the serial number is " & $serialNode.contentLen &
      " bytes; RFC 5280 bounds it at 20")
  result.serialHex = ""
  for i in 0 ..< serialNode.contentLen:
    result.serialHex.add toHex(int(der[serialNode.contentStart + i]), 2)
  result.serialHex = result.serialHex.toLowerAscii
  let innerAlgNode = readTlv(der, t, "tbsCertificate")
  readAlgorithmEcdsaSha256(der, innerAlgNode, "tbsCertificate")
  let issuerStart = t
  let issuerNode = readTlv(der, t, "issuer")
  expectTag(issuerNode, TagSequence, "issuer")
  result.issuerDn = slice(der, issuerStart, issuerNode.fin)
  result.issuerCn = commonNameOf(der, issuerStart, issuerNode.fin)
  let validityNode = readTlv(der, t, "validity")
  expectTag(validityNode, TagSequence, "validity")
  var vp2 = validityNode.contentStart
  let nbNode = readTlv(der, vp2, "notBefore")
  result.notBefore = parseDerTime(der, nbNode, "notBefore")
  let naNode = readTlv(der, vp2, "notAfter")
  result.notAfter = parseDerTime(der, naNode, "notAfter")
  if vp2 != validityNode.fin:
    fail("validity: bytes follow notAfter")
  if result.notAfter <= result.notBefore:
    fail("validity: notAfter is not after notBefore, so this certificate " &
      "is valid at no instant at all")
  let subjectStart = t
  let subjectNode = readTlv(der, t, "subject")
  expectTag(subjectNode, TagSequence, "subject")
  result.subjectDn = slice(der, subjectStart, subjectNode.fin)
  result.subjectCn = commonNameOf(der, subjectStart, subjectNode.fin)
  let spkiNode = readTlv(der, t, "subjectPublicKeyInfo")
  readSpki(der, spkiNode, result.publicKey)
  if t >= tbsNode.fin:
    fail("tbsCertificate: a v3 certificate with no extension block; " &
      "every certificate in an attestation chain states what it may be " &
      "used for, and one that states nothing constrains nothing")
  let extNode = readTlv(der, t, "extensions")
  readExtensions(der, extNode, result)
  if t != tbsNode.fin:
    fail("tbsCertificate: " & $(tbsNode.fin - t) &
      " bytes follow the extension block")

proc parseCrl*(der: openArray[byte]): X509Crl =
  ## One X.509 v2 certificate revocation list.
  if der.len == 0:
    fail("revocation list: zero bytes")
  if der.len > MaxCrlBytes:
    fail("revocation list: " & $der.len & " bytes; at most " & $MaxCrlBytes &
      " are read")
  result.der = slice(der, 0, der.len)
  var pos = 0
  let outer = readTlv(der, pos, "revocation list")
  expectTag(outer, TagSequence, "revocation list")
  if pos != der.len:
    fail("revocation list: bytes follow the outer SEQUENCE")
  var p = outer.contentStart
  let tbsStart = p
  let tbsNode = readTlv(der, p, "tbsCertList")
  expectTag(tbsNode, TagSequence, "tbsCertList")
  result.tbs = slice(der, tbsStart, tbsNode.fin)
  let algNode = readTlv(der, p, "revocation list")
  readAlgorithmEcdsaSha256(der, algNode, "revocation list")
  let sigNode = readTlv(der, p, "revocation list")
  result.signature = readSignatureBits(der, sigNode, "revocation list")
  if p != outer.fin:
    fail("revocation list: bytes follow the signature")

  var t = tbsNode.contentStart
  let vNode = readTlv(der, t, "tbsCertList version")
  expectTag(vNode, TagInteger, "tbsCertList version")
  if vNode.contentLen != 1 or der[vNode.contentStart] != 1'u8:
    fail("tbsCertList: the version is not v2, and a v1 list carries no " &
      "extensions and no way to say which issuer it speaks for")
  let innerAlg = readTlv(der, t, "tbsCertList")
  readAlgorithmEcdsaSha256(der, innerAlg, "tbsCertList")
  let issuerStart = t
  let issuerNode = readTlv(der, t, "tbsCertList issuer")
  expectTag(issuerNode, TagSequence, "tbsCertList issuer")
  result.issuerDn = slice(der, issuerStart, issuerNode.fin)
  result.issuerCn = commonNameOf(der, issuerStart, issuerNode.fin)
  let thisNode = readTlv(der, t, "thisUpdate")
  result.thisUpdate = parseDerTime(der, thisNode, "thisUpdate")
  if t < tbsNode.fin and der[t] in {TagUtcTime, TagGeneralizedTime}:
    let nextNode = readTlv(der, t, "nextUpdate")
    result.nextUpdate = parseDerTime(der, nextNode, "nextUpdate")
    result.hasNextUpdate = true
  if t < tbsNode.fin and der[t] == TagSequence:
    let listNode = readTlv(der, t, "revokedCertificates")
    var q = listNode.contentStart
    while q < listNode.fin:
      let entry = readTlv(der, q, "revoked entry")
      expectTag(entry, TagSequence, "revoked entry")
      var e = entry.contentStart
      let serialNode = readTlv(der, e, "revoked serialNumber")
      expectTag(serialNode, TagInteger, "revoked serialNumber")
      var hex = ""
      for i in 0 ..< serialNode.contentLen:
        hex.add toHex(int(der[serialNode.contentStart + i]), 2)
      let dateNode = readTlv(der, e, "revocationDate")
      if result.revoked.len >= MaxRevokedEntries:
        fail("revocation list: more than " & $MaxRevokedEntries & " entries")
      result.revoked.add X509RevokedEntry(
        serialHex: hex.toLowerAscii,
        revokedAt: parseDerTime(der, dateNode, "revocationDate"))
  if t < tbsNode.fin and der[t] == TagContext0:
    discard readTlv(der, t, "crlExtensions")
  if t != tbsNode.fin:
    fail("tbsCertList: " & $(tbsNode.fin - t) & " bytes follow the list")

# ---------------------------------------------------------------------
# The one public-key operation
# ---------------------------------------------------------------------

proc sha256Of(msg: openArray[byte]): array[32, byte] =
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha224Update(ctx, unsafeAddr msg[0], uint(msg.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

proc verifyEcdsaSha256*(message: openArray[byte];
                        signatureDer: openArray[byte];
                        publicKey: array[P256PointLen, byte]): bool =
  ## ECDSA-P256 over SHA-256, through BearSSL, with the signature in the
  ## DER ``ECDSA-Sig-Value`` form X.509 uses.
  ##
  ## Returns ``false`` on every failure rather than raising, because
  ## every caller here has a refusal to produce and none of them has a
  ## different answer for "the point is malformed" than for "the
  ## signature is wrong".
  if signatureDer.len == 0: return false
  let digest = sha256Of(message)
  var key = publicKey
  var sig = newSeq[byte](signatureDer.len)
  for i in 0 ..< signatureDer.len: sig[i] = signatureDer[i]
  var hashBuf = digest
  var pk: bsslEcAbi.EcPublicKey
  pk.curve = cint(bsslEcAbi.EC_secp256r1)
  pk.q = addr key[0]
  pk.qlen = uint(P256PointLen)
  let ecImpl = bsslEcAbi.ecGetDefault()
  let verifier = bsslEcAbi.ecdsaVrfyAsn1GetDefault()
  let ok = verifier(ecImpl, addr hashBuf[0], csize_t(hashBuf.len),
                    addr pk, addr sig[0], csize_t(sig.len))
  ok == 1'u32

proc signatureVerifiesUnder*(cert: X509Cert;
                             issuerKey: array[P256PointLen, byte]): bool =
  ## Whether this certificate's signature verifies under ``issuerKey``,
  ## over the TBS bytes **as they arrived**.
  verifyEcdsaSha256(cert.tbs, cert.signature, issuerKey)

proc signatureVerifiesUnder*(crl: X509Crl;
                             issuerKey: array[P256PointLen, byte]): bool =
  verifyEcdsaSha256(crl.tbs, crl.signature, issuerKey)

proc criticalOids*(cert: X509Cert): seq[string] =
  for ext in cert.extensions:
    if ext.critical: result.add ext.oid

proc describeName*(dn: openArray[byte]; cn: string): string =
  ## A Name for a diagnostic: its CN when it has one, and its length
  ## either way, so two Names that share a CN are still told apart.
  (if cn.len > 0: "CN=" & cn else: "<no common name>") &
    " (" & $dn.len & "-byte Name)"
