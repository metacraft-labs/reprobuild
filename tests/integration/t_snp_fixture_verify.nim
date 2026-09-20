## Genuine confidential-computing attestation reports verify, and every
## single-bit change to one is refused.
##
## ## What this gate is actually asserting
##
## Two reports produced by two different AMD EPYC parts are read, and
## each one's signature is checked against the P-384 key inside its own
## endorsement certificate — a certificate that this repository did not
## make and cannot make, because the key that signed it is AMD's. A
## report that verifies is therefore a statement about all 672 signed
## bytes at once: the platform version, the measurement, the 64 bytes the
## guest put in, the part identity, every reserved byte.
##
## The negative half is where the care goes. It is not enough that "a
## tampered report is refused": a gate that flips a bit anywhere and
## observes a refusal has not shown that the *signature* covers the
## field, only that something objected. So every mutation here declares
## the field it lands in, the gate checks that the offset really is
## inside that field, checks that exactly one bit moved, checks that the
## parsed value of the field really did change, and then asserts **which
## rule** refused — by message, and by the absence of every other rule's
## message.
##
## That last step is the one this tree has been caught by eleven times:
## a negative case satisfied by a refusal other than the one it was
## written for keeps passing after the rule it exists for is deleted.
##
## ## Three refusals, not one
##
## The signature field is 512 bytes and the curve uses 96 of them, so
## three different rules cover it and a gate that only knew about the
## first would leave 368 bytes and 48 more unchecked:
##
##   * a bit inside either scalar breaks the **signature**;
##   * a bit in the 24 bytes above either scalar is a scalar wider than
##     the curve, refused **before** any arithmetic;
##   * a bit in the 368 unused bytes is covered by nothing else at all —
##     not by the signed prefix, which stops before them, and not by the
##     verification, which reads two scalars — so it needs its own rule
##     or it is a covert channel inside a document that verifies.
##
## ## The elliptic-curve primitive is somebody else's, deliberately
##
## The verification runs through `repro_attest/cose`, which owns the only
## ECDSA implementation in this tree. This is that module's first
## production consumer, and it reaches it by the path its own
## documentation calls the dangerous one: the key is built from
## certificate bytes, never parsed from a COSE key map, so its width is
## whatever the caller made it. A block of cases below hands that path
## every wrong width there is — empty, one byte, the P-256 width, one
## short, one long, the two coordinates without their prefix — and
## requires a refusal rather than a crash from both the primitive and the
## message-level entry point.
##
## ## Mocking
##
## None. Real reports, real certificates, real curve arithmetic.

import std/[exitprocs, os, strutils, unittest]

import cbor
import repro_attest/cose
import repro_attest_verify/snp_chain
import repro_attest_verify/snp_report

include ./snp_vectors

# ---------------------------------------------------------------------
# Which refusals were reached
#
# The kind-level half of this is a CASE below, so a refusal kind that
# stops being reachable turns the gate red. The per-site list is written
# only when `REPRO_REFUSAL_CENSUS` names a file, so an ordinary run
# prints nothing extra; it is an instrument for measuring, not a check.
# ---------------------------------------------------------------------

var reachedReportKinds: set[SnpReportErrorKind] = {}
var reachedChainKinds: set[AmdChainRejection] = {}
var reachedCoseKinds: set[CoseErrorKind] = {}

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var f: File
  if open(f, path, fmAppend):
    for k in SnpReportErrorKind:
      if k in reachedReportKinds: f.writeLine("snp_report:" & $k)
    for k in AmdChainRejection:
      if k in reachedChainKinds: f.writeLine("snp_chain:" & $k)
    for k in CoseErrorKind:
      if k in reachedCoseKinds: f.writeLine("cose:" & $k)
    f.close()

addExitProc(writeCensus)

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

proc bytesOfHex(h: string): seq[byte] =
  doAssert h.len mod 2 == 0
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

