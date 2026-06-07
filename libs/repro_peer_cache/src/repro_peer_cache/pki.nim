## Peer-cache PKI — Peer-Cache-BearSSL M2.
##
## Self-signed X.509 v3 certificate generation, parsing, and a
## trust-anchor *directory* loader, layered on top of the M1
## ECDSA-P256 keypair primitives (`auth.nim`).
##
## See `reprobuild-specs/Peer-Cache-BearSSL.md` §"Identity model" and
## §"TLS layer" and `reprobuild-specs/Peer-Cache-BearSSL.milestones.org`
## §M2.
##
## ## Shape
##
## A minimal X.509 v3 cert is hand-encoded to DER following RFC 5280
## §4.1. The cert carries:
##
##   * Version 3.
##   * Serial number: 16 random bytes (always positive after the
##     leading-zero trim).
##   * Signature algorithm: `ecdsa-with-SHA256`
##     (OID 1.2.840.10045.4.3.2).
##   * Issuer == Subject (self-signed): `CN=<peerId hex>`.
##   * Validity: `notBefore = now` / `notAfter = now + validityDays * 86400`,
##     both written as `UTCTime` (BearSSL's minimal verifier accepts
##     both UTCTime and GeneralizedTime; we use UTCTime for compactness).
##   * SubjectPublicKeyInfo: `id-ecPublicKey` (1.2.840.10045.2.1) with
##     curve `prime256v1` (1.2.840.10045.3.1.7) and the 65-byte
##     uncompressed public point.
##   * Extensions: BasicConstraints (CA: false), KeyUsage
##     (digitalSignature; `keyEncipherment` is dropped because the
##     ECDSA-P256 cert never key-wraps), SubjectAltName (DNS:peerId).
##
## ## Signature wrap
##
## BearSSL's M1 `signMessage` produces raw `r || s` (64 bytes). X.509
## requires DER-encoded `SEQUENCE { r INTEGER, s INTEGER }`. We delegate
## to BearSSL's `ecdsaRawToAsn1` (already exposed in
## `bearssl/abi/bearssl_ec.nim`); it handles the leading-zero / negative
## INTEGER padding correctly.
##
## ## Buffer lifetime
##
## Same invariant as M1: BearSSL ABI structs that carry `ptr byte` only
## point into locals owned by the proc currently calling them. The cert
## bytes themselves are plain `seq[byte]` Nim-managed.

import std/[base64, os, strutils, tables, times]

import bearssl/[ec, hash as bsslHash]
import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi
import bearssl/abi/bearssl_x509 as bsslX509Abi
import bearssl/abi/consttypes as bsslConst

import nimcrypto/sysrand

import blake3

import ./types
import ./auth

# ---------------------------------------------------------------------------
# Public types.
# ---------------------------------------------------------------------------

type
  CertAndKey* = object
    ## A peer's keypair + self-signed cert, both in parsed and on-disk
    ## (PEM / DER) form.
    keypair*: PeerKeypair
    certPem*: string
    certDer*: seq[byte]
    subjectCn*: string
    notBefore*: int64       ## Unix seconds.
    notAfter*: int64        ## Unix seconds.

  TrustAnchorEntry* = object
    peerId*: PeerId
    publicKey*: PublicKeyBytes
    certDer*: seq[byte]
    certPem*: string
    notBefore*: int64
    notAfter*: int64
    subjectCn*: string
    subjectDn*: seq[byte]
      ## Peer-Cache-BearSSL M3: raw DER-encoded Subject Name SEQUENCE
      ## bytes (tag + length + content) lifted from the parsed cert.
      ## Required because `br_x509_minimal` matches a leaf cert's
      ## issuer DN against the trust anchor's DN byte-for-byte during
      ## chain validation, and the M2 `parseCertDer` path didn't
      ## surface it. See `findSubjectDn` / `loadTrustAnchorDir`.

  TrustAnchorSet* = object
    byPeerId*: Table[PeerId, TrustAnchorEntry]

  CertExpiredError* = object of CatchableError
  CertParseError* = object of CatchableError

# ---------------------------------------------------------------------------
# BLAKE3-based peer-ID derivation. Exported here because M1 deliberately
# left it unexported; M2 needs it for the cert subject CN.
# ---------------------------------------------------------------------------

proc derivePeerIdFromPublicKey*(publicKey: PublicKeyBytes): PeerId =
  ## `peerId = BLAKE3-256(uncompressed pubkey bytes)`. Spec §"Identity
  ## model" / §"Keypair shape".
  let digest = blake3.digest(publicKey)
  peerIdFromBytes(digest)

