## The endorsement chain behind an SEV-SNP report: VCEK or VLEK, its
## AMD intermediate, and AMD's root — **rooted at AMD by construction**.
##
## ## The one thing to read before anything else
##
## `evaluateAmdChain` takes no trust anchor.
##
## Not an anchor that defaults to AMD's, not a policy that names one, not
## a flag, not a file, not an environment variable, not a compile-time
## define. The procedure's whole parameter list is three certificates, a
## revocation list and a clock, and the set of root keys it will accept
## is `AmdRootKeys`, a `const`. There is no configuration of this
## function under which a chain rooted anywhere else is acceptable,
## because there is no configuration of this function.
##
## That is the difference between "the default root is AMD's" and "the
## root is AMD's". The first is a setting, and a setting is a thing an
## operator, a document, a mistake or an attacker can move. `AmdRootKeys`
## is none of those: changing it is editing this file and rebuilding.
##
## `AmdChainSignature` below records the parameter list as a type, and a
## `static` assertion pins `evaluateAmdChain` to it. Adding a parameter —
## an anchor, an "allowed roots", a bool — stops the compilation, by
## name, rather than quietly widening what the verifier trusts.
##
## ## Why the roots are pinned as KEYS and not as certificates
##
## An anchor is a public key. A certificate is a document *about* a
## public key, and every field of it except the key is a thing an
## impostor may copy: the subject name, the issuer name, the serial, the
## validity window, the extensions, the very algorithm identifiers. A
## chain matched on any of those is a chain that anyone who can spell
## "ARK-Milan" can present. So what is pinned here is the modulus and the
## exponent, and the common name is checked *against the pinned entry*
## afterwards — so a genuine Milan root cannot be presented as the Turin
## one either.
##
## ## The profile, and why it is a second profile rather than a wider one
##
## AMD's certificates are not the certificates `x509.nim` reads. Their
## signatures are RSASSA-PSS with SHA-384 over RSA-4096; the endorsement
## key is P-384; the intermediates carry critical `basicConstraints` and
## `keyUsage`; the leaf carries eleven extensions on AMD's own private
## enterprise arc and no `basicConstraints` at all. Widening `x509.nim`
## to admit all of that would weaken the reader the TPM chain depends on,
## because a reader that accepts two signature algorithms accepts the
## weaker one for both chains.
##
## So this is a second *profile* over the *same* reader. The DER grammar
## — `readTlv`, the length rules, the parent bounds, the OID decoding,
## the time parsing — is `x509.nim`'s, imported, not reimplemented. Only
## the question "which of these documents do I admit" differs, and each
## profile refuses the other's by name.
##
## ## What this build does NOT do, stated rather than implied
##
##   * It does not fetch. The KDS is an HTTP service; every byte here
##     arrives from the caller, and the gate's bytes arrive from a file.
##   * It reads the AMD-published revocation list and **requires** a
##     current one signed by the pinned root. What that list covers is
##     the intermediate: AMD revokes an ASK by serial, and revokes an
##     endorsement key by rotating the platform's version instead — which
##     is why the version floor, and not this list, is what retires a
##     VCEK.
##   * It implements no `authorityKeyIdentifier` matching. The chain is
##     three certificates in a known order; there is nothing to search.
##
## ## Mocking
##
## None. Real AMD DER, real RSASSA-PSS through BearSSL.

import std/[strutils]

import ./x509

import bearssl/abi/bearssl_hash as bsslHashAbi
import bearssl/abi/bearssl_rsa as bsslRsaAbi

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  AmdChainRejection* = enum
    ## `acAccepted` is the only value here that is not a refusal.
    ##
    ## **A kind is not a rule here, and a test must not read it as one.**
    ## Six of these values are produced by more than one rule:
    ## `acWrongKeyType` and `acBadSignature` by three apiece,
    ## `acNameMismatch`, `acNotACertificateAuthority` and `acExpired` by
    ## two, and `acNoRevocationData` by five conditions funnelling into a
    ## single refusal site. So asserting the kind alone says only that
    ## one of that value's rules fired.
    ##
    ## What makes a case mean ONE rule is the `detail` sentence, and
    ## every one of those rules carries a different one — including the
    ## five revocation conditions, which name individually why each list
    ## they were handed was set aside. Assert the kind *and* the
    ## sentence; `amdChainMessagesAreDistinguishable` only guarantees
    ## that two different KINDS cannot be confused.
    acAccepted
    acMalformed
    acWrongKeyType
    acNameMismatch
    acNotSelfIssued
    acNotACertificateAuthority
    acUnrecognisedCriticalExtension
    acBadSignature
    acRootIsNotAmd
    acRootNameDisagreesWithKey
    acExpired
    acNoRevocationData
    acRevoked
    acLeafIsNotAnEndorsementKey
    acLeafCarriesNoPlatformVersion
    acLeafCarriesNoChipIdentity

const
  AmdChainMessage*: array[AmdChainRejection, string] = [
    acAccepted:
      "this chain links by name, verifies link by link, ends at a root " &
      "this build holds the key of, and is inside every validity window " &
      "it states",
    acMalformed:
      "an element of this chain did not read as a certificate of the " &
      "shape the vendor issues",
    acWrongKeyType:
      "an element carries a subject key of a type its position in the " &
      "chain does not use",
    acNameMismatch:
      "an element names an issuer that the element above it is not",
    acNotSelfIssued:
      "the last element of this chain names an issuer other than itself, " &
      "so it is not the self-issued end a chain terminates in",
    acNotACertificateAuthority:
      "an element issued the element below it without carrying the " &
      "constraint that authorises it to issue anything",
    acUnrecognisedCriticalExtension:
      "an element marks an extension critical that this build cannot " &
      "act on, and its issuer said to refuse rather than ignore it",
    acBadSignature:
      "an element does not verify under the key of the element above it",
    acRootIsNotAmd:
      "the key this chain ends at is not one of the roots compiled into " &
      "this verifier, so nothing it says is endorsed by anybody this " &
      "build recognises",
    acRootNameDisagreesWithKey:
      "the root's key is one this build holds and the name beside it " &
      "belongs to a different one",
    acExpired:
      "an element is being used outside the window it states",
    acNoRevocationData:
      "no current revocation list signed by this root was supplied, so " &
      "whether the intermediate is still valid was never asked",
    acRevoked:
      "the intermediate's serial number appears on the current " &
      "revocation list its root publishes",
    acLeafIsNotAnEndorsementKey:
      "the first element is not named as one of the endorsement keys a " &
      "report may be signed with",
    acLeafCarriesNoPlatformVersion:
      "the endorsement certificate states no platform version, so there " &
      "is nothing to compare a report's version against",
    acLeafCarriesNoChipIdentity:
      "the endorsement certificate carries no chip identity, so it " &
      "cannot be tied to the part that produced a report"]

