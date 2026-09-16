## A software-root test hierarchy, in production algorithms and
## encodings, minted fresh on every run.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``attestation_verifier_harness.nim`` follows.
##
## ## What this mints
##
## A complete attestation hierarchy: a self-signed root, an intermediate
## that the root certifies, an endorsement certificate, a platform
## certificate and an attestation-key certificate, plus the two
## revocation lists their issuers publish. Every certificate is X.509 v3
## DER, ECDSA-P256 signed over SHA-256, with the TCG extended-key-usage
## OIDs real endorsement and attestation certificates carry. Nothing here
## is a stand-in shape: the bytes go straight into the production reader
## and the production chain evaluator, and a defect in either is a defect
## this module would surface.
##
## ## No key is ever committed
##
## Every private scalar is drawn from the operating system's random
## source at the moment a hierarchy is minted, lives in memory for the
## lifetime of one test process, and is written nowhere. There is no
## fixture file, no PEM in the tree, and no key material in this
## repository — so there is nothing here for a future reader to mistake
## for a credential, and nothing to rotate.
##
## ## The marker, and why it is critical
##
## A hierarchy minted with ``marked = true`` carries a **critical**
## extension on every one of its certificates, under an OID from the
## ``2.999`` arc ITU-T set aside for examples and testing. RFC 5280 §4.2
## requires a certificate-using system to refuse a certificate carrying a
## critical extension it does not recognise, so a production build — which
## recognises three critical extensions, none of them this one — refuses
## every certificate of such a hierarchy, at every position, whatever its
## trust store says. The marker sits inside the TBS, so it cannot be
## stripped off to launder the chain: the signature over it goes with it.
##
## ## The defect catalogue
##
## ``mintFixture`` returns a chain built from one base specification with
## exactly one thing changed. That is what makes a negative fixture worth
## anything: the base is accepted, the variant is refused, and the single
## difference between them is therefore the rule that refused.
##
## ## Mocking
##
## None. Real keys, real signatures, real DER.

import std/[options, strutils, times]

import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi

import nimcrypto/sysrand

import repro_attest
import repro_attest_verify

# ---------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------

const
  PrivLen = 32
  P256Order = [
    byte 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
    0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51]

type
  TestKey* = object
    priv*: array[PrivLen, byte]
    pub*: array[P256PointLen, byte]

proc scalarIsUsable(v: array[PrivLen, byte]): bool =
  var nonZero = false
  for b in v:
    if b != 0: nonZero = true
  if not nonZero: return false
  for i in 0 ..< PrivLen:
    if v[i] < P256Order[i]: return true
    if v[i] > P256Order[i]: return false
  false

proc newTestKey*(): TestKey =
  ## A fresh ECDSA-P256 keypair from the operating system's random
  ## source. Rejection-sampled into ``[1, n-1]`` rather than reduced,
  ## because a reduction biases the low scalars.
  while true:
    let read = randomBytes(addr result.priv[0], PrivLen)
    if read != PrivLen:
      raise newException(ValueError,
        "the OS random source returned " & $read & " bytes for a P-256 " &
        "scalar; a test hierarchy is not minted from short entropy")
    if scalarIsUsable(result.priv): break
  var sk: bsslEcAbi.EcPrivateKey
  sk.curve = cint(bsslEcAbi.EC_secp256r1)
  sk.x = addr result.priv[0]
  sk.xlen = uint(PrivLen)
  var pkBuf: array[bsslEcAbi.EC_KBUF_PUB_MAX_SIZE, byte]
  var pk: bsslEcAbi.EcPublicKey
  let n = bsslEcAbi.ecComputePub(bsslEcAbi.ecGetDefault(), addr pk,
                                 addr pkBuf[0], addr sk)
  if n == 0 or pk.qlen != uint(P256PointLen):
    raise newException(ValueError, "ecComputePub produced " & $n & " bytes")
  for i in 0 ..< P256PointLen: result.pub[i] = pkBuf[i]

