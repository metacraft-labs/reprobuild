## The measurement registers an Intel trust domain will report,
## computed before the domain is launched.
##
## ## What this is for
##
## A trust domain's report carries five measurements: `MRTD`, the
## build-time digest of the memory the domain was created with, and four
## runtime registers the domain extends after it starts. Verifying a
## quote's signatures says a real part produced it; it says nothing about
## *what was launched*. Only a value computed independently from the
## launch inputs can say that, and computing it is what this module does.
##
## The result is an expectation an image build publishes and a verifier
## later compares a running domain's quote against. Neither side may take
## the other's word for it, which is why the calculation lives here — one
## implementation, used by the build that publishes the expectation and
## by anyone who reproduces it.
##
## ## The build-time chain, and why it is not the neighbouring one
##
## `snp_launch.nim` folds one 112-byte structure per page into a SHA-384
## *chain*: each link hashes the previous link's output. `MRTD` is not a
## chain, it is a single SHA-384 *stream*. The module opens one digest
## context when the domain is created, feeds 128-byte records into it as
## the host places memory, and finalises it when the domain is sealed.
## Nothing is re-hashed, and there is no intermediate value to carry.
##
## Two kinds of record go in:
##
##   * **one per page placed**, 128 bytes: the ASCII `MEM.PAGE.ADD`
##     padded to 16, the page's guest physical address as a
##     little-endian 64-bit integer, and 104 zero bytes. Only the
##     *address* is in this record — a page added and never extended
##     contributes its position and nothing about its contents;
##   * **three per 256 bytes of measured content**: the ASCII `MR.EXTEND`
##     padded to 16, the chunk's address, 104 zero bytes — and then the
##     256 bytes themselves, as two 128-byte records.
##
## **In which order those two kinds are fed in is the HOST's choice, not
## the firmware's, and the two choices that exist in the wild produce
## different values.** A host may extend each page immediately after
## adding it, or add every page of a region and then extend them all.
## The same bytes go in either way; the digest does not come out the
## same.
##
## This is not read off a specification. It is measured, on both sides,
## against quotes two unrelated operators' machines signed: one
## operator's measurement is reproduced ONLY by extending after each
## page, the other's ONLY by extending after the region, and each order
## gives the wrong answer for the other operator's quote. A sweep over
## the plausible alternatives — the two orders against three section
## orderings — finds exactly one combination for each, so the difference
## really is the interleaving and not something else wearing its clothes.
##
## So `TdxHostOrder` exists for the same reason `SnpVmmKind` exists next
## door: a calculator with one order built in produces a correct number
## for one host and a wrong number everywhere else, and the symptom
## arrives at the far end of a deployment as an attestation failure with
## nothing to point at. There is no default. The caller states it.
##
## What correlates with it, recorded as an OBSERVATION rather than as a
## rule this build relies on: the operator whose host extends after each
## page runs a much newer emulator (10.1) than the one whose host
## extends after the region (8.2). That is two data points. It is not
## enough to infer the order from a version number, and this build does
## not try — it asks.
##
## The sections themselves are walked in the order the firmware's own
## table declares them, which for both real images is **not** ascending
## address order. That too was measured: sorting by address changes the
## answer, under either interleaving.
##
## ## The runtime registers
##
## The four runtime registers are ordinary TCG-style folds —
## `RTMR[i] := SHA-384(RTMR[i] ‖ data)` — and a domain records what it
## folded in a TCG event log exactly as a platform with a discrete
## security chip does. So the replay is the one in `event_log.nim`,
## under SHA-384, and the only trust-domain-specific part is which
## register an entry names: an entry's index is **one more** than the
## runtime register it belongs to, because index 0 is reserved for the
## log's own header. A replay that read the index as the register number
## would attribute every measurement to the register next door and still
## produce four well-formed values.
##
## ## Where the numbers come from
##
## The record layout and the two ASCII tags are Intel's *TDX Module
## Base Architecture Specification*, in the sections describing the page
## addition and measurement extension interfaces. The firmware's
## self-description — a table of sections carrying an offset, a size, a
## guest physical address, a kind and two attribute bits — is the *TDX
## Virtual Firmware Design Guide*. The table is found through the same
## GUID-terminated footer the other vendor's metadata uses, which is why
## this module does not read it itself: `snp_launch.parseOvmfImage`
## already walks that footer, and two readers in one repository
## disagreeing about where a firmware's table begins is the hazard that
## has already been paid for once here over a certificate serial number.
##
## ## What is refused
##
## Everything this module cannot read exactly, and two things it can read
## and should not accept. A firmware that publishes no trust-domain
## table, a table whose descriptor is not one, a section that is not page
## aligned, a section whose contents run off the end of the image, two
## sections claiming the same memory — and a firmware **none of whose
## sections are measured**, whose `MRTD` would then be a function of
## addresses alone and identical for every firmware laid out the same
## way. That last one is the shape a sibling calculator was caught by: a
## corpus in which nothing had contents meant a build that read no
## contents produced every published number correctly.
##
## ## What this build does NOT compute
##
##   * **`RTMR0` from a machine shape.** The first runtime register holds
##     the firmware's measurement of the virtual hardware it was handed —
##     the domain's hand-off block, the configuration volume, and the
##     host's ACPI tables. Reproducing it means reproducing a specific
##     emulator's table generation byte for byte, which is a different
##     piece of work and a much larger one. What is here instead is the
##     replay: given the log the domain wrote, this recomputes all four
##     registers and a verifier can require them to agree with the quote.
##   * **`RTMR1` and `RTMR2` from a kernel and a command line.** Same
##     reason, one layer up.
##   * **A service-domain measurement.** A domain bound to another
##     domain reports a fifth value, and this build does not compute it.
##
## ## Mocking
##
## None. Real firmware bytes, real SHA-384.

