## The Intel TDX attestation quote: its structure, and the three
## public-key operations that say a Trust Domain produced it.
##
## ## The document
##
## A quote is a 48-byte header, a TD report, a declared length, and a
## signature block that carries its own certificate chain. Every offset
## below is `sgx_quote_4.h`, `sgx_quote_5.h` and `sgx_quote_3.h` of
## Intel's `SGXDataCenterAttestationPrimitives` at tag `DCAP_1.25`
## (`229ec6b0d5f1a411b6c96436d664b9ecc018559a`), corroborated against
## `QuoteStructures.h` in Intel's quote-verification library at
## `d12717e3`. Every one of them is asserted against real quotes by the
## gate rather than trusted from the transcription.
##
## ## Three signatures, and why none of them alone says anything
##
## A quote is not one signed document. It is three, and a verifier that
## checks any one of them in isolation has established nothing:
##
##   * the **quote signature** covers the header and the TD report, and
##     is made by an attestation key that appears in the quote itself.
##     On its own that is a document vouching for itself.
##   * the **quoting enclave's report** is signed by a Provisioning
##     Certification Key whose certificate chains to Intel. That is what
##     ties the quote to a part — but the report says nothing about the
##     TD.
##   * the **binding** closes the loop: the quoting enclave's report data
##     is `SHA-256(attestation key ‖ authentication data)`, so the key
##     that signed the TD report is the key Intel's chain endorsed the
##     enclave for.
##
## Drop the third and the first two are two unrelated facts. That is why
## `qeReportBindsAttestationKey` is a rule here and not a note.
##
## ## Why the reader is this strict
##
## A quote arrives from the machine being judged, and it is a
## length-prefixed format nested three deep: the signature block declares
## its length, the quoting-enclave certification data inside it declares
## its own, the authentication data inside that declares its own, and the
## certificate chain inside that declares its own. Four chances for a
## declared length to disagree with the bytes actually present.
##
## Each disagreement is refused by its own rule and named. A reader that
## took the smaller of the two, or that ignored the remainder, would
## accept a document containing a second document nobody looks at — and
## the published corpus contains exactly that shape already: one of the
## quotes pinned by the gate carries 39 bytes past the end of what it
## declares, put there on purpose by its publisher.
##
## ## The public-key operations are NOT implemented here
##
## All three go to `repro_attest/cose`'s `ecdsaSignatureIsValid` with
## `ES256` and a `P-256` key, because all three are raw `R ‖ S` over
## SHA-256 — the form RFC 9053 §2.1 describes and the form that module's
## primitive takes. That module owns the single raw-signature ECDSA
## implementation in this tree, and this reaches it through its
## caller-built-key path: the key comes out of a certificate or out of
## the quote's own bytes, never out of a `COSE_Key` map, which is the
## path its own documentation says is the only way a point of a width
## this library did not choose reaches the curve.
##
## The *certificate* signatures are a different wire form — DER
## `ECDSA-Sig-Value` — and go to `x509.nim`'s primitive. That is one
## implementation per encoding rather than two opinions about one
## signature: no byte string is verifiable by both.
##
## ## Mocking
##
## None. Real quotes from real parts, real curve arithmetic.

import std/[strutils]

import repro_attest/cose

import bearssl/abi/bearssl_hash as bsslHashAbi

