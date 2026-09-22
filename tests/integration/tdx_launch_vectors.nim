## The corpus the trust-domain measurement gates read, and where every
## byte of it came from.
##
## ## Two genuine quotes, two operators, two firmwares
##
## This corpus is not a calculator checked against another calculator.
## Two unrelated operators each run real trust-domain machines, each
## serve a quote from one at an unauthenticated well-known path, and
## each publish the firmware image their domains are created with. Both
## quotes' initial-memory measurements are recomputed here from those
## published images.
##
##   * **Operator A.** `quote-operator-a.bin`, 5,247 bytes, fetched
##     2026-09-22 from `deepseek-v4-1-flash-inf16.tinfoil.containers.
##     tinfoil.dev/.well-known/tinfoil-attestation` (the body is
##     base64 over gzip; the pinned bytes are the quote inside it).
##     Version 4, TEE type 0x81. Its firmware is a stock distribution
##     package: `usr/share/ovmf/OVMF.fd` from Ubuntu's
##     `ovmf_2025.02-3ubuntu2_all.deb`, which that operator pins BY
##     DIGEST in a public toolchain lock, and whose measurement it also
##     publishes as an endorsement for every one of its machine shapes.
##   * **Operator B.** `quote-operator-b.bin`, 5,006 bytes, fetched the
##     same day from `api.redpill.ai/v1/attestation/report`. Version 4,
##     TEE type 0x81. Its firmware is `ovmf.fd` out of the
##     `dstack-0.5.9` image release, whose digest the quote's own
##     accompanying configuration names — and the same response carries
##     the domain's **measurement record**, which is why operator B is
##     the one that proves the runtime half.
##
## **The two operators' hosts fold in DIFFERENT orders, and that is the
## finding this corpus exists to have made.** Operator A's measurement
## is reproduced only by extending each page immediately after adding
## it; operator B's only by adding a whole region and then extending it.
## Each order gives the wrong answer for the other's quote. A one-host
## corpus would have shipped whichever order it happened to meet as a
## constant, and been silently wrong for every other host — which is the
## `SnpVmmKind` situation next door, arrived at by evidence rather than
## by reading a specification.
##
## **A re-fetch will not reproduce these bytes, and that is the point.**
## A quote is minted per request over fresh report data. What reproduces
## is the measurement: any quote from either operator's fleet carries
## the same `MRTD`, and that is a much stronger statement than a static
## file agreeing with itself. The pinned bytes are one observation each,
## dated, and the digests below are of those observations.
##
## ## What each fixture is for, stated rather than left to its name
##
## The two firmwares are not redundant. Their section tables differ —
## operator B's temporary-memory region is one page larger and sits at a
## different address — so a build that hard-coded either table produces
## the wrong answer for the other. One firmware would have left that
## dimension with no input at all, which is the shape the neighbouring
## calculator's review named: a corpus that is single-anything disables
## every rule about its dimension.
##
## What the two firmwares do NOT cover, said plainly: neither carries a
## section the host adds blank, a section whose contents are shorter
## than the memory it claims, or a second measured section. Those three
## dimensions have no published example in reach and are exercised by
## `syntheticFirmware` below, which carries no provenance and is
## evidence about nothing.
##
## `TdxGenuineTpmEventLog` is a real log a real platform wrote — the
## measured boot this repository already commits — and it is here for
## what it is NOT: a trust domain's log. It carries no long-digest bank,
## so it is the input that rule needs and nobody had to forge it.
##
## ## Mocking
##
## None. The firmwares are shipped binaries, the quotes were served by
## machines, and the digests are real SHA-384 over them.

import std/[strutils]

import nimcrypto/[hash, sha2]

import repro_attest/tdx_launch

import ./attested_boot_vectors

const
  FirmwareUbuntu* =
    staticRead("fixtures/tdx/ovmf-ubuntu-2025.02-3ubuntu2.fd")
  FirmwareDstack* = staticRead("fixtures/tdx/ovmf-dstack-0.5.9.fd")
  QuoteOperatorA* = staticRead("fixtures/tdx/quote-operator-a.bin")
  QuoteOperatorB* = staticRead("fixtures/tdx/quote-operator-b.bin")
  RegisterLogOperatorB* =
    staticRead("fixtures/tdx/dstack-0.5.9-register-log.json")

  FirmwareUbuntuOrigin* =
    "http://archive.ubuntu.com/ubuntu/pool/main/e/edk2/" &
    "ovmf_2025.02-3ubuntu2_all.deb -> usr/share/ovmf/OVMF.fd"
  FirmwareDstackOrigin* =
    "dstack-0.5.9 image release -> ovmf.fd; the image digest " &
    "bd369a8c… that names it is inside operator B's own quote response"