proc amdChainMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another.
  for a in AmdChainRejection:
    for b in AmdChainRejection:
      if a == b: continue
      if AmdChainMessage[a] in AmdChainMessage[b]: return false
  true

# ---------------------------------------------------------------------
# The profile
# ---------------------------------------------------------------------

const
  OidRsaEncryption* = "1.2.840.113549.1.1.1"
  OidRsassaPss* = "1.2.840.113549.1.1.10"
  OidSecp384r1* = "1.3.132.0.34"
  OidAuthorityKeyIdentifier* = "2.5.29.35"
  OidSubjectKeyIdentifier* = "2.5.29.14"
  OidCrlDistributionPoints* = "2.5.29.31"

  AmdArc* = "1.3.6.1.4.1.3704.1"
    ## AMD's private enterprise arc, `1.3.6.1.4.1.3704`, sub-arc 1.
  OidAmdStructVersion* = AmdArc & ".1"
  OidAmdProductName* = AmdArc & ".2"
  OidAmdBlSpl* = AmdArc & ".3.1"
  OidAmdTeeSpl* = AmdArc & ".3.2"
  OidAmdSnpSpl* = AmdArc & ".3.3"
  OidAmdUcodeSpl* = AmdArc & ".3.8"
  OidAmdHwId* = AmdArc & ".4"

  RsaModulusLen* = 512          ## RSA-4096.
  EcP384PointLen* = 97          ## `0x04 ‖ X(48) ‖ Y(48)`.
  HwIdLen* = 64

  PssSha384WithTrailerFieldHex* =
    "304606092a864886f70d01010a3039a00f300d060960864801650304020205" &
    "00a11c301a06092a864886f70d010108300d0609608648016503040202050" &
    "0a203020130a303020101"
  PssSha384OmittingTrailerFieldHex* =
    "304106092a864886f70d01010a3034a00f300d060960864801650304020205" &
    "00a11c301a06092a864886f70d010108300d0609608648016503040202050" &
    "0a203020130"
    ## The two complete DER `AlgorithmIdentifier` blocks this profile
    ## admits: RSASSA-PSS with SHA-384, MGF1-SHA-384 and a 48-byte salt,
    ## once with an explicit `trailerField` of 1 and once without it.
    ##
    ## **There are two because the vendor emits two.** `trailerField`
    ## has a DEFAULT of 1, and DER requires a field at its default to be
    ## omitted — so the second of these is the conformant spelling. The
    ## vendor's certificates nevertheless carry the first, and the
    ## vendor's revocation lists carry the second, in the same
    ## distribution, signed by the same key. Measured on the real bytes,
    ## not inferred: the certificate block is 72 bytes and the list's is
    ## 67, and the five-byte difference is exactly `a3 03 02 01 01`.
    ##
    ## Both are pinned as whole byte strings and compared **byte for
    ## byte** rather than parsed. Byte comparison is the stronger check
    ## and the smaller attack surface at once: DER gives a value exactly
    ## one encoding, so there is nothing for a lenient parser to
    ## normalise; and a parameter block that is never decoded is a
    ## parameter block with no decoder to confuse. The salt length in
    ## particular is a number that decides whether a signature verifies,
    ## and reading it out of the attacker's document in order to verify
    ## the attacker's document is a loop worth not closing.
    ##
    ## Listing two exact spellings is emphatically not the same as
    ## parsing the block leniently. Anything that is neither of these two
    ## strings is refused, including every other salt length, every other
    ## hash on either side, and the same parameters in a different order.

  RecognisedAmdCriticalOids*: array[2, string] =
    [OidBasicConstraints, OidKeyUsage]
    ## RFC 5280 §4.2, applied to this profile: these are the two critical
    ## extensions AMD's intermediates carry and this build acts on. It
    ## takes no parameter for the same reason the root set does not.

type
  AmdKeyKind* = enum
    akRsa4096
    akEcP384

  AmdCert* = object
    der*, tbs*: seq[byte]
    serialHex*: string
    issuerDn*, subjectDn*: seq[byte]
    issuerCn*, subjectCn*: string
    notBefore*, notAfter*: int64
    keyKind*: AmdKeyKind
    rsaModulus*, rsaExponent*: seq[byte]
    ecPoint*: seq[byte]
    signature*: seq[byte]
    extensions*: seq[X509Extension]
    isCa*, hasBasicConstraints*, hasKeyUsage*: bool
    keyUsage*: set[KeyUsageBit]
    productName*: string
    hasPlatformVersion*: bool
    blSpl*, teeSpl*, snpSpl*, ucodeSpl*: int
    hwId*: seq[byte]

  AmdCrl* = object
    der*, tbs*: seq[byte]
    issuerDn*: seq[byte]
    issuerCn*: string
    thisUpdate*, nextUpdate*: int64
    hasNextUpdate*: bool
    revokedSerials*: seq[string]
    signature*: seq[byte]

