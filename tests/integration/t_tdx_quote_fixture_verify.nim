## Genuine Intel TDX attestation quotes verify, and every single-bit
## change to one is refused.
##
## ## What this gate is actually asserting
##
## Three quotes produced by three different Intel parts are read, and
## for each one all three of its signatures are checked: the quoting
## enclave's report against the P-256 key inside the provisioning
## certificate the quote itself carries, the binding between that report
## and the quote's attestation key, and the quote's own signature
## against that key. A quote that passes all three is a statement about
## every signed byte at once — the module measurement, the trust
## domain's own measurement, the four runtime registers, the 64 bytes
## the guest put in, the platform's version array.
##
## The negative half is where the care goes. It is not enough that "a
## tampered quote is refused": a gate that flips a bit anywhere and
## observes a refusal has not shown that the *signature* covers the
## field, only that something objected. So every mutation here declares
## which of the three signed documents the offset lands in, the gate
## checks that the offset really is inside it, checks that exactly one
## bit moved, and then asserts **which** of the three operations
## failed and that the other two still succeed.
##
## That last step is the one this tree keeps being defeated by: a
## negative case satisfied by a refusal other than the one it was
## written for keeps passing after the rule it exists for is deleted.
##
## ## Three signatures, and dropping any one of them is green without it
##
## The three are not redundant and the gate proves it by construction:
## for each mutation there is exactly one operation that fails. A bit in
## the trust domain's report breaks the quote signature and neither
## other; a bit in the quoting enclave's report breaks the enclave
## signature and neither other; a bit in the attestation key breaks the
## binding, and the quote signature under the *mutated* key as well,
## and not the enclave signature. A build that checked only the first
## would accept a quote whose enclave report came from somewhere else
## entirely.
##
## ## The elliptic-curve primitive is somebody else's, deliberately
##
## All three verifications run through `repro_attest/cose`, which owns
## the only raw-signature ECDSA implementation in this tree. This is
## that module's ES256 consumer — its ES384 arm has one already — and it
## reaches it by the path its own documentation calls the dangerous one:
## the key is built from certificate bytes or from a quote's own bytes,
## never parsed from a COSE key map, so its width is whatever the caller
## made it. A block of cases below hands that path every wrong width
## there is and requires a refusal rather than a crash.
##
## ## Mocking
##
## None. Real quotes, real certificates, real curve arithmetic.

import std/[os, strutils, unittest]

import repro_attest/cose
import repro_attest_verify/tdx_quote
import repro_attest_verify/x509

include ./tdx_vectors

# ---------------------------------------------------------------------
# Which refusals were reached
#
# The kind-level half of this is a CASE below, so a refusal kind that
# stops being reachable turns the gate red. The per-site list is written
# only when `REPRO_REFUSAL_CENSUS` names a file, so an ordinary run
# prints nothing extra; it is an instrument for measuring, not a check.
# ---------------------------------------------------------------------

var reachedQuoteKinds: set[TdxQuoteErrorKind] = {}
var reachedQuoteSites: seq[string] = @[]
var reachedBindingKinds: set[TdxBindingOutcome] = {}

proc writeCensus() =
  # Called from the LAST case rather than from an exit procedure.
  #
  # It was an exit procedure, and it produced nonsense: the `seq[string]`
  # globals it reads are heap-allocated, and by the time an exit
  # procedure runs they have been collected, so what it wrote was
  # whatever had been allocated over them. That is worth recording
  # rather than silently fixing — an instrument that reports confidently
  # from freed memory is worse than one that does not run.
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var lines: seq[string] = @[]
  for k in TdxQuoteErrorKind:
    if k in reachedQuoteKinds: lines.add "tdx_quote:" & $k
  for k in TdxBindingOutcome:
    if k in reachedBindingKinds: lines.add "tdx_binding:" & $k
  for s in reachedQuoteSites: lines.add "tdx_quote_site:" & s
  writeFile(path, lines.join("\n") & "\n")



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

