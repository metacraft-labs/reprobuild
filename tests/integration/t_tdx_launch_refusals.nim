## Every rule the trust-domain measurement refuses on, with an input.
##
## ## What this gate is, and the two ways its kind usually fails
##
## A refusal vocabulary is worth exactly as much as the proportion of it
## that can actually be reached. Two failures recur in this repository's
## history and both are guarded against here by construction rather than
## by care:
##
##   1. **A rule with no reachable input.** Deleting it leaves every gate
##      green, so it is not a rule the program has. Every value of
##      `TdxLaunchCondition` below is raised by a case, and the census at
##      the end asserts the reached set EQUALS the whole enumeration —
##      an inequality would let a rule reached twice pay for one reached
##      never, which is the defect filed against the sibling
##      reader's census.
##   2. **A census that counts the wrong thing.** The thing worth
##      counting is SITES. That census and this one coincide only
##      because the source is scanned and the coincidence is PROVED: the
##      scan below reads every `tdxFail` call in both files that make
##      them and requires the multiset of conditions it finds to be each
##      value exactly once. A condition raised at two sites fails that
##      scan, and the duplicate this gate was first written against —
##      one kind for a binary log's index and for a supplied event's
##      register — was split into two rules because of it.
##
## ## Where the footer rules are
##
## A trust-domain table is found through a GUID-terminated footer that
## is not this format's: the other vendor's metadata is in the same
## structure, and `snp_launch.parseOvmfImage` is the repository's one
## reader for it. Its refusals are its own and are exercised by its own
## gate. What is here is everything from the trust-domain entry inwards.
##
## ## Mocking
##
## None. Every firmware below is minted by the corpus's own builder from
## real structure; nothing is stubbed.

import std/[strutils, unittest]

import repro_attest

include ./tdx_launch_vectors

# ---------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------

var reached: set[TdxLaunchCondition] = {}

proc refuses(body: proc (): void): ref TdxLaunchError =
  ## Run something that must refuse, record WHICH rule refused, and hand
  ## the error back so the case can pin the sentence too.
  try:
    body()
  except TdxLaunchError as err:
    reached.incl err.condition
    return err
  raise newException(ValueError, "nothing was refused")

proc cardOf(s: set[TdxLaunchCondition]): int =
  for c in TdxLaunchCondition:
    if c in s: inc result

const
  LaunchSource = staticRead(
    "../../libs/repro_attest/src/repro_attest/tdx_launch.nim")
  ManifestSource = staticRead(
    "../../libs/repro_attest/src/repro_attest/manifest.nim")

proc raisedConditionsIn(source: string): seq[string] =
  ## Every `tdxFail(<condition>` in a source, in order. The declaration
  ## of `tdxFail` itself is not a call site and does not match, because
  ## it reads `tdxFail*(condition:`.
  result = @[]
  var i = 0
  const Needle = "tdxFail(tlc"
  while i < source.len:
    let at = source.find(Needle, i)
    if at < 0: break
    var j = at + len("tdxFail(")
    var name = ""
    while j < source.len and (source[j].isAlphaAscii or source[j].isDigit):
      name.add source[j]
      inc j
    result.add name
    i = j

# ---------------------------------------------------------------------
# Helpers that build a firmware one field away from being read
# ---------------------------------------------------------------------

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc readingOf(image: string) =
  discard readTdvfSections(bytesOf(image))

proc withSections(sections: seq[MintedSection]): string =
  syntheticFirmware(sections, payload = repeat('\xA5', 0x3000))

proc oneBad(index: int; edit: proc (s: var MintedSection)): string =
  var secs = wellFormedSections()
  edit(secs[index])
  withSections(secs)

proc driveAFirmwareThatPublishesNoTrustDomainTable() =
  ## The body of test
  ##   "a firmware that publishes no trust-domain table"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), includeMetadataEntry = false)))
  check e.condition == tlcNoTrustDomainTable
  check "publishes nothing about which pages" in e.msg