import std/[json, strutils]

import nimcrypto/[hash, sha2]

import ./snp_launch
import ./tpm2
import ./event_log

type
  TdxLaunchCondition* = enum
    ## One value per rule. The vocabulary is per *condition* rather than
    ## per family for the reason `snp_launch` states: a value shared by
    ## several rules lets a new rule be added where no assertion can
    ## tell it from its neighbours.
    tlcNoTrustDomainTable
    tlcTablePositionTooShort
    tlcTablePositionIsZero
    tlcTablePositionBeforeImageFront
    tlcDescriptorHeaderPastImageEnd
    tlcNotADescriptor
    tlcUnsupportedDescriptorVersion
    tlcDescriptorLengthDisagreesWithCount
    tlcDescriptorDeclaresNoSections
    tlcSectionTablePastImageEnd
    tlcUnknownSectionKind
    tlcUnknownSectionAttributes
    tlcSectionIsEmpty
    tlcSectionNotPageAligned
    tlcSectionSizeNotWholePages
    tlcSectionDataExceedsItsMemory
    tlcSectionDataOutsideImage
    tlcSectionPositionWithoutContents
    tlcAugmentedSectionIsMeasured
    tlcMeasuredSectionHasNoContents
    tlcSectionsOverlap
    tlcNothingIsMeasured
    tlcBootVolumeIsNotMeasured
    tlcRegisterLogHasNoSha384
    tlcLogNamesAForeignRegister
    tlcEventNamesAForeignRegister
    tlcRegisterLogExtendsNothing
    tlcRegisterWidth
    tlcExtendedValueWidth
    tlcPublishedRegisterIsAResetValue
    tlcUnknownHostOrder
    tlcRecordIsNotReadable
    tlcRecordEntryIsMalformed

  TdxLaunchError* = object of CatchableError
    condition*: TdxLaunchCondition

