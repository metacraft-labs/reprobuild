## The AMD SEV-SNP attestation report: its structure, and the one
## public-key operation that says a chip produced it.
##
## ## The document
##
## A report is exactly 1,184 bytes (`0x4A0`). The first `0x2A0` bytes are
## the ones the chip signs; the remaining 512 carry the signature. The
## layout below is the `ATTESTATION_REPORT` table of AMD's *SEV Secure
## Nested Paging Firmware ABI Specification* (publication 56860), and
## every offset in it is asserted against real reports by the gate rather
## than trusted from the transcription.
##
## ## Why the reader is this strict
##
## A report arrives from the machine being judged. Four rules here exist
## because a lenient reader turns each of them into something an attacker
## can spend:
##
##   * **the signature's high bytes.** The signature field holds `R` and
##     `S` as 72-byte LITTLE-endian quantities, and a P-384 scalar is 48
##     bytes. The 24 bytes above each scalar are therefore padding that
##     must be zero. A reader that simply takes the low 48 bytes accepts
##     an unbounded family of distinct byte strings as one signature,
##     which is a malleability an audit log cannot see through.
##   * **the signature's tail.** Only 144 of the 512 signature bytes are
##     used. The other 368 are covered by nothing at all — not by the
##     ECDSA verification, which reads two scalars, and not by the signed
##     prefix, which stops at `0x2A0`. Left unchecked they are a covert
##     channel of 368 bytes inside a document that verifies.
##   * **the reserved fields.** Same argument, inside the signed region:
##     they cannot be changed without breaking the signature, so they are
##     not an attacker's channel — but a report whose reserved bytes are
##     not zero is a report this build does not understand, and
##     understanding it later is not something a verifier gets to defer.
##   * **the signature algorithm.** `SIGNATURE_ALGO` is a number the
##     report chooses. This build implements one algorithm, so it refuses
##     every other value by name instead of verifying under whatever it
##     happens to support.
##
## ## The public-key operation is NOT implemented here
##
## `verifyReportSignature` assembles `I2OSP(R,48) ‖ I2OSP(S,48)` and
## hands it to `repro_attest/cose`'s `ecdsaSignatureIsValid` with
## `ES384` and a `P-384` key. That module owns the single ECDSA
## primitive in this tree and it is exercised here through its
## caller-built-key path — the key comes out of a VCEK certificate, never
## out of a `COSE_Key` map — which is the path its own documentation
## says is the only way to reach the raw point with a width this library
## did not choose. Widening that path is why this module does not have
## a second ECDSA implementation of its own.
##
## ## Mocking
##
## None. Real reports from real chips, real P-384 verification.

import std/[strutils]

import repro_attest/cose

type
  SnpReportErrorKind* = enum
    ## One kind per rule. The messages below satisfy the property
    ## `snpReportMessagesAreDistinguishable` states and checks: **no
    ## message is a substring of any other**. A test that matches on a
    ## fragment of one refusal therefore cannot be satisfied by a
    ## different refusal, which is the shape that has passed review in
    ## this tree eleven times.
    sreWrongLength
    sreUnsupportedVersion
    sreUnsupportedSignatureAlgorithm
    sreReservedFieldNotZero
    sreSignatureScalarTooWide
    sreSignatureTailNotZero
    sreUnsupportedTcbLayout

  SnpReportError* = object of CatchableError
    kind*: SnpReportErrorKind

const
  SnpReportMessage*: array[SnpReportErrorKind, string] = [
    sreWrongLength:
      "an attestation report is a fixed-width document and this one is " &
      "not that width",
    sreUnsupportedVersion:
      "the report states a structure revision this build has no layout for",
    sreUnsupportedSignatureAlgorithm:
      "the report names a signing algorithm other than the one this build " &
      "verifies",
    sreReservedFieldNotZero:
      "a span the specification reserves carries something, so this " &
      "document is not the one whose fields are being read",
    sreSignatureScalarTooWide:
      "a signature scalar occupies more bytes than its curve has room for",
    sreSignatureTailNotZero:
      "the unused remainder of the signature field is not blank, and " &
      "nothing else in the document covers those bytes",
    sreUnsupportedTcbLayout:
      "the platform generation packs its version components in an order " &
      "this build does not read"]

proc snpReportMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked, not asserted: this is
  ## the property that makes a `in e.msg` assertion mean one rule.
  for a in SnpReportErrorKind:
    for b in SnpReportErrorKind:
      if a == b: continue
      if SnpReportMessage[a] in SnpReportMessage[b]: return false
  true