proc driveAnEntryTooShortToHoldAPosition() =
  ## The body of test
  ##   "an entry too short to hold a position"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), metadataEntryBytes = 2)))
  check e.condition == tlcTablePositionTooShort
  check "2 bytes where a position is 4" in e.msg

proc driveAPositionOfZeroWhichIsTheEndOfTheImage() =
  ## The body of test
  ##   "a position of zero, which is the end of the image"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), backOverride = 0)))
  check e.condition == tlcTablePositionIsZero

proc driveAPositionBeforeTheFrontOfTheImage() =
  ## The body of test
  ##   "a position before the front of the image"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), backOverride = 1_000_000)))
  check e.condition == tlcTablePositionBeforeImageFront

proc driveAHeaderThatDoesNotFitBeforeTheEnd() =
  ## The body of test
  ##   "a header that does not fit before the end"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), backOverride = 8)))
  check e.condition == tlcDescriptorHeaderPastImageEnd

proc driveFourBytesThatAreNotTheIdentifier() =
  ## The body of test
  ##   "four bytes that are not the identifier"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), signature = "XDVF")))
  check e.condition == tlcNotADescriptor

proc driveAVersionThisBuildHasNoLayoutFor() =
  ## The body of test
  ##   "a version this build has no layout for"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), version = 2'u32)))
  check e.condition == tlcUnsupportedDescriptorVersion
  check "version 2" in e.msg

proc driveAStatedLengthThatIsNotHeaderPlusSections() =
  ## The body of test
  ##   "a stated length that is not header plus sections"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), declaredLength = 999)))
  check e.condition == tlcDescriptorLengthDisagreesWithCount

proc driveATableCarryingNoSectionsAtAll() =
  ## The body of test
  ##   "a table carrying no sections at all"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000), declaredCount = 0)))
  check e.condition == tlcDescriptorDeclaresNoSections

proc driveSectionsThatRunOffTheEndOfTheImage() =
  ## The body of test
  ##   "sections that run off the end of the image"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Consistent header, impossible extent: a thousand sections do not
  # fit in a two-hundred-byte image.
  let e = refuses(proc () =
    readingOf(syntheticFirmware(wellFormedSections(),
      payload = repeat('\xA5', 0x3000),
      declaredCount = 1000, declaredLength = 16 + 1000 * 32)))
  check e.condition == tlcSectionTablePastImageEnd

suite "trust-domain firmware: the table":

  test "the whole vocabulary is distinguishable":
    # What makes an `in e.msg` assertion below mean ONE rule.
    check tdxLaunchMessagesAreDistinguishable()

  test "a firmware that publishes no trust-domain table":
    driveAFirmwareThatPublishesNoTrustDomainTable()

  test "an entry too short to hold a position":
    driveAnEntryTooShortToHoldAPosition()

  test "a position of zero, which is the end of the image":
    driveAPositionOfZeroWhichIsTheEndOfTheImage()

  test "a position before the front of the image":
    driveAPositionBeforeTheFrontOfTheImage()

  test "a header that does not fit before the end":
    driveAHeaderThatDoesNotFitBeforeTheEnd()

  test "four bytes that are not the identifier":
    driveFourBytesThatAreNotTheIdentifier()

  test "a version this build has no layout for":
    driveAVersionThisBuildHasNoLayoutFor()

  test "a stated length that is not header plus sections":
    driveAStatedLengthThatIsNotHeaderPlusSections()

  test "a table carrying no sections at all":
    driveATableCarryingNoSectionsAtAll()

  test "sections that run off the end of the image":
    driveSectionsThatRunOffTheEndOfTheImage()

proc driveAKindThisBuildCannotAccountFor() =
  ## The body of test
  ##   "a kind this build cannot account for"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(1, proc (s: var MintedSection) = s.kind = 9'u32)))
  check e.condition == tlcUnknownSectionKind
  check "names kind 9" in e.msg

proc driveAnAttributeBitThisBuildHasNoRuleFor() =
  ## The body of test
  ##   "an attribute bit this build has no rule for"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(1, proc (s: var MintedSection) =
      s.attributes = 4'u32)))
  check e.condition == tlcUnknownSectionAttributes

