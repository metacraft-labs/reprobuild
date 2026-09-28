## Every rule the launch-digest calculator has, on its own input.
##
## ## Why this gate builds firmware images instead of editing one
##
## A negative fixture has to be fabricated — an attacker mints their own
## bytes, so the test has to. But a fabricated firmware image is only
## worth something if the fabricator understands the real layout, and the
## usual way to find out that it did not is for every refusal to pass for
## the wrong reason.
##
## So the builder here is checked before it is used, and it is checked in
## the only way that settles it: **it reconstructs the real firmware
## image byte for byte**. The bytes outside the two tables are copied,
## the two tables are re-serialised from what the reader parsed out of
## them, and the result is compared against the published image with
## `==`. If a field's width, an entry's direction, a table's order or a
## length's base were wrong, the reconstruction would differ and the
## positive control would be red before a single refusal was reached.
##
## Every negative case below is then that same reconstruction with one
## named field changed, so a refusal is attributable to the field and to
## nothing else.
##
## ## One rule, one input, one sentence
##
## The refusal vocabulary is per RULE rather than per family of rules —
## see `snp_launch`'s header — and this gate requires every value of it
## to be reached by an input constructed here. That is the census, and
## it is a CASE rather than a report: a rule that stops being reachable
## turns this gate red instead of quietly lowering a number nobody reads.
##
## Each case also asserts the ABSENCE of every other rule's sentence, so
## a case cannot be satisfied by a refusal other than the one it was
## written for. That is the shape this tree has been caught by more than
## a dozen times.
##
## ## One deliberate disagreement with the reference implementation
##
## It is recorded here, with its own case, because a divergence nobody
## wrote down is a defect waiting to be found by somebody else. See "two
## conditions, and they are genuinely two" below.
##
## ## Mocking
##
## None. The published firmware image, and fabrications derived from it.

import std/[exitprocs, os, sequtils, strutils, unittest]

import repro_attest/snp_launch

include ./snp_digest_vectors

# ---------------------------------------------------------------------
# The census, gated
# ---------------------------------------------------------------------

var reachedLaunchConditions: set[SnpLaunchCondition] = {}

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var f: File
  if open(f, path, fmAppend):
    for c in SnpLaunchCondition:
      if c in reachedLaunchConditions: f.writeLine("snp_launch:" & $c)
    f.close()

addExitProc(writeCensus)

var refusalsObserved = 0
  ## Every refusal this gate has SEEN, with the right rule and with no
  ## other rule's wording in it.

proc bytesOfHex(h: string): seq[byte] =
  doAssert h.len mod 2 == 0
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc noteRefusal(msg: string; want: SnpLaunchCondition) =
  inc refusalsObserved
  check SnpLaunchMessage[want] in msg
  for other in SnpLaunchCondition:
    if other == want: continue
    check SnpLaunchMessage[other] notin msg
  reachedLaunchConditions.incl want

template expectRefusal(want: SnpLaunchCondition; body: untyped) =
  var raised = false
  try:
    body
  except SnpLaunchError as err:
    raised = true
    check err.condition == want
    noteRefusal(err.msg, want)
  check raised

# ---------------------------------------------------------------------
# The builder
# ---------------------------------------------------------------------

type
  SynthEntry = object
    guid: string
    value: seq[byte]
    declaredSize: int      ## -1 means "the size the bytes actually take"

  SynthSection = object
    gpa, size, kindNumber: uint32

  SynthFirmware = object
    base: seq[byte]
    entries: seq[SynthEntry]   ## in ASCENDING address order
    footerGuid: string
    declaredFooterSize: int    ## -1 means "the size the table actually takes"
    pageListAt: int
    marker: string
    declaredPageListLen: int   ## -1 means "the bytes actually written"
    revision: uint32
    declaredEntryCount: int    ## -1 means "the sections actually written"
    sections: seq[SynthSection]