proc snpFail*(kind: SnpReportErrorKind; detail: string) {.noreturn.} =
  var e = newException(SnpReportError, SnpReportMessage[kind])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.kind = kind
  raise e

# ---------------------------------------------------------------------
# The layout
# ---------------------------------------------------------------------

const
  SnpReportLen* = 0x4A0          ## 1,184 bytes.
  SnpSignedPrefixLen* = 0x2A0    ## What the chip signs: bytes 0 .. 0x29F.
  SnpSignatureOffset* = 0x2A0
  SnpSignatureLen* = 512

  SnpScalarFieldLen* = 72
    ## The width the report gives each of `R` and `S`, little-endian.
  SnpP384ScalarLen* = 48
    ## The width a P-384 scalar actually occupies. The 24-byte
    ## difference is the padding rule above.

  OffVersion* = 0x000
  OffGuestSvn* = 0x004
  OffPolicy* = 0x008
  OffFamilyId* = 0x010
  OffImageId* = 0x020
  OffVmpl* = 0x030
  OffSignatureAlgo* = 0x034
  OffCurrentTcb* = 0x038
  OffPlatformInfo* = 0x040
  OffKeyInfo* = 0x048
  OffReserved04C* = 0x04C
  OffReportData* = 0x050
  OffMeasurement* = 0x090
  OffHostData* = 0x0C0
  OffIdKeyDigest* = 0x0E0
  OffAuthorKeyDigest* = 0x110
  OffReportId* = 0x140
  OffReportIdMa* = 0x160
  OffReportedTcb* = 0x180
  OffReserved188* = 0x188
  OffChipId* = 0x1A0
  OffCommittedTcb* = 0x1E0
  OffCurrentBuild* = 0x1E8
  OffCommittedBuild* = 0x1EC
  OffLaunchTcb* = 0x1F0
  OffReserved1F8* = 0x1F8

  LenFamilyId* = 16
  LenReportData* = 64
  LenMeasurement* = 48
  LenHostData* = 32
  LenKeyDigest* = 48
  LenReportId* = 32
  LenChipId* = 64

  SnpSupportedVersions* = [2'u32, 3'u32]
    ## Version 2 is the Milan/Genoa report; version 3 adds three CPUID
    ## bytes at `0x188` and is otherwise identical. Both are read; the
    ## difference is confined to which bytes of the `0x188` span are
    ## required to be zero.

  SnpSignatureAlgoEcdsaP384Sha384* = 1'u32
    ## The only `SIGNATURE_ALGO` this build verifies.

  SnpReservedSpans*: array[3, tuple[start, stop: int]] = [
    (OffReserved04C, OffReportData),
    (OffReserved188, OffChipId),
    (OffReserved1F8, SnpSignatureOffset)]
    ## Every reserved span inside the SIGNED prefix, as half-open
    ## `[start, stop)` ranges. Declared as data rather than as three
    ## hand-written `if`s so the gate can walk the same list the checker
    ## walks; a span added here is a span checked, and a gate case counts
    ## them so a span cannot be quietly dropped.

type
  SnpTcbVersion* = object
    ## `TCB_VERSION`, the four security-patch levels that say which
    ## firmware the platform is running.
    bootloader*: int
    tee*: int
    snp*: int
    microcode*: int
    raw*: uint64

  SnpSigningKeyKind* = enum
    skkVcek = "VCEK"
    skkVlek = "VLEK"
    skkNone = "none"

  SnpReport* = object
    raw*: seq[byte]
    signedBytes*: seq[byte]
      ## Bytes 0 .. 0x29F, lifted verbatim. Never re-serialised: a
      ## verifier that checks a signature against its own re-encoding of
      ## a document is checking its decoder, not the document.
    version*: uint32
    guestSvn*: uint32
    policy*: uint64
    familyId*, imageId*: seq[byte]
    vmpl*: uint32
    signatureAlgo*: uint32
    currentTcb*, reportedTcb*, committedTcb*, launchTcb*: SnpTcbVersion
    platformInfo*: uint64
    signingKey*: SnpSigningKeyKind
    authorKeyEnabled*: bool
    maskChipKey*: bool
    reportData*: seq[byte]
    measurement*: seq[byte]
    hostData*: seq[byte]
    idKeyDigest*, authorKeyDigest*: seq[byte]
    reportId*, reportIdMa*: seq[byte]
    chipId*: seq[byte]
    currentFirmware*, committedFirmware*: tuple[major, minor, build: int]
    signatureR*, signatureS*: seq[byte]
      ## 48 bytes each, BIG-endian — i.e. `I2OSP(R, 48)`, the form
      ## RFC 9053 §2.1 wants — reversed out of the report's
      ## little-endian 72-byte fields here, once.