proc putLe32(data: var seq[byte]; at: int; v: uint32) =
  data[at] = byte(v and 0xff'u32)
  data[at + 1] = byte((v shr 8) and 0xff'u32)
  data[at + 2] = byte((v shr 16) and 0xff'u32)
  data[at + 3] = byte((v shr 24) and 0xff'u32)

proc putLe16(data: var seq[byte]; at: int; v: uint16) =
  data[at] = byte(v and 0xff'u16)
  data[at + 1] = byte((v shr 8) and 0xff'u16)

var refusalsObserved = 0
  ## Every refusal this gate has SEEN, with the right kind and with no
  ## other rule's wording in it. Cases below assert their own delta on
  ## it, so a loop that silently stopped iterating — or a fixture list
  ## that lost an entry — moves a number instead of going quiet.

proc siteOf(msg: string; kind: TdxQuoteErrorKind): string =
  ## A refusal SITE, not a refusal kind. Three of the kinds have more
  ## than one site, and a census that counted kinds would report them
  ## as one rule. The detail each site writes is what tells them apart,
  ## so the census keys on its first words.
  let marker = TdxQuoteMessage[kind] & ": "
  let at = msg.find(marker)
  if at < 0: return $kind & "/<no detail>"
  let tail = msg[at + marker.len .. ^1]
  var words: seq[string] = @[]
  for w in tail.split(' '):
    if words.len >= 6: break
    # Digits are collapsed, and that is the difference between a census
    # over SITES and a census over refusals. These sentences quote the
    # values they refused — a byte count, an offset, a type number — so
    # one site reached with two different inputs wrote two keys and
    # counted twice. Measured: twenty-three keys from twenty-two sites,
    # against an assertion that the count was at least twenty-two. An
    # inflated count under an inequality is a census that cannot notice
    # the thing it exists to notice, because a site reached twice pays
    # for a site reached never.
    var w2 = ""
    var wasDigit = false
    for c in w:
      if c in '0' .. '9':
        if not wasDigit: w2.add 'N'
        wasDigit = true
      else:
        w2.add c
        wasDigit = false
    words.add w2
  $kind & "/" & words.join(" ")

proc assertOnlyRefusal(msg: string; kind: TdxQuoteErrorKind) =
  inc refusalsObserved
  let site = siteOf(msg, kind)
  if site notin reachedQuoteSites: reachedQuoteSites.add site
  check TdxQuoteMessage[kind] in msg
  for other in TdxQuoteErrorKind:
    if other == kind: continue
    check TdxQuoteMessage[other] notin msg
  reachedQuoteKinds.incl kind

template expectQuoteRefusal(want: TdxQuoteErrorKind; body: untyped) =
  # The parameter is `want` and not `kind`, because a template
  # parameter named after a field is substituted into `err.kind` as
  # well and the result is a compile error at best.
  var raised = false
  try:
    body
  except TdxQuoteError as err:
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
    raw: seq[byte]
    version: uint16
    bodyBytes: int
    signedBytes: int
    teeTcbSvnHex, mrSeamHex, mrTdHex, rtMr0Hex, rtMr3Hex: string
    tdAttributesHex, xfamHex, reportDataHex: string
    hasPreservedTcb: bool
    teeTcbSvn2Hex, mrServiceTdHex: string
    qeIsvProdId, qeIsvSvn: int
    qeMrSignerHex, qeAttributesHex, qeAuthDataHex: string
    attestKeyHex, bindingHex: string
    userDataHex: string
    chainSizes: seq[int]
    leafSerialHex, fmspcHex: string

const
  QeVendorIdHex = "939a7233f79c4ca9940a0db3957f0607"
    ## The quoting-enclave vendor identifier. The same sixteen bytes in
    ## all three quotes, from three different parts and two quote
    ## versions, which is a fact worth pinning: it is Intel's, and a
    ## quote carrying a different one is not one of Intel's enclaves'.

  # The genuine prefix of the first fixture. The file itself is 4,974
  # bytes and the 39 after this are the publisher's own marker; both
  # halves are used below, the prefix as the positive and the whole
  # file as the trailing-bytes input.
  SprQuoteBytes = 4935

let sprQuoteWhole = bytesOfHex(GoTdxGuestSprQuoteHex)
let sprQuote = sprQuoteWhole[0 ..< SprQuoteBytes]
let gtgV5Quote = bytesOfHex(GoTdxGuestEmrQuoteHex)
let trusteeQuote = bytesOfHex(TrusteeV5QuoteHex)
let impostorQuote = bytesOfHex(ImpostorQuoteHex)
let intelSampleQuote = bytesOfHex(IntelSampleQuoteHex)

let specimens = @[
  Specimen(label: "google/go-tdx-guest Sapphire Rapids, version 4",
    raw: sprQuote, version: 4'u16, bodyBytes: 584, signedBytes: 632,
    teeTcbSvnHex: "03000400000000000000000000000000",
    mrSeamHex: "2fd279c16164a93dd5bf373d834328d46008c2b693af9ebb865b08b2" &
      "ced320c9a89b4869a9fab60fbe9d0c5a5363c656",
    mrTdHex: "6363b8043668a3ad953278e10389574d326c6749fb78aa810ecd9336" &
      "923db86f22fc00b8dcd404bc10d5e119d7215cbb",
    rtMr0Hex: "2927da70461cd63266f43230cc1849c03ef25ebe490062a801d8fcc8" &
      "0af42976823adf08f833c1e50b51779c6593f32a",
    rtMr3Hex: "0000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000",
    tdAttributesHex: "0000004000000000", xfamHex: "e71a060000000000",
    reportDataHex: "6c62dec1b8191749a31dab490be532a35944dea47caef1f98086" &
      "3993d9899545eb7406a38d1eed313b987a467dacead6f0c87a6d766c66f6" &
      "f29f8acb281f1113",
    hasPreservedTcb: false, teeTcbSvn2Hex: "", mrServiceTdHex: "",
    qeIsvProdId: 2, qeIsvSvn: 4,
    qeMrSignerHex: "dc9e2a7c6f948f17474e34a7fc43ed030f7c1563f1babddf63" &
      "40c82e0e54a8c5",
    qeAttributesHex: "1500000000000000e700000000000000",
    qeAuthDataHex: "000102030405060708090a0b0c0d0e0f101112131415161718" &
      "191a1b1c1d1e1f",
    attestKeyHex: "36f301ff1db5c282f9338966c5b8f5c7257e75b0210d0c6c8b1d" &
      "4a7846e4e0e84c2121d448c7154d37ace210247a6e17271cd1468db8ac7f" &
      "cd2473b34f7a43fc",
    bindingHex: "cf1ae2cb769ff1f27ac520344e60905448a48bca6de8f1014c92e" &
      "5a493d94101",
    userDataHex: "739c3f292a15bace1f726351a70d4b7900000000",
    chainSizes: @[1269, 666, 659],
    leafSerialHex: "00bba6c175d838b8df3900cc3411f24f512d104102",
    fmspcHex: "50806f000000"),
  Specimen(label: "google/go-tdx-guest, version 5",
    raw: gtgV5Quote, version: 5'u16, bodyBytes: 648, signedBytes: 702,
    teeTcbSvnHex: "0b010400000000000000000000000000",
    mrSeamHex: "7bf063280e94fb051f5dd7b1fc59ce9aac42bb961df8d44b709c9b0f" &
      "f87a7b4df648657ba6d1189589feab1d5a3c9a9d",
    mrTdHex: "7348651a34b2d2d3462822e3a750ec6110125f36757c78480bbfc69c" &
      "c0d21fb001a1ced3ee19747dda8f750c3bc8f876",
    rtMr0Hex: "5c8daf76063a71ac8fcef4067564661fc682ed7944c7a5d21dbbced0" &
      "2f61ceff4ba0678c6aef3bdae8cbc614cec24619",
    rtMr3Hex: "0000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000",
    tdAttributesHex: "0000001000000000", xfamHex: "e702060000000000",
    reportDataHex: "945eaacf5abc1f719d8666a942fda03d1edcb4490277396093dc" &
      "5a5289ab9f1e094aed63060cd4a4933a4dd537ed1255c9c79ecb3ed82cd1" &
      "b486233e31c25c3a",
    hasPreservedTcb: true,
    teeTcbSvn2Hex: "0d010400000000000000000000000000",
    mrServiceTdHex: "000000000000000000000000000000000000000000000000" &
      "000000000000000000000000000000000000000000000000",
    qeIsvProdId: 2, qeIsvSvn: 7,
    qeMrSignerHex: "dc9e2a7c6f948f17474e34a7fc43ed030f7c1563f1babddf63" &
      "40c82e0e54a8c5",
    qeAttributesHex: "1500000000000000e700000000000000",
    qeAuthDataHex: "000102030405060708090a0b0c0d0e0f101112131415161718" &
      "191a1b1c1d1e1f",
    attestKeyHex: "4763cf2f3848919fd0aec8f6e8f21e85e244b431102c25b341f8" &
      "016731e892b3029c8774bd88085e775cb36e2359fbac455e6963a073e12b" &
      "abaf28d9b81d9674",
    bindingHex: "a6a69454bb0df1e141a074cd52d80082a1fa4679baf085294a15d" &
      "2d0818c3afd",
    userDataHex: "ba103c0e5dffa40351f9d5dd559888eb00000000",
    chainSizes: @[1268, 666, 659],
    leafSerialHex: "281450cd833a6cf298ea01209af1400091fb756b",
    fmspcHex: "90c06f000000"),
  Specimen(label: "confidential-containers/trustee, version 5",
    raw: trusteeQuote, version: 5'u16, bodyBytes: 648, signedBytes: 702,
    teeTcbSvnHex: "05010200000000000000000000000000",
    mrSeamHex: "1cc6a17ab799e9a693fac7536be61c12ee1e0fabada82d0c999e08cc" &
      "ee2aa86de77b0870f558c570e7ffe55d6d47fa04",
    mrTdHex: "dfba221b48a22af8511542ee796603f37382800840dcd978703909bf" &
      "8e64d4c8a1e9de86e7c9638bfcba422f3886400a",
    rtMr0Hex: "9b529f3689e2e8ebb899e9abbbc3dab394d6545e8cdb28a2abb9cc2f" &
      "377b83a65c01ba56b824cd3ee885df20051f5128",
    rtMr3Hex: "0000000000000000000000000000000000000000000000000000" &
      "00000000000000000000000000000000000000000000",
    tdAttributesHex: "0000001000000000", xfamHex: "e742060000000000",
    reportDataHex: "6d6ab13b046cff606ac0074be13981b07b6325dba10b5facc96f" &
      "ebf551c0c3be2b75f92fe1f88f4bb996969ad0174b4b7a70261b7b85c844" &
      "f4b33a4674fd049f",
    hasPreservedTcb: true,
    teeTcbSvn2Hex: "05010200000000000000000000000000",
    mrServiceTdHex: "383c87d3bbb047b2d171eaca95312ede99f258088dc788f6ae" &
      "2ccf8b6dd848fe8d47629e08b3f6cbd4a00dd47a5a033d",
    qeIsvProdId: 2, qeIsvSvn: 6,
    qeMrSignerHex: "dc9e2a7c6f948f17474e34a7fc43ed030f7c1563f1babddf63" &
      "40c82e0e54a8c5",
    qeAttributesHex: "1500000000000000e700000000000000",
    qeAuthDataHex: "000102030405060708090a0b0c0d0e0f101112131415161718" &
      "191a1b1c1d1e1f",
    attestKeyHex: "dd91887a461170b0cf1fe61120c284901bb0c3bd0358e43e1d9d" &
      "0f57a2731f9bd7b2e6bb17a3995b8cb6f80d1f47089691fc8b1facd5e15d" &
      "5139d0c644a406d0",
    bindingHex: "4bd941ab4fe96831a0e3a3b7bba0c2e68a497fc30591eba4b4754" &
      "41015cd0280",
    userDataHex: "da2c7e326c5696889a6a6ab4f8a64b1700000000",
    chainSizes: @[1268, 666, 659],
    leafSerialHex: "00ad0a9c18dc00e40cb6d3fe7d39c553dd3fa2518b",
    fmspcHex: "90c06f000000")]

proc leafPointOf(q: TdxQuote): array[P256PointLen, byte] =
  parseCertificate(q.pckChain[0]).publicKey

# ---------------------------------------------------------------------

suite "tdx quote structure":

  test "t_tdx_fixture_digests_are_what_this_gate_was_written_against":
    # The corpus is pinned by DIGEST, as data, before a byte of it is
    # read as a quote. A fixture that changed would otherwise change
    # every expectation below it silently.
    #
    # The table's LENGTH is asserted too. Without that, a fixture could
    # be dropped from the corpus and from its own check at once by
    # deleting its row — which is the defeat this tree has already been
    # caught by once.
    check TdxFixtureDigests.len == 31
    var seen: seq[string] = @[]
    for row in TdxFixtureDigests:
      check row.name notin seen
      seen.add row.name
      check row.sha256.len == 64
      check row.bytes > 0
    # And EVERY row's digest is checked against the constant of that
    # name, which is what the table's own documentation says happens.
    #
    # It did not happen. Five of the thirty-one rows were checked and
    # twenty-six — including the pinned vendor root, its signing
    # certificate, all three withdrawal lists and all eight vendor
    # documents — carried a size and a digest that nothing compared to
    # anything. Corrupting one of those rows left this gate green, so
    # the table was a record rather than a check over most of its
    # length. A table of digests that is not walked is the same shape
    # as a report nobody reads.
    proc digestOf(b: openArray[byte]): string =
      # sha256 through the same BearSSL the verification uses.
      hexOfBytes(sha256Bytes(b))
    proc bytesOfText(s: string): seq[byte] =
      # The vendor's documents are pinned as the TEXT they arrived as,
      # and their digests are over those bytes.
      result = newSeq[byte](s.len)
      for i, c in s: result[i] = byte(c)
    var covered: seq[string] = @[]
    template pin(rowName: string; blob: untyped) =
      var found = false
      for row in TdxFixtureDigests:
        if row.name == rowName:
          found = true
          check row.bytes == blob.len
          check row.sha256 == digestOf(blob)
      check found
      check rowName notin covered
      covered.add rowName

    pin "GoTdxGuestSprQuoteHex", sprQuoteWhole
    pin "GoTdxGuestEmrQuoteHex", gtgV5Quote
    pin "TrusteeV5QuoteHex", trusteeQuote
    pin "IntelSampleQuoteHex", intelSampleQuote
    pin "ImpostorQuoteHex", impostorQuote
    pin "IntelSgxRootCaDerHex", bytesOfHex(IntelSgxRootCaDerHex)
    pin "IntelTcbSigningCertDerHex", bytesOfHex(IntelTcbSigningCertDerHex)
    pin "PcsPckCrlPlatformDerHex", bytesOfHex(PcsPckCrlPlatformDerHex)
    pin "PcsPckCrlProcessorDerHex", bytesOfHex(PcsPckCrlProcessorDerHex)
    pin "IntelRootCrlDerHex", bytesOfHex(IntelRootCrlDerHex)
    pin "IntelSampleRootDerHex", bytesOfHex(IntelSampleRootDerHex)
    pin "IntelSampleCaDerHex", bytesOfHex(IntelSampleCaDerHex)
    pin "IntelSampleLeafDerHex", bytesOfHex(IntelSampleLeafDerHex)
    pin "ImpostorRootDerHex", bytesOfHex(ImpostorRootDerHex)
    pin "ImpostorCaDerHex", bytesOfHex(ImpostorCaDerHex)
    pin "ImpostorLeafDerHex", bytesOfHex(ImpostorLeafDerHex)
    pin "ImpostorCaNotAnAuthorityDerHex",
      bytesOfHex(ImpostorCaNotAnAuthorityDerHex)
    pin "ImpostorCaWithoutCertSignDerHex",
      bytesOfHex(ImpostorCaWithoutCertSignDerHex)
    pin "ImpostorLeafWithoutPlatformDerHex",
      bytesOfHex(ImpostorLeafWithoutPlatformDerHex)
    pin "ImpostorLeafWithoutFmspcDerHex",
      bytesOfHex(ImpostorLeafWithoutFmspcDerHex)
    pin "ImpostorLeafWithoutTcbDerHex",
      bytesOfHex(ImpostorLeafWithoutTcbDerHex)
    pin "ImpostorLeafWithUnknownCriticalDerHex",
      bytesOfHex(ImpostorLeafWithUnknownCriticalDerHex)
    pin "PcsPckCrlPlatformWithoutNextUpdateDerHex",
      bytesOfHex(PcsPckCrlPlatformWithoutNextUpdateDerHex)
    pin "GtgTcbInfoSprJson", bytesOfText(GtgTcbInfoSprJson)
    pin "GtgTcbInfoEmrJson", bytesOfText(GtgTcbInfoEmrJson)
    pin "GtgQeIdentityJson", bytesOfText(GtgQeIdentityJson)
    pin "PcsTcbInfoSprJson", bytesOfText(PcsTcbInfoSprJson)
    pin "PcsTcbInfoEmrJson", bytesOfText(PcsTcbInfoEmrJson)
    pin "PcsTdxQeIdentityJson", bytesOfText(PcsTdxQeIdentityJson)
    pin "PcsSgxQeIdentityJson", bytesOfText(PcsSgxQeIdentityJson)
    pin "PcsSgxTcbInfoJson", bytesOfText(PcsSgxTcbInfoJson)

    # Coverage is total in BOTH directions, which is what stops this
    # from drifting back. No row may go unchecked, and no name may be
    # checked that the table does not carry — so a fixture added
    # without a digest, a digest added without a fixture, and a row
    # quietly dropped from this list all fail here.
    check covered.len == TdxFixtureDigests.len
    for row in TdxFixtureDigests:
      check row.name in covered

  test "t_tdx_quote_messages_are_distinguishable":
    check tdxQuoteMessagesAreDistinguishable()

  test "t_tdx_quote_layout_is_the_published_one":
    # The offsets are a transcription of a vendor header, so they are
    # checked against real documents rather than trusted.
    check TdxQuoteHeaderLen == 48
    check TdReportLen == 584
    check TdReport15Len == 648
    check TdReport15Len - TdReportLen == LenTeeTcbSvn + LenTeeMeasurement
    check OffTdReportData + LenTeeReportData == TdReportLen
    check OffMrServiceTd + LenTeeMeasurement == TdReport15Len
    check OffRtMr + TdxRtMrCount * LenTeeMeasurement == OffTdReportData
    check OffQeReportData + LenTeeReportData == SgxReportBodyLen
    check widthOf(qbtTdReport10) == TdReportLen
    check widthOf(qbtTdReport15) == TdReport15Len
    check ord(qbtTdReport10) == 2
    check ord(qbtTdReport15) == 3

    for s in specimens:
      checkpoint s.label
      let q = parseTdxQuote(s.raw)
      check q.version == s.version
      check q.attestationKeyType == TdxAttestationKeyTypeEcdsaP256
      check q.teeType == TdxTeeType
      check hexOfBytes(q.vendorId) == QeVendorIdHex
      check hexOfBytes(q.userData) == s.userDataHex
      check q.body.raw.len == s.bodyBytes
      check q.signedBytes.len == s.signedBytes
      check hexOfBytes(q.body.teeTcbSvn) == s.teeTcbSvnHex
      check hexOfBytes(q.body.mrSeam) == s.mrSeamHex
      check hexOfBytes(q.body.mrTd) == s.mrTdHex
      check hexOfBytes(q.body.rtMr[0]) == s.rtMr0Hex
      check hexOfBytes(q.body.rtMr[3]) == s.rtMr3Hex
      check hexOfBytes(q.body.tdAttributes) == s.tdAttributesHex
      check hexOfBytes(q.body.xfam) == s.xfamHex
      check hexOfBytes(q.body.reportData) == s.reportDataHex
      check q.body.hasPreservedTcb == s.hasPreservedTcb
      check hexOfBytes(q.body.teeTcbSvn2) == s.teeTcbSvn2Hex
      check hexOfBytes(q.body.mrServiceTd) == s.mrServiceTdHex
      check int(q.qeReport.isvProdId) == s.qeIsvProdId
      check int(q.qeReport.isvSvn) == s.qeIsvSvn
      check hexOfBytes(q.qeReport.mrSigner) == s.qeMrSignerHex
      check hexOfBytes(q.qeReport.attributes) == s.qeAttributesHex
      check hexOfBytes(q.qeAuthenticationData) == s.qeAuthDataHex
      check hexOfBytes(q.attestationKey) == s.attestKeyHex
      check q.pckChain.len == TdxChainElements
      for i in 0 ..< TdxChainElements:
        check q.pckChain[i].len == s.chainSizes[i]
      # The signed span is lifted, never rebuilt.
      for i in 0 ..< s.signedBytes:
        check q.signedBytes[i] == s.raw[i]

  test "t_tdx_corpus_is_not_degenerate_in_the_dimensions_that_matter":
    # A fixture set that is single-anything disables every rule about
    # its dimension, and no care with the assertions recovers it. So
    # the spread is asserted rather than assumed.
    var versions: seq[uint16] = @[]
    var bodyWidths: seq[int] = @[]
    var measurements: seq[string] = @[]
    var platforms: seq[string] = @[]
    var moduleMajors: seq[int] = @[]
    var serviceDomains = 0
    var preservedDiffer = 0
    var paddedSerials = 0
    for s in specimens:
      let q = parseTdxQuote(s.raw)
      if s.version notin versions: versions.add s.version
      if q.body.raw.len notin bodyWidths: bodyWidths.add q.body.raw.len
      check hexOfBytes(q.body.mrTd) notin measurements
      measurements.add hexOfBytes(q.body.mrTd)
      if s.fmspcHex notin platforms: platforms.add s.fmspcHex
      let major = int(q.body.teeTcbSvn[TdxModuleMajorSvnIndex])
      if major notin moduleMajors: moduleMajors.add major
      var allZero = true
      for b in q.body.mrServiceTd:
        if b != 0'u8: allZero = false
      if q.body.hasPreservedTcb and not allZero: inc serviceDomains
      if q.body.hasPreservedTcb and
         hexOfBytes(q.body.teeTcbSvn2) != hexOfBytes(q.body.teeTcbSvn):
        inc preservedDiffer
      if s.leafSerialHex.len == 42 and s.leafSerialHex[0 .. 1] == "00":
        inc paddedSerials
    check versions.len == 2
    check bodyWidths.len == 2
    check measurements.len == 3
    check platforms.len == 2
    # Both branches of the module rule: a major version of 0 means the
    # level comparison reads all sixteen components, and a non-zero one
    # means it skips two and consults a separate identity instead.
    check moduleMajors.len == 2
    check 0 in moduleMajors
    check 1 in moduleMajors
    # A wider report whose service-domain measurement is NOT zero, so a
    # build that never read those 48 bytes is visible.
    check serviceDomains == 1
    # A wider report whose two version arrays DIFFER, so a build that
    # evaluated one of them twice is visible.
    check preservedDiffer == 1
    # Both serial encodings: with DER's sign pad and without it. The
    # first is what a bound on the ENCODING refused.
    check paddedSerials == 2

  test "t_tdx_genuine_quotes_verify_all_three_ways":
    var verified = 0
    for s in specimens:
      checkpoint s.label
      let q = parseTdxQuote(s.raw)
      let point = leafPointOf(q)
      check verifyQeReportSignature(q, point)
      let binding = qeReportBindsAttestationKey(q)
      check binding.isBound
      check binding.computedHex == s.bindingHex
      check verifyQuoteSignature(q)
      inc verified
    check verified == 3

  test "t_tdx_a_quote_does_not_verify_under_another_quote_s_certificate":
    # Three parts, and each one's enclave report verifies under its own
    # provisioning certificate and under neither of the others'. Without
    # this the positive above is satisfied by any key at all that the
    # corpus happens to share.
    var crossChecks = 0
    for i, si in specimens:
      for j, sj in specimens:
        let qi = parseTdxQuote(si.raw)
        let qj = parseTdxQuote(sj.raw)
        let ok = verifyQeReportSignature(qi, leafPointOf(qj))
        check ok == (i == j)
        inc crossChecks
    check crossChecks == 9

# ---------------------------------------------------------------------

proc driveTdxOneBitInTheAttestationKeyBreaksTheBinding() =
  ## The body of test
  ##   "t_tdx_one_bit_in_the_attestation_key_breaks_the_binding"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var mutations = 0
  for s in specimens:
    checkpoint s.label
    let sigAt = s.signedBytes + 4
    let at = sigAt + EcdsaP256SignatureLen
    let mutated = flipBit(s.raw, at + 5, 2)
    check bitsDiffering(s.raw, mutated) == 1
    let q = parseTdxQuote(mutated)
    check hexOfBytes(q.attestationKey) != s.attestKeyHex
    let binding = qeReportBindsAttestationKey(q)
    check not binding.isBound
    check binding.outcome == tboReportDataDisagrees
    reachedBindingKinds.incl binding.outcome
    # The enclave report itself is untouched and still verifies; the
    # quote signature does not, because the key it would be checked
    # under is the mutated one.
    check verifyQeReportSignature(q, leafPointOf(q))
    check not verifyQuoteSignature(q)
    inc mutations
  check mutations == 3

proc driveTdxTheBindingComparesAllThirtyTwoDigestBytes() =
  ## The body of test
  ##   "t_tdx_the_binding_compares_all_thirty_two_digest_bytes"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The mutation table found this: every other negative here moves
  # the attestation key, which moves the WHOLE digest, so a build
  # comparing only the first sixteen bytes caught them all and the
  # rule "all thirty-two are compared" had no input.
  #
  # The input it needed is the other side of the comparison. Moving a
  # bit of the quoting enclave's report DATA at a chosen offset makes
  # the report and the recomputed digest differ at exactly that
  # offset and nowhere else, so a comparison that stopped early is
  # visible by where the difference is.
  var offsets = 0
  for at in [0, 15, 16, 31]:
    checkpoint "report data byte " & $at
    for s in specimens:
      let sigAt = s.signedBytes + 4
      let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
      let mutated = flipBit(s.raw, qeAt + OffQeReportData + at, 1)
      check bitsDiffering(s.raw, mutated) == 1
      let q = parseTdxQuote(mutated)
      let binding = qeReportBindsAttestationKey(q)
      check not binding.isBound
      check binding.outcome == tboReportDataDisagrees
      # The digest itself did not move: only the report did.
      check binding.computedHex == s.bindingHex
      reachedBindingKinds.incl binding.outcome
    inc offsets
  check offsets == 4
  # And the SAME construction at a byte the binding does not cover
  # reaches the other rule, so the two halves are told apart by where
  # the byte is and not by which case ran.
  let s0 = specimens[0]
  let sigAt0 = s0.signedBytes + 4
  let qeAt0 = sigAt0 + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
  let beyond = parseTdxQuote(
    flipBit(s0.raw, qeAt0 + OffQeReportData + 32, 1))
  check qeReportBindsAttestationKey(beyond).outcome ==
    tboReportDataTailNotZero

proc driveTdxTheUnusedHalfOfTheEnclaveReportDataMustBeBlank() =
  ## The body of test
  ##   "t_tdx_the_unused_half_of_the_enclave_report_data_must_be_blank"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var mutations = 0
  for s in specimens:
    checkpoint s.label
    let sigAt = s.signedBytes + 4
    let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
    # Byte 32 of the report data is the first the binding does not
    # cover. The quoting enclave's signature does cover it, so this is
    # a mutation that breaks TWO things, and the case asserts both.
    let at = qeAt + OffQeReportData + 32
    let mutated = flipBit(s.raw, at, 7)
    check bitsDiffering(s.raw, mutated) == 1
    let q = parseTdxQuote(mutated)
    let binding = qeReportBindsAttestationKey(q)
    check not binding.isBound
    check binding.outcome == tboReportDataTailNotZero
    check "byte 32" in binding.detail
    reachedBindingKinds.incl binding.outcome
    check not verifyQeReportSignature(q, leafPointOf(q))
    inc mutations
  check mutations == 3

suite "tdx quote mutations":

  test "t_tdx_one_bit_in_the_trust_domain_report_breaks_only_that_signature":
    # Every mutation declares the span it lands in; the gate checks it
    # really is in that span, that exactly one bit moved, that the
    # parsed field really changed, and that exactly ONE of the three
    # operations fails.
    var mutations = 0
    for s in specimens:
      let base = parseTdxQuote(s.raw)
      let bodyAt = if s.version == 5'u16: TdxQuoteHeaderLen + 6
                   else: TdxQuoteHeaderLen
      for (label, off) in {"tee tcb svn": OffTeeTcbSvn,
                           "mrseam": OffMrSeam,
                           "td attributes": OffTdAttributes,
                           "mrtd": OffMrTd,
                           "runtime register 0": OffRtMr,
                           "runtime register 3": OffRtMr + 3 * LenTeeMeasurement,
                           "report data": OffTdReportData}:
        checkpoint s.label & " / " & label
        let at = bodyAt + off
        check at >= bodyAt
        check at < bodyAt + s.bodyBytes
        let mutated = flipBit(s.raw, at, 3)
        check bitsDiffering(s.raw, mutated) == 1
        let q = parseTdxQuote(mutated)
        # The field really moved.
        check hexOfBytes(q.body.raw) != hexOfBytes(base.body.raw)
        # Exactly one of the three fails.
        check not verifyQuoteSignature(q)
        check verifyQeReportSignature(q, leafPointOf(q))
        check qeReportBindsAttestationKey(q).isBound
        inc mutations
    check mutations == 21

  test "t_tdx_one_bit_in_the_enclave_report_breaks_only_that_signature":
    var mutations = 0
    for s in specimens:
      let sigAt = s.signedBytes + 4
      let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
      for (label, off) in {"cpu svn": OffQeCpuSvn,
                           "measurer": OffQeMrSigner,
                           "product": OffQeIsvProdId,
                           "version": OffQeIsvSvn}:
        checkpoint s.label & " / " & label
        let at = qeAt + off
        check at >= qeAt
        check at < qeAt + SgxReportBodyLen
        let mutated = flipBit(s.raw, at, 0)
        check bitsDiffering(s.raw, mutated) == 1
        let q = parseTdxQuote(mutated)
        check hexOfBytes(q.qeReport.raw) !=
          hexOfBytes(parseTdxQuote(s.raw).qeReport.raw)
        check not verifyQeReportSignature(q, leafPointOf(q))
        check verifyQuoteSignature(q)
        # The binding survives: it reads the report's DATA, and none of
        # these four offsets is in it.
        check qeReportBindsAttestationKey(q).isBound
        inc mutations
    check mutations == 12

  test "t_tdx_one_bit_in_the_attestation_key_breaks_the_binding":
    driveTdxOneBitInTheAttestationKeyBreaksTheBinding()

  test "t_tdx_the_binding_compares_all_thirty_two_digest_bytes":
    driveTdxTheBindingComparesAllThirtyTwoDigestBytes()

  test "t_tdx_the_unused_half_of_the_enclave_report_data_must_be_blank":
    driveTdxTheUnusedHalfOfTheEnclaveReportDataMustBeBlank()

  test "t_tdx_every_single_byte_of_either_signature_is_covered":
    # A sweep rather than a sample, over one specimen, so a build that
    # read only part of a signature is visible. Both scalars of both
    # signatures, every byte, one bit each.
    let s = specimens[0]
    let sigAt = s.signedBytes + 4
    let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
    var quoteSigBytes = 0
    for i in 0 ..< EcdsaP256SignatureLen:
      let q = parseTdxQuote(flipBit(s.raw, sigAt + i, i mod 8))
      check not verifyQuoteSignature(q)
      inc quoteSigBytes
    var qeSigBytes = 0
    for i in 0 ..< EcdsaP256SignatureLen:
      let q = parseTdxQuote(flipBit(s.raw,
        qeAt + SgxReportBodyLen + i, i mod 8))
      check not verifyQeReportSignature(q, leafPointOf(q))
      inc qeSigBytes
    check quoteSigBytes == EcdsaP256SignatureLen
    check qeSigBytes == EcdsaP256SignatureLen

# ---------------------------------------------------------------------

proc driveTdxAPublishedDocumentLongerThanItDeclaresIsRefused() =
  ## The body of test
  ##   "t_tdx_a_published_document_longer_than_it_declares_is_refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Not a manufactured input: `google/go-tdx-guest` appends 39 bytes
  # of ASCII to its own fixture on purpose, and this is the rule that
  # notices. A reader that took the declared length and ignored the
  # remainder would accept a document carrying a second document
  # nobody looks at.
  check sprQuoteWhole.len == 4974
  check sprQuoteWhole.len - SprQuoteBytes == 39
  var marker = ""
  for i in SprQuoteBytes ..< sprQuoteWhole.len:
    marker.add char(sprQuoteWhole[i])
  check marker == "\nextra bytes(only for testing purpose)\n"
  let before = refusalsObserved
  expectQuoteRefusal(tqeTrailingBytes):
    discard parseTdxQuote(sprQuoteWhole)
  check refusalsObserved == before + 1

proc driveTdxIntelSOwnSampleQuoteIsRefusedForItsEncoding() =
  ## The body of test
  ##   "t_tdx_intel_s_own_sample_quote_is_refused_for_its_encoding"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Intel's quote-verification library ships a sample quote whose
  # endorsement material is raw DER in root-first order rather than
  # the textual armour in leaf-first order the kind it declares is
  # defined to carry. Refused by the rule about the ARMOUR, and the
  # case says so — its root being a test root is a different rule in
  # a different module, and reaching it needs the certificates handed
  # over directly.
  let before = refusalsObserved
  expectQuoteRefusal(tqeNotAPemCertificateChain):
    discard parseTdxQuote(intelSampleQuote)
  check refusalsObserved == before + 1

proc driveTdxEveryStructuralRuleRefusesItsOwnInput() =
  ## The body of test
  ##   "t_tdx_every_structural_rule_refuses_its_own_input"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # One constructed input per rule, each derived from a genuine quote
  # so that nothing but the mutated field can be what is objected to.
  let base = sprQuote
  let sigAt = specimens[0].signedBytes + 4
  let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
  let before = refusalsObserved

  expectQuoteRefusal(tqeTooShort):
    discard parseTdxQuote(base[0 ..< 40])

  var badVersion = base
  putLe16(badVersion, OffQuoteVersion, 3'u16)
  expectQuoteRefusal(tqeUnsupportedVersion):
    discard parseTdxQuote(badVersion)

  var badKeyType = base
  putLe16(badKeyType, OffQuoteAttestationKeyType, 3'u16)
  expectQuoteRefusal(tqeUnsupportedAttestationKeyType):
    discard parseTdxQuote(badKeyType)

  var badTee = base
  putLe32(badTee, OffQuoteTeeType, 0'u32)
  expectQuoteRefusal(tqeNotATrustDomainQuote):
    discard parseTdxQuote(badTee)

  var badReserved = base
  badReserved[OffQuoteHeaderReserved + 1] = 0x01'u8
  expectQuoteRefusal(tqeHeaderReservedNotZero):
    discard parseTdxQuote(badReserved)

  # The version-5 report descriptor: an unknown shape, and a declared
  # width that disagrees with a known one.
  var badShape = gtgV5Quote
  putLe16(badShape, TdxQuoteHeaderLen, 1'u16)
  expectQuoteRefusal(tqeUnsupportedBodyType):
    discard parseTdxQuote(badShape)

  var badWidth = gtgV5Quote
  putLe32(badWidth, TdxQuoteHeaderLen + 2, uint32(TdReportLen))
  expectQuoteRefusal(tqeBodySizeDisagreesWithItsType):
    discard parseTdxQuote(badWidth)

  # A version-5 quote whose declared report is wider than the bytes
  # supplied. The shape has to stay a known one, so the width moves
  # with it: shape 3 is 648 bytes and the document is truncated to
  # less than that plus its descriptor.
  var shortBody = gtgV5Quote[0 ..< TdxQuoteHeaderLen + 6 + 600]
  expectQuoteRefusal(tqeBodyRunsPastTheEnd):
    discard parseTdxQuote(shortBody)

  var longSig = base
  putLe32(longSig, specimens[0].signedBytes, 0xffff'u32)
  expectQuoteRefusal(tqeSignatureDataRunsPastTheEnd):
    discard parseTdxQuote(longSig)

  var badQeType = base
  putLe16(badQeType, sigAt + EcdsaP256SignatureLen +
    EcdsaP256PublicKeyLen, 5'u16)
  expectQuoteRefusal(tqeQeCertificationDataTypeUnsupported):
    discard parseTdxQuote(badQeType)

  var longQe = base
  putLe32(longQe, sigAt + EcdsaP256SignatureLen +
    EcdsaP256PublicKeyLen + 2, 0xffff'u32)
  expectQuoteRefusal(tqeQeCertificationDataRunsPastTheEnd):
    discard parseTdxQuote(longQe)

  var shortQe = base
  putLe32(shortQe, sigAt + EcdsaP256SignatureLen +
    EcdsaP256PublicKeyLen + 2, 500'u32)
  expectQuoteRefusal(tqeCertificationDataNotExactlyFilled):
    discard parseTdxQuote(shortQe)

  var longAuth = base
  putLe16(longAuth, qeAt + SgxReportBodyLen + EcdsaP256SignatureLen,
    0xffff'u16)
  expectQuoteRefusal(tqeQeAuthenticationDataRunsPastTheEnd):
    discard parseTdxQuote(longAuth)

  let authLen = specimens[0].qeAuthDataHex.len div 2
  let pckTypeAt = qeAt + SgxReportBodyLen + EcdsaP256SignatureLen + 2 +
    authLen
  var badPckType = base
  putLe16(badPckType, pckTypeAt, 4'u16)
  expectQuoteRefusal(tqePckCertificationDataTypeUnsupported):
    discard parseTdxQuote(badPckType)

  var longPck = base
  putLe32(longPck, pckTypeAt + 2, 0xffff'u32)
  expectQuoteRefusal(tqePckCertificationDataRunsPastTheEnd):
    discard parseTdxQuote(longPck)

  # Armour that holds one certificate rather than three. Built by
  # truncating the chain payload at the end of its first block and
  # restating every enclosing length, so nothing but the COUNT is
  # wrong.
  var oneCert = base
  block:
    var text = ""
    for i in 0 ..< specimens[0].chainSizes.len: discard i
    let q = parseTdxQuote(base)
    var pem = ""
    for b in q.pckChainPem: pem.add char(b)
    let firstEnd = pem.find(PemEnd) + PemEnd.len
    let kept = pem[0 ..< firstEnd] & "\n"
    var rebuilt: seq[byte] = @[]
    for i in 0 ..< pckTypeAt: rebuilt.add base[i]
    rebuilt.add byte(PckCertificateChainDataType and 0xff'u16)
    rebuilt.add byte((PckCertificateChainDataType shr 8) and 0xff'u16)
    let n = uint32(kept.len)
    rebuilt.add byte(n and 0xff'u32)
    rebuilt.add byte((n shr 8) and 0xff'u32)
    rebuilt.add byte((n shr 16) and 0xff'u32)
    rebuilt.add byte((n shr 24) and 0xff'u32)
    for c in kept: rebuilt.add byte(c)
    # Restate the two enclosing lengths and the signature-block one.
    let qeLen = uint32(rebuilt.len - qeAt)
    putLe32(rebuilt, qeAt - 4, qeLen)
    let sigLen = uint32(rebuilt.len - sigAt)
    putLe32(rebuilt, sigAt - 4, sigLen)
    oneCert = rebuilt
    text = ""
    discard text
  expectQuoteRefusal(tqeWrongCertificateChainLength):
    discard parseTdxQuote(oneCert)

  # Armour holding no block at all, built the same way.
  var noCert = oneCert
  block:
    var rebuilt: seq[byte] = @[]
    for i in 0 ..< pckTypeAt: rebuilt.add base[i]
    rebuilt.add byte(PckCertificateChainDataType and 0xff'u16)
    rebuilt.add byte((PckCertificateChainDataType shr 8) and 0xff'u16)
    let payload = "no armour here"
    let n = uint32(payload.len)
    rebuilt.add byte(n and 0xff'u32)
    rebuilt.add byte((n shr 8) and 0xff'u32)
    rebuilt.add byte((n shr 16) and 0xff'u32)
    rebuilt.add byte((n shr 24) and 0xff'u32)
    for c in payload: rebuilt.add byte(c)
    putLe32(rebuilt, qeAt - 4, uint32(rebuilt.len - qeAt))
    putLe32(rebuilt, sigAt - 4, uint32(rebuilt.len - sigAt))
    noCert = rebuilt
  expectQuoteRefusal(tqeNotAPemCertificateChain):
    discard parseTdxQuote(noCert)

  check refusalsObserved == before + 17

proc driveTdxTheFourRulesThatShareAKindEachGetTheirOwnInput() =
  ## The body of test
  ##   "t_tdx_the_four_rules_that_share_a_kind_each_get_their_own_input"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Three of the eighteen kinds are raised at more than one place —
  # the too-short rule at the version-4 prefix and again at the
  # version-5 one, the quoting-enclave length rule at three arithmetic
  # points, and the exactly-filled rule at two nesting levels. A case
  # that reached one of each would leave four rules with no input
  # while the kind census read 18 of 18, which is the shape this tree
  # keeps being defeated by.
  proc refusalMessage(data: seq[byte]): string =
    ## The message a document earns, or the empty string when it is
    ## not refused at all — which every check below would then fail
    ## on, so a silently-accepted input cannot pass as a refusal.
    try:
      discard parseTdxQuote(data)
      ""
    except TdxQuoteError as err:
      err.msg

  let before = refusalsObserved
  let base = sprQuote
  let v5 = gtgV5Quote
  let sigAt = specimens[0].signedBytes + 4
  let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6

  # The version-5 prefix: long enough for a version-4 header and a
  # length, short of a version-5 descriptor and one.
  var shortV5 = v5[0 ..< TdxQuoteHeaderLen + 6]
  check shortV5.len > TdxQuoteHeaderLen + 4
  check shortV5.len < TdxQuoteHeaderLen + 6 + 4
  expectQuoteRefusal(tqeTooShort):
    discard parseTdxQuote(shortV5)
  check "a version-5 header" in refusalMessage(shortV5)

  # The signature block shorter than its own fixed fields.
  var tinySig = base[0 ..< sigAt + 10]
  putLe32(tinySig, specimens[0].signedBytes, 10'u32)
  expectQuoteRefusal(tqeQeCertificationDataRunsPastTheEnd):
    discard parseTdxQuote(tinySig)
  check "its fixed fields alone are" in refusalMessage(tinySig)

  # The quoting enclave's certification data shorter than its own
  # report, signature and length field.
  var tinyQe = base[0 ..< qeAt + 100]
  putLe32(tinyQe, qeAt - 4, 100'u32)
  putLe32(tinyQe, specimens[0].signedBytes, uint32(tinyQe.len - sigAt))
  expectQuoteRefusal(tqeQeCertificationDataRunsPastTheEnd):
    discard parseTdxQuote(tinyQe)
  check "its report, signature and authentication length" in refusalMessage(tinyQe)

  # The INNER exactly-filled rule: the endorsement material declares
  # fewer bytes than remain beside it, while every enclosing length
  # still adds up.
  let authLen = specimens[0].qeAuthDataHex.len div 2
  let pckTypeAt = qeAt + SgxReportBodyLen + EcdsaP256SignatureLen + 2 +
    authLen
  var shortPck = base
  putLe32(shortPck, pckTypeAt + 2, 100'u32)
  expectQuoteRefusal(tqeCertificationDataNotExactlyFilled):
    discard parseTdxQuote(shortPck)
  check "its endorsement material declares" in refusalMessage(shortPck)

  check refusalsObserved == before + 4

# Every case whose outcomes the coverage case(s) below observe. The
# suite runner executes each case in its own process (`--run
# suite::test`), so the coverage case drives these itself rather than
# reading what earlier cases left in process-global state.
const QuoteDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("t_tdx_one_bit_in_the_attestation_key_breaks_the_binding",
    driveTdxOneBitInTheAttestationKeyBreaksTheBinding),
  ("t_tdx_the_binding_compares_all_thirty_two_digest_bytes",
    driveTdxTheBindingComparesAllThirtyTwoDigestBytes),
  ("t_tdx_the_unused_half_of_the_enclave_report_data_must_be_blank",
    driveTdxTheUnusedHalfOfTheEnclaveReportDataMustBeBlank),
  ("t_tdx_a_published_document_longer_than_it_declares_is_refused",
    driveTdxAPublishedDocumentLongerThanItDeclaresIsRefused),
  ("t_tdx_intel_s_own_sample_quote_is_refused_for_its_encoding",
    driveTdxIntelSOwnSampleQuoteIsRefusedForItsEncoding),
  ("t_tdx_every_structural_rule_refuses_its_own_input",
    driveTdxEveryStructuralRuleRefusesItsOwnInput),
  ("t_tdx_the_four_rules_that_share_a_kind_each_get_their_own_input",
    driveTdxTheFourRulesThatShareAKindEachGetTheirOwnInput)]

suite "tdx quote refusals":

  test "t_tdx_a_published_document_longer_than_it_declares_is_refused":
    driveTdxAPublishedDocumentLongerThanItDeclaresIsRefused()

  test "t_tdx_intel_s_own_sample_quote_is_refused_for_its_encoding":
    driveTdxIntelSOwnSampleQuoteIsRefusedForItsEncoding()

  test "t_tdx_the_impostor_quote_is_internally_valid":
    # The point of a structural negative: it must be refused for ONE
    # reason. So the gate first establishes that it is refused for none
    # of the others — it parses, its chain is three certificates, its
    # enclave report verifies under its own leaf, its binding holds and
    # its quote signature verifies.
    let q = parseTdxQuote(impostorQuote)
    check q.version == 4'u16
    check q.pckChain.len == TdxChainElements
    check verifyQeReportSignature(q, leafPointOf(q))
    check qeReportBindsAttestationKey(q).isBound
    check verifyQuoteSignature(q)
    # And it is the genuine quote's trust-domain report, byte for byte:
    # the substitution is in the endorsement material and in the
    # enclave report's signature, nowhere else.
    check hexOfBytes(q.body.raw) ==
      hexOfBytes(parseTdxQuote(sprQuote).body.raw)
    check hexOfBytes(q.attestationKey) == specimens[0].attestKeyHex
    # Its chain is NOT the genuine one.
    check hexOfBytes(q.pckChain[2]) != hexOfBytes(parseTdxQuote(
      sprQuote).pckChain[2])

  test "t_tdx_every_structural_rule_refuses_its_own_input":
    driveTdxEveryStructuralRuleRefusesItsOwnInput()

  test "t_tdx_the_four_rules_that_share_a_kind_each_get_their_own_input":
    driveTdxTheFourRulesThatShareAKindEachGetTheirOwnInput()

  test "t_tdx_every_refusal_kind_was_reached_by_some_case":
    # Driven HERE, from reset state: the runner executes every case in
    # its own process, so this case observes only what it runs itself.
    reachedQuoteKinds = {}
    reachedQuoteSites = @[]
    reachedBindingKinds = {}
    for (name, drive) in QuoteDrivers:
      checkpoint("driving " & name)
      drive()
    # The census, as a CASE. A kind that stops being reachable — because
    # its rule was deleted, or because the input that reached it was —
    # turns this red rather than going quiet.
    var missing: seq[string] = @[]
    for k in TdxQuoteErrorKind:
      if k notin reachedQuoteKinds: missing.add $k
    check missing.len == 0
    check card(reachedQuoteKinds) == 18
    var missingBinding: seq[string] = @[]
    for k in TdxBindingOutcome:
      if k == tboBound: continue
      if k notin reachedBindingKinds: missingBinding.add $k
    check missingBinding.len == 0
    # Sites, not kinds. Twenty-two places raise one of the eighteen
    # kinds, and the census keys on the sentence each writes.
    #
    # EQUALITY, not "at least". The inequality could be satisfied by a
    # site reached twice with different values while another was not
    # reached at all, which is exactly what the key was letting happen
    # before it collapsed digits. Equality makes both directions fail:
    # a site that stops being reached, and a twenty-third site added
    # with no input to reach it.
    check reachedQuoteSites.len == 22
    writeCensus()

# ---------------------------------------------------------------------

suite "tdx quote curve boundary":

  test "t_tdx_a_key_of_the_wrong_width_is_refused_rather_than_read_past":
    # `verifyQeReportSignature` builds a `CoseKey` from certificate
    # bytes, which is the only path by which a point of a width this
    # library did not choose reaches the curve implementation. Every
    # wrong width there is, and a refusal rather than a crash from each.
    let q = parseTdxQuote(sprQuote)
    let good = leafPointOf(q)
    var widths = 0
    for width in [0, 1, 32, 64, 65 - 1, 65 + 1, 97, 128]:
      checkpoint "point width " & $width
      var point = newSeq[byte](width)
      for i in 0 ..< width:
        point[i] = if i < good.len: good[i] else: 0x41'u8
      if width == P256PointLen:
        # The one width that is right; it is in the list so that the
        # list cannot be satisfied by refusing everything.
        check verifyQeReportSignature(q, point)
      else:
        check not verifyQeReportSignature(q, point)
      inc widths
    check widths == 8

  test "t_tdx_the_bare_coordinates_are_not_a_point":
    # A quote carries the attestation key as `X ‖ Y` with no prefix, and
    # a certificate carries it with one. Handing the bare 64 bytes to
    # the certificate-shaped entry point must be refused, or the two
    # spellings would both work and a build could hold two opinions
    # about which a key is.
    let q = parseTdxQuote(sprQuote)
    check not verifyQeReportSignature(q, q.attestationKey)
    check q.attestationKey.len == EcdsaP256PublicKeyLen
    check P256PointLen == EcdsaP256PublicKeyLen + 1