# ---------------------------------------------------------------------------
# ASN.1 DER encoding helpers.
#
# We encode a minimal X.509 v3 cert by composing length-prefixed TLV
# objects. Every helper returns a fresh `seq[byte]`; the final cert is
# assembled bottom-up so length prefixes can be computed exactly.
# ---------------------------------------------------------------------------

const
  AsnSequence = 0x30'u8
  AsnSet      = 0x31'u8
  AsnInteger  = 0x02'u8
  AsnBitString = 0x03'u8
  AsnOctetString = 0x04'u8
  AsnNull = 0x05'u8
  AsnOid = 0x06'u8
  AsnUtf8String = 0x0c'u8
  AsnPrintableString = 0x13'u8
  AsnUtcTime = 0x17'u8
  AsnBoolean = 0x01'u8
  # Context-specific [0] / [3] (constructed + tagged).
  AsnContext0Constructed = 0xa0'u8
  AsnContext3Constructed = 0xa3'u8

proc encodeLen(n: int): seq[byte] =
  ## DER length encoding (definite form).
  if n < 0x80:
    result = @[byte(n)]
  elif n <= 0xff:
    result = @[0x81'u8, byte(n)]
  elif n <= 0xffff:
    result = @[0x82'u8, byte((n shr 8) and 0xff), byte(n and 0xff)]
  elif n <= 0xffffff:
    result = @[0x83'u8,
               byte((n shr 16) and 0xff),
               byte((n shr 8) and 0xff),
               byte(n and 0xff)]
  else:
    result = @[0x84'u8,
               byte((n shr 24) and 0xff),
               byte((n shr 16) and 0xff),
               byte((n shr 8) and 0xff),
               byte(n and 0xff)]

proc tlv(tag: byte; payload: openArray[byte]): seq[byte] =
  result.add(tag)
  result.add(encodeLen(payload.len))
  for b in payload:
    result.add(b)

proc derInteger(value: openArray[byte]): seq[byte] =
  ## Encodes an arbitrary-precision unsigned integer in DER INTEGER form.
  ## Strips redundant leading zeros and re-inserts one if the next byte
  ## has the high bit set (so the integer stays positive).
  var i = 0
  while i < value.len - 1 and value[i] == 0:
    inc i
  var payload: seq[byte] = @[]
  if (value[i] and 0x80'u8) != 0:
    payload.add(0x00'u8)
  for j in i ..< value.len:
    payload.add(value[j])
  if payload.len == 0:
    payload.add(0x00'u8)
  result = tlv(AsnInteger, payload)

proc derSmallInteger(n: int): seq[byte] =
  ## Encodes a small non-negative integer (0..255) as DER INTEGER.
  if n == 0:
    result = tlv(AsnInteger, @[0x00'u8])
  elif n < 0x80:
    result = tlv(AsnInteger, @[byte(n)])
  else:
    result = tlv(AsnInteger, @[0x00'u8, byte(n)])

proc derOid(oid: openArray[int]): seq[byte] =
  ## Encodes an OID from arc components. The first two arcs are packed
  ## into a single byte: `40 * arc[0] + arc[1]` (RFC 5280 / X.690).
  doAssert oid.len >= 2, "OID needs at least two arcs"
  var payload: seq[byte] = @[]
  payload.add(byte(40 * oid[0] + oid[1]))
  for i in 2 ..< oid.len:
    var arc = oid[i]
    var bytesRev: seq[byte] = @[]
    bytesRev.add(byte(arc and 0x7f))
    arc = arc shr 7
    while arc > 0:
      bytesRev.add(byte((arc and 0x7f) or 0x80))
      arc = arc shr 7
    # Reverse into big-endian base-128.
    for j in countdown(bytesRev.high, 0):
      payload.add(bytesRev[j])
  result = tlv(AsnOid, payload)

proc derNull(): seq[byte] =
  result = @[AsnNull, 0x00'u8]

proc derSequence(parts: openArray[seq[byte]]): seq[byte] =
  var payload: seq[byte] = @[]
  for p in parts:
    for b in p:
      payload.add(b)
  result = tlv(AsnSequence, payload)

proc derSet(parts: openArray[seq[byte]]): seq[byte] =
  var payload: seq[byte] = @[]
  for p in parts:
    for b in p:
      payload.add(b)
  result = tlv(AsnSet, payload)

proc derBitString(content: openArray[byte]; unusedBits: int = 0): seq[byte] =
  var payload: seq[byte] = @[]
  payload.add(byte(unusedBits))
  for b in content:
    payload.add(b)
  result = tlv(AsnBitString, payload)

proc derOctetString(content: openArray[byte]): seq[byte] =
  result = tlv(AsnOctetString, content)

proc derUtf8(s: string): seq[byte] =
  var payload: seq[byte] = @[]
  for c in s:
    payload.add(byte(c))
  result = tlv(AsnUtf8String, payload)

proc derPrintable(s: string): seq[byte] =
  var payload: seq[byte] = @[]
  for c in s:
    payload.add(byte(c))
  result = tlv(AsnPrintableString, payload)

proc derUtcTime(unix: int64): seq[byte] =
  ## YYMMDDHHMMSSZ. RFC 5280: UTCTime is valid for years 1950-2049.
  let t = utc(fromUnix(unix))
  let year2 = t.year mod 100
  let s = align($year2, 2, '0') &
          align($ord(t.month), 2, '0') &
          align($t.monthday, 2, '0') &
          align($t.hour, 2, '0') &
          align($t.minute, 2, '0') &
          align($t.second, 2, '0') & "Z"
  var payload: seq[byte] = @[]
  for c in s:
    payload.add(byte(c))
  result = tlv(AsnUtcTime, payload)

proc derBoolean(b: bool): seq[byte] =
  result = tlv(AsnBoolean, @[if b: 0xff'u8 else: 0x00'u8])

proc derContext(tag: byte; payload: openArray[byte]): seq[byte] =
  result = tlv(tag, payload)

# ---------------------------------------------------------------------------
# X.509 building blocks.
# ---------------------------------------------------------------------------

# OIDs we use:
# - id-at-commonName = 2.5.4.3
# - id-ecPublicKey   = 1.2.840.10045.2.1
# - prime256v1       = 1.2.840.10045.3.1.7
# - ecdsa-with-SHA256= 1.2.840.10045.4.3.2
# - id-ce-basicConstraints = 2.5.29.19
# - id-ce-keyUsage         = 2.5.29.15
# - id-ce-subjectAltName   = 2.5.29.17

const
  OidCn               = @[2, 5, 4, 3]
  OidIdEcPublicKey    = @[1, 2, 840, 10045, 2, 1]
  OidPrime256v1       = @[1, 2, 840, 10045, 3, 1, 7]
  OidEcdsaWithSha256  = @[1, 2, 840, 10045, 4, 3, 2]
  OidBasicConstraints = @[2, 5, 29, 19]
  OidKeyUsage         = @[2, 5, 29, 15]
  OidSubjectAltName   = @[2, 5, 29, 17]

proc encodeSubjectName(cn: string): seq[byte] =
  ## Name ::= SEQUENCE OF RDN, where RDN ::= SET OF AttributeTypeAndValue.
  ## We emit a single RDN containing a single CN.
  let atv = derSequence([derOid(OidCn), derUtf8(cn)])
  let rdn = derSet([atv])
  result = derSequence([rdn])

proc encodeAlgorithmEcdsaSha256(): seq[byte] =
  ## AlgorithmIdentifier { ecdsa-with-SHA256, parameters ABSENT }.
  result = derSequence([derOid(OidEcdsaWithSha256)])

proc encodeAlgorithmEcPublicKey(): seq[byte] =
  ## AlgorithmIdentifier { id-ecPublicKey, parameters = prime256v1 OID }.
  result = derSequence([derOid(OidIdEcPublicKey), derOid(OidPrime256v1)])

proc encodeSpki(publicKey: PublicKeyBytes): seq[byte] =
  ## SubjectPublicKeyInfo ::= SEQUENCE { algorithm, subjectPublicKey BIT STRING }
  ## The BIT STRING content is the raw uncompressed point (`0x04 || X || Y`).
  let alg = encodeAlgorithmEcPublicKey()
  var pubBytes: seq[byte] = @[]
  for b in publicKey:
    pubBytes.add(b)
  let bits = derBitString(pubBytes)
  result = derSequence([alg, bits])

proc encodeValidity(notBefore, notAfter: int64): seq[byte] =
  result = derSequence([derUtcTime(notBefore), derUtcTime(notAfter)])

proc encodeBasicConstraints(): seq[byte] =
  ## Extension: BasicConstraints { cA: false }. Marked critical.
  let inner = derSequence([])  # SEQUENCE { } — cA defaults to FALSE.
  let extnValue = derOctetString(inner)
  result = derSequence([
    derOid(OidBasicConstraints),
    derBoolean(true),    # critical
    extnValue])

proc encodeKeyUsage(): seq[byte] =
  ## Extension: KeyUsage = digitalSignature(0) + keyEncipherment(2).
  ## BIT STRING content: 1 byte 0b10100000 = 0xA0; high bit = digitalSignature.
  let usage = derBitString(@[0xa0'u8], unusedBits = 5)
  let extnValue = derOctetString(usage)
  result = derSequence([
    derOid(OidKeyUsage),
    derBoolean(true),    # critical
    extnValue])

proc encodeSubjectAltName(dnsName: string): seq[byte] =
  ## Extension: SubjectAltName ::= SEQUENCE OF GeneralName, with one
  ## DNS-name entry. DNSName is `[2] IMPLICIT IA5String`.
  var nameBytes: seq[byte] = @[]
  for c in dnsName:
    nameBytes.add(byte(c))
  # [2] IMPLICIT: context-specific tag 0x82 (primitive).
  let dnsEntry = tlv(0x82'u8, nameBytes)
  let san = derSequence([dnsEntry])
  let extnValue = derOctetString(san)
  result = derSequence([
    derOid(OidSubjectAltName),
    extnValue])

# ---------------------------------------------------------------------------
# TBSCertificate + signing.
# ---------------------------------------------------------------------------

proc buildTbs(serial: openArray[byte];
              subjectCn: string;
              notBefore, notAfter: int64;
              publicKey: PublicKeyBytes): seq[byte] =
  ## Assemble the TBSCertificate. Self-signed: issuer == subject.
  let version = derContext(AsnContext0Constructed, derSmallInteger(2))  # v3
  let serialInt = derInteger(serial)
  let sigAlg = encodeAlgorithmEcdsaSha256()
  let name = encodeSubjectName(subjectCn)
  let validity = encodeValidity(notBefore, notAfter)
  let spki = encodeSpki(publicKey)

  let extList = derSequence([
    encodeBasicConstraints(),
    encodeKeyUsage(),
    encodeSubjectAltName(subjectCn)])
  let exts = derContext(AsnContext3Constructed, extList)

  result = derSequence([
    version, serialInt, sigAlg,
    name, validity, name,
    spki, exts])

proc sha256Digest(msg: openArray[byte]): array[32, byte] =
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha256Update(ctx, unsafeAddr msg[0], csize_t(msg.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

proc signTbsAsn1(kp: PeerKeypair; tbs: openArray[byte]): seq[byte] =
  ## Sign the TBS with the M1 keypair, then wrap raw 64 B sig into
  ## ASN.1 DER `SEQUENCE { r INTEGER, s INTEGER }` via BearSSL's
  ## `ecdsaRawToAsn1`. The buffer must have enough headroom for the
  ## DER expansion — BearSSL documents a worst case of `raw_len + 9`.
  let rawSig = signMessage(kp, tbs)
  var sigBuf: array[80, byte]
  for i in 0 ..< rawSig.len:
    sigBuf[i] = rawSig[i]
  let asnLen = bsslEcAbi.ecdsaRawToAsn1(addr sigBuf[0], csize_t(rawSig.len))
  if asnLen == 0:
    raise newException(CertParseError,
      "BearSSL ecdsaRawToAsn1 failed")
  result = newSeq[byte](int(asnLen))
  for i in 0 ..< int(asnLen):
    result[i] = sigBuf[i]

# ---------------------------------------------------------------------------
# Public API: cert generation.
# ---------------------------------------------------------------------------

proc randomSerial(): array[16, byte] =
  let n = randomBytes(addr result[0], sizeof(result))
  if n != sizeof(result):
    raise newException(CertParseError,
      "OS RNG returned " & $n & " bytes for serial; expected 16")
  # Force MSB clear so the integer is unambiguously positive AND fits
  # in <= 20 bytes per RFC 5280 §4.1.2.2.
  result[0] = result[0] and 0x7f'u8

proc derToPem(label: string; der: openArray[byte]): string =
  let bodyOneLine = encode(der)
  result = "-----BEGIN " & label & "-----\n"
  var i = 0
  while i < bodyOneLine.len:
    let stop = min(i + 64, bodyOneLine.len)
    result.add(bodyOneLine[i ..< stop])
    result.add('\n')
    i = stop
  result.add("-----END " & label & "-----\n")

proc pemToDer*(pem: string; label: string): seq[byte] =
  ## Generic PEM → DER decoder. Strips the BEGIN/END frame for the
  ## given label and base64-decodes the body.
  let begin = "-----BEGIN " & label & "-----"
  let fin = "-----END " & label & "-----"
  let bi = pem.find(begin)
  let ei = pem.find(fin)
  if bi < 0 or ei < 0 or ei <= bi:
    raise newException(CertParseError,
      "PEM frame for label `" & label & "` not found")
  let body = pem[bi + begin.len ..< ei]
  var b64: string = ""
  for c in body:
    if c notin {' ', '\t', '\r', '\n'}:
      b64.add(c)
  let raw = decode(b64)
  result = newSeq[byte](raw.len)
  for i in 0 ..< raw.len:
    result[i] = byte(raw[i])

proc certPemToDer*(pem: string): seq[byte] =
  pemToDer(pem, "CERTIFICATE")

proc certDerToPem*(der: seq[byte]): string =
  derToPem("CERTIFICATE", der)

proc generateSelfSignedCertWithWindow*(
    keypair: PeerKeypair;
    subjectCn: string;
    notBefore: int64;
    notAfter: int64): CertAndKey =
  ## Generates a self-signed X.509 v3 cert with a caller-supplied
  ## validity window. Used by the validity-window test to stamp out
  ## both expired and valid certs from the same primitive.
  if notAfter <= notBefore:
    raise newException(CertParseError,
      "cert validity window is empty: notBefore=" & $notBefore &
      " notAfter=" & $notAfter)
  let serial = randomSerial()
  let tbs = buildTbs(serial, subjectCn, notBefore, notAfter, keypair.publicKey)
  let sigDer = signTbsAsn1(keypair, tbs)
  let sigBit = derBitString(sigDer)
  let sigAlg = encodeAlgorithmEcdsaSha256()
  let certDer = derSequence([tbs, sigAlg, sigBit])

  result = CertAndKey(
    keypair: keypair,
    certPem: derToPem("CERTIFICATE", certDer),
    certDer: certDer,
    subjectCn: subjectCn,
    notBefore: notBefore,
    notAfter: notAfter)

proc generateSelfSignedCert*(
    keypair: PeerKeypair;
    subjectCn: string;
    validityDays: int = 365): CertAndKey =
  let now = getTime().toUnix
  let notAfter = now + int64(validityDays) * 86_400
  result = generateSelfSignedCertWithWindow(keypair, subjectCn, now, notAfter)

# ---------------------------------------------------------------------------
# Cert parsing (round-trip + trust-anchor loading).
# ---------------------------------------------------------------------------

proc dummyAppendDn(ctx: pointer; buf: bsslConst.ConstPointer;
                   len: csize_t) {.cdecl.} =
  discard

type
  ParsedCertInfo = object
    publicKey: PublicKeyBytes
    notBefore: int64
    notAfter: int64

proc daysSecondsToUnix(days: uint32; seconds: uint32): int64 =
  ## BearSSL reports time as `(days, seconds)` where days are counted
  ## since 0000-03-01 (the proleptic Gregorian epoch the C library uses
  ## internally; see `src/x509/x509_minimal.c` line `vd = ... + 719528`).
  ## The Unix epoch (1970-01-01) corresponds to 719_528 days under that
  ## count.
  const UnixEpochDays = 719_528'i64
  result = (int64(days) - UnixEpochDays) * 86_400 + int64(seconds)

proc parseCertDer(der: openArray[byte]): ParsedCertInfo =
  ## Drives `X509DecoderContext` over the cert bytes and extracts the
  ## EC public key + validity window. Raises `CertParseError` on any
  ## decoder error.
  var ctx: bsslX509Abi.X509DecoderContext
  bsslX509Abi.x509DecoderInit(ctx, dummyAppendDn, nil)
  if der.len > 0:
    bsslX509Abi.x509DecoderPush(ctx, unsafeAddr der[0], csize_t(der.len))
  if not ctx.decoded:
    raise newException(CertParseError,
      "X.509 decoder did not reach a complete cert (err=" & $ctx.err & ")")
  if ctx.err != 0:
    raise newException(CertParseError,
      "X.509 decoder error code " & $ctx.err)
  if ctx.pkey.keyType != bsslX509Abi.KEYTYPE_EC:
    raise newException(CertParseError,
      "X.509 cert SPKI is not EC (keyType=" & $ctx.pkey.keyType & ")")
  let ec = ctx.pkey.key.ec
  if ec.qlen != uint(P256PubLen):
    raise newException(CertParseError,
      "X.509 cert SPKI public key length is " & $ec.qlen &
      "; expected " & $P256PubLen)
  # Copy the EC public point bytes out of pkeyData (which `ec.q` points
  # into) before the decoder context goes out of scope.
  let qBuf = cast[ptr UncheckedArray[byte]](ctx.pkey.key.ec.q)
  for i in 0 ..< P256PubLen:
    result.publicKey[i] = qBuf[i]
  result.notBefore = daysSecondsToUnix(ctx.notbeforeDays, ctx.notbeforeSeconds)
  result.notAfter = daysSecondsToUnix(ctx.notafterDays, ctx.notafterSeconds)

# ---------------------------------------------------------------------------
# Subject-CN extraction (we re-parse the DER ourselves to pull the CN
# out of the subject Name — BearSSL's X509DecoderContext does not surface
# it directly).
# ---------------------------------------------------------------------------

proc readDerTlv(buf: openArray[byte]; pos: var int): (byte, int, int) =
  ## Parses a TLV at `pos`, returns `(tag, contentLen, contentStart)`
  ## and advances `pos` past the whole TLV.
  if pos >= buf.len:
    raise newException(CertParseError, "DER underrun at TLV header")
  let tag = buf[pos]
  inc pos
  if pos >= buf.len:
    raise newException(CertParseError, "DER underrun at length byte")
  let first = buf[pos]
  inc pos
  var contentLen: int
  if (first and 0x80'u8) == 0:
    contentLen = int(first)
  else:
    let n = int(first and 0x7f'u8)
    if n == 0 or n > 4:
      raise newException(CertParseError,
        "DER unsupported length encoding (n=" & $n & ")")
    if pos + n > buf.len:
      raise newException(CertParseError, "DER underrun in long-form length")
    contentLen = 0
    for i in 0 ..< n:
      contentLen = (contentLen shl 8) or int(buf[pos + i])
    pos += n
  let contentStart = pos
  if contentStart + contentLen > buf.len:
    raise newException(CertParseError, "DER content underrun")
  pos = contentStart + contentLen
  (tag, contentLen, contentStart)

proc findSubjectDn*(certDer: openArray[byte]): seq[byte] =
  ## Peer-Cache-BearSSL M3: extracts the raw DER bytes of the cert's
  ## Subject Name SEQUENCE (tag + length + content). Returns the empty
  ## seq if the cert doesn't parse. Used by `loadTrustAnchorDir` to
  ## populate `TrustAnchorEntry.subjectDn` so the BearSSL X509Minimal
  ## verifier can match a leaf's issuer DN against the anchor's DN.
  var pos = 0
  let (tag0, _, c0) = readDerTlv(certDer, pos)
  if tag0 != AsnSequence:
    return @[]
  pos = c0
  let (tagTbs, _, cTbs) = readDerTlv(certDer, pos)
  if tagTbs != AsnSequence:
    return @[]
  pos = cTbs
  # Skip optional [0] version.
  if pos < certDer.len and certDer[pos] == AsnContext0Constructed:
    discard readDerTlv(certDer, pos)
  # Skip serial INTEGER.
  discard readDerTlv(certDer, pos)
  # Skip signatureAlgorithm SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Skip Issuer Name SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Skip Validity SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Subject Name SEQUENCE — capture tag+length+content as a single span.
  let subjectStart = pos
  discard readDerTlv(certDer, pos)
  let subjectEnd = pos
  result = newSeq[byte](subjectEnd - subjectStart)
  for i in 0 ..< result.len:
    result[i] = certDer[subjectStart + i]

proc findSubjectCn(certDer: openArray[byte]): string =
  ## Walks the cert DER far enough to find the subject Name and pulls
  ## the first CN attribute out. Returns `""` if not found.
  var pos = 0
  # Outer Certificate SEQUENCE.
  let (tag0, _, c0) = readDerTlv(certDer, pos)
  if tag0 != AsnSequence:
    raise newException(CertParseError,
      "expected outer SEQUENCE, got tag 0x" & toHex(int(tag0), 2))
  # Descend into TBSCertificate.
  pos = c0
  let (tagTbs, _, cTbs) = readDerTlv(certDer, pos)
  if tagTbs != AsnSequence:
    raise newException(CertParseError, "expected TBSCertificate SEQUENCE")
  pos = cTbs
  # Skip optional [0] version.
  if pos < certDer.len and certDer[pos] == AsnContext0Constructed:
    discard readDerTlv(certDer, pos)
  # Skip serial INTEGER.
  discard readDerTlv(certDer, pos)
  # Skip sigAlg SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Issuer Name SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Validity SEQUENCE.
  discard readDerTlv(certDer, pos)
  # Subject Name SEQUENCE.
  let subStart = pos
  let (tagSub, _, cSub) = readDerTlv(certDer, pos)
  if tagSub != AsnSequence:
    raise newException(CertParseError, "expected subject Name SEQUENCE")
  # Walk subject RDNs looking for CN.
  var rdnPos = cSub
  let subEnd = subStart + (pos - subStart)
  while rdnPos < subEnd:
    let (rdnTag, _, cRdn) = readDerTlv(certDer, rdnPos)
    if rdnTag != AsnSet:
      continue
    var atvPos = cRdn
    while atvPos < rdnPos:
      let (atvTag, _, cAtv) = readDerTlv(certDer, atvPos)
      if atvTag != AsnSequence:
        continue
      var pAtv = cAtv
      let (oidTag, oidLen, oidStart) = readDerTlv(certDer, pAtv)
      if oidTag != AsnOid:
        continue
      # Compare OID bytes to CN OID 2.5.4.3 → DER `55 04 03`.
      if oidLen == 3 and certDer[oidStart] == 0x55'u8 and
         certDer[oidStart + 1] == 0x04'u8 and
         certDer[oidStart + 2] == 0x03'u8:
        let (_, vLen, vStart) = readDerTlv(certDer, pAtv)
        result = newString(vLen)
        for k in 0 ..< vLen:
          result[k] = char(certDer[vStart + k])
        return
  result = ""

# ---------------------------------------------------------------------------
# Verify the cert's self-signature with BearSSL's ECDSA verifier.
# This is the round-trip test's "verify the cert's self-signature with
# BearSSL's X.509 verifier" leg. We extract the TBS bytes from the DER
# (they're the first inner SEQUENCE of the outer Certificate SEQUENCE)
# and the signature BIT STRING content, then call
# `ecdsaVrfyAsn1GetDefault`.
# ---------------------------------------------------------------------------

proc verifyCertSelfSignature*(der: openArray[byte]): bool =
  ## Returns true iff the outer signature on `der` verifies under the
  ## SPKI inside `der` (self-signed). Drives BearSSL's
  ## `ecdsaVrfyAsn1GetDefault` against the TBS SHA-256.
  var pos = 0
  let (outerTag, _, outerStart) = readDerTlv(der, pos)
  if outerTag != AsnSequence:
    return false
  let outerEnd = pos
  # First child: TBSCertificate.
  var inner = outerStart
  let tbsStart = inner
  let (tbsTag, _, _) = readDerTlv(der, inner)
  if tbsTag != AsnSequence:
    return false
  let tbsEnd = inner
  let tbsLen = tbsEnd - tbsStart
  # Second child: signatureAlgorithm — skip.
  discard readDerTlv(der, inner)
  # Third child: signatureValue BIT STRING.
  let (sigTag, sigLen, sigStart) = readDerTlv(der, inner)
  if sigTag != AsnBitString or sigLen < 1:
    return false
  # First content byte is "unused bits"; must be 0 for a DER cert sig.
  if der[sigStart] != 0:
    return false
  let sigDerLen = sigLen - 1
  if sigDerLen <= 0:
    return false
  # Compute SHA-256 over the TBS bytes.
  var tbsBytes = newSeq[byte](tbsLen)
  for i in 0 ..< tbsLen:
    tbsBytes[i] = der[tbsStart + i]
  let tbsHash = sha256Digest(tbsBytes)
  # Parse the SPKI to get the EC pubkey.
  let info = parseCertDer(der)
  var pkBytes: array[P256PubLen, byte]
  for i in 0 ..< P256PubLen:
    pkBytes[i] = info.publicKey[i]
  var pk: bsslEcAbi.EcPublicKey
  pk.curve = cint(bsslEcAbi.EC_secp256r1)
  pk.q = addr pkBytes[0]
  pk.qlen = uint(P256PubLen)
  let ecImpl = bsslEcAbi.ecGetDefault()
  let verifier = bsslEcAbi.ecdsaVrfyAsn1GetDefault()
  var sigBytes = newSeq[byte](sigDerLen)
  for i in 0 ..< sigDerLen:
    sigBytes[i] = der[sigStart + 1 + i]
  var hashBuf: array[32, byte]
  for i in 0 ..< 32:
    hashBuf[i] = tbsHash[i]
  let ok = verifier(ecImpl, addr hashBuf[0], csize_t(hashBuf.len),
                    addr pk, addr sigBytes[0], csize_t(sigBytes.len))
  result = ok == 1'u32
  discard outerEnd

# ---------------------------------------------------------------------------
# Public API: parsing + I/O.
# ---------------------------------------------------------------------------

proc loadCertAndKey*(certPath, keyPath: string): CertAndKey =
  ## Reads `certPath` (PEM cert) and `keyPath` (the M1
  ## `ecdsa-p256:<hex>` private-key file) from disk, parses, and
  ## returns the bound `CertAndKey`. Raises `CertParseError` /
  ## `AuthError` on any I/O or parse failure. Does NOT auto-generate
  ## — generation is explicit via `generateSelfSignedCert` +
  ## `writeCertAndKey`.
  if not fileExists(certPath):
    raise newException(CertParseError,
      "cert file does not exist: " & certPath)
  if not fileExists(keyPath):
    raise newException(CertParseError,
      "key file does not exist: " & keyPath)
  let pem = readFile(certPath)
  let der = certPemToDer(pem)
  let info = parseCertDer(der)
  let cn = findSubjectCn(der)
  # Parse the M1 `ecdsa-p256:<hex>` key file inline (no auto-generation;
  # M2 generation is explicit via generateSelfSignedCert + writeCertAndKey).
  const KeyFilePrefix = "ecdsa-p256:"
  var privHex = ""
  for rawLine in readFile(keyPath).splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if not line.startsWith(KeyFilePrefix):
      raise newException(CertParseError,
        "key file " & keyPath & " lacks the `ecdsa-p256:` marker")
    privHex = line[KeyFilePrefix.len .. ^1]
    break
  if privHex.len != P256PrivLen * 2:
    raise newException(CertParseError,
      "key file " & keyPath & " hex length is " & $privHex.len &
      "; expected " & $(P256PrivLen * 2))
  var priv: PrivateKeyBytes
  for i in 0 ..< P256PrivLen:
    try:
      priv[i] = byte(parseHexInt(privHex[2 * i .. 2 * i + 1]))
    except ValueError:
      raise newException(CertParseError,
        "key file " & keyPath & " has invalid hex at position " & $(2 * i))
  let derivedPub = derivePublicKey(priv)
  if derivedPub != info.publicKey:
    raise newException(CertParseError,
      "key file " & keyPath & " does not match cert SPKI in " & certPath)
  result = CertAndKey(
    keypair: PeerKeypair(publicKey: derivedPub, privateKey: priv),
    certPem: pem,
    certDer: der,
    subjectCn: cn,
    notBefore: info.notBefore,
    notAfter: info.notAfter)

proc writeCertAndKey*(c: CertAndKey; certPath, keyPath: string) =
  ## Persists `c.certPem` to `certPath` and the M1 key-file format
  ## (`ecdsa-p256:<hex>`) to `keyPath`.
  let parent = parentDir(certPath)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(certPath, c.certPem)
  # Reuse M1's auth.writeKeyFile-equivalent via loadOrGenerateKeypair's
  # write path: we replicate the on-disk shape inline to avoid the
  # cert-side file that loadOrGenerateKeypair would also write.
  const KeyFilePrefix = "ecdsa-p256:"
  const HexChars = "0123456789abcdef"
  let keyParent = parentDir(keyPath)
  if keyParent.len > 0 and not dirExists(keyParent):
    createDir(keyParent)
  var hex = newString(P256PrivLen * 2)
  for i, b in c.keypair.privateKey:
    hex[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    hex[2 * i + 1] = HexChars[int(b) and 0xf]
  writeFile(keyPath, KeyFilePrefix & hex & "\n")

# ---------------------------------------------------------------------------
# Trust-anchor directory loader.
# ---------------------------------------------------------------------------

proc newTrustAnchorSet*(): TrustAnchorSet =
  result = TrustAnchorSet(byPeerId: initTable[PeerId, TrustAnchorEntry]())

proc loadTrustAnchorDir*(path: string): TrustAnchorSet =
  ## Reads every `*.crt` file in `path`. Each file is one PEM cert.
  ## Builds a `TrustAnchorSet` keyed by `peerId = BLAKE3-256(pubkey)`.
  if not dirExists(path):
    raise newException(CertParseError,
      "trust anchor directory does not exist: " & path)
  result = newTrustAnchorSet()
  for kind, entry in walkDir(path):
    if kind != pcFile:
      continue
    if not entry.endsWith(".crt"):
      continue
    let pem = readFile(entry)
    let der = certPemToDer(pem)
    let info = parseCertDer(der)
    let cn = findSubjectCn(der)
    let dn = findSubjectDn(der)
    let peerId = derivePeerIdFromPublicKey(info.publicKey)
    result.byPeerId[peerId] = TrustAnchorEntry(
      peerId: peerId,
      publicKey: info.publicKey,
      certDer: der,
      certPem: pem,
      notBefore: info.notBefore,
      notAfter: info.notAfter,
      subjectCn: cn,
      subjectDn: dn)

# ---------------------------------------------------------------------------
# Validity-window enforcement.
# ---------------------------------------------------------------------------

proc validateCertNotExpired*(entry: TrustAnchorEntry; now: int64): bool =
  ## Returns true iff `entry.notBefore <= now < entry.notAfter`.
  result = entry.notBefore <= now and now < entry.notAfter