type
  TdxLaunchCase* = enum
    ## The two genuine launches. Enumerated rather than listed so that a
    ## case cannot be dropped by deleting a line: every loop is
    ## `for c in TdxLaunchCase`, and a corpus that shrank to one would
    ## fail its own count.
    lcOperatorA
    lcOperatorB

  TdxLaunchVector* = object
    quote*: string
    firmware*: string
    mrtd*: string
      ## The measurement the QUOTE carries, written out so the gate can
      ## fail loudly rather than comparing two things it computed.
    firmwareSha256*: string
    firmwareOrigin*: string
    hasRegisterLog*: bool
    order*: TdxHostOrder
      ## Which order THIS operator's host folds in. Written per case
      ## rather than once, because the whole point of the corpus is that
      ## the two disagree.
    documentBytes*: int
      ## The served buffer is a FIXED SIZE and the quote is its prefix;
      ## the rest is zero padding the transport adds. Pinned as a number
      ## so that a wrong split is a failure rather than a shorter
      ## document nobody measured.

const
  TdxLaunchVectors*: array[TdxLaunchCase, TdxLaunchVector] = [
    lcOperatorA: TdxLaunchVector(
      quote: QuoteOperatorA,
      firmware: FirmwareUbuntu,
      mrtd: "7357a10d2e2724dffe68813e3cc4cfcde6814d749f2fb62e39" &
            "53e54f6e0b50a219786afe2cd478f684b52c61837e1114",
      firmwareSha256: "9e807cb2cd4313406a3aa4becc0836671a5c64ca7bdc08a45" &
                      "e15260184b446bf",
      firmwareOrigin: FirmwareUbuntuOrigin,
      hasRegisterLog: false,
      order: thoExtendAfterEachPage,
      documentBytes: 4940),
    lcOperatorB: TdxLaunchVector(
      quote: QuoteOperatorB,
      firmware: FirmwareDstack,
      mrtd: "f06dfda6dce1cf904d4e2bab1dc370634cf95cefa2ceb2de2e" &
            "ee127c9382698090d7a4a13e14c536ec6c9c3c8fa87077",
      firmwareSha256: "76888ce69c91aed86c43f840b913899b40b981964b7ce601" &
                      "8667f91ad06301f0",
      firmwareOrigin: FirmwareDstackOrigin,
      hasRegisterLog: true,
      order: thoExtendAfterTheRegion,
      documentBytes: 4936)]

type
  TdxMrtdPublisher* = enum
    ## The parties that publish operator A's firmware measurement as an
    ## EXPECTATION, independently of any quote. The quote is the
    ## evidence; these two are the corroboration, and they are separate
    ## claims resting on separate evidence on purpose.
    mpReferenceCalculator
    mpFleetEndorsement

  TdxPublishedMrtd* = object
    value*: string
    where*: string