proc driveASectionClaimingNoMemory() =
  ## The body of test
  ##   "a section claiming no memory"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(2, proc (s: var MintedSection) = s.memorySize = 0)))
  check e.condition == tlcSectionIsEmpty

proc driveASectionThatDoesNotBeginOnAPageBoundary() =
  ## The body of test
  ##   "a section that does not begin on a page boundary"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(2, proc (s: var MintedSection) =
      s.memoryAddress = 0x800800'u64)))
  check e.condition == tlcSectionNotPageAligned

proc driveASectionThatIsNotAWholeNumberOfPages() =
  ## The body of test
  ##   "a section that is not a whole number of pages"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(2, proc (s: var MintedSection) =
      s.memorySize = 0x1800'u64)))
  check e.condition == tlcSectionSizeNotWholePages

proc driveMoreBytesInTheImageThanMemoryToHoldThem() =
  ## The body of test
  ##   "more bytes in the image than memory to hold them"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(0, proc (s: var MintedSection) =
      s.rawSize = 0x9000'u32)))
  check e.condition == tlcSectionDataExceedsItsMemory

proc driveBytesSaidToLieOutsideTheImage() =
  ## The body of test
  ##   "bytes said to lie outside the image"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(0, proc (s: var MintedSection) =
      s.dataOffset = 0x7FFF_0000'u32)))
  check e.condition == tlcSectionDataOutsideImage

proc driveAPositionStatedForContentsThatDoNotExist() =
  ## The body of test
  ##   "a position stated for contents that do not exist"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(2, proc (s: var MintedSection) =
      s.dataOffset = 0x10'u32)))
  check e.condition == tlcSectionPositionWithoutContents

proc driveABlankSectionThatIsAlsoFoldedIn() =
  ## The body of test
  ##   "a blank section that is also folded in"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(3, proc (s: var MintedSection) =
      s.attributes = 3'u32)))
  check e.condition == tlcAugmentedSectionIsMeasured

proc driveASectionFoldedInWithNothingToFold() =
  ## The body of test
  ##   "a section folded in with nothing to fold"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(2, proc (s: var MintedSection) =
      s.attributes = 1'u32)))
  check e.condition == tlcMeasuredSectionHasNoContents

proc driveTwoSectionsClaimingTheSameMemory() =
  ## The body of test
  ##   "two sections claiming the same memory"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    readingOf(oneBad(1, proc (s: var MintedSection) =
      s.memoryAddress = 0xFFC00000'u64
      s.memorySize = 0x2000'u64
      s.rawSize = 0x1000'u32)))
  check e.condition == tlcSectionsOverlap