proc hexToBytes(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc admittedPssAlgorithmIdentifiers*(): array[2, seq[byte]] =
  [hexToBytes(PssSha384WithTrailerFieldHex),
   hexToBytes(PssSha384OmittingTrailerFieldHex)]

proc sameBytes(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc isAdmittedPssAlgorithm*(algBlock: openArray[byte]): bool =
  ## Whether these bytes are one of the two spellings above, exactly.
  for admitted in admittedPssAlgorithmIdentifiers():
    if sameBytes(algBlock, admitted): return true
  false

proc readAmdSpki(buf: openArray[byte]; node: DerNode; cert: var AmdCert) =
  expectTag(node, TagSequence, "SubjectPublicKeyInfo")
  var p = node.contentStart
  let algNode = readTlv(buf, p, "SubjectPublicKeyInfo algorithm", node.fin)
  expectTag(algNode, TagSequence, "SubjectPublicKeyInfo algorithm")
  var ap = algNode.contentStart
  let algOidNode = readTlv(buf, ap, "public key algorithm", algNode.fin)
  let algOid = oidToString(buf, algOidNode, "public key algorithm")
  let bitNode = readTlv(buf, p, "subjectPublicKey", node.fin)
  expectTag(bitNode, TagBitString, "subjectPublicKey")
  if bitNode.contentLen < 2 or buf[bitNode.contentStart] != 0:
    derFail("SubjectPublicKeyInfo: the key BIT STRING declares unused bits")
  if p != node.fin:
    derFail("SubjectPublicKeyInfo: bytes follow the subjectPublicKey")
  if algOid == OidRsaEncryption:
    cert.keyKind = akRsa4096
    var kp = bitNode.contentStart + 1
    let seqNode = readTlv(buf, kp, "RSAPublicKey", bitNode.fin)
    expectTag(seqNode, TagSequence, "RSAPublicKey")
    var q = seqNode.contentStart
    let nNode = readTlv(buf, q, "RSA modulus", seqNode.fin)
    expectTag(nNode, TagInteger, "RSA modulus")
    let eNode = readTlv(buf, q, "RSA exponent", seqNode.fin)
    expectTag(eNode, TagInteger, "RSA exponent")
    if q != seqNode.fin:
      derFail("RSAPublicKey: bytes follow the exponent")
    var ns = nNode.contentStart
    # An unsigned INTEGER whose top bit is set carries one leading zero
    # byte. Stripping it is not cosmetic: the modulus is what is
    # compared against the pinned root, and two spellings of one number
    # would be two roots.
    if buf[ns] == 0'u8: inc ns
    cert.rsaModulus = slice(buf, ns, nNode.fin)
    if cert.rsaModulus.len != RsaModulusLen:
      derFail("RSAPublicKey: the modulus is " & $cert.rsaModulus.len &
        " bytes and this profile reads " & $RsaModulusLen)
    cert.rsaExponent = slice(buf, eNode.contentStart, eNode.fin)
  elif algOid == OidEcPublicKey:
    cert.keyKind = akEcP384
    if ap >= algNode.fin:
      derFail("SubjectPublicKeyInfo: id-ecPublicKey with no named curve")
    let curveNode = readTlv(buf, ap, "named curve", algNode.fin)
    let curveOid = oidToString(buf, curveNode, "named curve")
    if curveOid != OidSecp384r1:
      derFail("SubjectPublicKeyInfo: the named curve is " & curveOid &
        " and this profile reads only secp384r1 (" & OidSecp384r1 & ")")
    if ap != algNode.fin:
      derFail("SubjectPublicKeyInfo: bytes follow the named curve")
    if bitNode.contentLen != EcP384PointLen + 1:
      derFail("SubjectPublicKeyInfo: the public key is " &
        $(bitNode.contentLen - 1) & " bytes; an uncompressed P-384 point " &
        "is " & $EcP384PointLen)
    if buf[bitNode.contentStart + 1] != 0x04'u8:
      derFail("SubjectPublicKeyInfo: the point does not begin 0x04, so it " &
        "is not in the uncompressed form this build reads")
    cert.ecPoint = slice(buf, bitNode.contentStart + 1, bitNode.fin)
  else:
    derFail("SubjectPublicKeyInfo: the key algorithm is " & algOid &
      " and this profile reads id-ecPublicKey and rsaEncryption only")

proc amdIntegerExtension(value: openArray[byte]; what: string): int =
  var p = 0
  let node = readTlv(value, p, what, value.len)
  expectTag(node, TagInteger, what)
  if node.contentLen < 1 or node.contentLen > 2:
    derFail(what & ": a platform version component is one byte")
  var v = 0
  for i in 0 ..< node.contentLen:
    v = (v shl 8) or int(value[node.contentStart + i])
  if v < 0 or v > 255:
    derFail(what & ": the value " & $v & " does not fit in a byte")
  v

proc amdStringExtension(value: openArray[byte]; what: string): string =
  var p = 0
  let node = readTlv(value, p, what, value.len)
  if node.tag notin {TagIa5String, TagUtf8String, TagPrintableString}:
    derFail(what & ": not a character string")
  for i in 0 ..< node.contentLen:
    result.add char(value[node.contentStart + i])

proc readAmdExtensions(buf: openArray[byte]; node: DerNode;
                       cert: var AmdCert) =
  expectTag(node, TagContext3, "extensions")
  var p = node.contentStart
  let listNode = readTlv(buf, p, "extensions", node.fin)
  expectTag(listNode, TagSequence, "extensions")
  if p != node.fin:
    derFail("extensions: bytes follow the extension list")
  var seen: seq[string] = @[]
  var extPos = listNode.contentStart
  while extPos < listNode.fin:
    let extNode = readTlv(buf, extPos, "extension", listNode.fin)
    expectTag(extNode, TagSequence, "extension")
    var q = extNode.contentStart
    let oidNode = readTlv(buf, q, "extension identifier", extNode.fin)
    expectTag(oidNode, TagOid, "extension identifier")
    var ext = X509Extension(oid: oidToString(buf, oidNode,
      "extension identifier"))
    if ext.oid in seen:
      derFail("extensions: the extension " & ext.oid & " appears twice, " &
        "and RFC 5280 gives no rule saying which one would apply")
    seen.add ext.oid
    if cert.extensions.len >= MaxExtensions:
      derFail("extensions: more than " & $MaxExtensions & " are carried")
    if q < extNode.fin and buf[q] == TagBoolean:
      let critNode = readTlv(buf, q, "extension criticality", extNode.fin)
      if critNode.contentLen != 1:
        derFail("extensions: the criticality of " & ext.oid &
          " is not one byte")
      if buf[critNode.contentStart] != 0xff'u8:
        derFail("extensions: the criticality of " & ext.oid &
          " is not the 0xFF DER writes TRUE as")
      ext.critical = true
    let valueNode = readTlv(buf, q, "extension value", extNode.fin)
    expectTag(valueNode, TagOctetString, "extension value")
    if q != extNode.fin:
      derFail("extensions: bytes follow the value of " & ext.oid)
    ext.value = slice(buf, valueNode.contentStart, valueNode.fin)
    cert.extensions.add ext

  var haveBl, haveTee, haveSnp, haveUcode = false
  for ext in cert.extensions:
    case ext.oid
    of OidBasicConstraints:
      cert.hasBasicConstraints = true
      var p2 = 0
      let bc = readTlv(ext.value, p2, "basicConstraints", ext.value.len)
      expectTag(bc, TagSequence, "basicConstraints")
      if bc.contentLen > 0 and ext.value[bc.contentStart] == TagBoolean:
        var q2 = bc.contentStart
        let b = readTlv(ext.value, q2, "basicConstraints cA", bc.fin)
        if b.contentLen != 1:
          derFail("basicConstraints: cA is not one byte")
        cert.isCa = ext.value[b.contentStart] != 0
    of OidKeyUsage:
      cert.hasKeyUsage = true
      var p2 = 0
      let ku = readTlv(ext.value, p2, "keyUsage", ext.value.len)
      expectTag(ku, TagBitString, "keyUsage")
      if ku.contentLen < 1:
        derFail("keyUsage: an empty BIT STRING")
      let unused = int(ext.value[ku.contentStart])
      if unused > 7:
        derFail("keyUsage: " & $unused & " unused bits")
      for bit in 0 ..< (ku.contentLen - 1) * 8 - unused:
        let b = ext.value[ku.contentStart + 1 + (bit div 8)]
        if (int(b) and (0x80 shr (bit mod 8))) != 0 and
           bit <= ord(high(KeyUsageBit)):
          cert.keyUsage.incl KeyUsageBit(bit)
    of OidAmdProductName:
      cert.productName = amdStringExtension(ext.value, "product name")
    of OidAmdBlSpl:
      cert.blSpl = amdIntegerExtension(ext.value, "bootloader version")
      haveBl = true
    of OidAmdTeeSpl:
      cert.teeSpl = amdIntegerExtension(ext.value, "tee version")
      haveTee = true
    of OidAmdSnpSpl:
      cert.snpSpl = amdIntegerExtension(ext.value, "snp version")
      haveSnp = true
    of OidAmdUcodeSpl:
      cert.ucodeSpl = amdIntegerExtension(ext.value, "microcode version")
      haveUcode = true
    of OidAmdHwId:
      # Taken RAW, and that is not an oversight. The vendor nests a DER
      # value inside the extension's OCTET STRING for the version
      # components and for the product name, and does NOT nest one here:
      # measured on a real certificate, the bytes run
      # `30 4d 06 09 <oid> 04 40 <64 bytes>`, so the `04 40` IS the
      # extnValue wrapper and the identity is its content. A reader that
      # assumed the nesting was uniform refuses every genuine
      # endorsement certificate there is, which is how this was found.
      cert.hwId = ext.value
    else:
      discard
  cert.hasPlatformVersion = haveBl and haveTee and haveSnp and haveUcode

proc parseAmdCertificate*(der: openArray[byte]): AmdCert =
  ## One certificate of AMD's profile. Refuses anything else by name.
  if der.len == 0:
    derFail("certificate: zero bytes")
  if der.len > MaxCertificateBytes:
    derFail("certificate: " & $der.len & " bytes; at most " &
      $MaxCertificateBytes & " are read")
  result.der = slice(der, 0, der.len)
  var pos = 0
  let outer = readTlv(der, pos, "certificate", der.len)
  expectTag(outer, TagSequence, "certificate")
  if pos != der.len:
    derFail("certificate: " & $(der.len - pos) &
      " bytes follow the outer SEQUENCE")
  var p = outer.contentStart
  let tbsStart = p
  let tbsNode = readTlv(der, p, "tbsCertificate", outer.fin)
  expectTag(tbsNode, TagSequence, "tbsCertificate")
  result.tbs = slice(der, tbsStart, tbsNode.fin)

  let algStart = p
  let algNode = readTlv(der, p, "certificate", outer.fin)
  if not isAdmittedPssAlgorithm(slice(der, algStart, algNode.fin)):
    derFail("certificate: the signature algorithm block is not the single " &
      "RSASSA-PSS/SHA-384 identifier this profile admits")
  let sigNode = readTlv(der, p, "certificate", outer.fin)
  expectTag(sigNode, TagBitString, "certificate signature")
  if sigNode.contentLen < 2 or der[sigNode.contentStart] != 0:
    derFail("certificate: the signature BIT STRING declares unused bits")
  result.signature = slice(der, sigNode.contentStart + 1, sigNode.fin)
  if result.signature.len != RsaModulusLen:
    derFail("certificate: the signature is " & $result.signature.len &
      " bytes and an RSA-4096 signature is " & $RsaModulusLen)
  if p != outer.fin:
    derFail("certificate: bytes follow the signature")

  var t = tbsNode.contentStart
  if t < tbsNode.fin and der[t] == TagContext0:
    let vNode = readTlv(der, t, "version", tbsNode.fin)
    var vp = vNode.contentStart
    let vInt = readTlv(der, vp, "version", vNode.fin)
    expectTag(vInt, TagInteger, "version")
    if vInt.contentLen != 1 or der[vInt.contentStart] != 2'u8:
      derFail("tbsCertificate: the version is not v3")
    if vp != vNode.fin:
      derFail("tbsCertificate: bytes follow the version")
  else:
    derFail("tbsCertificate: no version is present, so this is a v1 " &
      "certificate; this profile reads v3 only")
  let serialNode = readTlv(der, t, "serialNumber", tbsNode.fin)
  # One reader for serial numbers, shared with the X.509 profile beside
  # this one. This used to bound the serial's ENCODING at twenty octets,
  # where RFC 5280 §4.1.2.2 bounds its VALUE — and DER writes a
  # non-negative INTEGER whose top bit is set with a leading zero octet,
  # so a conformant twenty-octet serial above `0x7f…` occupies
  # twenty-one content octets and was refused.
  #
  # No processor vendor certificate in reach is affected: every root and
  # intermediate this backend reads carries a three-octet serial and
  # every endorsement key certificate carries a one-octet one, measured
  # across the live certificate service and every pinned fixture. So
  # this is a latent bound rather than one anything here trips, and it
  # is repaired because the repair also brings the two readers into
  # agreement about what a serial IS — the shared procedure enforces
  # DER's minimality, which this one did not, and a serial that spells
  # differently on the two sides of a withdrawal comparison is a
  # withdrawal that silently does not apply.
  result.serialHex = readSerialNumber(der, serialNode, "tbsCertificate")

  let innerAlgStart = t
  let innerAlg = readTlv(der, t, "tbsCertificate", tbsNode.fin)
  if not isAdmittedPssAlgorithm(slice(der, innerAlgStart, innerAlg.fin)):
    derFail("tbsCertificate: the signature algorithm block inside the " &
      "signed body is not the single RSASSA-PSS/SHA-384 identifier this " &
      "profile admits")

  let issuerStart = t
  let issuerNode = readTlv(der, t, "issuer", tbsNode.fin)
  expectTag(issuerNode, TagSequence, "issuer")
  result.issuerDn = slice(der, issuerStart, issuerNode.fin)
  result.issuerCn = commonNameOf(der, issuerStart, issuerNode.fin)
  let validityNode = readTlv(der, t, "validity", tbsNode.fin)
  expectTag(validityNode, TagSequence, "validity")
  var vp2 = validityNode.contentStart
  let nbNode = readTlv(der, vp2, "notBefore", validityNode.fin)
  result.notBefore = parseDerTime(der, nbNode, "notBefore")
  let naNode = readTlv(der, vp2, "notAfter", validityNode.fin)
  result.notAfter = parseDerTime(der, naNode, "notAfter")
  if vp2 != validityNode.fin:
    derFail("validity: bytes follow notAfter")
  if result.notAfter <= result.notBefore:
    derFail("validity: notAfter is not after notBefore, so this " &
      "certificate is valid at no instant at all")
  let subjectStart = t
  let subjectNode = readTlv(der, t, "subject", tbsNode.fin)
  expectTag(subjectNode, TagSequence, "subject")
  result.subjectDn = slice(der, subjectStart, subjectNode.fin)
  result.subjectCn = commonNameOf(der, subjectStart, subjectNode.fin)
  let spkiNode = readTlv(der, t, "subjectPublicKeyInfo", tbsNode.fin)
  readAmdSpki(der, spkiNode, result)
  if t >= tbsNode.fin:
    derFail("tbsCertificate: a v3 certificate with no extension block")
  let extNode = readTlv(der, t, "extensions", tbsNode.fin)
  readAmdExtensions(der, extNode, result)
  if t != tbsNode.fin:
    derFail("tbsCertificate: " & $(tbsNode.fin - t) &
      " bytes follow the extension block")

proc parseAmdCrl*(der: openArray[byte]): AmdCrl =
  ## One v2 certificate revocation list of AMD's profile.
  if der.len == 0:
    derFail("revocation list: zero bytes")
  if der.len > MaxCrlBytes:
    derFail("revocation list: " & $der.len & " bytes; at most " &
      $MaxCrlBytes & " are read")
  result.der = slice(der, 0, der.len)
  var pos = 0
  let outer = readTlv(der, pos, "revocation list", der.len)
  expectTag(outer, TagSequence, "revocation list")
  if pos != der.len:
    derFail("revocation list: bytes follow the outer SEQUENCE")
  var p = outer.contentStart
  let tbsStart = p
  let tbsNode = readTlv(der, p, "tbsCertList", outer.fin)
  expectTag(tbsNode, TagSequence, "tbsCertList")
  result.tbs = slice(der, tbsStart, tbsNode.fin)
  let algStart = p
  let algNode = readTlv(der, p, "revocation list", outer.fin)
  if not isAdmittedPssAlgorithm(slice(der, algStart, algNode.fin)):
    derFail("revocation list: the signature algorithm block is not the " &
      "single RSASSA-PSS/SHA-384 identifier this profile admits")
  let sigNode = readTlv(der, p, "revocation list", outer.fin)
  expectTag(sigNode, TagBitString, "revocation list signature")
  if sigNode.contentLen < 2 or der[sigNode.contentStart] != 0:
    derFail("revocation list: the signature BIT STRING declares unused bits")
  result.signature = slice(der, sigNode.contentStart + 1, sigNode.fin)
  if p != outer.fin:
    derFail("revocation list: bytes follow the signature")

  var t = tbsNode.contentStart
  let vNode = readTlv(der, t, "tbsCertList version", tbsNode.fin)
  expectTag(vNode, TagInteger, "tbsCertList version")
  if vNode.contentLen != 1 or der[vNode.contentStart] != 1'u8:
    derFail("tbsCertList: the version is not v2")
  let innerAlgStart = t
  let innerAlg = readTlv(der, t, "tbsCertList", tbsNode.fin)
  if not isAdmittedPssAlgorithm(slice(der, innerAlgStart, innerAlg.fin)):
    derFail("tbsCertList: the signature algorithm block inside the signed " &
      "body is not the single RSASSA-PSS/SHA-384 identifier this profile " &
      "admits")
  let issuerStart = t
  let issuerNode = readTlv(der, t, "tbsCertList issuer", tbsNode.fin)
  expectTag(issuerNode, TagSequence, "tbsCertList issuer")
  result.issuerDn = slice(der, issuerStart, issuerNode.fin)
  result.issuerCn = commonNameOf(der, issuerStart, issuerNode.fin)
  let thisNode = readTlv(der, t, "thisUpdate", tbsNode.fin)
  result.thisUpdate = parseDerTime(der, thisNode, "thisUpdate")
  if t < tbsNode.fin and der[t] in {TagUtcTime, TagGeneralizedTime}:
    let nextNode = readTlv(der, t, "nextUpdate", tbsNode.fin)
    result.nextUpdate = parseDerTime(der, nextNode, "nextUpdate")
    result.hasNextUpdate = true
  if t < tbsNode.fin and der[t] == TagSequence:
    let listNode = readTlv(der, t, "revokedCertificates", tbsNode.fin)
    var q = listNode.contentStart
    while q < listNode.fin:
      let entry = readTlv(der, q, "revoked entry", listNode.fin)
      expectTag(entry, TagSequence, "revoked entry")
      var e = entry.contentStart
      let serialNode = readTlv(der, e, "revoked serialNumber", entry.fin)
      # The same reader as the certificate side, deliberately: a serial
      # is only ever compared against another serial, and the two sides
      # have to agree about what one is or a withdrawal stops applying.
      let hex = readSerialNumber(der, serialNode, "revoked entry")
      if result.revokedSerials.len >= MaxRevokedEntries:
        derFail("revocation list: more than " & $MaxRevokedEntries &
          " entries")
      result.revokedSerials.add hex.toLowerAscii
      discard readTlv(der, e, "revocationDate", entry.fin)
  if t < tbsNode.fin and der[t] == TagContext0:
    discard readTlv(der, t, "crlExtensions", tbsNode.fin)
  if t != tbsNode.fin:
    derFail("tbsCertList: " & $(tbsNode.fin - t) & " bytes follow the list")

# ---------------------------------------------------------------------
# RSASSA-PSS, SHA-384, through BearSSL
# ---------------------------------------------------------------------

proc sha384Of(msg: openArray[byte]): array[48, byte] =
  var ctx: bsslHashAbi.Sha384Context
  bsslHashAbi.sha384Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha384Update(ctx, unsafeAddr msg[0], uint(msg.len))
  bsslHashAbi.sha384Out(ctx, addr result[0])

const PssSaltLen* = 48

proc verifyRsaPssSha384*(message: openArray[byte];
                         signature: openArray[byte];
                         modulus, exponent: openArray[byte]): bool =
  ## The single RSA operation in this module.
  ##
  ## Refuses rather than dereferences on every degenerate input: an empty
  ## signature, an empty modulus, an empty exponent, or a signature whose
  ## width is not the modulus's. BearSSL's own `br_rsa_pss_vrfy` reads
  ## `xlen` bytes at `x` and takes the modulus length from the key, so a
  ## signature shorter than the modulus is a read past the end unless it
  ## is stopped here.
  if signature.len == 0 or modulus.len == 0 or exponent.len == 0:
    return false
  if signature.len != modulus.len:
    return false
  var digest = sha384Of(message)
  var sig = @signature
  var n = @modulus
  var e = @exponent
  var pk: bsslRsaAbi.RsaPublicKey
  pk.n = addr n[0]
  pk.nlen = uint(n.len)
  pk.e = addr e[0]
  pk.elen = uint(e.len)
  let vrfy = bsslRsaAbi.rsaPssVrfyGetDefault()
  vrfy(addr sig[0], csize_t(sig.len),
       addr bsslHashAbi.sha384Vtable, addr bsslHashAbi.sha384Vtable,
       addr digest[0], csize_t(PssSaltLen), addr pk) == 1'u32

proc signatureVerifiesUnder*(cert: AmdCert; issuer: AmdCert): bool =
  if issuer.keyKind != akRsa4096: return false
  verifyRsaPssSha384(cert.tbs, cert.signature,
                     issuer.rsaModulus, issuer.rsaExponent)

proc signatureVerifiesUnder*(crl: AmdCrl; issuer: AmdCert): bool =
  if issuer.keyKind != akRsa4096: return false
  verifyRsaPssSha384(crl.tbs, crl.signature,
                     issuer.rsaModulus, issuer.rsaExponent)

# ---------------------------------------------------------------------
# The roots — a const, with no way in
# ---------------------------------------------------------------------

type
  AmdProductLine* = enum
    aplMilan = "Milan"
    aplGenoa = "Genoa"
    aplTurin = "Turin"

  AmdRootKey* = object
    line*: AmdProductLine
    commonName*: string
    modulusHex*: string
    exponentHex*: string

const
  AmdRootKeys*: array[AmdProductLine, AmdRootKey] = [
    aplMilan: AmdRootKey(
      line: aplMilan, commonName: "ARK-Milan", exponentHex: "010001",
      modulusHex:
        "d0b779d9124e75e88996a2b625db15983ec592dba8b56c17d5f3605b8d5763" &
        "d5f3d471214949a12f3f42bbd0c7465be02523716de618b2725fbf28f1d4c7" &
        "d4d15e6d90a894d447ac345b5ad644c0d2cccd8ac75873d8acaa4ee65d3e7e" &
        "29f1916df73857ff73448704f2394737ad52d63bbc5fddfee9dc4352b1b64b" &
        "3c6a278061ab2626503aee3d72525f8bd4734d4fee3f7c329a8e4bde6b3917" &
        "461de239d8d6b3e66d81f8efaf8ec0b4eb4777ee363d2c57ae38fe0c7ab8bc" &
        "aa07e2d92e642aa83f685e9a3edb80650551eeedca1585cfe7d5e6260b5ca2" &
        "0d398262344ff3a2b4b86ecd5be965c2e9874a1d87fd483d7ab1dfe3278c3f" &
        "7b03b7d7a6a19dff2f0ac57ee392c4c4cc03a06ca01e6a6de59bedf2288713" &
        "60c96c44c5cf72335b22f9ac072903fffc529e2bacb870648279443445b1d5" &
        "471b410aecfa054392e54f86c9f321136062f338f18fbb2c6889627ae613cc" &
        "5cadec5e901c6bbdad95f53250aa7377439de4b79be2422dfe8027e69300b4" &
        "174b62ac865b2e45cfacfc3367433d78dc6123249bda7a497e09eacf9e48d2" &
        "edf7c21e2bd1935079319fc34dcc054b72bb319eb0691cc3e968a8c6aad6a4" &
        "78b6319b3d8c42be90aaefe3a0a420a830d8addae2e8f4cd7c7c7cf5d2538c" &
        "4fc9d6014bd1645ced7970a6fbb3c77583e5990c14c372ef7a727f20b5e840" &
        "f1df6e41f40b23df865d635a124565ab"),
    aplGenoa: AmdRootKey(
      line: aplGenoa, commonName: "ARK-Genoa", exponentHex: "010001",
      modulusHex:
        "dc277de52fee14eb9122c916f6fcfd543045ebd343405efda1184bfcbd8f55" &
        "01a12b761d7c4060a45fc98b058506c4ff7d70e1cc0d35a772e4713ffb2dd8" &
        "dc45f2978c797ed10abf338759921e900e851e2b33412c37012830c65a8def" &
        "df9372af16c0d439e463050a5390009383fde2d2972e9f34a31b7ce1a8721e" &
        "82e673f2eab06b29fa8ab5073e0f3ec60bc131b888c29569a4fdd3fa19e08f" &
        "2889b4abbbddaf26196a58edbb77f47173789433284d7864e83af831fe2528" &
        "e201a91bad4d0e990452f233b8a71a331f08753a568360c5e92c05d0881531" &
        "f7e7bed26603af01c09356a351383cb25d68f7c189f709a6e045c0d55020f4" &
        "04557dda3fcf47252a7c61b63d972492e8f95512a4c106d6909a2e004c698c" &
        "47e9f62bf7be240854d868fb8c8a4984e91d1fd7e2ad00e79a50364857c9fc" &
        "27349863735bd466221c8e527345a1c966911865dff01053962cf50b1a9f58" &
        "d3fc48b24fea42a669c0fb2f5e76f84309b386f05da8c47191753064ca5ba7" &
        "82b917246622c06ad1f246a2aafecd37c42138132a62371bae412bd1ff1030" &
        "a925212e6bb8e7ea94b302070f092c1dcb923a5682d0fb3a9c64cd2b2884de" &
        "3b5289bce9163a969ef683c7971cfd6a62b9ef873686d52ef4bf0e8e91b69a" &
        "0bd123887fee1e0009406c689fbbb443bc60a1111603f7bb25c050c0b83cd0" &
        "7abfb1b46ea9eb31cfbc01592636e787"),
    aplTurin: AmdRootKey(
      line: aplTurin, commonName: "ARK-Turin", exponentHex: "010001",
      modulusHex:
        "c1a02b881ec422e55ce19075c03dd87c3c4bfbd7b24bbfa2ce6d098f75bbef" &
        "63483425a5f018f7c3f243d998e66d1c56748abfe1df626ab08aa2b5e5a095" &
        "01d6345d831a9c713c7568ea22838fb6c355e1555253ecae39ef04f964b349" &
        "8106b1a9af44b64c2377afbdb0e86508313d978de443447606291525afeecb" &
        "254e4b0124e70e6d5ca3ae1bd8efaba42d00c25ab16dfcc25a910da2841ad6" &
        "7d554806a27dbb66e2f8b1326e0bf6b3cfdfe2401c3c9048a5cce97de40893" &
        "91e6398d21010d66c0aa7664e6a94cee4212286db4920426d789a134a0c8da" &
        "9da8b9afb3b801bb8b9d9ea68445d867d4d13624ff27febc2341dad9de7211" &
        "50b8fd9ef1b2e4f7965da8f8bdfd45b0e095e3b5d100e2ed896299524943d0" &
        "5405cab7a2d5aae8ed25c339f492abdaed1743be4ac3170ca75e604978417c" &
        "89ef3c0c2e018e1d130c06a93f28220e1eb0f1f012c98286161e0c8c4f1bd4" &
        "787f1f4ed2aea9f066fe1d7953892e3b3fd60d78ea6274e50acc397f4b53af" &
        "ca10ed48bf0b25cdb84004c5c9da3f883fca51dbc54d1943d1cae400c9192e" &
        "8590f212c319ce816495ec75ded97f67b8516ded23fd6887fdaddb73addf3c" &
        "a14dcbf98036c006ed0b8d57bdf2e4674b5e523302bffe526df5ee41a8abe0" &
        "001912a0005ff81e1516d3d5117d3282b61a15a23d8b9001af19d5066cd7a5" &
        "16f6d622353653427ce1943c8855a561")]
    ## AMD's three published root keys, one per platform generation.
    ##
    ## Each was taken from the certificate the vendor's own distribution
    ## service serves at `/vcek/v1/<line>/cert_chain`, and the gate
    ## re-derives all three from that service's verbatim response rather
    ## than reading them from here — so this table is checked against the
    ## vendor's bytes, not merely transcribed from them once.
    ##
    ## There is no fourth entry and no way to add one at run time. That
    ## is the whole mechanism by which a chain rooted somewhere else is
    ## refused: not a comparison that a flag could skip, but an absence
    ## of anywhere to put another key.

proc hexBytes*(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc amdRootFor*(modulus, exponent: openArray[byte]): int =
  ## The index of the pinned root holding exactly this key, or `-1`.
  ## Compared on BOTH halves: an impostor that reused AMD's modulus with
  ## a different exponent would be a different key.
  for line in AmdProductLine:
    let k = AmdRootKeys[line]
    if sameBytes(modulus, hexBytes(k.modulusHex)) and
       sameBytes(exponent, hexBytes(k.exponentHex)):
      return ord(line)
  -1

# ---------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------

const
  AmdChainElements* = 3
    ## The endorsement key, the vendor's signing key, the vendor's root.
    ## Named because a caller that bundles a different number is making
    ## a different claim, and the count is the first thing to check.

  VcekCommonName* = "SEV-VCEK"
  VlekCommonName* = "SEV-VLEK"
  EndorsementKeyCommonNames*: array[2, string] =
    [VcekCommonName, VlekCommonName]
    ## The two names a report's signing key may carry. A VCEK is issued
    ## per part by the AMD Signing Key; a VLEK is issued to a cloud
    ## operator by the AMD SEV Versioned Loaded Endorsement Key. Both
    ## chains end at the SAME root, which is why they are one decision
    ## here and not two.

type
  AmdChainVerdict* = object
    reason*: AmdChainRejection
    detail*: string
    rootLine*: AmdProductLine
    rootMatched*: bool
    leafCn*, intermediateCn*, rootCn*: string
    endorsedTcb*: tuple[bootloader, tee, snp, microcode: int]
    hwId*: seq[byte]
    endorsedAt*: int64
      ## The endorsement certificate's `notBefore`: the instant the
      ## vendor endorsed THIS part at THIS platform version. Inside the
      ## signed certificate, so the machine being judged cannot move it.
    productName*: string
    revocationConsulted*: bool

  AmdChainSignature* = proc (leafDer, intermediateDer, rootDer: seq[byte];
                             crlDer: seq[seq[byte]];
                             nowSeconds: int64): AmdChainVerdict {.nimcall.}
    ## The parameter list `evaluateAmdChain` has, recorded as a type so
    ## that it cannot change without a compile error. See the `static`
    ## block at the foot of this file.

proc isAccepted*(v: AmdChainVerdict): bool = v.reason == acAccepted

proc unrecognisedCriticalOid(cert: AmdCert): string =
  for ext in cert.extensions:
    if ext.critical and ext.oid notin RecognisedAmdCriticalOids:
      return ext.oid
  ""

proc evaluateAmdChain*(leafDer, intermediateDer, rootDer: seq[byte];
                       crlDer: seq[seq[byte]];
                       nowSeconds: int64): AmdChainVerdict =
  ## Three certificates, leaf first, and the revocation lists the caller
  ## fetched. No anchor: see this module's header.
  template no(refusal: AmdChainRejection; because: string) =
    # The parameters are NOT called `reason` and `detail`: a template
    # parameter named after a field of `result` is substituted into
    # `result.detail`, which produces a syntax error in the best case
    # and the wrong field in the worst.
    result.reason = refusal
    result.detail = AmdChainMessage[refusal] & ": " & because
    return result

  var leaf, mid, root: AmdCert
  try:
    leaf = parseAmdCertificate(leafDer)
    mid = parseAmdCertificate(intermediateDer)
    root = parseAmdCertificate(rootDer)
  except X509Error as err:
    no(acMalformed, err.msg)

  result.leafCn = leaf.subjectCn
  result.intermediateCn = mid.subjectCn
  result.rootCn = root.subjectCn
  result.productName = leaf.productName
  result.endorsedAt = leaf.notBefore

  # RFC 5280 §4.2, on all three.
  for i, c in [leaf, mid, root]:
    let oid = unrecognisedCriticalOid(c)
    if oid.len > 0:
      no(acUnrecognisedCriticalExtension, "element " & $i & " (" &
        describeName(c.subjectDn, c.subjectCn) & ") marks " & oid &
        " critical")

  # Key types, by position.
  if leaf.keyKind != akEcP384:
    no(acWrongKeyType, "the endorsement certificate carries an " &
      $leaf.keyKind & " key and a report is signed with P-384")
  if mid.keyKind != akRsa4096:
    no(acWrongKeyType, "the intermediate carries an " & $mid.keyKind &
      " key and it signs with RSA-4096")
  if root.keyKind != akRsa4096:
    no(acWrongKeyType, "the root carries an " & $root.keyKind &
      " key and it signs with RSA-4096")

  # What the leaf HAS to be, checked here rather than at the end.
  #
  # These are facts about the document's shape, like the name links
  # below, and the position is deliberate: a rule that sits after the
  # signature checks can only ever be reached by a chain the vendor
  # actually signed, which for an offline gate means it cannot be
  # reached at all. Ordering the structural rules before the
  # cryptographic ones costs nothing — a refusal is a refusal — and it
  # is the difference between a rule with a test and a rule with a
  # comment saying it could not be given one.
  var isEndorsement = false
  for n in EndorsementKeyCommonNames:
    if leaf.subjectCn == n: isEndorsement = true
  if not isEndorsement:
    no(acLeafIsNotAnEndorsementKey, "it is " & leaf.subjectCn.escape() &
      " and a report is signed by one of " &
      EndorsementKeyCommonNames.join(" or "))
  if not leaf.hasPlatformVersion:
    no(acLeafCarriesNoPlatformVersion, "the four components this build " &
      "compares are not all present on " & leaf.subjectCn)
  if leaf.hwId.len != HwIdLen:
    no(acLeafCarriesNoChipIdentity, "it carries " & $leaf.hwId.len &
      " bytes of chip identity and a part identifier is " & $HwIdLen)

  # Names link before signatures are looked at, so a chain that is not a
  # chain is refused as that rather than as a bad signature.
  if not sameBytes(leaf.issuerDn, mid.subjectDn):
    no(acNameMismatch, "the endorsement certificate names " &
      describeName(leaf.issuerDn, leaf.issuerCn) & " and the intermediate " &
      "is " & describeName(mid.subjectDn, mid.subjectCn))
  if not sameBytes(mid.issuerDn, root.subjectDn):
    no(acNameMismatch, "the intermediate names " &
      describeName(mid.issuerDn, mid.issuerCn) & " and the root is " &
      describeName(root.subjectDn, root.subjectCn))
  if not sameBytes(root.issuerDn, root.subjectDn):
    no(acNotSelfIssued, "it is issued by " &
      describeName(root.issuerDn, root.issuerCn))

  for (name, c) in {"intermediate": mid, "root": root}:
    if not c.hasBasicConstraints or not c.isCa:
      no(acNotACertificateAuthority, "the " & name & " (" &
        describeName(c.subjectDn, c.subjectCn) &
        ") does not carry basicConstraints cA TRUE")
    if c.hasKeyUsage and kuKeyCertSign notin c.keyUsage:
      no(acNotACertificateAuthority, "the " & name & " (" &
        describeName(c.subjectDn, c.subjectCn) &
        ") has a keyUsage that does not include keyCertSign")

  # THE root rule. Before any signature is checked, because a chain that
  # ends nowhere this build knows is not worth the arithmetic.
  let idx = amdRootFor(root.rsaModulus, root.rsaExponent)
  if idx < 0:
    no(acRootIsNotAmd, "it ends at " &
      describeName(root.subjectDn, root.subjectCn) & " carrying a " &
      $(root.rsaModulus.len * 8) & "-bit key that is none of the " &
      $(ord(high(AmdProductLine)) + 1) & " this build was built with")
  result.rootLine = AmdProductLine(idx)
  result.rootMatched = true
  if root.subjectCn != AmdRootKeys[result.rootLine].commonName:
    no(acRootNameDisagreesWithKey, "the key is " &
      AmdRootKeys[result.rootLine].commonName & "'s and the certificate " &
      "calls itself " & root.subjectCn.escape())

  if not leaf.signatureVerifiesUnder(mid):
    no(acBadSignature, "the endorsement certificate does not verify under " &
      describeName(mid.subjectDn, mid.subjectCn))
  if not mid.signatureVerifiesUnder(root):
    no(acBadSignature, "the intermediate does not verify under " &
      describeName(root.subjectDn, root.subjectCn))
  if not root.signatureVerifiesUnder(root):
    no(acBadSignature, "the root does not verify under its own key, so " &
      "it is not the self-signed certificate it is shaped like")

  for (name, c) in {"endorsement certificate": leaf, "intermediate": mid,
                    "root": root}:
    if nowSeconds < c.notBefore:
      no(acExpired, "the " & name & " is not valid until " & $c.notBefore &
        " and this verification is being made at " & $nowSeconds)
    if nowSeconds >= c.notAfter:
      no(acExpired, "the " & name & " stopped being valid at " &
        $c.notAfter & " and this verification is being made at " &
        $nowSeconds)

  # Revocation, for the intermediate. A list is current, issued by the
  # root and signed by it, or it is not a list this verifier will use.
  var covering = -1
  var crls: seq[AmdCrl] = @[]
  var unreadable: seq[string] = @[]
  for der in crlDer:
    try:
      crls.add parseAmdCrl(der)
    except X509Error as err:
      # Counted and NAMED rather than swallowed. A list this build
      # cannot read is still "no revocation data" — the outcome is the
      # same and it is the fail-closed one — but an operator who handed
      # the verifier a list and got told none was supplied deserves to
      # be told which of the two happened.
      unreadable.add err.msg
  # Five separate conditions decide whether a list answers the question,
  # and each one NAMES itself when it sets a list aside.
  #
  # They used to be five bare `continue`s ending in one sentence, and
  # that is the shape this tree keeps being defeated by: one refusal
  # answering five rules means a case asserting the refusal is asserting
  # none of them in particular. Measured rather than supposed — with the
  # bare `continue`s, deleting the issuer check, the next-update check or
  # the has-a-next-update check left every gate green, because the list
  # each of those cases supplied was set aside by the SIGNATURE check
  # immediately below them instead.
  var setAside: seq[string] = @[]
  for j, crl in crls:
    if not sameBytes(crl.issuerDn, root.subjectDn):
      setAside.add "one is issued by " &
        describeName(crl.issuerDn, crl.issuerCn) & " and not by this root"
      continue
    if not crl.hasNextUpdate:
      setAside.add "one states no next update at all, so nothing in it " &
        "says it is still current"
      continue
    if nowSeconds < crl.thisUpdate:
      setAside.add "one is not in force until " & $crl.thisUpdate
      continue
    if nowSeconds >= crl.nextUpdate:
      setAside.add "one stopped being current at " & $crl.nextUpdate
      continue
    if not crl.signatureVerifiesUnder(root):
      setAside.add "one carries a signature this root did not make"
      continue
    covering = j
    break
  if covering < 0:
    no(acNoRevocationData, "this verifier was handed " & $crlDer.len &
      " revocation list(s), of which " & $unreadable.len &
      " did not read at all, and none of the rest is a current one " &
      "issued by " & describeName(root.subjectDn, root.subjectCn) &
      " and signed by it" &
      (if unreadable.len > 0: " (first reading failure: " & unreadable[0] & ")"
       else: "") &
      (if setAside.len > 0: "; of the ones that did read, " &
        setAside.join(", and ") else: ""))
  result.revocationConsulted = true
  for serial in crls[covering].revokedSerials:
    if serial == mid.serialHex:
      no(acRevoked, "the intermediate's serial is " & mid.serialHex)

  result.endorsedTcb = (bootloader: leaf.blSpl, tee: leaf.teeSpl,
                        snp: leaf.snpSpl, microcode: leaf.ucodeSpl)
  result.hwId = leaf.hwId
  result.reason = acAccepted
  result.detail = AmdChainMessage[acAccepted] & ": " & leaf.subjectCn &
    " for " & leaf.productName & " under " & mid.subjectCn & " under " &
    root.subjectCn & ", whose key is this build's " &
    $result.rootLine & " root"

static:
  # The structural claim, made mechanically rather than in prose.
  #
  # If anyone adds a parameter to `evaluateAmdChain` — a trust anchor, a
  # set of allowed roots, a "permissive" bool, an options object — this
  # assertion stops the build and names the procedure. Prose in a header
  # asking a future editor not to widen a verifier is prose; this is the
  # rule with teeth.
  #
  # It is not a `not compiles(...)`, which passes just as happily on a
  # misspelling as on the property it meant to assert. It is an equality
  # between two type expressions, both of which must name real things
  # for the module to compile at all.
  doAssert typeof(evaluateAmdChain) is AmdChainSignature