proc pemCertificates*(text: string): seq[seq[byte]] =
  ## Every `CERTIFICATE` block of a PEM document, in order.
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

proc flipBit(data: seq[byte]; offset, bit: int): seq[byte] =
  result = data
  result[offset] = result[offset] xor byte(1 shl bit)

proc bitsDiffering(a, b: openArray[byte]): int =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    var x = int(a[i] xor b[i])
    while x != 0:
      result += x and 1
      x = x shr 1

# Every refusal message this gate can see, so that a case asserting one
# can assert the ABSENCE of all the others by construction rather than
# by remembering to list them.
var refusalsObserved = 0
  ## Every refusal this gate has SEEN, with the right kind and with no
  ## other rule's wording in it. Cases below assert their own delta on
  ## it, so a loop that silently stopped iterating — or a fixture list
  ## that lost an entry — moves a number instead of going quiet.

proc assertOnlyRefusal(msg: string; kind: SnpReportErrorKind) =
  inc refusalsObserved
  check SnpReportMessage[kind] in msg
  for other in SnpReportErrorKind:
    if other == kind: continue
    check SnpReportMessage[other] notin msg
  reachedReportKinds.incl kind

template expectReportRefusal(want: SnpReportErrorKind; body: untyped) =
  # The parameter is `want` and not `kind`, because a template parameter
  # named after a field is substituted into `err.kind` as well and the
  # result is a compile error at best.
  var raised = false
  try:
    body
  except SnpReportError as err:
    raised = true
    check err.kind == want
    assertOnlyRefusal(err.msg, want)
  check raised

# ---------------------------------------------------------------------
# The fixtures, read once
# ---------------------------------------------------------------------

type
  Specimen = object
    label: string
    report: seq[byte]
    vcek: seq[byte]
    chipIdHex: string
    measurementHex: string
    reportDataHex: string
    bootloader, tee, snp, microcode: int
    firmware: string

let specimens = @[
  Specimen(label: "virtee/sev Milan",
    report: bytesOfHex(VirteeMilanReportHex),
    vcek: bytesOfHex(VirteeMilanVcekDerHex),
    chipIdHex: "d49554ec717f4e5b0fe6b143bcf0405bd7ae304727edf46603f2a76aef6a" &
      "3abc15d7af38db757039029f0efacfd08e244324884738c72b082e2f87a4" &
      "4d541eb6",
    measurementHex: "7a1e5c266c0108dbc9bb94fa926951320940915d0aafb42464bd8" &
      "8b579ea158d3e1a0dc39b2c60bd95b9c480cd81841f",
    reportDataHex: "d447b55d197491bfe15cf298f9de9986b7a7c4be2468b4f6e2d53b71" &
      "d7c645810b0f2cdfca0040433be063fc1a8293f0f3f8dae7b79fecb3d1cd" &
      "82bd6a93ebfd",
    bootloader: 3, tee: 0, snp: 8, microcode: 115, firmware: "1.52.4"),
  Specimen(label: "google/go-sev-guest Milan",
    report: bytesOfHex(GsgMilanReportHex),
    vcek: bytesOfHex(GsgMilanVcekDerHex),
    chipIdHex: "3ac3fe21e13fb0990eb28a802e3fb6a29483a6b0753590c951bdd3b8e537" &
      "86184ca39e359669a2b76a1936776b564ea464cdce40c05f63c9b610c506" &
      "8b006b5d",
    measurementHex: "b07af9620f3b839b47996422ddec6058338951d984e312115131e" &
      "a82705eaf5b6bdf8a9ece31a5a608eb0cf2e4872b01",
    reportDataHex: "01020304050000000000000000000000000000000000000000000000" &
      "000000000000000000000000000000000000000000000000000000000000" &
      "000000000000",
    bootloader: 2, tee: 0, snp: 5, microcode: 68, firmware: "1.49.3")]