proc driveAFirmwareNoneOfWhoseSectionsAreFoldedIn() =
  ## The body of test
  ##   "a firmware none of whose sections are folded in"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The anti-degeneracy rule. Such a measurement is a function of
  # addresses alone, and every firmware laid out this way produces it.
  var secs = wellFormedSections()
  for i in 0 ..< secs.len:
    if (secs[i].attributes and 1'u32) != 0: secs[i].attributes = 0'u32
  let e = refuses(proc () = readingOf(withSections(secs)))
  check e.condition == tlcNothingIsMeasured

proc driveABootVolumeThatIsNotFoldedIn() =
  ## The body of test
  ##   "a boot volume that is not folded in"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Distinct from the rule above, and it has to be: something else
  # here IS folded in, so the measurement is not address-only — it
  # simply does not cover the code the domain starts executing.
  var secs = wellFormedSections()
  secs[0].attributes = 0'u32
  let e = refuses(proc () = readingOf(withSections(secs)))
  check e.condition == tlcBootVolumeIsNotMeasured
  check "execution begins in" in e.msg

suite "trust-domain firmware: a section":

  test "a kind this build cannot account for":
    driveAKindThisBuildCannotAccountFor()

  test "an attribute bit this build has no rule for":
    driveAnAttributeBitThisBuildHasNoRuleFor()

  test "a section claiming no memory":
    driveASectionClaimingNoMemory()

  test "a section that does not begin on a page boundary":
    driveASectionThatDoesNotBeginOnAPageBoundary()

  test "a section that is not a whole number of pages":
    driveASectionThatIsNotAWholeNumberOfPages()

  test "more bytes in the image than memory to hold them":
    driveMoreBytesInTheImageThanMemoryToHoldThem()

  test "bytes said to lie outside the image":
    driveBytesSaidToLieOutsideTheImage()

  test "a position stated for contents that do not exist":
    driveAPositionStatedForContentsThatDoNotExist()

  test "a blank section that is also folded in":
    driveABlankSectionThatIsAlsoFoldedIn()

  test "a section folded in with nothing to fold":
    driveASectionFoldedInWithNothingToFold()

  test "two sections claiming the same memory":
    driveTwoSectionsClaimingTheSameMemory()

  test "a firmware none of whose sections are folded in":
    driveAFirmwareNoneOfWhoseSectionsAreFoldedIn()

  test "a boot volume that is not folded in":
    driveABootVolumeThatIsNotFoldedIn()

  test "and the table they are one field away from IS read":
    # Every case above edits ONE field of this table. Without this, a
    # refusal could be coming from some other defect in the fixture and
    # the gate would not know.
    let secs = readTdvfSections(bytesOf(wellFormedFirmware()))
    check secs.len == 4
    check secs[0].measured
    check secs[1].measured
    check not secs[2].measured
    check secs[3].augmented
    # The three dimensions neither genuine firmware has.
    check secs[1].rawSize.uint64 < secs[1].memorySize
    var measured = 0
    for s in secs:
      if s.measured: inc measured
    check measured == 2
    for o in TdxHostOrder:
      check tdxMrtdHex(bytesOf(wellFormedFirmware()), o).len == 96

suite "the three dimensions no shipped firmware has":

  # Pass 1 of the mutation table found all three of these GREEN, and
  # they are one cause: neither operator's firmware carries a section
  # the host adds blank, a section whose contents are shorter than its
  # memory, or a second measured section. The minted firmware HAS all
  # three, but nothing compared a measurement over it to anything, so
  # the rules about those dimensions had no reachable input anywhere.
  #
  # Each case below is an EQUIVALENCE rather than a pinned value. A
  # pinned value for a minted firmware would be this build's own output
  # written down, which proves nothing; an equivalence is a property the
  # calculation must have, and a build that got the dimension wrong
  # breaks it.

  test "a blank section contributes nothing at all":
    # Pages the host adds to a domain that is already running are
    # outside the build-time measurement. So a firmware carrying one
    # must measure exactly as the same firmware without it.
    let withBlank = wellFormedSections()
    var without: seq[MintedSection] = @[]
    for s in withBlank:
      if (s.attributes and 2'u32) == 0: without.add s
    check withBlank.len == without.len + 1
    for o in TdxHostOrder:
      check tdxMrtdHex(bytesOf(withSections(withBlank)), o) ==
            tdxMrtdHex(bytesOf(withSections(without)), o)
    # And the two firmwares are genuinely different documents, so the
    # equality above is not a comparison of something with itself.
    check withSections(withBlank) != withSections(without)

  test "a page short of its contents is measured as zeroes":
    # Stated as an equivalence: a section whose memory exceeds its bytes
    # must measure exactly as the same section with those zeroes written
    # out in the image. The first firmware's image carries NON-zero
    # bytes past the section's contents, so a build that read past the
    # end, or that left the previous page in the buffer, produces a
    # different answer.
    let short = @[MintedSection(dataOffset: 0, rawSize: 0x1000,
      memoryAddress: 0xFFC00000'u64, memorySize: 0x3000, kind: 0,
      attributes: 1)]
    let spelled = @[MintedSection(dataOffset: 0, rawSize: 0x3000,
      memoryAddress: 0xFFC00000'u64, memorySize: 0x3000, kind: 0,
      attributes: 1)]
    let payloadShort = repeat('\xA5', 0x1000) & repeat('\xC3', 0x2000)
    let payloadSpelled = repeat('\xA5', 0x1000) & repeat('\0', 0x2000)
    check payloadShort != payloadSpelled
    for o in TdxHostOrder:
      check tdxMrtdHex(bytesOf(
              syntheticFirmware(short, payload = payloadShort)), o) ==
            tdxMrtdHex(bytesOf(
              syntheticFirmware(spelled, payload = payloadSpelled)), o)

  test "the SECOND measured section's bytes are read too":
    # A walk that stopped after the first would be invisible against
    # either shipped firmware, which has exactly one measured section.
    var payload = repeat('\xA5', 0x3000)
    let base = tdxMrtdHex(bytesOf(
      syntheticFirmware(wellFormedSections(), payload = payload)),
      thoExtendAfterEachPage)
    # 0x2000 is inside the SECOND measured section and outside the
    # first, which runs to 0x1FFF.
    payload[0x2000] = '\x5A'
    check tdxMrtdHex(bytesOf(
      syntheticFirmware(wellFormedSections(), payload = payload)),
      thoExtendAfterEachPage) != base

proc driveARealPlatformSLogNamesRegistersADomainDoesNotHave() =
  ## The body of test
  ##   "a real platform's log names registers a domain does not have"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A GENUINE input, and nobody had to forge it: this is the measured
  # boot this repository already commits, offered as a domain's log.
  # A platform with a discrete security chip writes indices 0 and 7
  # among others, and none of those is a runtime register.
  let e = refuses(proc () =
    discard replayTdxRegisters(parseEventLog(
      fixtureBytes(fxGenuineTpmEventLog))))
  check e.condition == tlcLogNamesAForeignRegister
  check "names index 0" in e.msg

proc driveAMintedLogNamingAnIndexJustPastTheWindow() =
  ## The body of test
  ##   "a minted log naming an index just past the window"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The edge the genuine log above does not sit on: index 5 is one
  # past the last register, where index 0 is one before the first.
  let e = refuses(proc () =
    discard replayTdxRegisters(parseEventLog(
      syntheticRegisterLog([1, 5]))))
  check e.condition == tlcLogNamesAForeignRegister
  check "names index 5" in e.msg

proc driveALogCarryingNoLongDigestBank() =
  ## The body of test
  ##   "a log carrying no long-digest bank"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Minted, and it has to be: every log a real platform in this
  # repository's corpus wrote carries all four banks, so no genuine
  # document refuses here. Said plainly rather than implied by a name.
  let e = refuses(proc () =
    discard replayTdxRegisters(parseEventLog(
      syntheticRegisterLog([1, 2], alg = Sha256AlgId))))
  check e.condition == tlcRegisterLogHasNoSha384
  check "no bank this build can fold" in e.msg

proc driveAFoldAskedForAgainstARegisterThatDoesNotExist() =
  ## The body of test
  ##   "a fold asked for against a register that does not exist"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    discard foldTdxRegisters(@[
      TdxMeasuredEvent(register: 4, digest: bytesOf(digest384("x")))]))
  check e.condition == tlcEventNamesAForeignRegister
  check "names register 4" in e.msg