const
  TdxLaunchMessage*: array[TdxLaunchCondition, string] = [
    tlcNoTrustDomainTable:
      "this firmware publishes nothing about which pages a trust domain " &
      "is created with, so there would be nothing to measure but the image",
    tlcTablePositionTooShort:
      "the entry that should point at the trust-domain table is too short " &
      "to hold a position",
    tlcTablePositionIsZero:
      "the trust-domain table is said to sit at the very end of the " &
      "firmware image, where its own header cannot fit",
    tlcTablePositionBeforeImageFront:
      "the trust-domain table is said to begin before the front of the " &
      "firmware image",
    tlcDescriptorHeaderPastImageEnd:
      "the header of the trust-domain table runs off the end of the " &
      "firmware image",
    tlcNotADescriptor:
      "the trust-domain table does not begin with the four characters " &
      "that identify one",
    tlcUnsupportedDescriptorVersion:
      "the trust-domain table states a version this build has no layout " &
      "for",
    tlcDescriptorLengthDisagreesWithCount:
      "the trust-domain table's stated overall length is not its header " &
      "plus the number of sections it says it carries",
    tlcDescriptorDeclaresNoSections:
      "the trust-domain table carries no sections, so a domain created " &
      "from this firmware would have no memory at all",
    tlcSectionTablePastImageEnd:
      "the sections of the trust-domain table run off the end of the " &
      "firmware image",
    tlcUnknownSectionKind:
      "a section names a kind of memory this build cannot account for, " &
      "and a region placed under the wrong kind is a different number",
    tlcUnknownSectionAttributes:
      "a section sets an attribute bit this build has no rule for, and a " &
      "bit that changes what the host does changes the measurement",
    tlcSectionIsEmpty:
      "a section claims no memory at all, so nothing about it could be " &
      "placed or measured",
    tlcSectionNotPageAligned:
      "a section does not begin on a guest page boundary, and a partial " &
      "page has no address to be measured at",
    tlcSectionSizeNotWholePages:
      "a section does not span a whole number of guest pages",
    tlcSectionDataExceedsItsMemory:
      "a section carries more bytes in the image than it claims memory " &
      "to hold them",
    tlcSectionDataOutsideImage:
      "a section's bytes are said to lie outside the firmware image",
    tlcSectionPositionWithoutContents:
      "a section carries no bytes in the image and still states a " &
      "position for them, so two readers would disagree about whether it " &
      "has contents",
    tlcAugmentedSectionIsMeasured:
      "a section is both added blank by the host and folded into the " &
      "measurement, and there is nothing of it to fold in",
    tlcMeasuredSectionHasNoContents:
      "a section is folded into the measurement and carries no bytes in " &
      "the image, so what would be measured is a run of zeroes",
    tlcSectionsOverlap:
      "two sections claim the same guest memory, and the later one would " &
      "be measured over bytes the earlier one already placed",
    tlcNothingIsMeasured:
      "no section of this firmware is folded into the measurement, so " &
      "the value would depend on addresses alone and every firmware laid " &
      "out this way would produce it",
    tlcBootVolumeIsNotMeasured:
      "the volume a trust domain begins executing is not folded into the " &
      "measurement, so the value would not cover the code that runs first",
    tlcRegisterLogHasNoSha384:
      "the log a trust domain wrote carries no bank this build can fold, " &
      "and the registers a domain reports are the long digest",
    tlcLogNamesAForeignRegister:
      "an entry of the binary log names an index outside the window a " &
      "trust domain's registers occupy, so it is not this machine's log",
    tlcEventNamesAForeignRegister:
      "a fold was asked for against a register number a trust domain " &
      "does not have",
    tlcRegisterLogExtendsNothing:
      "nothing at all was folded in, so every register would be reported " &
      "at its reset value, which is an answer that agrees with every " &
      "domain rather than with this one",
    tlcRegisterWidth:
      "a runtime register was supplied at a width a trust domain's " &
      "registers do not have",
    tlcExtendedValueWidth:
      "a value to be folded into a runtime register was supplied at a " &
      "width the fold does not take",
    tlcPublishedRegisterIsAResetValue:
      "the log reached none of the folds for a register this build is " &
      "about to publish, so the expectation would be a row of zeroes " &
      "that agrees with every domain that never extended it",
    tlcUnknownHostOrder:
      "this build has no fold order by the name the caller gave, and " &
      "every order produces a different measurement over the same bytes",
    tlcRecordIsNotReadable:
      "a domain's measurement record was offered in neither shape this " &
      "build reads: it is not a sequence of entries, and a record with " &
      "no entries would fold to every register's reset value",
    tlcRecordEntryIsMalformed:
      "an entry of a domain's measurement record does not carry a " &
      "register number and a digest this build can read"]

proc tdxLaunchMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked, not asserted: this
  ## is the property that makes an `in e.msg` assertion mean one rule.
  for a in TdxLaunchCondition:
    for b in TdxLaunchCondition:
      if a == b: continue
      if TdxLaunchMessage[a] in TdxLaunchMessage[b]: return false
  true

proc tdxFail*(condition: TdxLaunchCondition; detail: string) {.noreturn.} =
  var e = newException(TdxLaunchError, TdxLaunchMessage[condition])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.condition = condition
  raise e

# ---------------------------------------------------------------------
# The firmware's self-description
# ---------------------------------------------------------------------