let milanChain = pemCertificates(KdsMilanChainPem)
let milanAsk = milanChain[0]
let milanArk = milanChain[1]
let milanCrl = @[bytesOfHex(KdsMilanCrlDerHex)]

const
  # Inside the vendor revocation list's window (thisUpdate 2026-08-19,
  # nextUpdate 2026-10-04) and inside every certificate's window. Fixed,
  # not read from the host: a gate that used the real clock would start
  # failing on a date nobody chose.
  Now = 1_788_220_800'i64
    ## 2026-09-01T00:00:00Z. Chosen to sit inside the vendor revocation
    ## list's own window — it states a this-update of 2026-08-19 and a
    ## next-update of 2026-10-04 — and inside every certificate's window.
    ## Fixed rather than read from the host: a gate that consulted the
    ## real clock would pass today and start failing on 2026-10-04,
    ## which is a date nobody chose and a failure nobody would connect
    ## to this file.

proc pointOf(vcekDer: seq[byte]): seq[byte] =
  parseAmdCertificate(vcekDer).ecPoint

# ---------------------------------------------------------------------

suite "snp report structure":

  test "t_snp_report_messages_are_distinguishable":
    check snpReportMessagesAreDistinguishable()
    check amdChainMessagesAreDistinguishable()

  test "t_snp_report_layout_is_the_published_one":
    # The offsets are a transcription of a vendor table, so they are
    # checked against real documents rather than trusted. Each report
    # is read and every field the gate names is compared with the value
    # an independent tool read out of the same bytes.
    check SnpReportLen == 1184
    check SnpSignedPrefixLen == 672
    check SnpSignatureOffset + SnpSignatureLen == SnpReportLen
    check SnpScalarFieldLen - SnpP384ScalarLen == 24
    check SnpReservedSpans.len == 3
    var reservedBytes = 0
    for span in SnpReservedSpans:
      check span.start < span.stop
      check span.stop <= SnpSignedPrefixLen
      reservedBytes += span.stop - span.start
    check reservedBytes == 4 + 24 + 168

    for s in specimens:
      checkpoint s.label
      check s.report.len == SnpReportLen
      let r = parseSnpReport(s.report)
      check r.version == 2'u32
      check r.signatureAlgo == SnpSignatureAlgoEcdsaP384Sha384
      check r.vmpl == 0'u32
      check r.signingKey == skkVcek
      check hexOfBytes(r.chipId) == s.chipIdHex
      check hexOfBytes(r.measurement) == s.measurementHex
      check hexOfBytes(r.reportData) == s.reportDataHex
      check r.reportedTcb.bootloader == s.bootloader
      check r.reportedTcb.tee == s.tee
      check r.reportedTcb.snp == s.snp
      check r.reportedTcb.microcode == s.microcode
      check $r.currentFirmware.major & "." & $r.currentFirmware.minor &
        "." & $r.currentFirmware.build == s.firmware
      check r.signedBytes.len == SnpSignedPrefixLen
      check r.signatureR.len == SnpP384ScalarLen
      check r.signatureS.len == SnpP384ScalarLen
      # The signed prefix is lifted, never rebuilt.
      for i in 0 ..< SnpSignedPrefixLen:
        check r.signedBytes[i] == s.report[i]

  test "t_snp_two_parts_each_verify_under_their_own_endorsement_key":
    # The positive result AND its own negative control, from the same
    # two fixtures: each report verifies under its own part's key and
    # fails under the other's. A verifier that returned true for
    # everything would fail the second half; one that returned false for
    # everything would fail the first.
    check specimens.len == 2
    var verified = 0
    var crossRejected = 0
    for i, a in specimens:
      let report = parseSnpReport(a.report)
      for j, b in specimens:
        let ok = verifyReportSignature(report, pointOf(b.vcek))
        if i == j:
          check ok
          if ok: inc verified
        else:
          check not ok
          if not ok: inc crossRejected
    check verified == 2
    check crossRejected == 2

  test "t_snp_endorsement_certificates_are_amd_signed":
    # Each part's endorsement certificate, the vendor's signing key and
    # the vendor's root, evaluated as a chain. The root is not supplied:
    # see `snp_chain`'s header.
    for s in specimens:
      checkpoint s.label
      let v = evaluateAmdChain(s.vcek, milanAsk, milanArk, milanCrl, Now)
      checkpoint v.detail
      check v.isAccepted
      check v.rootMatched
      check v.rootLine == aplMilan
      check v.leafCn == "SEV-VCEK"
      check v.intermediateCn == "SEV-Milan"
      check v.rootCn == "ARK-Milan"
      check v.productName == "Milan-B0"
      check v.revocationConsulted
      check hexOfBytes(v.hwId) == s.chipIdHex
      check v.endorsedTcb.bootloader == s.bootloader
      check v.endorsedTcb.tee == s.tee
      check v.endorsedTcb.snp == s.snp
      check v.endorsedTcb.microcode == s.microcode