proc driveAFoldOverNothingAtAll() =
  ## The body of test
  ##   "a fold over nothing at all"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () = discard foldTdxRegisters(@[]))
  check e.condition == tlcRegisterLogExtendsNothing

proc driveARegisterOfTheWrongWidth() =
  ## The body of test
  ##   "a register of the wrong width"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    discard extendRtmr(newSeq[byte](47), bytesOf(digest384("x"))))
  check e.condition == tlcRegisterWidth
  check "47 bytes where a register is 48" in e.msg

proc driveAValueOfTheWrongWidth() =
  ## The body of test
  ##   "a value of the wrong width"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    discard extendRtmr(initialRtmr(), newSeq[byte](47)))
  check e.condition == tlcExtendedValueWidth
  check "47 bytes where a fold takes 48" in e.msg

proc driveARecordWithNoEntriesInIt() =
  ## The body of test
  ##   "a record with no entries in it"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A record that folds nothing leaves every register at its reset
  # value, which is an answer that agrees with every domain there is.
  let e = refuses(proc () = discard readTdxMeasurementRecord("[]"))
  check e.condition == tlcRecordIsNotReadable
  # And a record that opens the textual shape and does not finish it.
  let e2 = refuses(proc () =
    discard readTdxMeasurementRecord("[{\"imr\":"))
  check e2.condition == tlcRecordIsNotReadable