const
  TdxMetadataOffsetGuid* = "e47a6535-984a-4798-865e-4685a7bf8ec2"
    ## The footer-table entry whose four bytes say how far back from the
    ## END of the image the trust-domain table begins.

  TdvfSignature* = "TDVF"
  TdvfDescriptorHeaderLen* = 16
  TdvfSectionLen* = 32
  TdvfSupportedVersion* = 1'u32

  TdxPageSize* = 4096
  TdxChunkSize* = 256
    ## A measured page is folded in 256 bytes at a time, and each chunk
    ## states its own address. A page is therefore 16 chunks and 48
    ## records.
  TdxRecordLen* = 128
  TdxMeasurementBytes* = 48     ## SHA-384, and the width of every register.
  TdxRuntimeRegisterCount* = 4

  TdxPageAddTag* = "MEM.PAGE.ADD"
  TdxExtendTag* = "MR.EXTEND"
  TdxTagFieldLen* = 16

  TdxFirstLogRegisterIndex* = 1
    ## The event log's index for `RTMR0`. Index 0 is the log's own
    ## header and never names a register.

type
  TdvfSectionKind* = enum
    ## The `Type` field. The ordinals are Intel's; they are not this
    ## enumeration's convenience, because a caller reading a refusal
    ## needs the number the firmware actually wrote.
    tskBootVolume = 0
    tskConfigVolume = 1
    tskHandoffBlock = 2
    tskTemporaryMemory = 3
    tskPermanentMemory = 4
    tskPayload = 5
    tskPayloadParameters = 6

  TdvfSection* = object
    dataOffset*: uint32
      ## Where the section's bytes sit in the firmware image.
    rawSize*: uint32
      ## How many bytes of the image the section carries. Zero means the
      ## host places blank pages.
    memoryAddress*: uint64
    memorySize*: uint64
    kind*: TdvfSectionKind
    measured*: bool
      ## The `MR.EXTEND` attribute: the host folds this section's
      ## contents in, not only its addresses.
    augmented*: bool
      ## The `PAGE.AUG` attribute: the host adds these pages to a domain
      ## that is already running, so they are outside `MRTD` entirely.

const
  AttrMrExtend* = 0x1'u32
  AttrPageAug* = 0x2'u32
  KnownSectionAttributes* = AttrMrExtend or AttrPageAug

proc le(data: openArray[byte]; at, width: int): uint64 =
  for i in countdown(width - 1, 0):
    result = (result shl 8) or uint64(data[at + i])