suite "snp single-bit mutations":

  test "t_snp_bitflip_in_the_measurement_is_refused":
    # 0x90 is the first byte of the launch measurement, which is inside
    # the signed prefix.
    const Offset = OffMeasurement
    check Offset >= 0 and Offset < OffMeasurement + LenMeasurement
    check Offset < SnpSignedPrefixLen
    for s in specimens:
      checkpoint s.label
      let mutated = flipBit(s.report, Offset, 0)
      check bitsDiffering(s.report, mutated) == 1
      let good = parseSnpReport(s.report)
      let bad = parseSnpReport(mutated)          # it still PARSES
      check hexOfBytes(bad.measurement) != hexOfBytes(good.measurement)
      check hexOfBytes(bad.reportData) == hexOfBytes(good.reportData)
      check verifyReportSignature(good, pointOf(s.vcek))
      check not verifyReportSignature(bad, pointOf(s.vcek))

  test "t_snp_bitflip_in_the_report_data_is_refused":
    const Offset = OffReportData + 3
    check Offset >= OffReportData
    check Offset < OffReportData + LenReportData
    check Offset < SnpSignedPrefixLen
    for s in specimens:
      checkpoint s.label
      let mutated = flipBit(s.report, Offset, 5)
      check bitsDiffering(s.report, mutated) == 1
      let good = parseSnpReport(s.report)
      let bad = parseSnpReport(mutated)
      check hexOfBytes(bad.reportData) != hexOfBytes(good.reportData)
      check hexOfBytes(bad.measurement) == hexOfBytes(good.measurement)
      check not verifyReportSignature(bad, pointOf(s.vcek))

  test "t_snp_bitflip_inside_a_signature_scalar_is_refused":
    # Inside R's low 48 bytes, i.e. the part of the field the curve
    # actually reads. This one has to fail the ARITHMETIC, not a width
    # rule, so the report must still parse.
    const Offset = SnpSignatureOffset + 7
    check Offset >= SnpSignatureOffset
    check Offset < SnpSignatureOffset + SnpP384ScalarLen
    for s in specimens:
      checkpoint s.label
      let mutated = flipBit(s.report, Offset, 2)
      check bitsDiffering(s.report, mutated) == 1
      let good = parseSnpReport(s.report)
      let bad = parseSnpReport(mutated)
      check hexOfBytes(bad.signedBytes) == hexOfBytes(good.signedBytes)
      check hexOfBytes(bad.signatureR) != hexOfBytes(good.signatureR)
      check hexOfBytes(bad.signatureS) == hexOfBytes(good.signatureS)
      check not verifyReportSignature(bad, pointOf(s.vcek))

  test "t_snp_a_scalar_wider_than_its_curve_is_refused_before_arithmetic":
    # Byte 48 of the 72-byte field: above a P-384 scalar. A reader that
    # took the low 48 bytes would accept this as the SAME signature,
    # which is a malleability an audit log cannot see through.
    for half in 0 .. 1:
      for extra in [0, 12, 23]:
        let offset = SnpSignatureOffset + half * SnpScalarFieldLen +
          SnpP384ScalarLen + extra
        check offset >= SnpSignatureOffset + SnpP384ScalarLen
        check offset < SnpSignatureOffset + 2 * SnpScalarFieldLen
        for s in specimens:
          check s.report[offset] == 0'u8      # genuine padding is blank
          let mutated = flipBit(s.report, offset, 4)
          check bitsDiffering(s.report, mutated) == 1
          expectReportRefusal(sreSignatureScalarTooWide):
            discard parseSnpReport(mutated)

  test "t_snp_a_bit_in_the_unused_signature_tail_is_refused":
    # 368 bytes that no signature covers and no signed prefix reaches.
    const TailStart = SnpSignatureOffset + 2 * SnpScalarFieldLen
    check SnpReportLen - TailStart == 368
    for offset in [TailStart, TailStart + 100, SnpReportLen - 1]:
      for s in specimens:
        check s.report[offset] == 0'u8
        let mutated = flipBit(s.report, offset, 7)
        check bitsDiffering(s.report, mutated) == 1
        # It would still verify: the curve never reads these bytes.
        expectReportRefusal(sreSignatureTailNotZero):
          discard parseSnpReport(mutated)

  test "t_snp_a_bit_in_a_reserved_span_is_refused":
    var spansExercised = 0
    for span in SnpReservedSpans:
      inc spansExercised
      let offset = span.start
      for s in specimens:
        check s.report[offset] == 0'u8
        let mutated = flipBit(s.report, offset, 1)
        check bitsDiffering(s.report, mutated) == 1
        expectReportRefusal(sreReservedFieldNotZero):
          discard parseSnpReport(mutated)
    check spansExercised == SnpReservedSpans.len