proc driveARecordWhoseEntryThisBuildCannotRead() =
  ## The body of test
  ##   "a record whose entry this build cannot read"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    discard readTdxMeasurementRecord("""[{"imr": 0, "digest": "zz"}]"""))
  check e.condition == tlcRecordEntryIsMalformed
  check "entry 0" in e.msg

proc driveAFoldOrderThisBuildDoesNotKnow() =
  ## The body of test
  ##   "a fold order this build does not know"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () = discard tdxHostOrderFor("whatever"))
  check e.condition == tlcUnknownHostOrder
  # Both known names are offered, so the refusal is actionable.
  for o in TdxHostOrder:
    check KnownTdxHostOrders[o] in e.msg

suite "trust-domain runtime registers: the refusals":

  test "a real platform's log names registers a domain does not have":
    driveARealPlatformSLogNamesRegistersADomainDoesNotHave()

  test "a minted log naming an index just past the window":
    driveAMintedLogNamingAnIndexJustPastTheWindow()

  test "a log carrying no long-digest bank":
    driveALogCarryingNoLongDigestBank()

  test "a fold asked for against a register that does not exist":
    driveAFoldAskedForAgainstARegisterThatDoesNotExist()

  test "a fold over nothing at all":
    driveAFoldOverNothingAtAll()

  test "a register of the wrong width":
    driveARegisterOfTheWrongWidth()

  test "a value of the wrong width":
    driveAValueOfTheWrongWidth()

  test "a record with no entries in it":
    driveARecordWithNoEntriesInIt()

  test "a record whose entry this build cannot read":
    driveARecordWhoseEntryThisBuildCannotRead()

  test "a fold order this build does not know":
    driveAFoldOrderThisBuildDoesNotKnow()

proc driveARegisterTheRecordNeverReachedIsNotPublished() =
  ## The body of test
  ##   "a register the record never reached is not published"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The rule exists because forty-eight zero bytes agree with every
  # domain that never extended that register. The log below reaches
  # the first register and nothing else.
  let e = refuses(proc () =
    discard tdxExpectationFor(TdxLaunchInputs(
      firmware: FirmwareUbuntu,
      registerLog: syntheticRegisterLog([1, 1]),
      order: thoExtendAfterEachPage)))
  check e.condition == tlcPublishedRegisterIsAResetValue
  check "runtime register 1" in e.msg

suite "publishing an expectation":

  test "a register the record never reached is not published":
    driveARegisterTheRecordNeverReachedIsNotPublished()

# ---------------------------------------------------------------------
# The census, written from the LAST case
# ---------------------------------------------------------------------