proc putLe32(buf: var seq[byte]; at: int; v: uint64) =
  for i in 0 ..< 4: buf[at + i] = byte((v shr (8 * i)) and 0xff'u64)

proc le32Bytes(v: uint64): seq[byte] =
  result = newSeq[byte](4)
  putLe32(result, 0, v)

proc entryBytes(e: SynthEntry): seq[byte] =
  ## An entry is its value, then its own length, then its identifier —
  ## the header at the END, which is what makes the table readable only
  ## backwards.
  result = e.value
  let size = if e.declaredSize >= 0: e.declaredSize
             else: e.value.len + OvmfEntryHeaderLen
  result.add byte(size and 0xff)
  result.add byte((size shr 8) and 0xff)
  result.add guidLe(e.guid)

proc pageListBytes(f: SynthFirmware): seq[byte] =
  for c in f.marker: result.add byte(c)
  let declaredLen =
    if f.declaredPageListLen >= 0: f.declaredPageListLen
    else: SevPageListHeaderLen + f.sections.len * SevPageListEntryLen
  result.add le32Bytes(uint64(declaredLen))
  result.add le32Bytes(uint64(f.revision))
  result.add le32Bytes(uint64(
    if f.declaredEntryCount >= 0: f.declaredEntryCount else: f.sections.len))
  for s in f.sections:
    result.add le32Bytes(uint64(s.gpa))
    result.add le32Bytes(uint64(s.size))
    result.add le32Bytes(uint64(s.kindNumber))

proc render(f: SynthFirmware): seq[byte] =
  ## The image: everything outside the two tables copied from the real
  ## one, the two tables written from this record, and the total length
  ## unchanged.
  var table: seq[byte] = @[]
  for e in f.entries: table.add entryBytes(e)
  let footerSize = if f.declaredFooterSize >= 0: f.declaredFooterSize
                   else: table.len + OvmfEntryHeaderLen
  var footer: seq[byte] = @[byte(footerSize and 0xff),
                            byte((footerSize shr 8) and 0xff)]
  footer.add guidLe(f.footerGuid)
  let headLen = f.base.len - OvmfFooterTrailerLen - OvmfEntryHeaderLen -
                table.len
  doAssert headLen > 0
  result = f.base[0 ..< headLen]
  let list = pageListBytes(f)
  doAssert f.pageListAt + list.len <= result.len
  for i in 0 ..< list.len: result[f.pageListAt + i] = list[i]
  result.add table
  result.add footer
  result.add f.base[f.base.len - OvmfFooterTrailerLen ..< f.base.len]

# ---------------------------------------------------------------------
# The faithful reconstruction, driven by the reader
# ---------------------------------------------------------------------

let amdSevFirmware = bytesOfHex(UpstreamOvmfAmdSevSuffixHex)
let ovmfX64Firmware = bytesOfHex(UpstreamOvmfX64SuffixHex)
let parsedAmdSev = parseOvmfImage(amdSevFirmware)

proc faithful(): SynthFirmware =
  ## Built from what the reader found, not from a transcription. The
  ## reader walks the identifying table backwards, so its entries come
  ## out in descending address order and are reversed here.
  result.base = amdSevFirmware
  for i in countdown(parsedAmdSev.entries.len - 1, 0):
    result.entries.add SynthEntry(guid: parsedAmdSev.entries[i].guid,
      value: parsedAmdSev.entries[i].value, declaredSize: -1)
  result.footerGuid = OvmfTableFooterGuid
  result.declaredFooterSize = -1
  let pointerValue = parsedAmdSev.entryValue(OvmfSevMetadataGuid)
  var offsetFromEnd = 0
  for i in countdown(3, 0):
    offsetFromEnd = (offsetFromEnd shl 8) or int(pointerValue[i])
  result.pageListAt = amdSevFirmware.len - offsetFromEnd
  result.marker = SevPageListMarker
  result.declaredPageListLen = -1
  result.revision = SevPageListRevision
  result.declaredEntryCount = -1
  for s in parsedAmdSev.sections:
    result.sections.add SynthSection(gpa: s.gpa, size: s.size,
      kindNumber: uint32(ord(s.kind)))

proc entryIndex(f: SynthFirmware; guid: string): int =
  result = -1
  for i, e in f.entries:
    if e.guid == guid: return i

proc sectionIndex(f: SynthFirmware; kind: OvmfSectionKind): int =
  result = -1
  for i, s in f.sections:
    if s.kindNumber == uint32(ord(kind)): return i

proc snpParams(firmware: seq[byte]; vcpus = 1; hasKernel = false):
    SevLaunchParameters =
  SevLaunchParameters(mode: slmSevSnp, firmware: firmware, vcpus: vcpus,
    vcpuSignature: cpuSignatureFor("EPYC-v4"), guestFeatures: 0x21,
    vmm: svkQemu, hasKernel: hasKernel, cmdline: "console=ttyS0")

proc driveAnImageTooShortToCarryAFooterIsRefused() =
  ## The body of test
  ##   "an image too short to carry a footer is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  expectRefusal(slcFirmwareTooSmall):
    discard parseOvmfImage(amdSevFirmware[0 ..< 49])
  # And one byte longer is not, so the bound is the bound rather than
  # an artefact of the value chosen.
  expectRefusal(slcNoGuidFooter):
    discard parseOvmfImage(amdSevFirmware[0 ..< 50])
  check refusalsObserved == refusalsBefore + 2

proc driveAnImageThatIsNotAWholeNumberOfPagesIsRefused() =
  ## The body of test
  ##   "an image that is not a whole number of pages is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var padded = newSeq[byte](SnpPageSize - 1)
  padded.add amdSevFirmware
  check padded.len mod SnpPageSize != 0
  expectRefusal(slcFirmwareNotWholePages):
    discard snpLaunchDigest(snpParams(padded))
  # One more byte of padding makes it whole pages and it is measured,
  # so the rule is about the remainder and not about the padding.
  var whole = newSeq[byte](SnpPageSize)
  whole.add amdSevFirmware
  check snpLaunchDigest(snpParams(whole)).len == SnpDigestLen

proc driveAnImageWhoseFooterIsNotTheFooterIsRefused() =
  ## The body of test
  ##   "an image whose footer is not the footer is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.footerGuid = "96b582de-1fb2-45f7-baea-a366c55a082e"   ## last digit
  expectRefusal(slcNoGuidFooter):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAFooterShorterThanAFooterIsRefused() =
  ## The body of test
  ##   "a footer shorter than a footer is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.declaredFooterSize = OvmfEntryHeaderLen - 1
  expectRefusal(slcFooterSizeBelowHeader):
    discard parseOvmfImage(render(f))
  # At exactly the header length it is an empty table, not a refusal:
  # the edge is where it is stated to be.
  f.declaredFooterSize = OvmfEntryHeaderLen
  let empty = parseOvmfImage(render(f))
  check empty.entries.len == 0
  check not empty.hasPageList

proc driveATableClaimingToStartBeforeTheImageIsRefused() =
  ## The body of test
  ##   "a table claiming to start before the image is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.declaredFooterSize = 0xffff
  expectRefusal(slcFooterTableStartsBeforeImage):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAnEntryShorterThanAnEntryHeaderIsRefused() =
  ## The body of test
  ##   "an entry shorter than an entry header is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.entries[^1].declaredSize = OvmfEntryHeaderLen - 1
  expectRefusal(slcEntrySizeBelowHeader):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAnEntryClaimingMoreBytesThanTheTableHoldsIsRefused() =
  ## The body of test
  ##   "an entry claiming more bytes than the table holds is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  var tableLen = 0
  for e in f.entries: tableLen += e.value.len + OvmfEntryHeaderLen
  f.entries[^1].declaredSize = tableLen + 1
  # The footer still states the real table length, so the entry is
  # overrunning the table and not the image.
  f.declaredFooterSize = tableLen + OvmfEntryHeaderLen
  expectRefusal(slcEntryOverrunsTable):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAFirmwareThatDeclaresNoPageListCannotBeMeasured() =
  ## The body of test
  ##   "a firmware that declares no page list cannot be measured"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.entries[f.entryIndex(OvmfSevMetadataGuid)].guid =
    "dc886566-984a-4798-a75e-5585a7bf67cd"                ## last digit
  let img = parseOvmfImage(render(f))
  check not img.hasPageList
  check img.entries.len == 5
  expectRefusal(slcNoPageList):
    discard snpLaunchDigest(snpParams(render(f)))
  # The two older shapes never consult the list, so the same image
  # measures under them. This is what says the rule belongs to the
  # shape rather than to the reader.
  check sevLaunchDigest(SevLaunchParameters(mode: slmSev,
    firmware: render(f), vcpus: 1)).len == 32

proc driveAPageListPointerTooShortToHoldAPositionIsRefused() =
  ## The body of test
  ##   "a page-list pointer too short to hold a position is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.entries[f.entryIndex(OvmfSevMetadataGuid)].value = @[1'u8, 2'u8, 3'u8]
  expectRefusal(slcPageListPointerTooShort):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAPageListSaidToBeginOutsideTheImageIsRefused() =
  ## The body of test
  ##   "a page list said to begin outside the image is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  let at = f.entryIndex(OvmfSevMetadataGuid)
  f.entries[at].value = le32Bytes(uint64(amdSevFirmware.len + 1))
  expectRefusal(slcPageListOutsideImage):
    discard parseOvmfImage(render(f))
  f.entries[at].value = le32Bytes(0)
  expectRefusal(slcPageListOutsideImage):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 2

proc driveAPageListHeaderRunningOffTheEndOfTheImageIsRefused() =
  ## The body of test
  ##   "a page-list header running off the end of the image is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.entries[f.entryIndex(OvmfSevMetadataGuid)].value =
    le32Bytes(uint64(SevPageListHeaderLen - 1))
  expectRefusal(slcPageListHeaderOutsideImage):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAPageListWithoutItsMarkerIsRefused() =
  ## The body of test
  ##   "a page list without its marker is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.marker = "ASEW"
  expectRefusal(slcPageListMarker):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAPageListOfAnUnknownRevisionIsRefused() =
  ## The body of test
  ##   "a page list of an unknown revision is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.revision = SevPageListRevision + 1
  expectRefusal(slcPageListRevision):
    discard parseOvmfImage(render(f))
  check refusalsObserved == refusalsBefore + 1

proc driveAPageListShorterThanItsOwnHeaderIsRefused() =
  ## The body of test
  ##   "a page list shorter than its own header is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.declaredPageListLen = SevPageListHeaderLen - 1
  expectRefusal(slcPageListSizeBelowHeader):
    discard parseOvmfImage(render(f))
  # A length long enough to BE a list but reaching past the end of the
  # image is a different condition, and it had no input: the two shared
  # one value, and the sentence that value carries describes the other
  # one. It has its own rule and its own sentence now.
  f.declaredPageListLen = amdSevFirmware.len
  check f.pageListAt + f.declaredPageListLen > amdSevFirmware.len
  expectRefusal(slcPageListRunsPastImage):
    discard parseOvmfImage(render(f))
  # Reaching exactly the end is accepted, so the edge is the edge.
  f.declaredPageListLen = amdSevFirmware.len - f.pageListAt
  check parseOvmfImage(render(f)).hasPageList
  check refusalsObserved == refusalsBefore + 2

proc driveAPageListCountingMoreEntriesThanItHasRoomForIsRefused() =
  ## The body of test
  ##   "a page list counting more entries than it has room for is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.declaredEntryCount = f.sections.len + 1
  expectRefusal(slcPageListEntriesExceedSize):
    discard parseOvmfImage(render(f))
  # One fewer is not refused — it is a shorter list, which is a
  # different thing — so the rule is about the arithmetic and not
  # about the count disagreeing with the bytes.
  f.declaredEntryCount = f.sections.len - 1
  check parseOvmfImage(render(f)).sections.len == f.sections.len - 1

proc driveAPageKindThisBuildCannotAccountForIsRefused() =
  ## The body of test
  ##   "a page kind this build cannot account for is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.sections[0].kindNumber = 99
  expectRefusal(slcUnknownPageKind):
    discard parseOvmfImage(render(f))
  # Every kind the enumeration declares IS accounted for, which is the
  # other direction of the same rule: a kind added to the type and not
  # to the reader's list would be refused on a real image.
  for kind in OvmfSectionKinds:
    var g = faithful()
    g.sections[0].kindNumber = uint32(ord(kind))
    check parseOvmfImage(render(g)).sections[0].kind == kind
  check OvmfSectionKinds.len == 5
  check OvmfSectionKinds.deduplicate.len == 5

proc driveARegionThatIsNotWholePagesAtAPageBoundaryIsRefused() =
  ## The body of test
  ##   "a region that is not whole pages at a page boundary is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.sections[0].size = f.sections[0].size + 1
  expectRefusal(slcRegionNotPageAligned):
    discard parseOvmfImage(render(f))
  f = faithful()
  f.sections[0].gpa = f.sections[0].gpa + 1
  expectRefusal(slcRegionNotPageAligned):
    discard parseOvmfImage(render(f))
  f = faithful()
  f.sections[0].size = 0
  expectRefusal(slcRegionNotPageAligned):
    discard parseOvmfImage(render(f))

  # -------------------------------------------------------------------
  # The kernel's digests
  # -------------------------------------------------------------------
  check refusalsObserved == refusalsBefore + 3

proc driveTwoConditionsAndTheyAreGenuinelyTwo() =
  ## The body of test
  ##   "two conditions, and they are genuinely two"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A firmware must publish the ADDRESS the table of kernel digests
  # goes at, and its page list must RESERVE the region that address
  # falls in. Those are two separate statements in two separate
  # tables, and a firmware can make either without the other.
  #
  # The reference implementation checks only the second one for this
  # launch shape, and computes a number for the first — placing the
  # table at offset zero in the page, which is not where the
  # hypervisor would write it. This build refuses instead. It is a
  # DELIBERATE disagreement, recorded here with its input, because a
  # divergence nobody wrote down is a defect somebody else finds.
  var noAddress = faithful()
  noAddress.entries[noAddress.entryIndex(SevHashTableRvGuid)].value =
    @[0'u8, 0, 0, 0, 0, 0, 0, 0]
  let a = parseOvmfImage(render(noAddress))
  check a.kernelDigestsTableGpa() == 0
  check a.reservesKernelDigestRegion()
  expectRefusal(slcKernelDigestsNoAddress):
    discard snpLaunchDigest(snpParams(render(noAddress), hasKernel = true))

  var noRegion = faithful()
  noRegion.sections.delete(noRegion.sectionIndex(oskKernelDigests))
  let b = parseOvmfImage(render(noRegion))
  check b.kernelDigestsTableGpa() != 0
  check not b.reservesKernelDigestRegion()
  expectRefusal(slcKernelDigestsNoRegion):
    discard snpLaunchDigest(snpParams(render(noRegion), hasKernel = true))

  # Neither refusal fires when no kernel is offered: a launch that
  # measures no kernel needs neither the address nor the region.
  check snpLaunchDigest(snpParams(render(noAddress))).len == SnpDigestLen
  check snpLaunchDigest(snpParams(render(noRegion))).len == SnpDigestLen

proc driveThePublishedFirmwareWithoutADigestRegionRefusesAKernel() =
  ## The body of test
  ##   "the published firmware without a digest region refuses a kernel"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The same rule on a real image rather than a fabricated one: the
  # second published fixture is the plain firmware build, and it has
  # neither the address nor the region.
  let img = parseOvmfImage(ovmfX64Firmware)
  check img.kernelDigestsTableGpa() == 0
  check not img.reservesKernelDigestRegion()
  # This rule has TWO sites — one per launch shape — and a case that
  # asserted the rule would be satisfied while only one of them
  # worked. So both are exercised, and each site's sentence is
  # required to name its own shape and NOT the other's.
  var sentences: seq[string] = @[]
  expectRefusal(slcKernelDigestsNoAddress):
    try:
      discard snpLaunchDigest(snpParams(ovmfX64Firmware, hasKernel = true))
    except SnpLaunchError as err:
      sentences.add err.msg
      raise
  expectRefusal(slcKernelDigestsNoAddress):
    try:
      discard sevLaunchDigest(SevLaunchParameters(mode: slmSevEs,
        firmware: ovmfX64Firmware, vcpus: 1, hasKernel: true))
    except SnpLaunchError as err:
      sentences.add err.msg
      raise
  check sentences.len == 2
  check sentences[0] != sentences[1]
  check "region its page list reserves" in sentences[0]
  check "region its page list reserves" notin sentences[1]
  check "appended the digests to the firmware image" in sentences[1]
  check "appended the digests to the firmware image" notin sentences[0]

proc driveADigestTableThatDoesNotFitInItsPageIsRefused() =
  ## The body of test
  ##   "a digest table that does not fit in its page is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  let at = f.entryIndex(SevHashTableRvGuid)
  var value = f.entries[at].value
  # The published address is 0x810c00; move it far enough into the
  # page that the 176-byte table runs past the end.
  let moved = (uint64(value[0]) or (uint64(value[1]) shl 8) or
               (uint64(value[2]) shl 16) or (uint64(value[3]) shl 24))
  let shifted = (moved and not 0xfff'u64) or 0xf80'u64
  for i in 0 ..< 4:
    value[i] = byte((shifted shr (8 * i)) and 0xff'u64)
  f.entries[at].value = value
  check int(shifted mod uint64(SnpPageSize)) +
    SevDigestTablePaddedLen > SnpPageSize
  expectRefusal(slcKernelDigestsOverflowPage):
    discard snpLaunchDigest(snpParams(render(f), hasKernel = true))

proc driveAReservedRegionThatIsNotOnePageIsRefused() =
  ## The body of test
  ##   "a reserved region that is not one page is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.sections[f.sectionIndex(oskKernelDigests)].size = uint32(2 * SnpPageSize)
  expectRefusal(slcKernelDigestsRegionSize):
    discard snpLaunchDigest(snpParams(render(f), hasKernel = true))
  # Without a kernel the same region is folded in as two zero pages
  # rather than refused, because nothing has to fit in it.
  check snpLaunchDigest(snpParams(render(f))).len == SnpDigestLen

proc driveMoreThanOneProcessorNeedsAnAddressForTheOthers() =
  ## The body of test
  ##   "more than one processor needs an address for the others"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var f = faithful()
  f.entries[f.entryIndex(SevEsResetBlockGuid)].guid =
    "00f771de-1a7e-4fcb-890e-68c77e2fb44f"                ## last digit
  check parseOvmfImage(render(f)).resetVectorEip() == 0
  expectRefusal(slcNoResetVector):
    discard snpLaunchDigest(snpParams(render(f), vcpus = 2))
  # One processor does not need it, and the edge is between one and
  # two rather than somewhere else.
  check snpLaunchDigest(snpParams(render(f), vcpus = 1)).len == SnpDigestLen

proc driveAProcessorCountOutsideTheRangeIsRefusedAtBothEnds() =
  ## The body of test
  ##   "a processor count outside the range is refused at both ends"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  expectRefusal(slcProcessorCountOutOfRange):
    discard snpLaunchDigest(snpParams(amdSevFirmware, vcpus = 0))
  expectRefusal(slcProcessorCountOutOfRange):
    discard snpLaunchDigest(snpParams(amdSevFirmware,
      vcpus = MaxProcessors + 1))
  # Both edges are inside, so the bound is the bound. The upper one is
  # a real calculation over a thousand VMSA pages, not a parse.
  check snpLaunchDigest(snpParams(amdSevFirmware, vcpus = 1)).len ==
    SnpDigestLen
  check snpLaunchDigest(snpParams(amdSevFirmware,
    vcpus = MaxProcessors)).len == SnpDigestLen

proc driveAHypervisorThisBuildHasNoRegisterStateForIsRefused() =
  ## The body of test
  ##   "a hypervisor this build has no register state for is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  expectRefusal(slcUnknownHypervisor):
    discard vmmKindFor("cloud-hypervisor")
  expectRefusal(slcUnknownHypervisor):
    discard vmmKindFor("QEMU")             # the names are exact
  # The caller-facing list and the set that is implemented, against
  # each other in both directions. A name in the list that does not
  # resolve, or a hypervisor the list does not offer, is a surface
  # that lies about what this build can compute.
  for name in KnownVmms:
    check $vmmKindFor(name) == name
  for k in SnpVmmKind:
    check $k in KnownVmms
  check KnownVmms.len == 3

proc driveAProcessorModelThisBuildDoesNotKnowIsRefused() =
  ## The body of test
  ##   "a processor model this build does not know is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  expectRefusal(slcUnknownProcessorModel):
    discard cpuSignatureFor("EPYC-Bergamo")
  expectRefusal(slcUnknownProcessorModel):
    discard cpuSignatureFor("epyc-v4")     ## the names are exact
  check cpuSignatureFor("EPYC-v4") != 0'u32

proc driveALaunchUnderAParavisorIsRefusedByName() =
  ## The body of test
  ##   "a launch under a paravisor is refused by name"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let refusalsBefore = refusalsObserved
  var f = faithful()
  f.entries[f.entryIndex(SevEsResetBlockGuid)].guid = ParavisorInfoGuid
  expectRefusal(slcParavisorNotMeasured):
    discard parseOvmfImage(render(f))

  # -------------------------------------------------------------------
  # The structures, checked against themselves
  # -------------------------------------------------------------------
  check refusalsObserved == refusalsBefore + 1

# The cases above whose inputs build the launch-condition census and the refusal count.
# The coverage case below drives every one of them itself: the suite
# runner executes each case in its own process (`--run suite::test`),
# so the census holds only what ran in THAT process, and a coverage
# case that read what earlier cases left behind would measure the
# execution mode rather than the code under test.
const LaunchRefusalDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("an image too short to carry a footer is refused",
    driveAnImageTooShortToCarryAFooterIsRefused),
  ("an image that is not a whole number of pages is refused",
    driveAnImageThatIsNotAWholeNumberOfPagesIsRefused),
  ("an image whose footer is not the footer is refused",
    driveAnImageWhoseFooterIsNotTheFooterIsRefused),
  ("a footer shorter than a footer is refused",
    driveAFooterShorterThanAFooterIsRefused),
  ("a table claiming to start before the image is refused",
    driveATableClaimingToStartBeforeTheImageIsRefused),
  ("an entry shorter than an entry header is refused",
    driveAnEntryShorterThanAnEntryHeaderIsRefused),
  ("an entry claiming more bytes than the table holds is refused",
    driveAnEntryClaimingMoreBytesThanTheTableHoldsIsRefused),
  ("a firmware that declares no page list cannot be measured",
    driveAFirmwareThatDeclaresNoPageListCannotBeMeasured),
  ("a page-list pointer too short to hold a position is refused",
    driveAPageListPointerTooShortToHoldAPositionIsRefused),
  ("a page list said to begin outside the image is refused",
    driveAPageListSaidToBeginOutsideTheImageIsRefused),
  ("a page-list header running off the end of the image is refused",
    driveAPageListHeaderRunningOffTheEndOfTheImageIsRefused),
  ("a page list without its marker is refused",
    driveAPageListWithoutItsMarkerIsRefused),
  ("a page list of an unknown revision is refused",
    driveAPageListOfAnUnknownRevisionIsRefused),
  ("a page list shorter than its own header is refused",
    driveAPageListShorterThanItsOwnHeaderIsRefused),
  ("a page list counting more entries than it has room for is refused",
    driveAPageListCountingMoreEntriesThanItHasRoomForIsRefused),
  ("a page kind this build cannot account for is refused",
    driveAPageKindThisBuildCannotAccountForIsRefused),
  ("a region that is not whole pages at a page boundary is refused",
    driveARegionThatIsNotWholePagesAtAPageBoundaryIsRefused),
  ("two conditions, and they are genuinely two",
    driveTwoConditionsAndTheyAreGenuinelyTwo),
  ("the published firmware without a digest region refuses a kernel",
    driveThePublishedFirmwareWithoutADigestRegionRefusesAKernel),
  ("a digest table that does not fit in its page is refused",
    driveADigestTableThatDoesNotFitInItsPageIsRefused),
  ("a reserved region that is not one page is refused",
    driveAReservedRegionThatIsNotOnePageIsRefused),
  ("more than one processor needs an address for the others",
    driveMoreThanOneProcessorNeedsAnAddressForTheOthers),
  ("a processor count outside the range is refused at both ends",
    driveAProcessorCountOutsideTheRangeIsRefusedAtBothEnds),
  ("a hypervisor this build has no register state for is refused",
    driveAHypervisorThisBuildHasNoRegisterStateForIsRefused),
  ("a processor model this build does not know is refused",
    driveAProcessorModelThisBuildDoesNotKnowIsRefused),
  ("a launch under a paravisor is refused by name",
    driveALaunchUnderAParavisorIsRefusedByName)]

suite "the launch-digest calculator refuses what it cannot read exactly":

  test "no rule's sentence is a substring of another's":
    # The property every case below relies on. Checked rather than
    # asserted, because a message edited to overlap another turns every
    # `notin` assertion in this file into a weaker statement silently.
    check snpLaunchMessagesAreDistinguishable()
    var lengths: seq[int] = @[]
    for c in SnpLaunchCondition:
      check SnpLaunchMessage[c].len > 20
      lengths.add SnpLaunchMessage[c].len
    check lengths.len == 27

  test "the builder reconstructs the published firmware byte for byte":
    # The positive control, and the reason any refusal below means
    # anything. If the layout were misunderstood in any of its widths,
    # directions or bases, these 4,096 bytes would differ.
    let rebuilt = render(faithful())
    check rebuilt.len == amdSevFirmware.len
    check rebuilt == amdSevFirmware
    if rebuilt != amdSevFirmware:
      var firstDiff = -1
      for i in 0 ..< min(rebuilt.len, amdSevFirmware.len):
        if rebuilt[i] != amdSevFirmware[i]:
          firstDiff = i
          break
      checkpoint("first difference at " & $firstDiff)
    # And it measures the same, which is the property the rest of the
    # tree cares about.
    check snpLaunchDigest(snpParams(rebuilt)) ==
      snpLaunchDigest(snpParams(amdSevFirmware))
    # The two tables are pinned against the regions they overwrite,
    # separately from the whole-image comparison. Without this, a builder
    # that wrote NO page list at all would still reconstruct the image —
    # the splice would be empty and the copied bytes would carry the
    # original — and the control above would pass while the serialiser it
    # is meant to vouch for did nothing.
    let f = faithful()
    let list = pageListBytes(f)
    check list.len == SevPageListHeaderLen +
      f.sections.len * SevPageListEntryLen
    check list.len == 100
    check amdSevFirmware[f.pageListAt ..< f.pageListAt + list.len] == list
    var table: seq[byte] = @[]
    for e in f.entries: table.add entryBytes(e)
    check table.len == 118
    let tableAt = amdSevFirmware.len - OvmfFooterTrailerLen -
      OvmfEntryHeaderLen - table.len
    check amdSevFirmware[tableAt ..< tableAt + table.len] == table

  test "the reconstruction is accepted, so a refusal below is about its field":
    let f = faithful()
    check parseOvmfImage(render(f)).sections.len == 7
    check snpLaunchDigest(snpParams(render(f), vcpus = 2)).len == SnpDigestLen

  # -------------------------------------------------------------------
  # The image and its identifying table
  # -------------------------------------------------------------------

  test "an image too short to carry a footer is refused":
    driveAnImageTooShortToCarryAFooterIsRefused()

  test "an image that is not a whole number of pages is refused":
    driveAnImageThatIsNotAWholeNumberOfPagesIsRefused()

  test "an image whose footer is not the footer is refused":
    driveAnImageWhoseFooterIsNotTheFooterIsRefused()

  test "a footer shorter than a footer is refused":
    driveAFooterShorterThanAFooterIsRefused()

  test "a table claiming to start before the image is refused":
    driveATableClaimingToStartBeforeTheImageIsRefused()

  test "an entry shorter than an entry header is refused":
    driveAnEntryShorterThanAnEntryHeaderIsRefused()

  test "an entry claiming more bytes than the table holds is refused":
    driveAnEntryClaimingMoreBytesThanTheTableHoldsIsRefused()

  # -------------------------------------------------------------------
  # The list of placed pages
  # -------------------------------------------------------------------

  test "a firmware that declares no page list cannot be measured":
    driveAFirmwareThatDeclaresNoPageListCannotBeMeasured()

  test "a page-list pointer too short to hold a position is refused":
    driveAPageListPointerTooShortToHoldAPositionIsRefused()

  test "a page list said to begin outside the image is refused":
    driveAPageListSaidToBeginOutsideTheImageIsRefused()

  test "a page-list header running off the end of the image is refused":
    driveAPageListHeaderRunningOffTheEndOfTheImageIsRefused()

  test "a page list without its marker is refused":
    driveAPageListWithoutItsMarkerIsRefused()

  test "a page list of an unknown revision is refused":
    driveAPageListOfAnUnknownRevisionIsRefused()

  test "a page list shorter than its own header is refused":
    driveAPageListShorterThanItsOwnHeaderIsRefused()

  test "a page list counting more entries than it has room for is refused":
    driveAPageListCountingMoreEntriesThanItHasRoomForIsRefused()

  test "a page kind this build cannot account for is refused":
    driveAPageKindThisBuildCannotAccountForIsRefused()

  test "a region that is not whole pages at a page boundary is refused":
    driveARegionThatIsNotWholePagesAtAPageBoundaryIsRefused()

  test "two conditions, and they are genuinely two":
    driveTwoConditionsAndTheyAreGenuinelyTwo()

  test "the published firmware without a digest region refuses a kernel":
    driveThePublishedFirmwareWithoutADigestRegionRefusesAKernel()

  test "a digest table that does not fit in its page is refused":
    driveADigestTableThatDoesNotFitInItsPageIsRefused()

  test "a reserved region that is not one page is refused":
    driveAReservedRegionThatIsNotOnePageIsRefused()

  test "the digest table is what the hypervisor writes":
    # The table's own shape, independently of any measurement: its
    # length, its padding, the order of its three entries, and the
    # terminating NUL on the command line.
    let d = kernelDigestsFor(@[], @[], "")
    check SevDigestTableLen == 168
    check SevDigestTablePaddedLen == 176
    let table = kernelDigestTable(d)
    check table.len == SevDigestTablePaddedLen
    check table[0 ..< 16] == guidLe(SevDigestTableHeaderGuid)
    check table[18 ..< 34] == guidLe(SevCmdlineEntryGuid)
    check table[18 + SevDigestEntryLen ..< 34 + SevDigestEntryLen] ==
      guidLe(SevInitrdEntryGuid)
    check table[18 + 2 * SevDigestEntryLen ..< 34 + 2 * SevDigestEntryLen] ==
      guidLe(SevKernelEntryGuid)
    for i in SevDigestTableLen ..< SevDigestTablePaddedLen:
      check table[i] == 0
    # An empty command line is a NUL, not nothing. The two digests below
    # are SHA-256 of one zero byte and of no bytes; a calculator that
    # hashed the empty string would produce the second.
    check d.cmdline != d.initrd
    check kernelDigestsFor(@[], @[], "").cmdline ==
      kernelDigestsFor(@[], @[], "").cmdline
    check kernelDigestsFor(@[], @[], "a").cmdline !=
      kernelDigestsFor(@[], @[], "a\0").cmdline
    check d.kernel == d.initrd        ## both are SHA-256 of no bytes

  # -------------------------------------------------------------------
  # The processors
  # -------------------------------------------------------------------

  test "more than one processor needs an address for the others":
    driveMoreThanOneProcessorNeedsAnAddressForTheOthers()

  test "a processor count outside the range is refused at both ends":
    driveAProcessorCountOutsideTheRangeIsRefusedAtBothEnds()

  test "a hypervisor this build has no register state for is refused":
    driveAHypervisorThisBuildHasNoRegisterStateForIsRefused()

  test "a processor model this build does not know is refused":
    driveAProcessorModelThisBuildDoesNotKnowIsRefused()

  test "a launch under a paravisor is refused by name":
    driveALaunchUnderAParavisorIsRefusedByName()

  test "the page-info structure tiles its own length":
    var spans = @[(OffPageInfoDigestCur, SnpDigestLen),
                  (OffPageInfoContents, SnpDigestLen),
                  (OffPageInfoLength, 2), (OffPageInfoPageKind, 1),
                  (OffPageInfoImiPage, 1), (OffPageInfoVmpl3Perms, 1),
                  (OffPageInfoVmpl2Perms, 1), (OffPageInfoVmpl1Perms, 1),
                  (OffPageInfoReserved67, 1), (OffPageInfoGpa, 8)]
    var covered = 0
    var at = 0
    for s in spans:
      check s[0] == at
      at = s[0] + s[1]
      covered += s[1]
    check covered == SnpPageInfoLen
    check at == SnpPageInfoLen
    # And the bytes really land there. Two distinguishable inputs, read
    # back out of the structure the module built.
    let ld = newSeq[byte](SnpDigestLen)
    var contents = newSeq[byte](SnpDigestLen)
    for i in 0 ..< SnpDigestLen: contents[i] = byte(i + 1)
    let info = pageInfoBytes(ld, contents, spkSecrets, 0x1234_5678_9abc_d000'u64)
    check info.len == SnpPageInfoLen
    check info[OffPageInfoContents ..< OffPageInfoContents + SnpDigestLen] ==
      contents
    check info[OffPageInfoLength] == byte(SnpPageInfoLen)
    check info[OffPageInfoLength + 1] == 0
    check info[OffPageInfoPageKind] == 5
    check info[OffPageInfoGpa] == 0x00
    check info[OffPageInfoGpa + 1] == 0xd0
    check info[OffPageInfoGpa + 7] == 0x12
    for i in OffPageInfoImiPage .. OffPageInfoReserved67:
      check info[i] == 0
    # The page kinds are the vendor's numbers, and a gate that did not
    # say so would let them be renumbered into whatever order the
    # enumeration happened to have.
    check ord(spkNormal) == 1
    check ord(spkVmsa) == 2
    check ord(spkZero) == 3
    check ord(spkUnmeasured) == 4
    check ord(spkSecrets) == 5
    check ord(spkCpuid) == 6

  test "the processor-state page is exactly the fields that are declared":
    var seen = newSeq[bool](SnpPageSize)
    var total = 0
    for f in SnpVmsaFieldOffsets:
      check f.at >= 0
      check f.at + f.len <= SnpPageSize
      for i in f.at ..< f.at + f.len:
        check not seen[i]           ## no two declared fields overlap
        seen[i] = true
      total += f.len
    check total == 254
    # Every byte the builder writes is inside a declared field. Checked
    # under six parameter sets — three hypervisors by two reset vectors —
    # because the hypervisors write different values and a field only one
    # of them sets would otherwise be invisible.
    for vmm in [svkQemu, svkEc2, svkGce]:
      for eip in [VmsaBspEip, 0x0080_b004'u32]:
        let page = vmsaPage(eip, 0x21'u64, cpuSignatureFor("EPYC-v4"), vmm)
        check page.len == SnpPageSize
        for i in 0 ..< SnpPageSize:
          if not seen[i]: check page[i] == 0

  test "an identifier survives the round trip through the table's order":
    # The stored order is not the written order, and getting it wrong
    # would make every identifier unrecognisable — which would show up
    # as a firmware with no tables rather than as a wrong answer.
    for guid in [OvmfTableFooterGuid, SevHashTableRvGuid,
                 SevEsResetBlockGuid, OvmfSevMetadataGuid,
                 ParavisorInfoGuid, SevDigestTableHeaderGuid,
                 SevKernelEntryGuid, SevInitrdEntryGuid,
                 SevCmdlineEntryGuid]:
      check guidCanonical(guidLe(guid)) == guid
    # The mixing is real: the first three groups are byte-reversed and
    # the last two are not.
    let stored = guidLe("00010203-0405-0607-0809-0a0b0c0d0e0f")
    check stored == @[3'u8, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]

  test "every rule has been reached by an input built in this gate":
    # The census, as a CASE. A rule that stops being reachable is red
    # here rather than silently absent from a report — and the
    # vocabulary is per rule, so a rule added under an existing family
    # cannot hide inside one that is already reached.
    # Drive every input the census is built from, HERE and from an
    # empty census, so the verdict is the same whether this case runs
    # alone (the runner gives each case its own process) or after
    # the cases above.
    reachedLaunchConditions = {}
    refusalsObserved = 0
    for (name, drive) in LaunchRefusalDrivers:
      checkpoint("driving " & name)
      drive()
    var unreached: seq[string] = @[]
    for c in SnpLaunchCondition:
      if c notin reachedLaunchConditions: unreached.add $c
    check unreached == newSeq[string]()
    if unreached.len > 0: checkpoint("unreached: " & unreached.join(", "))
    check refusalsObserved == 36