proc readTdvfSections*(image: openArray[byte]): seq[TdvfSection] =
  ## The firmware's own account of the memory a trust domain is created
  ## with.
  ##
  ## The GUID-terminated footer is read by `snp_launch.parseOvmfImage`,
  ## which is the repository's one reader for that structure. Its rules
  ## — the footer's presence, its stated length, the walk over the
  ## entries — are therefore that reader's rules and are exercised by
  ## its own gate; what is added here begins at the entry this format
  ## cares about.
  let img = parseOvmfImage(image, withPageList = false)
  let position = img.entryValue(TdxMetadataOffsetGuid)
  if position.len == 0:
    tdxFail(tlcNoTrustDomainTable,
      "no entry carrying " & TdxMetadataOffsetGuid & " among the " &
      $img.entries.len & " the footer lists")
  if position.len < 4:
    tdxFail(tlcTablePositionTooShort,
      $position.len & " bytes where a position is 4")

  let back = int(le(position, 0, 4))
  if back == 0:
    tdxFail(tlcTablePositionIsZero, "the stated distance back is 0")
  if back > image.len:
    tdxFail(tlcTablePositionBeforeImageFront,
      $back & " bytes back from the end of a " & $image.len & "-byte image")

  let at = image.len - back
  if at + TdvfDescriptorHeaderLen > image.len:
    tdxFail(tlcDescriptorHeaderPastImageEnd,
      "a " & $TdvfDescriptorHeaderLen & "-byte header at 0x" &
      toHex(at, 8) & " of a " & $image.len & "-byte image")

  var signature = ""
  for i in 0 ..< 4: signature.add char(image[at + i])
  if signature != TdvfSignature:
    tdxFail(tlcNotADescriptor,
      "the four bytes at 0x" & toHex(at, 8) & " are " & signature.escape())

  let declaredLen = uint32(le(image, at + 4, 4))
  let version = uint32(le(image, at + 8, 4))
  let count = int(le(image, at + 12, 4))
  if version != TdvfSupportedVersion:
    tdxFail(tlcUnsupportedDescriptorVersion,
      "version " & $version & "; this build reads " & $TdvfSupportedVersion)
  if count == 0:
    tdxFail(tlcDescriptorDeclaresNoSections, "the stated count is 0")
  let expectedLen = TdvfDescriptorHeaderLen + count * TdvfSectionLen
  if int(declaredLen) != expectedLen:
    tdxFail(tlcDescriptorLengthDisagreesWithCount,
      "it states " & $declaredLen & " bytes and " & $count &
      " sections, which is " & $expectedLen)
  if at + expectedLen > image.len:
    tdxFail(tlcSectionTablePastImageEnd,
      $count & " sections from 0x" & toHex(at, 8) & " of a " & $image.len &
      "-byte image")

  result = @[]
  for i in 0 ..< count:
    let o = at + TdvfDescriptorHeaderLen + i * TdvfSectionLen
    let dataOffset = uint32(le(image, o, 4))
    let rawSize = uint32(le(image, o + 4, 4))
    let memoryAddress = le(image, o + 8, 8)
    let memorySize = le(image, o + 16, 8)
    let kindNumber = uint32(le(image, o + 24, 4))
    let attributes = uint32(le(image, o + 28, 4))

    var kind = tskBootVolume
    var known = false
    for k in TdvfSectionKind:
      if uint32(ord(k)) == kindNumber:
        kind = k
        known = true
    if not known:
      tdxFail(tlcUnknownSectionKind,
        "section " & $i & " names kind " & $kindNumber)
    if (attributes and not KnownSectionAttributes) != 0:
      tdxFail(tlcUnknownSectionAttributes,
        "section " & $i & " states 0x" & toHex(int(attributes), 8) &
        " and this build knows 0x" & toHex(int(KnownSectionAttributes), 8))

    if memorySize == 0:
      tdxFail(tlcSectionIsEmpty, "section " & $i & " states 0 bytes")
    if memoryAddress mod uint64(TdxPageSize) != 0:
      tdxFail(tlcSectionNotPageAligned,
        "section " & $i & " begins at 0x" & toHex(int64(memoryAddress), 16))
    if memorySize mod uint64(TdxPageSize) != 0:
      tdxFail(tlcSectionSizeNotWholePages,
        "section " & $i & " spans 0x" & toHex(int64(memorySize), 16) &
        " bytes")
    if uint64(rawSize) > memorySize:
      tdxFail(tlcSectionDataExceedsItsMemory,
        "section " & $i & " carries 0x" & toHex(int(rawSize), 8) &
        " bytes into 0x" & toHex(int64(memorySize), 16))
    if rawSize > 0'u32 and
       int(dataOffset) + int(rawSize) > image.len:
      tdxFail(tlcSectionDataOutsideImage,
        "section " & $i & " reads 0x" & toHex(int(rawSize), 8) &
        " bytes from 0x" & toHex(int(dataOffset), 8) & " of a " &
        $image.len & "-byte image")
    if rawSize == 0'u32 and dataOffset != 0'u32:
      tdxFail(tlcSectionPositionWithoutContents,
        "section " & $i & " states position 0x" & toHex(int(dataOffset), 8) &
        " and size 0")

    let measured = (attributes and AttrMrExtend) != 0
    let augmented = (attributes and AttrPageAug) != 0
    if measured and augmented:
      tdxFail(tlcAugmentedSectionIsMeasured,
        "section " & $i & " states 0x" & toHex(int(attributes), 8))
    if measured and rawSize == 0'u32:
      tdxFail(tlcMeasuredSectionHasNoContents,
        "section " & $i & " spans 0x" & toHex(int64(memorySize), 16) &
        " bytes of memory and 0 bytes of image")

    result.add TdvfSection(dataOffset: dataOffset, rawSize: rawSize,
      memoryAddress: memoryAddress, memorySize: memorySize, kind: kind,
      measured: measured, augmented: augmented)

  for i in 0 ..< result.len:
    for j in i + 1 ..< result.len:
      let a = result[i]
      let b = result[j]
      if a.memoryAddress < b.memoryAddress + b.memorySize and
         b.memoryAddress < a.memoryAddress + a.memorySize:
        tdxFail(tlcSectionsOverlap,
          "section " & $i & " at 0x" & toHex(int64(a.memoryAddress), 16) &
          " and section " & $j & " at 0x" &
          toHex(int64(b.memoryAddress), 16))

  var anyMeasured = false
  for s in result:
    if s.measured: anyMeasured = true
  if not anyMeasured:
    tdxFail(tlcNothingIsMeasured,
      $result.len & " sections and none of them is folded in")
  for i, s in result:
    if s.kind == tskBootVolume and not s.measured:
      tdxFail(tlcBootVolumeIsNotMeasured,
        "section " & $i & " is the volume execution begins in")

# ---------------------------------------------------------------------
# The build-time measurement
# ---------------------------------------------------------------------