# Every case whose outcomes the coverage case(s) below observe. The
# suite runner executes each case in its own process (`--run
# suite::test`), so the coverage case drives these itself rather than
# reading what earlier cases left in process-global state.
const ConditionDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("a firmware that publishes no trust-domain table",
    driveAFirmwareThatPublishesNoTrustDomainTable),
  ("an entry too short to hold a position",
    driveAnEntryTooShortToHoldAPosition),
  ("a position of zero, which is the end of the image",
    driveAPositionOfZeroWhichIsTheEndOfTheImage),
  ("a position before the front of the image",
    driveAPositionBeforeTheFrontOfTheImage),
  ("a header that does not fit before the end",
    driveAHeaderThatDoesNotFitBeforeTheEnd),
  ("four bytes that are not the identifier",
    driveFourBytesThatAreNotTheIdentifier),
  ("a version this build has no layout for",
    driveAVersionThisBuildHasNoLayoutFor),
  ("a stated length that is not header plus sections",
    driveAStatedLengthThatIsNotHeaderPlusSections),
  ("a table carrying no sections at all", driveATableCarryingNoSectionsAtAll),
  ("sections that run off the end of the image",
    driveSectionsThatRunOffTheEndOfTheImage),
  ("a kind this build cannot account for", driveAKindThisBuildCannotAccountFor),
  ("an attribute bit this build has no rule for",
    driveAnAttributeBitThisBuildHasNoRuleFor),
  ("a section claiming no memory", driveASectionClaimingNoMemory),
  ("a section that does not begin on a page boundary",
    driveASectionThatDoesNotBeginOnAPageBoundary),
  ("a section that is not a whole number of pages",
    driveASectionThatIsNotAWholeNumberOfPages),
  ("more bytes in the image than memory to hold them",
    driveMoreBytesInTheImageThanMemoryToHoldThem),
  ("bytes said to lie outside the image", driveBytesSaidToLieOutsideTheImage),
  ("a position stated for contents that do not exist",
    driveAPositionStatedForContentsThatDoNotExist),
  ("a blank section that is also folded in",
    driveABlankSectionThatIsAlsoFoldedIn),
  ("a section folded in with nothing to fold",
    driveASectionFoldedInWithNothingToFold),
  ("two sections claiming the same memory",
    driveTwoSectionsClaimingTheSameMemory),
  ("a firmware none of whose sections are folded in",
    driveAFirmwareNoneOfWhoseSectionsAreFoldedIn),
  ("a boot volume that is not folded in", driveABootVolumeThatIsNotFoldedIn),
  ("a real platform's log names registers a domain does not have",
    driveARealPlatformSLogNamesRegistersADomainDoesNotHave),
  ("a minted log naming an index just past the window",
    driveAMintedLogNamingAnIndexJustPastTheWindow),
  ("a log carrying no long-digest bank", driveALogCarryingNoLongDigestBank),
  ("a fold asked for against a register that does not exist",
    driveAFoldAskedForAgainstARegisterThatDoesNotExist),
  ("a fold over nothing at all", driveAFoldOverNothingAtAll),
  ("a register of the wrong width", driveARegisterOfTheWrongWidth),
  ("a value of the wrong width", driveAValueOfTheWrongWidth),
  ("a record with no entries in it", driveARecordWithNoEntriesInIt),
  ("a record whose entry this build cannot read",
    driveARecordWhoseEntryThisBuildCannotRead),
  ("a fold order this build does not know",
    driveAFoldOrderThisBuildDoesNotKnow),
  ("a register the record never reached is not published",
    driveARegisterTheRecordNeverReachedIsNotPublished)]

suite "the census":

  test "every rule has a site, and every site has exactly one rule":
    # The static half. This is what makes the runtime census below a
    # census over SITES rather than over kinds: it proves the two
    # coincide instead of assuming they do.
    var found: seq[string] = @[]
    for n in raisedConditionsIn(LaunchSource): found.add n
    for n in raisedConditionsIn(ManifestSource): found.add n
    check found.len == 33
    check ord(high(TdxLaunchCondition)) + 1 == 33
    for c in TdxLaunchCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      check seen == 1
    # And the other direction: nothing is raised that is not a value of
    # the enumeration. A name the enum does not carry would not compile,
    # so what this catches is a misspelling that happens to compile —
    # which is why it compares against the enum's own spellings.
    for n in found:
      var known = false
      for c in TdxLaunchCondition:
        if n == $c: known = true
      check known

  test "every rule was reached, and the count is an EQUALITY":
    # Driven HERE, from reset state: the runner executes every case in
    # its own process, so this case observes only what it runs itself.
    reached = {}
    for (name, drive) in ConditionDrivers:
      checkpoint("driving " & name)
      drive()
    # Not `>=`. Under an inequality a rule reached twice pays for a rule
    # reached never, and the census cannot notice the one thing it
    # exists to notice.
    var missing: seq[string] = @[]
    for c in TdxLaunchCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    check cardOf(reached) == 33
    check cardOf(reached) == ord(high(TdxLaunchCondition)) + 1