proc le32(b: openArray[byte]; at: int): uint32 =
  uint32(b[at]) or (uint32(b[at + 1]) shl 8) or
    (uint32(b[at + 2]) shl 16) or (uint32(b[at + 3]) shl 24)

proc le64(b: openArray[byte]; at: int): uint64 =
  var v = 0'u64
  for i in countdown(7, 0):
    v = (v shl 8) or uint64(b[at + i])
  v

proc bytesAt(b: openArray[byte]; at, n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = b[at + i]

proc parseTcbVersion*(raw: uint64): SnpTcbVersion =
  ## The Milan/Genoa packing: bootloader, tee, four reserved bytes, snp,
  ## microcode — least significant byte first.
  ##
  ## Turin repacks this field (a firmware-microcode component moves into
  ## byte 0), so a Turin report read under this layout would report four
  ## numbers that are not the ones it stated. `parseSnpReport` refuses
  ## rather than guesses; see `sreUnsupportedTcbLayout`.
  result.raw = raw
  result.bootloader = int(raw and 0xff'u64)
  result.tee = int((raw shr 8) and 0xff'u64)
  result.snp = int((raw shr 48) and 0xff'u64)
  result.microcode = int((raw shr 56) and 0xff'u64)

proc tcbReservedBytes*(raw: uint64): uint32 =
  ## Bytes 2 .. 5 of a `TCB_VERSION`, which the Milan/Genoa layout
  ## reserves. Non-zero here is the observable difference between that
  ## layout and Turin's, and it is what `sreUnsupportedTcbLayout` fires
  ## on — rather than on a product name, which lives in a certificate
  ## this function has never seen.
  uint32((raw shr 16) and 0xffff_ffff'u64)

proc `$`*(t: SnpTcbVersion): string =
  "bootloader " & $t.bootloader & ", tee " & $t.tee & ", snp " & $t.snp &
    ", microcode " & $t.microcode

proc parseSnpReport*(raw: openArray[byte]): SnpReport =
  if raw.len != SnpReportLen:
    snpFail(sreWrongLength, $raw.len & " bytes against " & $SnpReportLen)
  result.raw = bytesAt(raw, 0, raw.len)
  result.signedBytes = bytesAt(raw, 0, SnpSignedPrefixLen)

  result.version = le32(raw, OffVersion)
  var versionKnown = false
  for v in SnpSupportedVersions:
    if result.version == v: versionKnown = true
  if not versionKnown:
    snpFail(sreUnsupportedVersion, "version " & $result.version)

  result.signatureAlgo = le32(raw, OffSignatureAlgo)
  if result.signatureAlgo != SnpSignatureAlgoEcdsaP384Sha384:
    snpFail(sreUnsupportedSignatureAlgorithm,
      "SIGNATURE_ALGO " & $result.signatureAlgo & "; this build verifies " &
      $SnpSignatureAlgoEcdsaP384Sha384 & " (ECDSA P-384 with SHA-384)")

  # Reserved spans, inside the signed prefix. A version-3 report puts
  # three CPUID bytes at the head of the 0x188 span, so that span starts
  # three bytes later for it; nothing else moves.
  for span in SnpReservedSpans:
    var start = span.start
    if result.version >= 3'u32 and span.start == OffReserved188:
      start = OffReserved188 + 3
    for i in start ..< span.stop:
      if raw[i] != 0'u8:
        snpFail(sreReservedFieldNotZero,
          "byte 0x" & toHex(i, 3) & " of the span 0x" & toHex(start, 3) &
          "-0x" & toHex(span.stop, 3) & " is 0x" & toHex(int(raw[i]), 2))

  result.guestSvn = le32(raw, OffGuestSvn)
  result.policy = le64(raw, OffPolicy)
  result.familyId = bytesAt(raw, OffFamilyId, LenFamilyId)
  result.imageId = bytesAt(raw, OffImageId, LenFamilyId)
  result.vmpl = le32(raw, OffVmpl)
  result.platformInfo = le64(raw, OffPlatformInfo)

  let keyInfo = le32(raw, OffKeyInfo)
  result.authorKeyEnabled = (keyInfo and 1'u32) != 0
  result.maskChipKey = (keyInfo and 2'u32) != 0
  result.signingKey =
    case int((keyInfo shr 2) and 0x7'u32)
    of 0: skkVcek
    of 1: skkVlek
    else: skkNone

  result.reportData = bytesAt(raw, OffReportData, LenReportData)
  result.measurement = bytesAt(raw, OffMeasurement, LenMeasurement)
  result.hostData = bytesAt(raw, OffHostData, LenHostData)
  result.idKeyDigest = bytesAt(raw, OffIdKeyDigest, LenKeyDigest)
  result.authorKeyDigest = bytesAt(raw, OffAuthorKeyDigest, LenKeyDigest)
  result.reportId = bytesAt(raw, OffReportId, LenReportId)
  result.reportIdMa = bytesAt(raw, OffReportIdMa, LenReportId)
  result.chipId = bytesAt(raw, OffChipId, LenChipId)

  for at in [OffCurrentTcb, OffReportedTcb, OffCommittedTcb, OffLaunchTcb]:
    let v = le64(raw, at)
    if tcbReservedBytes(v) != 0'u32:
      snpFail(sreUnsupportedTcbLayout,
        "the version field at 0x" & toHex(at, 3) & " carries 0x" &
        toHex(int(tcbReservedBytes(v)), 8) & " where this layout reserves " &
        "four zero bytes")
  result.currentTcb = parseTcbVersion(le64(raw, OffCurrentTcb))
  result.reportedTcb = parseTcbVersion(le64(raw, OffReportedTcb))
  result.committedTcb = parseTcbVersion(le64(raw, OffCommittedTcb))
  result.launchTcb = parseTcbVersion(le64(raw, OffLaunchTcb))

  result.currentFirmware = (major: int(raw[OffCurrentBuild + 2]),
                            minor: int(raw[OffCurrentBuild + 1]),
                            build: int(raw[OffCurrentBuild]))
  result.committedFirmware = (major: int(raw[OffCommittedBuild + 2]),
                              minor: int(raw[OffCommittedBuild + 1]),
                              build: int(raw[OffCommittedBuild]))

  # The signature. Two rules, and they refuse different things.
  for half in 0 .. 1:
    let base = SnpSignatureOffset + half * SnpScalarFieldLen
    for i in SnpP384ScalarLen ..< SnpScalarFieldLen:
      if raw[base + i] != 0'u8:
        snpFail(sreSignatureScalarTooWide,
          (if half == 0: "R" else: "S") & " carries 0x" &
          toHex(int(raw[base + i]), 2) & " at byte " & $i &
          " of its " & $SnpScalarFieldLen & "-byte field, and a P-384 " &
          "scalar ends at byte " & $SnpP384ScalarLen)
  for i in SnpSignatureOffset + 2 * SnpScalarFieldLen ..<
           SnpSignatureOffset + SnpSignatureLen:
    if raw[i] != 0'u8:
      snpFail(sreSignatureTailNotZero,
        "byte 0x" & toHex(i, 3) & " is 0x" & toHex(int(raw[i]), 2))

  # Little-endian in the document, big-endian to the curve. Reversed
  # once, here, so nothing downstream has a second opinion about which
  # way round a scalar is.
  result.signatureR = newSeq[byte](SnpP384ScalarLen)
  result.signatureS = newSeq[byte](SnpP384ScalarLen)
  for i in 0 ..< SnpP384ScalarLen:
    result.signatureR[SnpP384ScalarLen - 1 - i] =
      raw[SnpSignatureOffset + i]
    result.signatureS[SnpP384ScalarLen - 1 - i] =
      raw[SnpSignatureOffset + SnpScalarFieldLen + i]

# ---------------------------------------------------------------------
# The one public-key operation
# ---------------------------------------------------------------------

const
  SnpP384PointLen* = 1 + 2 * SnpP384ScalarLen
    ## `0x04 ‖ X(48) ‖ Y(48)`.

proc verifyReportSignature*(report: SnpReport;
                            vcekPoint: openArray[byte]): bool =
  ## Whether this report's signature verifies under `vcekPoint`, the
  ## uncompressed P-384 point out of an endorsement certificate.
  ##
  ## Returns `false` for a malformed point as well as for a wrong
  ## signature, because no caller has a different answer for the two and
  ## the alternative is a second failure channel to forget about.
  ##
  ## The key is built HERE, from certificate bytes, and handed to
  ## `cose`'s primitive. That is deliberately the caller-built-key path:
  ## a `CoseKey` that never went through `parseCoseKey` is the only way
  ## a point of the wrong width reaches the curve implementation, and a
  ## build in which that path stopped checking the width would be a build
  ## in which this call reads past the end of a buffer. The gate hands it
  ## every wrong width there is.
  var key = CoseKey(curve: ccP384, point: @[])
  for b in vcekPoint: key.point.add b
  var sig = report.signatureR
  for b in report.signatureS: sig.add b
  ecdsaSignatureIsValid(key, caEs384, report.signedBytes, sig)