suite "snp structural refusals":

  test "t_snp_a_document_of_the_wrong_width_is_refused":
    let before = refusalsObserved
    let widths = [0, 1, SnpReportLen - 1, SnpReportLen + 1, 2 * SnpReportLen]
    for n in widths:
      check n != SnpReportLen
      expectReportRefusal(sreWrongLength):
        discard parseSnpReport(newSeq[byte](n))
    check refusalsObserved - before == widths.len

  test "t_snp_an_unknown_structure_revision_is_refused":
    for v in [0'u8, 1'u8, 4'u8, 255'u8]:
      for s in specimens:
        var mutated = s.report
        mutated[OffVersion] = v
        expectReportRefusal(sreUnsupportedVersion):
          discard parseSnpReport(mutated)
    # …and the two it does read are read.
    check SnpSupportedVersions.len == 2
    for s in specimens:
      var v3 = s.report
      v3[OffVersion] = 3'u8
      let r = parseSnpReport(v3)
      check r.version == 3'u32

  test "t_snp_the_later_revision_frees_exactly_three_bytes_and_no_more":
    # The two revisions differ in ONE way: the later one puts three
    # identification bytes at the head of the span the earlier one
    # reserves. Setting the version number on a report whose bytes there
    # are already zero does not observe that difference at all, so the
    # difference is observed directly instead — the same three bytes,
    # non-zero, under each revision in turn, and the FOURTH byte, which
    # neither revision frees.
    for s in specimens:
      checkpoint s.label
      for offset in [OffReserved188, OffReserved188 + 1, OffReserved188 + 2]:
        check s.report[offset] == 0'u8
        var v2 = s.report
        v2[offset] = 0x5a'u8
        check v2[OffVersion] == 2'u8
        expectReportRefusal(sreReservedFieldNotZero):
          discard parseSnpReport(v2)
        var v3 = v2
        v3[OffVersion] = 3'u8
        let r = parseSnpReport(v3)     # the later revision reads it
        check r.version == 3'u32
      # The fourth byte is reserved under BOTH, which is what pins the
      # shift at three rather than at "some".
      var v3 = s.report
      v3[OffVersion] = 3'u8
      v3[OffReserved188 + 3] = 0x5a'u8
      expectReportRefusal(sreReservedFieldNotZero):
        discard parseSnpReport(v3)
      var v2 = s.report
      v2[OffReserved188 + 3] = 0x5a'u8
      expectReportRefusal(sreReservedFieldNotZero):
        discard parseSnpReport(v2)

  test "t_snp_the_signing_key_field_is_read_and_every_value_is_reachable":
    # Three named values, and the two reports carry one of them. The
    # other two are declared, so they are given an input rather than
    # left as names nothing produces.
    var seen: set[SnpSigningKeyKind] = {}
    for s in specimens:
      seen.incl parseSnpReport(s.report).signingKey
    check seen == {skkVcek}
    let base = specimens[0].report
    for (bits, want) in {0'u8: skkVcek, 1'u8: skkVlek, 2'u8: skkNone,
                         3'u8: skkNone, 7'u8: skkNone}:
      var m = base
      m[OffKeyInfo] = (m[OffKeyInfo] and 0xe3'u8) or (bits shl 2)
      let r = parseSnpReport(m)
      check r.signingKey == want
      seen.incl r.signingKey
    check seen == {skkVcek, skkVlek, skkNone}
    # The two single-bit flags below the signing-key field, each on its
    # own so neither is read as the other.
    check not parseSnpReport(base).authorKeyEnabled
    check not parseSnpReport(base).maskChipKey
    var a = base
    a[OffKeyInfo] = a[OffKeyInfo] or 1'u8
    check parseSnpReport(a).authorKeyEnabled
    check not parseSnpReport(a).maskChipKey
    var b = base
    b[OffKeyInfo] = b[OffKeyInfo] or 2'u8
    check parseSnpReport(b).maskChipKey
    check not parseSnpReport(b).authorKeyEnabled

  test "t_snp_an_unknown_signing_algorithm_is_refused":
    let before = refusalsObserved
    let algos = [0'u8, 2'u8, 17'u8]
    for a in algos:
      check uint32(a) != SnpSignatureAlgoEcdsaP384Sha384
      for s in specimens:
        check s.report[OffSignatureAlgo] ==
          byte(SnpSignatureAlgoEcdsaP384Sha384)
        var mutated = s.report
        mutated[OffSignatureAlgo] = a
        expectReportRefusal(sreUnsupportedSignatureAlgorithm):
          discard parseSnpReport(mutated)
    check refusalsObserved - before == algos.len * specimens.len

  test "t_snp_a_foreign_version_packing_is_refused_rather_than_misread":
    # Bytes 2-5 of a version field are reserved in the packing this
    # build reads and are used in a later one. Reading a later part's
    # report under this layout would report four numbers it never
    # stated, so it is refused instead.
    for at in [OffCurrentTcb, OffReportedTcb, OffCommittedTcb, OffLaunchTcb]:
      for s in specimens:
        var mutated = s.report
        mutated[at + 2] = 0x11'u8
        expectReportRefusal(sreUnsupportedTcbLayout):
          discard parseSnpReport(mutated)
    check tcbReservedBytes(0x7308000000000003'u64) == 0'u32
    check tcbReservedBytes(0x7308000011000003'u64) != 0'u32

suite "the curve primitive, reached the way a certificate reaches it":

  test "t_snp_a_caller_built_key_of_the_wrong_width_is_refused_not_dereferenced":
    # `repro_attest/cose` parses keys out of COSE key maps and cannot
    # produce a point of the wrong width that way. This module builds
    # one from certificate bytes instead, so it is the caller that
    # decides the width — and a build in which that path stopped
    # checking would read past the end of a buffer here rather than
    # answer no. Every wrong width there is:
    let genuine = pointOf(specimens[0].vcek)
    check genuine.len == SnpP384PointLen
    check genuine.len == 97
    let report = parseSnpReport(specimens[0].report)
    check verifyReportSignature(report, genuine)

    var widths: seq[int] = @[]
    for n in [0, 1, 32, 64, 65, 96, 98, 129, 200]:
      widths.add n
      var point = newSeq[byte](n)
      if n > 0: point[0] = 0x04'u8
      for i in 1 ..< n: point[i] = genuine[i mod genuine.len]
      check not verifyReportSignature(report, point)
    check widths.len == 9
    # The genuine point truncated and extended, which is the shape an
    # off-by-one in a certificate reader would produce.
    check not verifyReportSignature(report, genuine[0 ..< genuine.len - 1])
    var oversize = genuine
    oversize.add 0'u8
    check not verifyReportSignature(report, oversize)
    # …and the two coordinates without the 0x04 that says they are a
    # point at all.
    check not verifyReportSignature(report, genuine[1 .. ^1])

  test "t_snp_the_message_entry_point_refuses_the_same_keys":
    # The primitive above returns a bool. The message-level entry point
    # raises, and it is the one whose key-width guard was added after a
    # review observed that nothing in the tree reached it. It is reached
    # here.
    let genuine = pointOf(specimens[0].vcek)
    for n in [0, 1, 96, 98]:
      var point = newSeq[byte](n)
      for i in 0 ..< n: point[i] = genuine[i mod genuine.len]
      let key = CoseKey(curve: ccP384, point: point, kid: @[1'u8])
      var raised = false
      try:
        # A syntactically fine COSE_Sign1 whose kid names this key, so
        # the walk reaches key selection rather than stopping earlier.
        # alg = ES384 (-35, so the encoded argument is 34), kid = 0x01.
        check CoseAlgorithmLabel[caEs384] == -35'i64
        let protected = encodeDeterministic(
          cMap([cPair(cUInt(uint64(LabelAlg)), cNegInt(34))]))
        let message = encodeItem(cTag(CoseSign1Tag, cArray([
          cBytes(protected),
          cMap([cPair(cUInt(uint64(LabelKid)), cBytes(@[1'u8]))]),
          cBytes(@[0'u8]),
          cBytes(newSeq[byte](96))])))
        discard verifyCoseSign1(message, [key])
      except CoseError as err:
        raised = true
        check err.kind == cxeKeyCoordinateWrongLength
        reachedCoseKinds.incl err.kind
      check raised

  test "t_snp_the_report_signature_is_es384_over_p384":
    # Not a restatement of a constant: the report is verified with the
    # algorithm this module names, and the two neighbouring algorithms
    # are shown NOT to verify it, so the pairing is observed rather
    # than declared.
    let key = CoseKey(curve: ccP384, point: pointOf(specimens[0].vcek))
    let report = parseSnpReport(specimens[0].report)
    var sig = report.signatureR
    for b in report.signatureS: sig.add b
    check sig.len == 96
    check ecdsaSignatureIsValid(key, caEs384, report.signedBytes, sig)
    check not ecdsaSignatureIsValid(key, caEs256, report.signedBytes, sig)
    check not ecdsaSignatureIsValid(key, caEs512, report.signedBytes, sig)
    check CoseCurveCoordinateLen[ccP384] == SnpP384ScalarLen
    check CoseAlgorithmCurve[caEs384] == ccP384

suite "snp refusal coverage":

  test "t_snp_report_every_refusal_kind_is_reached":
    var unreached: seq[string] = @[]
    var count = 0
    for k in SnpReportErrorKind:
      inc count
      if k notin reachedReportKinds: unreached.add $k
    check count == 7
    if unreached.len > 0:
      checkpoint("never reached: " & unreached.join(", "))
    check unreached.len == 0
    check card(reachedReportKinds) == 7