type
  TdxHostOrder* = enum
    ## The order a host feeds the two kinds of record in. No default,
    ## deliberately: see this module's header. Both values are attested
    ## by a genuine quote in this repository's corpus.
    thoExtendAfterEachPage
      ## Add a page, extend that page, move to the next.
    thoExtendAfterTheRegion
      ## Add every page of a section, then extend every page of it.

  TdxMeasurementContext* = object
    ## The open digest. It carries no intermediate register value,
    ## because `MRTD` has none: the whole creation is one stream.
    ctx: sha384

proc tagged(tag: string; address: uint64): array[TdxRecordLen, byte] =
  ## One 128-byte record: the tag padded to sixteen bytes, the address
  ## as a little-endian sixty-four-bit integer, and zeroes.
  doAssert tag.len <= TdxTagFieldLen
  for i in 0 ..< tag.len: result[i] = byte(tag[i])
  var v = address
  for i in 0 ..< 8:
    result[TdxTagFieldLen + i] = byte(v and 0xFF'u64)
    v = v shr 8

const
  KnownTdxHostOrders*: array[TdxHostOrder, string] = [
    thoExtendAfterEachPage: "per-page",
    thoExtendAfterTheRegion: "per-region"]
    ## The names a caller writes. Descriptive of the BEHAVIOUR rather
    ## than of a host or an emulator version, because this build has two
    ## data points about which host does which and that is not enough to
    ## name them after anybody.

proc tdxHostOrderNames*(): string =
  var names: seq[string] = @[]
  for o in TdxHostOrder: names.add KnownTdxHostOrders[o]
  names.join(", ")

proc tdxHostOrderFor*(name: string): TdxHostOrder =
  for o in TdxHostOrder:
    if KnownTdxHostOrders[o] == name: return o
  tdxFail(tlcUnknownHostOrder,
    name.escape() & "; this build knows " & tdxHostOrderNames())

proc initTdxMeasurement*(): TdxMeasurementContext =
  result.ctx.init()

proc addPage*(m: var TdxMeasurementContext; gpa: uint64) =
  ## What the host does for every page it places: the page's address
  ## goes in, and nothing about its contents does.
  let record = tagged(TdxPageAddTag, gpa)
  m.ctx.update(record)

proc extendPage*(m: var TdxMeasurementContext; gpa: uint64;
                 page: openArray[byte]) =
  ## What the host does for a page whose contents are measured: sixteen
  ## chunks, each announced by its own address and then fed in as two
  ## halves.
  doAssert page.len == TdxPageSize
  for c in 0 ..< TdxPageSize div TdxChunkSize:
    let record = tagged(TdxExtendTag, gpa + uint64(c * TdxChunkSize))
    m.ctx.update(record)
    let base = c * TdxChunkSize
    m.ctx.update(toOpenArray(page, base, base + TdxRecordLen - 1))
    m.ctx.update(toOpenArray(page, base + TdxRecordLen,
                             base + TdxChunkSize - 1))

proc finish*(m: var TdxMeasurementContext): seq[byte] =
  let d = m.ctx.finish()
  result = newSeq[byte](TdxMeasurementBytes)
  for i in 0 ..< TdxMeasurementBytes: result[i] = d.data[i]

proc mrtdOf*(sections: openArray[TdvfSection];
             image: openArray[byte];
             order: TdxHostOrder): seq[byte] =
  ## `MRTD` for a firmware, from its own table of sections and the
  ## order the host that will create the domain feeds records in.
  ##
  ## The sections are walked in TABLE order. That is not a choice — it
  ## is measured, and address order gives a different value for both
  ## genuine firmwares under both interleavings.
  var m = initTdxMeasurement()
  var page = newSeq[byte](TdxPageSize)
  template contentsOf(s: TdvfSection; p: int) =
    # A template rather than a nested procedure: `image` is an
    # `openArray` and a closure may not capture one.
    for i in 0 ..< TdxPageSize: page[i] = 0'u8
    let start = int(s.dataOffset) + p * TdxPageSize
    let available = max(0, min(TdxPageSize,
      int(s.dataOffset) + int(s.rawSize) - start))
    for i in 0 ..< available: page[i] = image[start + i]

  for s in sections:
    if s.augmented: continue
    let pages = int(s.memorySize div uint64(TdxPageSize))
    case order
    of thoExtendAfterEachPage:
      for p in 0 ..< pages:
        let gpa = s.memoryAddress + uint64(p * TdxPageSize)
        m.addPage(gpa)
        if s.measured:
          contentsOf(s, p)
          m.extendPage(gpa, page)
    of thoExtendAfterTheRegion:
      for p in 0 ..< pages:
        m.addPage(s.memoryAddress + uint64(p * TdxPageSize))
      if s.measured:
        for p in 0 ..< pages:
          contentsOf(s, p)
          m.extendPage(s.memoryAddress + uint64(p * TdxPageSize), page)
  m.finish()

proc toHexLower*(data: openArray[byte]): string =
  const Digits = "0123456789abcdef"
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add Digits[int(b shr 4)]
    result.add Digits[int(b and 0xF'u8)]

proc tdxMrtdHex*(image: openArray[byte]; order: TdxHostOrder): string =
  ## `MRTD` for a firmware image, whole: read its table, then fold.
  toHexLower(mrtdOf(readTdvfSections(image), image, order))

# ---------------------------------------------------------------------
# The runtime registers
# ---------------------------------------------------------------------

type
  TdxRuntimeRegisterSet* = array[TdxRuntimeRegisterCount, seq[byte]]

  TdxRuntimeRegisterReplay* = object
    registers*: TdxRuntimeRegisterSet
    extendsApplied*: int
    reached*: array[TdxRuntimeRegisterCount, bool]
      ## Which registers the log actually wrote to. A register the log
      ## never reached holds its reset value, and a verifier comparing
      ## it against a quote has to know which of the two it is looking
      ## at: forty-eight zero bytes agree with every domain that never
      ## extended that register, and that is not evidence.

proc initialRtmr*(): seq[byte] =
  ## A runtime register before anything is folded in. All zero — unlike
  ## six of a discrete chip's registers, which reset to all ones. This
  ## is stated as a value rather than inherited, because the replay this
  ## module borrows knows the other rule and applies it by index.
  newSeq[byte](TdxMeasurementBytes)

proc extendRtmr*(current, value: openArray[byte]): seq[byte] =
  ## One fold: `SHA-384(current ‖ value)`. Both widths are checked
  ## before anything is hashed, because a register or a value of the
  ## wrong length still hashes to *something*, and that something is
  ## indistinguishable from a correct register.
  if current.len != TdxMeasurementBytes:
    tdxFail(tlcRegisterWidth,
      $current.len & " bytes where a register is " & $TdxMeasurementBytes)
  if value.len != TdxMeasurementBytes:
    tdxFail(tlcExtendedValueWidth,
      $value.len & " bytes where a fold takes " & $TdxMeasurementBytes)
  var buf = newSeq[byte](TdxMeasurementBytes * 2)
  for i in 0 ..< TdxMeasurementBytes: buf[i] = current[i]
  for i in 0 ..< TdxMeasurementBytes:
    buf[TdxMeasurementBytes + i] = value[i]
  let d = sha384.digest(buf)
  result = newSeq[byte](TdxMeasurementBytes)
  for i in 0 ..< TdxMeasurementBytes: result[i] = d.data[i]

type
  TdxMeasuredEvent* = object
    ## One fold, reduced to the only two things that change a register.
    ##
    ## This exists because a domain's measurement record is published in
    ## more than one shape — the binary record firmware writes, and the
    ## JSON an agent serves beside a quote — and the FOLD must not be
    ## implemented once per shape. A second implementation of a
    ## one-line hash chain is how two readers come to disagree about
    ## what a machine reported.
    register*: int
      ## 0 to 3. The register itself, NOT the index a log writes.
    digest*: seq[byte]

proc foldTdxRegisters*(events: openArray[TdxMeasuredEvent]): TdxRuntimeRegisterReplay =
  ## The fold, and the only place it happens.
  for r in 0 ..< TdxRuntimeRegisterCount:
    result.registers[r] = initialRtmr()
    result.reached[r] = false
  if events.len == 0:
    tdxFail(tlcRegisterLogExtendsNothing, "0 events supplied")
  for i, e in events:
    if e.register < 0 or e.register >= TdxRuntimeRegisterCount:
      tdxFail(tlcEventNamesAForeignRegister,
        "event " & $i & " names register " & $e.register &
        ", and a domain has " & $TdxRuntimeRegisterCount)
    result.registers[e.register] =
      extendRtmr(result.registers[e.register], e.digest)
    result.reached[e.register] = true
    inc result.extendsApplied

proc tdxEventsFromLog*(log: TcgEventLog): seq[TdxMeasuredEvent] =
  ## The binary log's entries, reduced to what the fold takes.
  ##
  ## The one trust-domain-specific thing about a domain's log is decided
  ## here: an entry's index is one MORE than the register it belongs to,
  ## because index 0 is the log's own header. A reader that took the
  ## index for the register number would attribute every measurement to
  ## the register next door and still produce four well-formed values.
  var carriesSha384 = false
  for b in banks(log):
    if b == TpmAlgSha384: carriesSha384 = true
  if not carriesSha384:
    tdxFail(tlcRegisterLogHasNoSha384,
      "the log declares " &
      (block:
         var names: seq[string] = @[]
         for b in banks(log): names.add $b
         names.join(", ")))
  result = @[]
  for i, event in log.events:
    if event.eventType == EvNoAction: continue
    if event.pcrIndex < TdxFirstLogRegisterIndex or
       event.pcrIndex >= TdxFirstLogRegisterIndex + TdxRuntimeRegisterCount:
      tdxFail(tlcLogNamesAForeignRegister,
        "entry " & $i & " at offset " & $event.wireOffset & " names index " &
        $event.pcrIndex & ", and a domain's four registers are indices " &
        $TdxFirstLogRegisterIndex & " to " &
        $(TdxFirstLogRegisterIndex + TdxRuntimeRegisterCount - 1))
    var digest: seq[byte] = @[]
    for d in event.digests:
      if d.alg == TpmAlgSha384:
        digest = newSeq[byte](d.digest.len)
        for k in 0 ..< d.digest.len: digest[k] = byte(d.digest[k])
    result.add TdxMeasuredEvent(
      register: event.pcrIndex - TdxFirstLogRegisterIndex, digest: digest)

proc replayTdxRegisters*(log: TcgEventLog): TdxRuntimeRegisterReplay =
  ## Recompute the four runtime registers from the binary log a domain's
  ## firmware wrote.
  ##
  ## The parse is `event_log.parseEventLog`'s and the fold is
  ## `foldTdxRegisters`; what is decided HERE is the mapping, which is
  ## the one trust-domain-specific thing about a domain's log: an
  ## entry's index is one MORE than the register it belongs to, because
  ## index 0 is the log's own header. A replay that read the index as
  ## the register number would attribute every measurement to the
  ## register next door and still produce four well-formed values.
  foldTdxRegisters(tdxEventsFromLog(log))

proc tdxEventsFromRecord*(text: string): seq[TdxMeasuredEvent] =
  ## The other shape a domain's record is published in: an array of
  ## entries naming a register and the digest folded into it, which is
  ## what an agent serves beside a quote.
  ##
  ## This is a second front end, NOT a second fold. It ends where the
  ## binary reader ends — at a list of `(register, digest)` — and the
  ## chain itself happens in exactly one place.
  var doc: JsonNode
  var readable = true
  try:
    doc = parseJson(text)
  except CatchableError:
    readable = false
  if not readable or doc.kind != JArray or doc.elems.len == 0:
    tdxFail(tlcRecordIsNotReadable,
      $text.len & " bytes")
  result = @[]
  for i, e in doc.elems:
    var malformed = e.kind != JObject or
      not e.hasKey("imr") or not e.hasKey("digest") or
      e["imr"].kind != JInt or e["digest"].kind != JString
    var raw = ""
    if not malformed:
      let hex = e["digest"].getStr
      if hex.len mod 2 != 0:
        malformed = true
      else:
        raw = newString(hex.len div 2)
        for k in 0 ..< raw.len:
          try:
            raw[k] = char(parseHexInt(hex[2 * k .. 2 * k + 1]))
          except ValueError:
            malformed = true
    if malformed:
      tdxFail(tlcRecordEntryIsMalformed, "entry " & $i)
    var digest = newSeq[byte](raw.len)
    for k in 0 ..< raw.len: digest[k] = byte(raw[k])
    result.add TdxMeasuredEvent(register: e["imr"].getInt, digest: digest)

proc readTdxMeasurementRecord*(data: string): seq[TdxMeasuredEvent] =
  ## Read a record in whichever of the two published shapes it is in.
  ##
  ## The choice is made on the first byte that is not blank: a record
  ## that opens a sequence is the textual shape, anything else is the
  ## binary log firmware writes. That is a rule rather than a guess — a
  ## binary log opens with a register index, and the index a bracket
  ## would spell is not one a platform writes.
  var i = 0
  while i < data.len and data[i] in {' ', '\t', '\n', '\r'}: inc i
  if i < data.len and data[i] == '[':
    tdxEventsFromRecord(data)
  else:
    tdxEventsFromLog(parseEventLog(data))