proc sha256Of(msg: openArray[byte]): array[32, byte] =
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha224Update(ctx, unsafeAddr msg[0], uint(msg.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

proc signRawEcdsa*(key: TestKey; message: openArray[byte]):
                  tuple[r, s: string] =
  ## ECDSA-P256 over SHA-256 of ``message``, as the two 32-byte scalars a
  ## ``TPMT_SIGNATURE`` carries rather than as the DER ``SEQUENCE`` X.509
  ## carries.
  ##
  ## Exported from here because this is the module that holds keys. A
  ## signer living beside a caller would be a second place a private
  ## scalar is handled, and the one property this file has to keep is
  ## that there is only one.
  var digest = sha256Of(message)
  var scalar = key.priv
  var sk: bsslEcAbi.EcPrivateKey
  sk.curve = cint(bsslEcAbi.EC_secp256r1)
  sk.x = addr scalar[0]
  sk.xlen = uint(PrivLen)
  var raw: array[64, byte]
  let n = bsslEcAbi.ecdsaSignRawGetDefault()(
    bsslEcAbi.ecGetDefault(), addr bsslHashAbi.sha256Vtable,
    addr digest[0], addr sk, addr raw[0])
  if n != 64'u:
    raise newException(ValueError, "ecdsaSignRaw produced " & $n & " bytes")
  result.r = newString(32)
  result.s = newString(32)
  for i in 0 ..< 32:
    result.r[i] = char(raw[i])
    result.s[i] = char(raw[32 + i])

proc signDer(key: TestKey; message: openArray[byte]): seq[byte] =
  ## An ``ECDSA-Sig-Value`` over SHA-256 of ``message``.
  var digest = sha256Of(message)
  var scalar = key.priv
  var sk: bsslEcAbi.EcPrivateKey
  sk.curve = cint(bsslEcAbi.EC_secp256r1)
  sk.x = addr scalar[0]
  sk.xlen = uint(PrivLen)
  var raw: array[64, byte]
  let n = bsslEcAbi.ecdsaSignRawGetDefault()(
    bsslEcAbi.ecGetDefault(), addr bsslHashAbi.sha256Vtable,
    addr digest[0], addr sk, addr raw[0])
  if n != 64'u:
    raise newException(ValueError, "ecdsaSignRaw produced " & $n & " bytes")
  var buf: array[80, byte]
  for i in 0 ..< 64: buf[i] = raw[i]
  let asnLen = bsslEcAbi.ecdsaRawToAsn1(addr buf[0], csize_t(64))
  if asnLen == 0:
    raise newException(ValueError, "ecdsaRawToAsn1 refused a raw signature")
  result = newSeq[byte](int(asnLen))
  for i in 0 ..< int(asnLen): result[i] = buf[i]

# ---------------------------------------------------------------------
# DER writing
# ---------------------------------------------------------------------

proc encodeLen(n: int): seq[byte] =
  if n < 0x80: @[byte(n)]
  elif n <= 0xff: @[0x81'u8, byte(n)]
  elif n <= 0xffff: @[0x82'u8, byte((n shr 8) and 0xff), byte(n and 0xff)]
  else: @[0x83'u8, byte((n shr 16) and 0xff), byte((n shr 8) and 0xff),
          byte(n and 0xff)]

proc tlv(tag: byte; payload: openArray[byte]): seq[byte] =
  result.add tag
  result.add encodeLen(payload.len)
  for b in payload: result.add b

proc cat(parts: varargs[seq[byte]]): seq[byte] =
  for p in parts:
    for b in p: result.add b

proc derSeq(parts: varargs[seq[byte]]): seq[byte] = tlv(0x30'u8, cat(parts))
proc derSet(parts: varargs[seq[byte]]): seq[byte] = tlv(0x31'u8, cat(parts))

proc derInteger(value: openArray[byte]): seq[byte] =
  var i = 0
  while i < value.len - 1 and value[i] == 0: inc i
  var payload: seq[byte] = @[]
  if value.len > 0 and (value[i] and 0x80'u8) != 0: payload.add 0x00'u8
  for j in i ..< value.len: payload.add value[j]
  if payload.len == 0: payload.add 0x00'u8
  tlv(0x02'u8, payload)

proc derSmallInt(n: int): seq[byte] =
  if n == 0: tlv(0x02'u8, @[0x00'u8])
  elif n < 0x80: tlv(0x02'u8, @[byte(n)])
  else: tlv(0x02'u8, @[0x00'u8, byte(n)])

proc derOid*(dotted: string): seq[byte] =
  ## DER for a dotted-decimal OID, with the first two arcs packed as
  ## X.690 requires: ``40 * a + b``, base-128 — which for ``a = 2`` can
  ## exceed one byte, and does for the ``2.999`` testing arc.
  var arcs: seq[uint64] = @[]
  for part in dotted.split('.'):
    arcs.add uint64(parseBiggestUInt(part))
  if arcs.len < 2:
    raise newException(ValueError, "an OID needs at least two arcs: " & dotted)
  var subs: seq[uint64] = @[arcs[0] * 40 + arcs[1]]
  for i in 2 ..< arcs.len: subs.add arcs[i]
  var payload: seq[byte] = @[]
  for s in subs:
    var groups: seq[byte] = @[byte(s and 0x7f'u64)]
    var v = s shr 7
    while v > 0:
      groups.add byte((v and 0x7f'u64) or 0x80'u64)
      v = v shr 7
    for j in countdown(groups.high, 0): payload.add groups[j]
  tlv(0x06'u8, payload)

proc derUtf8(s: string): seq[byte] =
  var p: seq[byte] = @[]
  for c in s: p.add byte(c)
  tlv(0x0c'u8, p)

proc derIa5(s: string): seq[byte] =
  var p: seq[byte] = @[]
  for c in s: p.add byte(c)
  tlv(0x16'u8, p)

proc derOctets(content: openArray[byte]): seq[byte] = tlv(0x04'u8, content)

proc derBitString(content: openArray[byte]; unused = 0): seq[byte] =
  var p: seq[byte] = @[byte(unused)]
  for b in content: p.add b
  tlv(0x03'u8, p)

proc derBool(b: bool): seq[byte] =
  tlv(0x01'u8, @[if b: 0xff'u8 else: 0x00'u8])

proc derUtcTime(unix: int64): seq[byte] =
  let t = utc(fromUnix(unix))
  let s = align($(t.year mod 100), 2, '0') & align($ord(t.month), 2, '0') &
          align($t.monthday, 2, '0') & align($t.hour, 2, '0') &
          align($t.minute, 2, '0') & align($t.second, 2, '0') & "Z"
  var p: seq[byte] = @[]
  for c in s: p.add byte(c)
  tlv(0x17'u8, p)

proc nameWithCn*(cn: string): seq[byte] =
  derSeq(derSet(derSeq(derOid(OidCommonName), derUtf8(cn))))

proc algEcdsaSha256(): seq[byte] = derSeq(derOid(OidEcdsaWithSha256))

proc spkiOf(key: TestKey): seq[byte] =
  var point: seq[byte] = @[]
  for b in key.pub: point.add b
  derSeq(derSeq(derOid(OidEcPublicKey), derOid(OidPrime256v1)),
         derBitString(point))

proc extension(oid: string; critical: bool; value: seq[byte]): seq[byte] =
  if critical: derSeq(derOid(oid), derBool(true), derOctets(value))
  else: derSeq(derOid(oid), derOctets(value))

proc keyUsageExt(bits: openArray[int]): seq[byte] =
  var highest = 0
  for b in bits:
    if b > highest: highest = b
  let byteCount = (highest div 8) + 1
  var mask = newSeq[byte](byteCount)
  for b in bits:
    mask[b div 8] = mask[b div 8] or byte(0x80 shr (b mod 8))
  let unused = (byteCount * 8) - (highest + 1)
  extension(OidKeyUsage, true, derBitString(mask, unused))

proc basicConstraintsExt(isCa: bool): seq[byte] =
  extension(OidBasicConstraints, true,
            (if isCa: derSeq(derBool(true)) else: derSeq()))

proc ekuExt(oids: openArray[string]): seq[byte] =
  var parts: seq[byte] = @[]
  for o in oids:
    for b in derOid(o): parts.add b
  extension(OidExtKeyUsage, false, tlv(0x30'u8, parts))

proc sanExt(dnsNames: openArray[string]): seq[byte] =
  var parts: seq[byte] = @[]
  for n in dnsNames:
    var raw: seq[byte] = @[]
    for c in n: raw.add byte(c)
    for b in tlv(0x82'u8, raw): parts.add b
  extension(OidSubjectAltName, false, tlv(0x30'u8, parts))

const
  SoftwareRootMarkerTestOid* = "2.999.1.1"
    ## Spelled here as a literal rather than reached for through the
    ## evaluator's own constant. A minting side that asked the verifying
    ## side what to write would agree with it however either was
    ## renamed, and agreement reached that way is not evidence.

  MarkerText* = "software root: this hierarchy is for testing and is " &
    "trusted by no production verifier"

proc markerExt(): seq[byte] =
  extension(SoftwareRootMarkerTestOid, true, derUtf8(MarkerText))

# ---------------------------------------------------------------------
# Minting
# ---------------------------------------------------------------------

type
  CertOptions* = object
    subjectCn*: string
    issuerName*: seq[byte]      ## Empty means self-issued.
    serial*: seq[byte]
    notBefore*, notAfter*: int64
    isCa*: bool
    keyUsageBits*: seq[int]
    eku*: seq[string]
    sanDnsNames*: seq[string]
    marked*: bool
    omitKeyCertSign*: bool
    duplicateFirstExtension*: bool
      ## Emit the first extension twice. RFC 5280 §4.2 forbids it and the
      ## reader refuses it; without a way to MINT one, that refusal has no
      ## reachable input and nothing proves it fires.

  MintedCert* = object
    key*: TestKey
    der*: string                ## Raw DER, as a report carries it.
    subjectName*: seq[byte]
    serial*: seq[byte]

proc randomSerial*(): seq[byte] =
  result = newSeq[byte](16)
  if randomBytes(addr result[0], 16) != 16:
    raise newException(ValueError, "the OS random source returned short")
  result[0] = result[0] and 0x7f'u8

proc mintCert*(subjectKey, issuerKey: TestKey;
               opts: CertOptions): MintedCert =
  ## One certificate, signed by ``issuerKey``. When ``issuerName`` is
  ## empty the certificate is self-issued and ``issuerKey`` is expected
  ## to be ``subjectKey``.
  let subject = nameWithCn(opts.subjectCn)
  let issuer = (if opts.issuerName.len == 0: subject else: opts.issuerName)
  var exts: seq[seq[byte]] = @[basicConstraintsExt(opts.isCa)]
  if opts.keyUsageBits.len > 0:
    exts.add keyUsageExt(opts.keyUsageBits)
  if opts.eku.len > 0:
    exts.add ekuExt(opts.eku)
  if opts.sanDnsNames.len > 0:
    exts.add sanExt(opts.sanDnsNames)
  if opts.marked:
    exts.add markerExt()
  if opts.duplicateFirstExtension:
    exts.add exts[0]
  var extBytes: seq[byte] = @[]
  for e in exts:
    for b in e: extBytes.add b
  let tbs = derSeq(
    tlv(0xa0'u8, derSmallInt(2)),
    derInteger(opts.serial),
    algEcdsaSha256(),
    issuer,
    derSeq(derUtcTime(opts.notBefore), derUtcTime(opts.notAfter)),
    subject,
    spkiOf(subjectKey),
    tlv(0xa3'u8, tlv(0x30'u8, extBytes)))
  let sig = signDer(issuerKey, tbs)
  let der = derSeq(tbs, algEcdsaSha256(), derBitString(sig))
  result.key = subjectKey
  result.subjectName = subject
  result.serial = opts.serial
  result.der = newString(der.len)
  for i in 0 ..< der.len: result.der[i] = char(der[i])

proc mintCrl*(issuerKey: TestKey; issuerName: seq[byte];
              thisUpdate, nextUpdate: int64;
              revokedSerials: openArray[seq[byte]]): string =
  ## One X.509 v2 revocation list, signed by the issuer whose Name it
  ## carries.
  var entries: seq[byte] = @[]
  for serial in revokedSerials:
    for b in derSeq(derInteger(serial), derUtcTime(thisUpdate)):
      entries.add b
  var parts: seq[seq[byte]] = @[
    derSmallInt(1), algEcdsaSha256(), issuerName,
    derUtcTime(thisUpdate), derUtcTime(nextUpdate)]
  if revokedSerials.len > 0:
    parts.add tlv(0x30'u8, entries)
  var body: seq[byte] = @[]
  for p in parts:
    for b in p: body.add b
  let tbs = tlv(0x30'u8, body)
  let sig = signDer(issuerKey, tbs)
  let der = derSeq(tbs, algEcdsaSha256(), derBitString(sig))
  result = newString(der.len)
  for i in 0 ..< der.len: result[i] = char(der[i])

# ---------------------------------------------------------------------
# The hierarchy
# ---------------------------------------------------------------------

const
  TestBackendName* = "tpm2"
  OtherBackendName* = "sev-snp"
  RootCn* = "software-root test hierarchy root"
  IntermediateCn* = "software-root test hierarchy issuing authority"
  AkCn* = "software-root test attestation key"
  EkCn* = "software-root test endorsement key"
  PlatformCn* = "software-root test platform"
  OtherAuthorityCn* = "software-root test hierarchy OTHER authority"
  Day = 86_400'i64

type
  TestHierarchy* = object
    marked*: bool
    root*, intermediate*, ak*, ek*, platform*: MintedCert
    rootCrl*, intermediateCrl*: string
    now*: int64

proc mintHierarchy*(now: int64; marked: bool;
                    backend = TestBackendName): TestHierarchy =
  ## Root, intermediate, endorsement, platform and attestation-key
  ## certificates plus both revocation lists — all fresh.
  result.marked = marked
  result.now = now
  let rootKey = newTestKey()
  result.root = mintCert(rootKey, rootKey, CertOptions(
    subjectCn: RootCn, serial: randomSerial(),
    notBefore: now - 30 * Day, notAfter: now + 3650 * Day,
    isCa: true, keyUsageBits: @[5, 6], marked: marked))
  let interKey = newTestKey()
  result.intermediate = mintCert(interKey, rootKey, CertOptions(
    subjectCn: IntermediateCn, issuerName: result.root.subjectName,
    serial: randomSerial(),
    notBefore: now - 20 * Day, notAfter: now + 1825 * Day,
    isCa: true, keyUsageBits: @[5, 6], marked: marked))
  result.ak = mintCert(newTestKey(), interKey, CertOptions(
    subjectCn: AkCn, issuerName: result.intermediate.subjectName,
    serial: randomSerial(),
    notBefore: now - Day, notAfter: now + 365 * Day,
    keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
    sanDnsNames: @[requiredSubjectAltNameFor(backend)], marked: marked))
  result.ek = mintCert(newTestKey(), interKey, CertOptions(
    subjectCn: EkCn, issuerName: result.intermediate.subjectName,
    serial: randomSerial(),
    notBefore: now - Day, notAfter: now + 365 * Day,
    keyUsageBits: @[0], eku: @[OidTcgEkCertificate],
    sanDnsNames: @[requiredSubjectAltNameFor(backend)], marked: marked))
  result.platform = mintCert(newTestKey(), interKey, CertOptions(
    subjectCn: PlatformCn, issuerName: result.intermediate.subjectName,
    serial: randomSerial(),
    notBefore: now - Day, notAfter: now + 365 * Day,
    keyUsageBits: @[0], eku: @[OidTcgPlatformCertificate],
    sanDnsNames: @[requiredSubjectAltNameFor(backend)], marked: marked))
  result.rootCrl = mintCrl(rootKey, result.root.subjectName,
    now - Day, now + 30 * Day, [])
  result.intermediateCrl = mintCrl(interKey, result.intermediate.subjectName,
    now - Day, now + 30 * Day, [])

proc akChain*(h: TestHierarchy): seq[string] =
  @[h.ak.der, h.intermediate.der, h.root.der]

proc ekChain*(h: TestHierarchy): seq[string] =
  @[h.ek.der, h.intermediate.der, h.root.der]

proc platformChain*(h: TestHierarchy): seq[string] =
  @[h.platform.der, h.intermediate.der, h.root.der]

proc toBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = byte(text[i])

proc parseCertText*(text: string): X509Cert = parseCertificate(toBytes(text))

proc parseCrlText*(text: string): X509Crl = parseCrl(toBytes(text))

proc anchorsOf*(h: TestHierarchy): seq[X509Cert] =
  @[parseCertText(h.root.der)]

proc crlsOf*(h: TestHierarchy): seq[X509Crl] =
  @[parseCrlText(h.rootCrl), parseCrlText(h.intermediateCrl)]

proc akExpectation*(now: int64; backend = TestBackendName): ChainExpectation =
  ChainExpectation(
    requiredEku: OidTcgAikCertificate,
    requiredSubjectAltName: requiredSubjectAltNameFor(backend),
    nowSeconds: now)

# ---------------------------------------------------------------------
# The defect catalogue
# ---------------------------------------------------------------------

type
  ChainDefect* = enum
    ## One base hierarchy, one thing changed. ``cdNone`` is the base and
    ## must be accepted; every other value must be refused, and refused
    ## by its own rule.
    cdNone
    cdMalformedEncoding
    cdSingleElement
    cdSoftwareRootMarker
    cdBrokenNameLink
    cdIssuerIsNotACa
    cdForgedSignature
    cdRootNotInTrustStore
    cdLeafOutOfWindow
    cdRevocationListMissing
    cdLeafRevoked
    cdEndorsementCertificateInsteadOfAttestationKey
    cdMintedForAnotherBackend

  ChainFixture* = object
    defect*: ChainDefect
    chain*: seq[string]
    anchors*: seq[X509Cert]
    crls*: seq[X509Crl]
    expect*: ChainExpectation

proc mintFixture*(defect: ChainDefect; now: int64): ChainFixture =
  ## The base hierarchy with exactly one thing changed.
  ##
  ## The base is minted *unmarked*, so every defect below is reached by
  ## an evaluator that had no other reason to refuse. ``cdSoftwareRootMarker``
  ## is the one variant that marks it.
  result.defect = defect
  let h = mintHierarchy(now, marked = false)
  result.chain = h.akChain
  result.anchors = h.anchorsOf
  result.crls = h.crlsOf
  result.expect = akExpectation(now)
  case defect
  of cdNone:
    discard
  of cdSoftwareRootMarker:
    # The LEAF alone is marked, and the trust anchor is the unmarked
    # root the rest of this catalogue uses. Two rules in the evaluator
    # produce ``crUnrecognisedCriticalExtension`` — one about a chain
    # element, one about the trust store — and a fixture that tripped
    # both could not tell which had been deleted. This one can reach
    # only the first.
    result.chain[0] = mintCert(h.ak.key, h.intermediate.key, CertOptions(
      subjectCn: AkCn, issuerName: h.intermediate.subjectName,
      serial: h.ak.serial,
      notBefore: now - Day, notAfter: now + 365 * Day,
      keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)],
      marked: true)).der
  of cdMalformedEncoding:
    # Truncate the intermediate. The bytes still look like the start of
    # a certificate and stop being one part way through.
    result.chain[1] = result.chain[1][0 ..< result.chain[1].len div 2]
  of cdSingleElement:
    result.chain = @[h.ak.der]
  of cdBrokenNameLink:
    # An attestation key whose issuer Name is somebody else's, signed by
    # the intermediate's real key. The signature would verify; the names
    # do not meet, and that is what must decide.
    result.chain[0] = mintCert(h.ak.key, h.intermediate.key, CertOptions(
      subjectCn: AkCn, issuerName: nameWithCn(OtherAuthorityCn),
      serial: randomSerial(),
      notBefore: now - Day, notAfter: now + 365 * Day,
      keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)])).der
  of cdIssuerIsNotACa:
    # Re-mint the intermediate without basicConstraints cA, and re-mint
    # the leaf under it so the chain still links and still verifies.
    let interKey = newTestKey()
    let inter = mintCert(interKey, h.root.key, CertOptions(
      subjectCn: IntermediateCn, issuerName: h.root.subjectName,
      serial: randomSerial(),
      notBefore: now - 20 * Day, notAfter: now + 1825 * Day,
      isCa: false, keyUsageBits: @[5, 6]))
    let leaf = mintCert(newTestKey(), interKey, CertOptions(
      subjectCn: AkCn, issuerName: inter.subjectName,
      serial: randomSerial(),
      notBefore: now - Day, notAfter: now + 365 * Day,
      keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)]))
    result.chain = @[leaf.der, inter.der, h.root.der]
    result.crls = @[h.crlsOf[0],
      parseCrlText(mintCrl(interKey, inter.subjectName,
        now - Day, now + 30 * Day, []))]
  of cdForgedSignature:
    # An attestation key that names the real intermediate as its issuer
    # and is signed by a key the intermediate does not have.
    result.chain[0] = mintCert(newTestKey(), newTestKey(), CertOptions(
      subjectCn: AkCn, issuerName: h.intermediate.subjectName,
      serial: randomSerial(),
      notBefore: now - Day, notAfter: now + 365 * Day,
      keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)])).der
  of cdRootNotInTrustStore:
    # A perfectly good chain, and a trust store holding a different
    # root. Nothing about the chain is wrong; nothing trusts it.
    result.anchors = mintHierarchy(now, marked = false).anchorsOf
  of cdLeafOutOfWindow:
    result.chain[0] = mintCert(h.ak.key, h.intermediate.key, CertOptions(
      subjectCn: AkCn, issuerName: h.intermediate.subjectName,
      serial: randomSerial(),
      notBefore: now - 400 * Day, notAfter: now - 10 * Day,
      keyUsageBits: @[0], eku: @[OidTcgAikCertificate],
      sanDnsNames: @[requiredSubjectAltNameFor(TestBackendName)])).der
  of cdRevocationListMissing:
    # The intermediate's list is withheld and nothing else changes.
    result.crls = @[h.crlsOf[0]]
  of cdLeafRevoked:
    result.crls = @[h.crlsOf[0],
      parseCrlText(mintCrl(h.intermediate.key, h.intermediate.subjectName,
        now - Day, now + 30 * Day, [h.ak.serial]))]
  of cdEndorsementCertificateInsteadOfAttestationKey:
    result.chain = h.ekChain
  of cdMintedForAnotherBackend:
    let other = mintHierarchy(now, marked = false, backend = OtherBackendName)
    result.chain = other.akChain
    result.anchors = other.anchorsOf
    result.crls = other.crlsOf

proc expectedRejection*(defect: ChainDefect): ChainRejection =
  ## The rule that must decide each fixture. Written as a total
  ## function over the enum, so a defect added without a rule to catch
  ## it does not compile.
  case defect
  of cdNone: crAccepted
  of cdMalformedEncoding: crMalformed
  of cdSingleElement: crTooShort
  of cdSoftwareRootMarker: crUnrecognisedCriticalExtension
  of cdBrokenNameLink: crNameMismatch
  of cdIssuerIsNotACa: crNotACertificateAuthority
  of cdForgedSignature: crBadSignature
  of cdRootNotInTrustStore: crUnknownRoot
  of cdLeafOutOfWindow: crExpired
  of cdRevocationListMissing: crNoRevocationData
  of cdLeafRevoked: crRevoked
  of cdEndorsementCertificateInsteadOfAttestationKey: crWrongEku
  of cdMintedForAnotherBackend: crBackendMismatch

# ---------------------------------------------------------------------
# Production serialization
#
# A chain only matters once it has travelled. These build a real
# ``reproos.attestation-report.v1`` around one, through the library's
# own constructor and renderer — so the bytes a gate verifies are the
# bytes an agent would have produced, base64 and all, rather than a
# record handed straight to the verifier.
# ---------------------------------------------------------------------

const
  PkiTimestamp* = "2026-09-15T09:00:00Z"

proc reportTextWithChain*(chain: seq[string]; challengeHex: string;
                          claims: UnverifiedClaims;
                          evidence = "opaque-measured-boot-evidence"): string =
  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  renderAttestationReport(attestationReport(abTpm2, PkiTimestamp,
    challengeHex, bindings, evidence, claims, some(chain)))

proc mintCrlWithoutNextUpdate*(issuerKey: TestKey; issuerName: seq[byte];
                               thisUpdate: int64): string =
  ## A revocation list omitting the OPTIONAL ``nextUpdate``. RFC 5280
  ## allows it; this build refuses to treat such a list as current,
  ## because a list that never expires is a list nobody has to reissue.
  var parts: seq[seq[byte]] = @[
    derSmallInt(1), algEcdsaSha256(), issuerName, derUtcTime(thisUpdate)]
  var body: seq[byte] = @[]
  for p in parts:
    for b in p: body.add b
  let tbs = tlv(0x30'u8, body)
  let sig = signDer(issuerKey, tbs)
  let der = derSeq(tbs, algEcdsaSha256(), derBitString(sig))
  result = newString(der.len)
  for i in 0 ..< der.len: result[i] = char(der[i])

proc recombine*(tbs, signature: openArray[byte]): string =
  ## A certificate assembled from one body and another certificate's
  ## signature.
  ##
  ## This is the whole of what somebody holding a signed certificate can
  ## do to it without the issuer's key: rearrange the parts. It is how
  ## the laundering attempt in the negative-fixture gate is built, and
  ## the point is that the result does not verify.
  let der = derSeq(@tbs, algEcdsaSha256(), derBitString(signature))
  result = newString(der.len)
  for i in 0 ..< der.len: result[i] = char(der[i])