proc sha256Bytes*(msg: openArray[byte]): array[32, byte] =
  ## The same SHA-256 the signature verification hashes with, reached
  ## the same way, because the binding rule below compares a digest
  ## against bytes a signature covers — and a build with two SHA-256
  ## implementations has two answers available to whichever comparison
  ## is convenient.
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha224Update(ctx, unsafeAddr msg[0], uint(msg.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  TdxQuoteErrorKind* = enum
    ## One kind per rule. The messages below satisfy the property
    ## `tdxQuoteMessagesAreDistinguishable` states and checks: **no
    ## message is a substring of any other**. A case that matches on a
    ## fragment of one refusal therefore cannot be satisfied by a
    ## different refusal.
    tqeTooShort
    tqeUnsupportedVersion
    tqeUnsupportedAttestationKeyType
    tqeNotATrustDomainQuote
    tqeHeaderReservedNotZero
    tqeUnsupportedBodyType
    tqeBodySizeDisagreesWithItsType
    tqeBodyRunsPastTheEnd
    tqeSignatureDataRunsPastTheEnd
    tqeTrailingBytes
    tqeQeCertificationDataTypeUnsupported
    tqeQeCertificationDataRunsPastTheEnd
    tqeQeAuthenticationDataRunsPastTheEnd
    tqePckCertificationDataTypeUnsupported
    tqePckCertificationDataRunsPastTheEnd
    tqeCertificationDataNotExactlyFilled
    tqeNotAPemCertificateChain
    tqeWrongCertificateChainLength

  TdxQuoteError* = object of CatchableError
    kind*: TdxQuoteErrorKind

const
  TdxQuoteMessage*: array[TdxQuoteErrorKind, string] = [
    tqeTooShort:
      "this document is shorter than the fixed prefix every quote of " &
      "every version begins with",
    tqeUnsupportedVersion:
      "the quote states a structure revision this build has no layout for",
    tqeUnsupportedAttestationKeyType:
      "the quote names an attestation key type other than the one this " &
      "build verifies",
    tqeNotATrustDomainQuote:
      "the quote names an execution environment other than a trust " &
      "domain, so nothing in it is a statement about one",
    tqeHeaderReservedNotZero:
      "the span the header specification reserves carries something, so " &
      "this is not the document whose fields are being read",
    tqeUnsupportedBodyType:
      "the quote names a report shape that this build has no field " &
      "layout for",
    tqeBodySizeDisagreesWithItsType:
      "the report declares a width other than the one its own stated " &
      "shape has",
    tqeBodyRunsPastTheEnd:
      "the report the quote declares extends beyond the bytes supplied",
    tqeSignatureDataRunsPastTheEnd:
      "the signature block the quote declares extends beyond the bytes " &
      "supplied",
    tqeTrailingBytes:
      "bytes follow the signature block, and nothing in this document " &
      "covers them",
    tqeQeCertificationDataTypeUnsupported:
      "the signature block carries certification data of a kind that is " &
      "not the quoting enclave report this build reads",
    tqeQeCertificationDataRunsPastTheEnd:
      "the quoting enclave's certification data declares more bytes than " &
      "the signature block holds",
    tqeQeAuthenticationDataRunsPastTheEnd:
      "the quoting enclave's authentication data declares more bytes " &
      "than remain beside it",
    tqePckCertificationDataTypeUnsupported:
      "the endorsement material is of a kind other than the certificate " &
      "chain this build reads",
    tqePckCertificationDataRunsPastTheEnd:
      "the endorsement material declares more bytes than remain beside it",
    tqeCertificationDataNotExactlyFilled:
      "a nested block is not exactly filled by what it contains, so the " &
      "remainder is covered by no field at all",
    tqeNotAPemCertificateChain:
      "the endorsement material holds no certificate in the textual " &
      "armour this kind is defined to carry",
    tqeWrongCertificateChainLength:
      "the endorsement material holds a number of certificates that is " &
      "not the length of the chain a quote is endorsed by"]

proc tdxQuoteMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked, not asserted: this
  ## is the property that makes an `in e.msg` assertion mean one rule.
  for a in TdxQuoteErrorKind:
    for b in TdxQuoteErrorKind:
      if a == b: continue
      if TdxQuoteMessage[a] in TdxQuoteMessage[b]: return false
  true

proc tdxFail*(kind: TdxQuoteErrorKind; detail: string) {.noreturn.} =
  var e = newException(TdxQuoteError, TdxQuoteMessage[kind])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.kind = kind
  raise e

# ---------------------------------------------------------------------
# The layout
# ---------------------------------------------------------------------

const
  TdxQuoteHeaderLen* = 48
  OffQuoteVersion* = 0
  OffQuoteAttestationKeyType* = 2
  OffQuoteTeeType* = 4
  OffQuoteHeaderReserved* = 8
  OffQuoteVendorId* = 12
  OffQuoteUserData* = 28
  LenQuoteVendorId* = 16
  LenQuoteUserData* = 20

  TdxQuoteVersion4* = 4'u16
  TdxQuoteVersion5* = 5'u16
  TdxSupportedQuoteVersions* = [TdxQuoteVersion4, TdxQuoteVersion5]

  TdxAttestationKeyTypeEcdsaP256* = 2'u16
    ## `sgx_attestation_algorithm_id_t`'s `ECDSA_P256`. The only value
    ## this build verifies.

  TdxTeeType* = 0x81'u32
    ## `TEE_TYPE_TDX`. `0` is SGX, which this build refuses by name
    ## rather than reading a TD report's offsets out of an enclave
    ## report.

  TdReportLen* = 584
    ## `sgx_report2_body_t`: TDX 1.0's report.
  TdReport15Len* = 648
    ## `sgx_report2_body_v1_5_t`: the same 584 bytes followed by a second
    ## TCB SVN array and the measurement of a bound service domain.

  OffTeeTcbSvn* = 0
  OffMrSeam* = 16
  OffMrSignerSeam* = 64
  OffSeamAttributes* = 112
  OffTdAttributes* = 120
  OffXfam* = 128
  OffMrTd* = 136
  OffMrConfigId* = 184
  OffMrOwner* = 232
  OffMrOwnerConfig* = 280
  OffRtMr* = 328
  OffTdReportData* = 520
  OffTeeTcbSvn2* = 584
  OffMrServiceTd* = 600

  LenTeeTcbSvn* = 16
  LenTeeMeasurement* = 48
  LenTeeAttributes* = 8
  LenTeeReportData* = 64
  TdxRtMrCount* = 4

  TdxModuleMajorSvnIndex* = 1
    ## `TDX_MODULE_MAJOR_SVN_INDEX` in Intel's evaluation: the entry of
    ## `teeTcbSvn` that names WHICH module is running. Declared here,
    ## beside the array it indexes, rather than beside the evaluation
    ## that consults it — an index into a field belongs with the field,
    ## and a second declaration would be a second opinion about which
    ## byte decides.
  TdxModuleMinorSvnIndex* = 0
    ## `TDX_MODULE_MINOR_SVN_INDEX`: the entry compared against that
    ## module identity's own published versions.

  # The SGX report body the quoting enclave signs.
  SgxReportBodyLen* = 384
  OffQeCpuSvn* = 0
  OffQeMiscSelect* = 16
  OffQeAttributes* = 48
  OffQeMrEnclave* = 64
  OffQeMrSigner* = 128
  OffQeIsvProdId* = 256
  OffQeIsvSvn* = 258
  OffQeReportData* = 320

  EcdsaP256SignatureLen* = 64
    ## `R ‖ S`, each 32 bytes big-endian.
  EcdsaP256PublicKeyLen* = 64
    ## `X ‖ Y`, without the `0x04` an uncompressed point carries in DER.
  EcdsaP256PointLen* = 1 + EcdsaP256PublicKeyLen

  QeReportCertificationDataType* = 6'u16
    ## `PPID/QE report` certification data: the kind that carries the
    ## quoting enclave's report, its signature, its authentication data
    ## and the endorsement chain.
  PckCertificateChainDataType* = 5'u16
    ## The kind whose payload is a PEM certificate chain, leaf first.

  TdxChainElements* = 3
    ## The Provisioning Certification Key, its authority, and Intel's
    ## root. A quote that bundles a different number is making a
    ## different claim, and the count is the first thing to check.

type
  TdxQuoteBodyShape* = enum
    ## What the report in a quote is. A version-4 quote states none of
    ## this and is always `tbsTdReport`; a version-5 quote names it.
    tbsTdReport = "TD report"
    tbsTdReport15 = "TD report with a preserved TCB and a service domain"

  TdxQuoteBodyType* = enum
    ## `sgx_quote5_t.type`. The two this build reads and their values;
    ## `1` (an SGX enclave report) and `4` (the 1.5ex report) are
    ## refused by `tqeUnsupportedBodyType` rather than read.
    qbtTdReport10 = 2
    qbtTdReport15 = 3

  TdxTdReport* = object
    ## The fields of the TD report, lifted by offset.
    shape*: TdxQuoteBodyShape
    raw*: seq[byte]
    teeTcbSvn*: seq[byte]
    mrSeam*, mrSignerSeam*: seq[byte]
    seamAttributes*, tdAttributes*, xfam*: seq[byte]
    mrTd*, mrConfigId*, mrOwner*, mrOwnerConfig*: seq[byte]
    rtMr*: array[TdxRtMrCount, seq[byte]]
    reportData*: seq[byte]
    hasPreservedTcb*: bool
    teeTcbSvn2*: seq[byte]
    mrServiceTd*: seq[byte]

  TdxQeReport* = object
    ## The quoting enclave's SGX report, lifted by offset.
    raw*: seq[byte]
    cpuSvn*: seq[byte]
    miscSelect*: uint32
    attributes*: seq[byte]
    mrEnclave*, mrSigner*: seq[byte]
    isvProdId*, isvSvn*: uint16
    reportData*: seq[byte]

  TdxQuote* = object
    raw*: seq[byte]
    signedBytes*: seq[byte]
      ## The header and the report, lifted verbatim — for a version-5
      ## quote that includes the two fields that describe the report's
      ## shape, because the signature covers them. Never re-serialised:
      ## a verifier that checks a signature against its own re-encoding
      ## of a document is checking its decoder, not the document.
    version*: uint16
    attestationKeyType*: uint16
    teeType*: uint32
    vendorId*, userData*: seq[byte]
    bodyType*: TdxQuoteBodyType
    body*: TdxTdReport
    quoteSignature*: seq[byte]
    attestationKey*: seq[byte]
    qeReport*: TdxQeReport
    qeReportSignature*: seq[byte]
    qeAuthenticationData*: seq[byte]
    pckChainPem*: seq[byte]
    pckChain*: seq[seq[byte]]
      ## The three certificates the armour decodes to, leaf first.

proc le16(b: openArray[byte]; at: int): uint16 =
  uint16(b[at]) or (uint16(b[at + 1]) shl 8)

proc le32(b: openArray[byte]; at: int): uint32 =
  uint32(b[at]) or (uint32(b[at + 1]) shl 8) or
    (uint32(b[at + 2]) shl 16) or (uint32(b[at + 3]) shl 24)

proc bytesAt(b: openArray[byte]; at, n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = b[at + i]

# ---------------------------------------------------------------------
# The textual armour
# ---------------------------------------------------------------------

const
  PemBegin* = "-----BEGIN CERTIFICATE-----"
  PemEnd* = "-----END CERTIFICATE-----"
  Base64Alphabet* =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc base64Decode*(text: openArray[char]): seq[byte] =
  ## Base64 over the standard alphabet, stopping at the first pad.
  ##
  ## Characters outside the alphabet are skipped rather than refused,
  ## and that is deliberate for exactly one reason: the only thing this
  ## decodes is the interior of a PEM block, whose line breaks are not
  ## optional and whose content is about to be handed to a DER reader
  ## that refuses anything it does not understand. A lenient decoder in
  ## front of a strict parser adds no acceptance; a strict decoder in
  ## front of it would only argue about line endings.
  var acc = 0
  var bits = 0
  for c in text:
    if c == '=': break
    let idx = Base64Alphabet.find(c)
    if idx < 0: continue
    acc = (acc shl 6) or idx
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xff)

proc pemCertificates*(data: openArray[byte]): seq[seq[byte]] =
  ## Every `CERTIFICATE` block of a PEM document, in the order it
  ## carries them.
  var text = newString(data.len)
  for i in 0 ..< data.len: text[i] = char(data[i])
  var pos = 0
  while true:
    let b = text.find(PemBegin, pos)
    if b < 0: break
    let e = text.find(PemEnd, b)
    if e < 0: break
    result.add base64Decode(toOpenArray(text, b + PemBegin.len, e - 1))
    pos = e + PemEnd.len

# ---------------------------------------------------------------------
# The reader
# ---------------------------------------------------------------------

proc readTdReport(raw: openArray[byte]; at, width: int): TdxTdReport =
  result.shape =
    if width == TdReport15Len: tbsTdReport15 else: tbsTdReport
  result.raw = bytesAt(raw, at, width)
  result.teeTcbSvn = bytesAt(raw, at + OffTeeTcbSvn, LenTeeTcbSvn)
  result.mrSeam = bytesAt(raw, at + OffMrSeam, LenTeeMeasurement)
  result.mrSignerSeam = bytesAt(raw, at + OffMrSignerSeam, LenTeeMeasurement)
  result.seamAttributes = bytesAt(raw, at + OffSeamAttributes, LenTeeAttributes)
  result.tdAttributes = bytesAt(raw, at + OffTdAttributes, LenTeeAttributes)
  result.xfam = bytesAt(raw, at + OffXfam, LenTeeAttributes)
  result.mrTd = bytesAt(raw, at + OffMrTd, LenTeeMeasurement)
  result.mrConfigId = bytesAt(raw, at + OffMrConfigId, LenTeeMeasurement)
  result.mrOwner = bytesAt(raw, at + OffMrOwner, LenTeeMeasurement)
  result.mrOwnerConfig = bytesAt(raw, at + OffMrOwnerConfig, LenTeeMeasurement)
  for i in 0 ..< TdxRtMrCount:
    result.rtMr[i] =
      bytesAt(raw, at + OffRtMr + i * LenTeeMeasurement, LenTeeMeasurement)
  result.reportData = bytesAt(raw, at + OffTdReportData, LenTeeReportData)
  if width == TdReport15Len:
    result.hasPreservedTcb = true
    result.teeTcbSvn2 = bytesAt(raw, at + OffTeeTcbSvn2, LenTeeTcbSvn)
    result.mrServiceTd = bytesAt(raw, at + OffMrServiceTd, LenTeeMeasurement)

proc readQeReport(raw: openArray[byte]; at: int): TdxQeReport =
  result.raw = bytesAt(raw, at, SgxReportBodyLen)
  result.cpuSvn = bytesAt(raw, at + OffQeCpuSvn, 16)
  result.miscSelect = le32(raw, at + OffQeMiscSelect)
  result.attributes = bytesAt(raw, at + OffQeAttributes, 16)
  result.mrEnclave = bytesAt(raw, at + OffQeMrEnclave, 32)
  result.mrSigner = bytesAt(raw, at + OffQeMrSigner, 32)
  result.isvProdId = le16(raw, at + OffQeIsvProdId)
  result.isvSvn = le16(raw, at + OffQeIsvSvn)
  result.reportData = bytesAt(raw, at + OffQeReportData, LenTeeReportData)

proc widthOf*(bodyType: TdxQuoteBodyType): int =
  ## The width a stated report shape has. Exported because the gate
  ## checks the two against each other rather than reading one of them
  ## out of the same table the parser reads.
  case bodyType
  of qbtTdReport10: TdReportLen
  of qbtTdReport15: TdReport15Len

proc parseTdxQuote*(raw: openArray[byte]): TdxQuote =
  ## One Intel TDX attestation quote, version 4 or version 5.
  ##
  ## Refuses anything else by name. In particular it refuses a document
  ## that is *longer* than it declares, which is not pedantry: the
  ## corpus this is gated against contains one.
  if raw.len < TdxQuoteHeaderLen + 4:
    tdxFail(tqeTooShort,
      $raw.len & " bytes, and a header and a declared length are " &
      $(TdxQuoteHeaderLen + 4))
  result.raw = bytesAt(raw, 0, raw.len)

  result.version = le16(raw, OffQuoteVersion)
  var versionKnown = false
  for v in TdxSupportedQuoteVersions:
    if result.version == v: versionKnown = true
  if not versionKnown:
    tdxFail(tqeUnsupportedVersion, "version " & $result.version)

  result.attestationKeyType = le16(raw, OffQuoteAttestationKeyType)
  if result.attestationKeyType != TdxAttestationKeyTypeEcdsaP256:
    tdxFail(tqeUnsupportedAttestationKeyType,
      "attestation key type " & $result.attestationKeyType &
      "; this build verifies " & $TdxAttestationKeyTypeEcdsaP256 &
      " (ECDSA over P-256)")

  result.teeType = le32(raw, OffQuoteTeeType)
  if result.teeType != TdxTeeType:
    tdxFail(tqeNotATrustDomainQuote,
      "TEE type 0x" & toHex(int(result.teeType), 8) &
      " and a trust domain is 0x" & toHex(int(TdxTeeType), 8))

  for i in OffQuoteHeaderReserved ..< OffQuoteVendorId:
    if raw[i] != 0'u8:
      tdxFail(tqeHeaderReservedNotZero,
        "byte 0x" & toHex(i, 3) & " of the span 0x" &
        toHex(OffQuoteHeaderReserved, 3) & "-0x" &
        toHex(OffQuoteVendorId, 3) & " is 0x" & toHex(int(raw[i]), 2))

  result.vendorId = bytesAt(raw, OffQuoteVendorId, LenQuoteVendorId)
  result.userData = bytesAt(raw, OffQuoteUserData, LenQuoteUserData)

  # Where the report starts, how wide it is, and how much of the
  # preamble the signature covers. A version-4 quote states none of
  # this; a version-5 quote states all of it, and the two fields it
  # states are inside the signed span precisely so that a shape cannot
  # be restated after the fact.
  var bodyAt = TdxQuoteHeaderLen
  var bodyWidth = TdReportLen
  result.bodyType = qbtTdReport10
  if result.version == TdxQuoteVersion5:
    if raw.len < TdxQuoteHeaderLen + 6 + 4:
      tdxFail(tqeTooShort,
        $raw.len & " bytes, and a version-5 header, a report descriptor " &
        "and a declared length are " & $(TdxQuoteHeaderLen + 6 + 4))
    let stated = le16(raw, TdxQuoteHeaderLen)
    var known = false
    for t in TdxQuoteBodyType:
      if uint16(ord(t)) == stated:
        result.bodyType = t
        known = true
    if not known:
      tdxFail(tqeUnsupportedBodyType,
        "report shape " & $stated & "; this build reads " &
        $ord(qbtTdReport10) & " and " & $ord(qbtTdReport15))
    let declared = int(le32(raw, TdxQuoteHeaderLen + 2))
    bodyWidth = widthOf(result.bodyType)
    if declared != bodyWidth:
      tdxFail(tqeBodySizeDisagreesWithItsType,
        "the report states shape " & $ord(result.bodyType) & " (" &
        $result.bodyType & ", " & $bodyWidth & " bytes) and declares " &
        $declared)
    bodyAt = TdxQuoteHeaderLen + 6

  if bodyAt + bodyWidth + 4 > raw.len:
    tdxFail(tqeBodyRunsPastTheEnd,
      "the report occupies bytes " & $bodyAt & " to " &
      $(bodyAt + bodyWidth) & " and a declared length follows it, " &
      "against " & $raw.len & " bytes supplied")

  result.body = readTdReport(raw, bodyAt, bodyWidth)
  result.signedBytes = bytesAt(raw, 0, bodyAt + bodyWidth)

  let sigAt = bodyAt + bodyWidth + 4
  let sigLen = int(le32(raw, bodyAt + bodyWidth))
  if sigLen < 0 or sigAt + sigLen > raw.len:
    tdxFail(tqeSignatureDataRunsPastTheEnd,
      "it declares " & $sigLen & " bytes at offset " & $sigAt &
      ", against " & $raw.len & " bytes supplied")
  if sigAt + sigLen != raw.len:
    tdxFail(tqeTrailingBytes,
      $(raw.len - sigAt - sigLen) & " bytes follow the " & $sigLen &
      " the quote declares at offset " & $sigAt)

  # The signature block. Three fixed fields, then a nested certification
  # data envelope.
  const fixed = EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 2 + 4
  if sigLen < fixed:
    tdxFail(tqeQeCertificationDataRunsPastTheEnd,
      "the signature block is " & $sigLen & " bytes and its fixed " &
      "fields alone are " & $fixed)
  result.quoteSignature = bytesAt(raw, sigAt, EcdsaP256SignatureLen)
  result.attestationKey = bytesAt(raw, sigAt + EcdsaP256SignatureLen,
    EcdsaP256PublicKeyLen)

  let qeTypeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen
  let qeType = le16(raw, qeTypeAt)
  if qeType != QeReportCertificationDataType:
    tdxFail(tqeQeCertificationDataTypeUnsupported,
      "certification data type " & $qeType & "; this build reads " &
      $QeReportCertificationDataType)
  let qeLen = int(le32(raw, qeTypeAt + 2))
  let qeAt = qeTypeAt + 6
  if qeLen < 0 or qeAt + qeLen > sigAt + sigLen:
    tdxFail(tqeQeCertificationDataRunsPastTheEnd,
      "it declares " & $qeLen & " bytes and " &
      $(sigAt + sigLen - qeAt) & " remain in the signature block")
  if qeAt + qeLen != sigAt + sigLen:
    tdxFail(tqeCertificationDataNotExactlyFilled,
      "the signature block has " & $(sigAt + sigLen - qeAt - qeLen) &
      " bytes beyond the " & $qeLen & " its certification data declares")

  const qeFixed = SgxReportBodyLen + EcdsaP256SignatureLen + 2
  if qeLen < qeFixed:
    tdxFail(tqeQeCertificationDataRunsPastTheEnd,
      "the quoting enclave's certification data is " & $qeLen &
      " bytes and its report, signature and authentication length " &
      "alone are " & $qeFixed)
  result.qeReport = readQeReport(raw, qeAt)
  result.qeReportSignature = bytesAt(raw, qeAt + SgxReportBodyLen,
    EcdsaP256SignatureLen)

  let authLenAt = qeAt + SgxReportBodyLen + EcdsaP256SignatureLen
  let authLen = int(le16(raw, authLenAt))
  let authAt = authLenAt + 2
  if authAt + authLen + 6 > qeAt + qeLen:
    tdxFail(tqeQeAuthenticationDataRunsPastTheEnd,
      "it declares " & $authLen & " bytes and " &
      $(qeAt + qeLen - authAt) & " remain, of which 6 are the " &
      "endorsement material's own header")
  result.qeAuthenticationData = bytesAt(raw, authAt, authLen)

  let pckTypeAt = authAt + authLen
  let pckType = le16(raw, pckTypeAt)
  if pckType != PckCertificateChainDataType:
    tdxFail(tqePckCertificationDataTypeUnsupported,
      "endorsement material type " & $pckType & "; this build reads " &
      $PckCertificateChainDataType & " (a certificate chain in textual " &
      "armour)")
  let pckLen = int(le32(raw, pckTypeAt + 2))
  let pckAt = pckTypeAt + 6
  if pckLen < 0 or pckAt + pckLen > qeAt + qeLen:
    tdxFail(tqePckCertificationDataRunsPastTheEnd,
      "it declares " & $pckLen & " bytes and " &
      $(qeAt + qeLen - pckAt) & " remain")
  if pckAt + pckLen != qeAt + qeLen:
    tdxFail(tqeCertificationDataNotExactlyFilled,
      "the quoting enclave's certification data has " &
      $(qeAt + qeLen - pckAt - pckLen) & " bytes beyond the " & $pckLen &
      " its endorsement material declares")
  result.pckChainPem = bytesAt(raw, pckAt, pckLen)

  result.pckChain = pemCertificates(result.pckChainPem)
  if result.pckChain.len == 0:
    tdxFail(tqeNotAPemCertificateChain,
      "the " & $pckLen & "-byte payload contains no " & PemBegin &
      " block")
  if result.pckChain.len != TdxChainElements:
    tdxFail(tqeWrongCertificateChainLength,
      "it holds " & $result.pckChain.len & " certificates and a quote " &
      "is endorsed by " & $TdxChainElements &
      " — the provisioning certification key, its authority and the " &
      "vendor's root")

# ---------------------------------------------------------------------
# The three public-key operations
# ---------------------------------------------------------------------

proc p256KeyOf(publicKey: openArray[byte]): CoseKey =
  ## `X ‖ Y` as it appears in a quote, widened to the uncompressed point
  ## form the curve implementation reads.
  ##
  ## The `0x04` is prepended HERE and nowhere else. A quote carries the
  ## two coordinates bare; a certificate carries them behind the prefix;
  ## and a build with two opinions about which of those a key is would
  ## verify under whichever one happened to agree.
  result = CoseKey(curve: ccP256, point: @[0x04'u8])
  for b in publicKey: result.point.add b

proc verifyQuoteSignature*(quote: TdxQuote): bool =
  ## Whether the header and the report verify under the attestation key
  ## the quote itself carries.
  ##
  ## On its own this establishes nothing — the key is in the document it
  ## signs. `qeReportBindsAttestationKey` below is what turns it into a
  ## statement about a part.
  ecdsaSignatureIsValid(p256KeyOf(quote.attestationKey), caEs256,
                        quote.signedBytes, quote.quoteSignature)

proc verifyQeReportSignature*(quote: TdxQuote;
                              pckPoint: openArray[byte]): bool =
  ## Whether the quoting enclave's report verifies under `pckPoint`, the
  ## uncompressed P-256 point out of the provisioning certification
  ## key's certificate.
  ##
  ## Returns `false` for a malformed point as well as for a wrong
  ## signature, because no caller has a different answer for the two.
  ## The key is built here, from certificate bytes, and handed to
  ## `cose`'s primitive — deliberately the caller-built-key path, which
  ## is the only way a point of a width this library did not choose
  ## reaches the curve. The gate hands it every wrong width there is.
  var key = CoseKey(curve: ccP256, point: @[])
  for b in pckPoint: key.point.add b
  ecdsaSignatureIsValid(key, caEs256, quote.qeReport.raw,
                        quote.qeReportSignature)

type
  TdxBindingOutcome* = enum
    tboBound
    tboReportDataDisagrees
    tboReportDataTailNotZero

  TdxBindingVerdict* = object
    outcome*: TdxBindingOutcome
    detail*: string
    computedHex*: string

proc isBound*(v: TdxBindingVerdict): bool = v.outcome == tboBound

proc hexOf*(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc qeReportBindsAttestationKey*(quote: TdxQuote): TdxBindingVerdict =
  ## Whether the quoting enclave's report is *about* this quote's
  ## attestation key.
  ##
  ## The rule is `SHA-256(attestation key ‖ authentication data)` in the
  ## first 32 bytes of the report data. The digest is recomputed here
  ## from the quote's own two fields and never read back out of the
  ## report, so the comparison has two independent sides.
  ##
  ## The remaining 32 bytes are required to be zero. They are inside the
  ## signed report, so they are not a channel an attacker can spend
  ## without breaking the quoting enclave's signature — but a report
  ## whose unused half carries something is a report this build does not
  ## understand, and understanding it later is not something a verifier
  ## gets to defer.
  var preimage = quote.attestationKey
  for b in quote.qeAuthenticationData: preimage.add b
  let digest = sha256Bytes(preimage)
  result.computedHex = hexOf(digest)
  let inReport = quote.qeReport.reportData
  var agrees = true
  for i in 0 ..< digest.len:
    if inReport[i] != digest[i]: agrees = false
  if not agrees:
    result.outcome = tboReportDataDisagrees
    result.detail = "the quoting enclave's report binds " &
      hexOf(inReport[0 ..< digest.len]) & " and this quote's " &
      "attestation key and authentication data digest to " &
      result.computedHex & "; the report and the key it is supposed to " &
      "be about do not go together"
    return
  for i in digest.len ..< inReport.len:
    if inReport[i] != 0'u8:
      result.outcome = tboReportDataTailNotZero
      result.detail = "byte " & $i & " of the quoting enclave's report " &
        "data is 0x" & toHex(int(inReport[i]), 2) & ", and only the " &
        "first " & $digest.len & " carry the binding this build reads"
      return
  result.outcome = tboBound
  result.detail = "the quoting enclave's report data is the digest of " &
    "this quote's own attestation key and authentication data (" &
    result.computedHex & ")"