const
  PublishedMrtd*: array[TdxMrtdPublisher, TdxPublishedMrtd] = [
    mpReferenceCalculator: TdxPublishedMrtd(
      value: "7357a10d2e2724dffe68813e3cc4cfcde6814d749f2fb62e39" &
             "53e54f6e0b50a219786afe2cd478f684b52c61837e1114",
      where: "virtee/tdx-measure, all three of tests/fixtures/" &
             "{canonical-defaults,q35-with-hpet,runtime-capture}/" &
             "expected.json; its own tests/fetch_ovmf.sh pins the same " &
             "package and the same sha256, so both halves are published " &
             "together rather than asserted to match"),
    mpFleetEndorsement: TdxPublishedMrtd(
      value: "7357a10d2e2724dffe68813e3cc4cfcde6814d749f2fb62e39" &
             "53e54f6e0b50a219786afe2cd478f684b52c61837e1114",
      where: "operator A's platform-endorsements release v0.0.14, the " &
             "same value under measurements[*].mrtd for every one of " &
             "sixteen machine shapes — which is itself a statement that " &
             "the measurement depends on the firmware and on nothing else")]

  # Each firmware's section table, as ORDERED literals.
  #
  # Ordered, because the order is an input: neither table is in ascending
  # address order, and walking them that way produces a different
  # well-formed value. A test comparing them as sets would not notice.
  SectionKindsA*: array[6, int] = [0, 1, 3, 3, 2, 3]
  SectionAddressesA*: array[6, uint64] = [
    0xFFC84000'u64, 0xFFC00000'u64, 0x811000'u64,
    0x80B000'u64, 0x809000'u64, 0x800000'u64]
  SectionSizesA*: array[6, uint64] = [
    0x37C000'u64, 0x84000'u64, 0xF000'u64,
    0x2000'u64, 0x2000'u64, 0x6000'u64]

  SectionKindsB*: array[6, int] = [0, 1, 3, 3, 2, 3]
  SectionAddressesB*: array[6, uint64] = [
    0xFFC84000'u64, 0xFFC00000'u64, 0x810000'u64,
    0x80B000'u64, 0x809000'u64, 0x800000'u64]
  SectionSizesB*: array[6, uint64] = [
    0x37C000'u64, 0x84000'u64, 0x10000'u64,
    0x2000'u64, 0x2000'u64, 0x6000'u64]

  MeasuredSectionsBoth*: array[6, bool] =
    [true, false, false, false, false, false]

  MeasuredPagesBoth* = 892
    ## 0x37C000 bytes of boot volume, in BOTH firmwares. Written as a
    ## number so that a corpus shrinking to a single page is a failure
    ## rather than a smaller number nobody compares.
  PlacedPagesA* = 892 + 132 + 15 + 2 + 2 + 6
  PlacedPagesB* = 892 + 132 + 16 + 2 + 2 + 6

  OperatorBRegistersReached* = 4
    ## Operator B's record folds into all four registers, so the replay
    ## has an input for every one — including the fourth, which both of
    ## the other quotes in this repository leave at its reset value.

# ---------------------------------------------------------------------
# Minting a firmware
# ---------------------------------------------------------------------

type
  MintedSection* = object
    ## One row of a minted firmware's table. Every field is written by
    ## the caller, including the ones a well-formed firmware would never
    ## get wrong, because the rules under test are exactly the rules
    ## about those fields.
    dataOffset*: uint32
    rawSize*: uint32
    memoryAddress*: uint64
    memorySize*: uint64
    kind*: uint32
    attributes*: uint32

const
  OvmfFooterGuidBytes*: array[16, byte] = [
    0xDE'u8, 0x82, 0xB5, 0x96, 0xB2, 0x1F, 0xF7, 0x45,
    0xBA, 0xEA, 0xA3, 0x66, 0xC5, 0x5A, 0x08, 0x2D]
  TdxMetadataGuidBytes*: array[16, byte] = [
    0x35'u8, 0x65, 0x7A, 0xE4, 0x4A, 0x98, 0x98, 0x47,
    0x86, 0x5E, 0x46, 0x85, 0xA7, 0xBF, 0x8E, 0xC2]

proc putLe*(s: var string; at: int; value: uint64; width: int) =
  var v = value
  for i in 0 ..< width:
    s[at + i] = char(v and 0xFF'u64)
    v = v shr 8

proc syntheticFirmware*(sections: openArray[MintedSection];
                        payload = "";
                        signature = "TDVF";
                        version = 1'u32;
                        declaredLength = -1;
                        declaredCount = -1;
                        metadataEntryBytes = 4;
                        backOverride = -1;
                        includeMetadataEntry = true;
                        footerGuid = OvmfFooterGuidBytes): string =
  ## A firmware image carrying exactly the table asked for.
  ##
  ## The layout is the one the shared footer reader walks: the payload,
  ## then the descriptor, then the entry table, then the two-byte table
  ## length, the sixteen-byte terminating identifier, and thirty-two
  ## bytes of tail the reader skips. Everything a rule is about is a
  ## parameter, so that no rule has to be reached by corrupting a byte
  ## whose meaning the test would then have to re-derive.
  let count = if declaredCount >= 0: declaredCount else: sections.len
  let descriptorLen = 16 + sections.len * 32
  let entryLen = 18 + metadataEntryBytes
  let tableSize = (if includeMetadataEntry: entryLen else: 0)
  let descriptorAt = payload.len
  let tableStart = descriptorAt + descriptorLen
  let footerAt = tableStart + tableSize
  let total = footerAt + 18 + 32
  result = newString(total)
  for i in 0 ..< total: result[i] = '\0'
  for i in 0 ..< payload.len: result[i] = payload[i]

  for i in 0 ..< min(4, signature.len):
    result[descriptorAt + i] = signature[i]
  let declared =
    if declaredLength >= 0: uint64(declaredLength) else: uint64(descriptorLen)
  result.putLe(descriptorAt + 4, declared, 4)
  result.putLe(descriptorAt + 8, uint64(version), 4)
  result.putLe(descriptorAt + 12, uint64(count), 4)
  for i, s in sections:
    let o = descriptorAt + 16 + i * 32
    result.putLe(o, uint64(s.dataOffset), 4)
    result.putLe(o + 4, uint64(s.rawSize), 4)
    result.putLe(o + 8, s.memoryAddress, 8)
    result.putLe(o + 16, s.memorySize, 8)
    result.putLe(o + 24, uint64(s.kind), 4)
    result.putLe(o + 28, uint64(s.attributes), 4)

  if includeMetadataEntry:
    let back = if backOverride >= 0: backOverride else: total - descriptorAt
    if metadataEntryBytes > 0:
      result.putLe(tableStart, uint64(back), min(metadataEntryBytes, 8))
    result.putLe(tableStart + metadataEntryBytes, uint64(entryLen), 2)
    for i in 0 ..< 16:
      result[tableStart + metadataEntryBytes + 2 + i] =
        char(TdxMetadataGuidBytes[i])

  result.putLe(footerAt, uint64(tableSize + 18), 2)
  for i in 0 ..< 16:
    result[footerAt + 2 + i] = char(footerGuid[i])

proc wellFormedSections*(): seq[MintedSection] =
  ## A table that is ACCEPTED, so that every refusal below is one field
  ## away from a firmware this build reads rather than a pile of zeroes.
  ## It covers the three dimensions neither genuine firmware has: a
  ## second measured section, a section whose contents are shorter than
  ## its memory, and a section the host adds blank.
  @[MintedSection(dataOffset: 0, rawSize: 0x2000,
                  memoryAddress: 0xFFC00000'u64, memorySize: 0x2000,
                  kind: 0, attributes: 1),
    MintedSection(dataOffset: 0x2000, rawSize: 0x1000,
                  memoryAddress: 0xFFC10000'u64, memorySize: 0x3000,
                  kind: 5, attributes: 1),
    MintedSection(dataOffset: 0, rawSize: 0, memoryAddress: 0x800000'u64,
                  memorySize: 0x1000, kind: 2, attributes: 0),
    MintedSection(dataOffset: 0, rawSize: 0, memoryAddress: 0x900000'u64,
                  memorySize: 0x2000, kind: 4, attributes: 2)]

proc wellFormedFirmware*(): string =
  syntheticFirmware(wellFormedSections(), payload = repeat('\xA5', 0x3000))

# ---------------------------------------------------------------------
# Minting a trust domain's binary log
# ---------------------------------------------------------------------

const
  Sha384AlgId* = 0x000C'u16
  Sha256AlgId* = 0x000B'u16
  EvNoActionValue* = 3'u32
  EvEventTagValue* = 6'u32

proc specIdHeaderEntry(alg: uint16; digestBytes: uint16): string =
  ## The legacy-shaped first entry every crypto-agile log opens with,
  ## deliberately readable by a parser that knows only the old shape.
  var data = ""
  data.add "Spec ID Event03\0"
  var tmp = newString(4); tmp.putLe(0, 0'u64, 4); data.add tmp
  data.add char(0)
  data.add char(2)
  data.add char(0)
  data.add char(2)
  tmp = newString(4); tmp.putLe(0, 1'u64, 4); data.add tmp
  tmp = newString(2); tmp.putLe(0, uint64(alg), 2); data.add tmp
  tmp = newString(2); tmp.putLe(0, uint64(digestBytes), 2); data.add tmp
  data.add char(0)

  result = ""
  var head = newString(4); head.putLe(0, 0'u64, 4); result.add head
  head = newString(4); head.putLe(0, uint64(EvNoActionValue), 4)
  result.add head
  result.add repeat('\0', 20)
  head = newString(4); head.putLe(0, uint64(data.len), 4); result.add head
  result.add data

proc agileEntry(index: int; alg: uint16; digest, data: string): string =
  result = ""
  var head = newString(4); head.putLe(0, uint64(index), 4); result.add head
  head = newString(4); head.putLe(0, uint64(EvEventTagValue), 4)
  result.add head
  head = newString(4); head.putLe(0, 1'u64, 4); result.add head
  head = newString(2); head.putLe(0, uint64(alg), 2); result.add head
  result.add digest
  head = newString(4); head.putLe(0, uint64(data.len), 4); result.add head
  result.add data

proc digest384*(seed: string): string =
  let d = sha384.digest(seed)
  result = newString(48)
  for i in 0 ..< 48: result[i] = char(d.data[i])

proc digest256*(seed: string): string =
  let d = sha256.digest(seed)
  result = newString(32)
  for i in 0 ..< 32: result[i] = char(d.data[i])

proc syntheticRegisterLog*(indices: openArray[int];
                           alg = Sha384AlgId): string =
  ## A log that folds one entry into each index named, in that order.
  let width = if alg == Sha384AlgId: 48'u16 else: 32'u16
  result = specIdHeaderEntry(alg, width)
  for n, index in indices:
    let seed = "trust-domain log entry " & $n & " index " & $index
    result.add agileEntry(index, alg,
      (if alg == Sha384AlgId: digest384(seed) else: digest256(seed)),
      "entry " & $n)

# ---------------------------------------------------------------------
# The provenance table: every corpus, every row checked, both ways
# ---------------------------------------------------------------------

type
  TdxFixtureName* = enum
    ## One value per byte corpus. The table below is indexed BY this
    ## enumeration rather than being a list of rows, so a corpus cannot
    ## exist without a row and a row cannot exist without a corpus. The
    ## defect that shape prevents was filed against the sibling
    ## calculator's corpus: a table documenting that it checked all its rows,
    ## checking a fifth of them, with the headline constant among the
    ## twenty-six it did not check.
    fxFirmwareA
    fxFirmwareB
    fxQuoteA
    fxQuoteB
    fxRegisterLogB
    fxGenuineTpmEventLog

  TdxFixtureProvenance* = object
    bytes*: int
    sha256*: string
    origin*: string
    observed*: string
      ## When these bytes were taken. Empty for a published artifact
      ## that does not change; dated for one served live, because a
      ## re-fetch of a live endpoint returns DIFFERENT bytes and a
      ## reader must not read a mismatch as a refutation.

proc hexOfBytes*(s: string): string =
  const Digits = "0123456789abcdef"
  result = newStringOfCap(s.len * 2)
  for c in s:
    result.add Digits[int(uint8(c) shr 4)]
    result.add Digits[int(uint8(c) and 0xF'u8)]

proc sha256Hex*(s: string): string =
  let d = sha256.digest(s)
  var raw = newString(32)
  for i in 0 ..< 32: raw[i] = char(d.data[i])
  hexOfBytes(raw)

proc hexToBytes*(hex: string): string =
  doAssert hex.len mod 2 == 0
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc fixtureBytes*(name: TdxFixtureName): string =
  ## The bytes behind every row. Exhaustive over the enumeration by
  ## construction: Nim refuses a `case` that does not cover a value, so
  ## a corpus added without bytes does not compile.
  case name
  of fxFirmwareA: FirmwareUbuntu
  of fxFirmwareB: FirmwareDstack
  of fxQuoteA: QuoteOperatorA
  of fxQuoteB: QuoteOperatorB
  of fxRegisterLogB: RegisterLogOperatorB
  of fxGenuineTpmEventLog: hexToBytes(AttestedBootEventLogHex)

const
  TdxFixtureProvenances*: array[TdxFixtureName, TdxFixtureProvenance] = [
    fxFirmwareA: TdxFixtureProvenance(
      bytes: 4194304,
      sha256: "9e807cb2cd4313406a3aa4becc0836671a5c64ca7bdc08a45" &
              "e15260184b446bf",
      origin: FirmwareUbuntuOrigin,
      observed: ""),
    fxFirmwareB: TdxFixtureProvenance(
      bytes: 4194304,
      sha256: "76888ce69c91aed86c43f840b913899b40b981964b7ce601" &
              "8667f91ad06301f0",
      origin: FirmwareDstackOrigin,
      observed: ""),
    fxQuoteA: TdxFixtureProvenance(
      bytes: 5247,
      sha256: "214e926b905c8541fbc9192d7d42ce38a1f53ba1d89fb883" &
              "3fcf7ddb2828c1ab",
      origin: "operator A, served live at a well-known path over gzip " &
              "inside a base64 envelope",
      observed: "2026-09-22"),
    fxQuoteB: TdxFixtureProvenance(
      bytes: 5006,
      sha256: "585d61c63d162cd59fd42e4b53e8c6b9dac1bfdda49b42d6" &
              "0880f06d0f4db1b2",
      origin: "operator B, served live as the intel_quote member of an " &
              "attestation report",
      observed: "2026-09-22"),
    fxRegisterLogB: TdxFixtureProvenance(
      bytes: 7357,
      sha256: "69d46b1a6a8b7409e2aff24368e9d0a9bce50a3e44653115" &
              "c7b607efa1e23bd3",
      origin: "operator B, the measurement record served beside that " &
              "same quote in the same response",
      observed: "2026-09-22"),
    fxGenuineTpmEventLog: TdxFixtureProvenance(
      bytes: 9700,
      sha256: "ab9cdb41a46dbfaa750f9f9b9d50f9b4237d58351d5e92b6" &
              "06881d1cd711ad9a",
      origin: "a measured boot this repository already commits; a real " &
              "platform's log, carried here for the bank it does NOT have",
      observed: "")]
