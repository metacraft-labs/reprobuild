## The launch measurement an AMD SEV-SNP machine will report, computed
## before the machine is launched.
##
## ## What this is for
##
## A confidential guest's attestation report carries a `MEASUREMENT`
## field: a SHA-384 chain the security processor builds while it places
## the guest's initial memory. Verifying a report's signature says a real
## part produced it; it says nothing about *what was launched*. Only a
## value computed independently from the launch inputs can say that, and
## computing it is what this module does.
##
## The result is an expectation an image build publishes and a verifier
## later compares a running machine's report against. Neither side may
## take the other's word for it, which is why the calculation lives here
## — one implementation, used by the build that publishes the
## expectation and by anyone who reproduces it.
##
## ## The chain
##
## The measurement starts at 48 zero bytes and is replaced, once per page
## the firmware places, by
##
##   `LD := SHA-384(PAGE_INFO)`
##
## where `PAGE_INFO` is the 112-byte structure below: the *previous* LD,
## a digest of the page's contents (or 48 zero bytes for a page whose
## contents are not measured), the structure's own length, the page type,
## and the guest physical address the page lands at. Every field is
## little-endian. A page's address is inside the measurement as much as
## its contents are, and so is the order the pages are folded in.
##
## Then one more update per virtual CPU, over that CPU's initial register
## state — the VMSA page. This is why a measurement depends on the
## *number* of processors and on the *model* the hypervisor reports,
## neither of which is a property of any file on disk.
##
## ## Three launch shapes, and why the older two are here
##
## `slmSevSnp` is the one this repository cares about. `slmSev` and
## `slmSevEs` are the two earlier generations, whose launch digest is a
## flat SHA-256 rather than a chain — and they are implemented because
## they combine the *same* two hard-to-get-right pieces, the VMSA page
## and the kernel-digest table, under a completely different accumulator.
## A vector that agrees under both accumulators is much better evidence
## about those two pieces than one that agrees under either alone: a
## transposition inside the chain cannot hide a wrong VMSA byte when a
## flat SHA-256 over the same VMSA has to agree too.
##
## ## Where the numbers come from
##
## The `PAGE_INFO` layout and the page types are AMD's *SEV Secure Nested
## Paging Firmware ABI Specification* (publication 56860), §8.17.2. The
## VMSA layout is the `SEV_ES_SAVE_AREA` of the *AMD64 Architecture
## Programmer's Manual* Volume 2, Table B-4. The initial register values
## are the *hypervisor's*, not the architecture's, which is why
## `SnpVmmKind` exists at all: of the three hypervisors here, one starts a
## guest with a different `%rdx`, a different `MXCSR` and a different x87
## control word from the other two, one of those two uses a different
## page-attribute table, and one of them starts its FIRST processor with a
## code segment the others do not. A calculator with one hypervisor built
## in produces a correct number for one cloud and a wrong number
## everywhere else.
##
## Offsets are written here as named constants and *checked against each
## other* rather than trusted: `SnpVmsaFieldOffsets` is data, and a gate
## walks it and requires the fields not to overlap and to account for
## exactly the bytes the builder sets — so an offset typed wrongly
## collides with its neighbour instead of quietly moving a value.
##
## ## One rule per refusal, and the refusal vocabulary is the rule set
##
## `SnpLaunchCondition` has one value per *condition*, not one per
## family of conditions. That is deliberate and it is the second attempt:
## a vocabulary whose values are families lets a new rule be added under
## an existing value, where it is indistinguishable from its neighbours —
## so a test asserting the value is not asserting the rule, and a census
## over the values does not move when a rule stops being reachable.
## `snpLaunchMessagesAreDistinguishable` states and checks the property
## that makes the finer vocabulary worth having: **no message is a
## substring of any other**.
##
## ## What is refused
##
## Everything this module cannot read exactly. A firmware image whose
## GUID footer table is absent or overruns, a page list with the wrong
## marker or revision, a page kind this build does not know, a region
## that is not page-aligned, a kernel offered to a firmware with nowhere
## to put its digests. A measurement computed from a guess is worse than
## no measurement, because it is published as an expectation and then
## never matches anything.
##
## ## What this build does NOT compute
##
##   * **A launch under a paravisor.** A guest whose most privileged
##     level runs a supervisor measures that supervisor too, with a
##     second VMSA layout. Refused by name rather than measured under the
##     wrong model.
##   * **An identity block.** The signed block a launch may present
##     alongside its measurement is a separate document, and is not built
##     here.
##
## ## Mocking
##
## None. Real firmware bytes, real SHA-384.

import std/[strutils]

import nimcrypto/[hash, sha2]

type
  SnpLaunchCondition* = enum
    ## One value per rule. See this module's header for why the
    ## vocabulary is this fine.
    slcFirmwareTooSmall
    slcFirmwareNotWholePages
    slcNoGuidFooter
    slcFooterSizeBelowHeader
    slcFooterTableStartsBeforeImage
    slcEntrySizeBelowHeader
    slcEntryOverrunsTable
    slcNoPageList
    slcPageListPointerTooShort
    slcPageListOutsideImage
    slcPageListHeaderOutsideImage
    slcPageListMarker
    slcPageListRevision
    slcPageListSizeBelowHeader
    slcPageListRunsPastImage
    slcPageListEntriesExceedSize
    slcUnknownPageKind
    slcRegionNotPageAligned
    slcKernelDigestsNoAddress
    slcKernelDigestsNoRegion
    slcKernelDigestsOverflowPage
    slcKernelDigestsRegionSize
    slcNoResetVector
    slcProcessorCountOutOfRange
    slcUnknownProcessorModel
    slcUnknownHypervisor
    slcParavisorNotMeasured

  SnpLaunchError* = object of CatchableError
    condition*: SnpLaunchCondition

const
  SnpLaunchMessage*: array[SnpLaunchCondition, string] = [
    slcFirmwareTooSmall:
      "the firmware image is shorter than the footer that has to sit at " &
      "the end of it",
    slcFirmwareNotWholePages:
      "the firmware image does not occupy a whole number of guest pages, " &
      "and a partial page has no address to be measured at",
    slcNoGuidFooter:
      "the firmware image carries no identifying table where one must be, " &
      "so nothing in it says what a hypervisor would place or where",
    slcFooterSizeBelowHeader:
      "the identifying table's own footer states a length smaller than a " &
      "footer",
    slcFooterTableStartsBeforeImage:
      "the identifying table claims to begin before the front of the " &
      "firmware image",
    slcEntrySizeBelowHeader:
      "an entry of the identifying table states a length smaller than an " &
      "entry's header",
    slcEntryOverrunsTable:
      "an entry of the identifying table claims more bytes than remain " &
      "before that table begins",
    slcNoPageList:
      "this firmware declares nothing about which pages a confidential " &
      "launch places, so there would be nothing to measure but the image",
    slcPageListPointerTooShort:
      "the entry that should point at the list of placed pages is too " &
      "short to hold a position",
    slcPageListOutsideImage:
      "the list of placed pages is said to begin outside the firmware image",
    slcPageListHeaderOutsideImage:
      "the header of the list of placed pages runs off the end of the " &
      "firmware image",
    slcPageListMarker:
      "the list of placed pages does not begin with the marker that " &
      "identifies it",
    slcPageListRevision:
      "the list of placed pages states a revision this build has no " &
      "layout for",
    slcPageListSizeBelowHeader:
      "the list of placed pages states an overall length smaller than its " &
      "own header",
    slcPageListRunsPastImage:
      "the list of placed pages states an overall length that reaches " &
      "past the end of the firmware image",
    slcPageListEntriesExceedSize:
      "the list of placed pages counts more entries than its stated " &
      "overall length has room for",
    slcUnknownPageKind:
      "the list of placed pages names a kind of page this build cannot " &
      "account for, and a page folded in under the wrong kind is a " &
      "different number",
    slcRegionNotPageAligned:
      "a region in the list of placed pages does not begin and end on a " &
      "guest page boundary",
    slcKernelDigestsNoAddress:
      "a kernel was supplied and this firmware publishes no address for " &
      "the table its digests travel in",
    slcKernelDigestsNoRegion:
      "a kernel was supplied and this firmware's list of placed pages " &
      "reserves nothing for the table its digests travel in",
    slcKernelDigestsOverflowPage:
      "the table of kernel digests does not fit in the page it is placed " &
      "at the given position within",
    slcKernelDigestsRegionSize:
      "the region reserved for kernel digests is not the size of the page " &
      "that goes into it",
    slcNoResetVector:
      "more than one processor was asked for and this firmware publishes " &
      "no address for the others to start at",
    slcProcessorCountOutOfRange:
      "the processor count is outside the range a launch can have",
    slcUnknownProcessorModel:
      "this build knows no family, model and stepping for the processor " &
      "the launch names, and guessing one would produce a number no " &
      "machine reports",
    slcUnknownHypervisor:
      "this build has no initial register state for the hypervisor the " &
      "launch names, and every one of them starts a guest differently",
    slcParavisorNotMeasured:
      "this launch runs a supervisor at the most privileged guest level, " &
      "which this build does not measure"]

proc snpLaunchMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked, not asserted: this is
  ## the property that makes an `in e.msg` assertion mean one rule.
  for a in SnpLaunchCondition:
    for b in SnpLaunchCondition:
      if a == b: continue
      if SnpLaunchMessage[a] in SnpLaunchMessage[b]: return false
  true

proc launchFail*(condition: SnpLaunchCondition;
                 detail: string) {.noreturn.} =
  var e = newException(SnpLaunchError, SnpLaunchMessage[condition])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.condition = condition
  raise e

# ---------------------------------------------------------------------
# The measurement chain
# ---------------------------------------------------------------------

const
  SnpPageSize* = 4096
  SnpDigestLen* = 48            ## SHA-384, and the width of `MEASUREMENT`.
  SnpPageInfoLen* = 0x70        ## 112 bytes.

  # `PAGE_INFO`, field by field.
  OffPageInfoDigestCur* = 0x00
  OffPageInfoContents* = 0x30
  OffPageInfoLength* = 0x60
  OffPageInfoPageKind* = 0x62
  OffPageInfoImiPage* = 0x63
  OffPageInfoVmpl3Perms* = 0x64
  OffPageInfoVmpl2Perms* = 0x65
  OffPageInfoVmpl1Perms* = 0x66
  OffPageInfoReserved67* = 0x67
  OffPageInfoGpa* = 0x68

  SnpVmsaGpa* = 0xFFFF_FFFF_F000'u64
    ## A VMSA page is folded in against `(uint64)-1`, page-aligned and
    ## with everything above bit 51 cleared. It is not where the page
    ## lives; it is the address the specification says to measure it at.

type
  SnpPageKind* = enum
    ## The `PAGE_TYPE` byte. The ordinals are AMD's, not this
    ## enumeration's convenience — they go into the digest.
    spkNormal = 0x01
    spkVmsa = 0x02
    spkZero = 0x03
    spkUnmeasured = 0x04
    spkSecrets = 0x05
    spkCpuid = 0x06

  SnpLaunchContext* = object
    ## The running chain. It carries only the current digest, because
    ## that is all the chain carries: a value here is a statement about
    ## every page folded in so far, and about the order.
    ld*: seq[byte]

proc sha384Of*(data: openArray[byte]): seq[byte] =
  let d = sha384.digest(data)
  result = newSeq[byte](SnpDigestLen)
  for i in 0 ..< SnpDigestLen: result[i] = d.data[i]

proc sha256Of*(data: openArray[byte]): seq[byte] =
  let d = sha256.digest(data)
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = d.data[i]

proc newSnpLaunchContext*(seed: openArray[byte] = []): SnpLaunchContext =
  ## A fresh chain, or one resumed from a digest computed earlier.
  ##
  ## Resuming is not a shortcut this module invented: a firmware image is
  ## megabytes, and its contribution to the measurement is a pure
  ## function of those bytes alone, so a build may publish that one
  ## digest and let everything downstream start from it.
  ## `snpFirmwareDigest` computes it. An empty seed is the zero digest
  ## the specification starts at.
  result.ld = newSeq[byte](SnpDigestLen)
  if seed.len == 0: return
  if seed.len != SnpDigestLen:
    raise newException(ValueError,
      "a resumed launch measurement is " & $SnpDigestLen &
      " bytes and this one is " & $seed.len)
  for i in 0 ..< SnpDigestLen: result.ld[i] = seed[i]

proc putLe(buf: var seq[byte]; at: int; value: uint64; width: int) =
  for i in 0 ..< width:
    buf[at + i] = byte((value shr (8 * i)) and 0xff'u64)

proc pageInfoBytes*(ld, contents: openArray[byte];
                    kind: SnpPageKind; gpa: uint64): seq[byte] =
  ## The exact bytes hashed for one page. Exposed so a gate can read the
  ## structure this module builds, rather than hold a second opinion
  ## about what it ought to be.
  doAssert ld.len == SnpDigestLen
  doAssert contents.len == SnpDigestLen
  result = newSeq[byte](SnpPageInfoLen)
  for i in 0 ..< SnpDigestLen:
    result[OffPageInfoDigestCur + i] = ld[i]
    result[OffPageInfoContents + i] = contents[i]
  putLe(result, OffPageInfoLength, uint64(SnpPageInfoLen), 2)
  result[OffPageInfoPageKind] = byte(ord(kind))
  # The initial-image flag, the three permission masks and the reserved
  # byte are zero for every launch this build measures. They are written
  # explicitly, by name, because they are inside the digest: a launch
  # shape that sets one of them changes every measurement, and that has
  # to be a visible edit here rather than an omission.
  result[OffPageInfoImiPage] = 0
  result[OffPageInfoVmpl3Perms] = 0
  result[OffPageInfoVmpl2Perms] = 0
  result[OffPageInfoVmpl1Perms] = 0
  result[OffPageInfoReserved67] = 0
  putLe(result, OffPageInfoGpa, gpa, 8)

proc update*(ctx: var SnpLaunchContext; kind: SnpPageKind; gpa: uint64;
             contents: openArray[byte]) =
  ## Fold one page into the chain.
  ctx.ld = sha384Of(pageInfoBytes(ctx.ld, contents, kind, gpa))

proc updateNormalPages*(ctx: var SnpLaunchContext; gpa: uint64;
                        data: openArray[byte]) =
  ## Pages whose contents are measured, in address order.
  if data.len mod SnpPageSize != 0:
    launchFail(slcFirmwareNotWholePages,
      $data.len & " bytes is " & $(data.len mod SnpPageSize) &
      " past a multiple of " & $SnpPageSize)
  var offset = 0
  while offset < data.len:
    var page = newSeq[byte](SnpPageSize)
    for i in 0 ..< SnpPageSize: page[i] = data[offset + i]
    ctx.update(spkNormal, gpa + uint64(offset), sha384Of(page))
    offset += SnpPageSize

proc updateContentlessPages*(ctx: var SnpLaunchContext; kind: SnpPageKind;
                             gpa: uint64; length: int) =
  ## Pages whose *contents* are not measured but whose address, kind and
  ## position in the sequence are. The 48 content bytes are zero; that is
  ## the specification's value, not a placeholder.
  ##
  ## The page alignment is an ASSERTION and not a refusal, deliberately.
  ## Every caller gets its length from a region the reader has already
  ## refused a misaligned value for, so a refusal here would be a rule
  ## with no input reaching it — which is a rule the program does not
  ## have, dressed up as one it does. If this fires it is a defect in
  ## this module, not a statement about a firmware image.
  doAssert length > 0 and length mod SnpPageSize == 0,
    $length & " bytes against a page size of " & $SnpPageSize
  let zeros = newSeq[byte](SnpDigestLen)
  var offset = 0
  while offset < length:
    ctx.update(kind, gpa + uint64(offset), zeros)
    offset += SnpPageSize

proc updateVmsaPage*(ctx: var SnpLaunchContext; page: openArray[byte]) =
  doAssert page.len == SnpPageSize
  ctx.update(spkVmsa, SnpVmsaGpa, sha384Of(page))

# ---------------------------------------------------------------------
# The firmware image: its GUID footer table and its page list
# ---------------------------------------------------------------------

const
  OvmfFooterTrailerLen* = 32
    ## The GUID table ends this many bytes before the end of the image.
  OvmfEntryHeaderLen* = 18
    ## A `uint16` length, then a 16-byte GUID.
  FourGiB* = 0x1_0000_0000'u64
    ## A firmware image ends at the 4 GiB boundary of guest physical
    ## memory and runs backwards from it. That is what fixes every
    ## address in the calculation without anyone stating one, and it is
    ## why the image's *length* is load-bearing.

  OvmfTableFooterGuid* = "96b582de-1fb2-45f7-baea-a366c55a082d"
  SevHashTableRvGuid* = "7255371f-3a3b-4b04-927b-1da6efa8d454"
  SevEsResetBlockGuid* = "00f771de-1a7e-4fcb-890e-68c77e2fb44e"
  OvmfSevMetadataGuid* = "dc886566-984a-4798-a75e-5585a7bf67cc"
  ParavisorInfoGuid* = "a789a612-0597-4c4b-a49f-cbb1fe9d1ddd"
    ## Present only in a paravisor image. Recognised so that such an
    ## image is REFUSED by name rather than measured as if it were an
    ## ordinary one: the difference is a second VMSA layout and an extra
    ## measured binary, which would otherwise be silently missing from
    ## the answer.

  SevPageListMarker* = "ASEV"
  SevPageListRevision* = 1'u32
  SevPageListHeaderLen* = 16
  SevPageListEntryLen* = 12

type
  OvmfSectionKind* = enum
    ## The kind field of one entry of the firmware's page list.
    oskSecMem = 1
    oskSecrets = 2
    oskCpuid = 3
    oskParavisorCallArea = 4
    oskKernelDigests = 0x10

  OvmfSection* = object
    gpa*: uint32
    size*: uint32
    kind*: OvmfSectionKind

  OvmfEntry* = object
    guid*: string
    value*: seq[byte]

const
  OvmfSectionKinds*: array[5, OvmfSectionKind] =
    [oskSecMem, oskSecrets, oskCpuid, oskParavisorCallArea, oskKernelDigests]
    ## The complete set of page kinds a firmware may declare, as data.
    ## The enumeration's values are not contiguous — the vendor left a
    ## gap between the four ordinary kinds and the one that carries a
    ## kernel's digests — so it cannot be iterated as a range, and the
    ## reader that decides whether a declared number is known walks this
    ## list. A kind added to the enumeration and not to this list is a
    ## kind the reader refuses, which is the safe direction; a gate
    ## checks the two agree so that it is not also a silent one.

type

  OvmfImage* = object
    data*: seq[byte]
    gpa*: uint64
    entries*: seq[OvmfEntry]
    hasPageList*: bool
    sections*: seq[OvmfSection]

proc guidLe*(canonical: string): seq[byte] =
  ## A GUID in the byte order a firmware table stores it in.
  ##
  ## The first three groups are little-endian and the last two are not —
  ## the mixed-endian layout these identifiers have always had, and which
  ## RFC 4122 records as a variant. Converting here, from the canonical
  ## text, is deliberate: the constants above stay readable and
  ## comparable against any other document naming the same identifier,
  ## instead of being sixteen bytes nobody can check.
  var digits = ""
  for c in canonical:
    if c != '-': digits.add c
  doAssert digits.len == 32, "an identifier is 32 hex digits: " & canonical
  var raw = newSeq[byte](16)
  for i in 0 ..< 16:
    raw[i] = byte(parseHexInt(digits[2 * i .. 2 * i + 1]))
  result = newSeq[byte](16)
  result[0] = raw[3]; result[1] = raw[2]; result[2] = raw[1]; result[3] = raw[0]
  result[4] = raw[5]; result[5] = raw[4]
  result[6] = raw[7]; result[7] = raw[6]
  for i in 8 ..< 16: result[i] = raw[i]

proc guidCanonical*(stored: openArray[byte]): string =
  ## The inverse of `guidLe`, so the table's keys are the readable text.
  doAssert stored.len == 16
  var canon = newSeq[byte](16)
  canon[0] = stored[3]; canon[1] = stored[2]
  canon[2] = stored[1]; canon[3] = stored[0]
  canon[4] = stored[5]; canon[5] = stored[4]
  canon[6] = stored[7]; canon[7] = stored[6]
  for i in 8 ..< 16: canon[i] = stored[i]
  for i in 0 ..< 16:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add toHex(int(canon[i]), 2).toLowerAscii

proc readLe(data: openArray[byte]; at, width: int): uint64 =
  for i in countdown(width - 1, 0):
    result = (result shl 8) or uint64(data[at + i])

proc entryValue*(img: OvmfImage; guid: string): seq[byte] =
  for e in img.entries:
    if e.guid == guid: return e.value
  @[]

proc hasEntry*(img: OvmfImage; guid: string): bool =
  for e in img.entries:
    if e.guid == guid: return true
  false

proc parsePageList(img: var OvmfImage; data: openArray[byte]) =
  let pointerValue = img.entryValue(OvmfSevMetadataGuid)
  if pointerValue.len < 4:
    launchFail(slcPageListPointerTooShort,
      $pointerValue.len & " bytes where four are needed")
  let offsetFromEnd = int(readLe(pointerValue, 0, 4))
  if offsetFromEnd <= 0 or offsetFromEnd > data.len:
    launchFail(slcPageListOutsideImage,
      $offsetFromEnd & " bytes before the end of a " & $data.len &
      "-byte image")
  let start = data.len - offsetFromEnd
  if start + SevPageListHeaderLen > data.len:
    launchFail(slcPageListHeaderOutsideImage,
      "a " & $SevPageListHeaderLen & "-byte header at 0x" & toHex(start, 4) &
      " of a " & $data.len & "-byte image")
  var marker = ""
  for i in 0 ..< 4: marker.add char(data[start + i])
  if marker != SevPageListMarker:
    launchFail(slcPageListMarker,
      "the four bytes at 0x" & toHex(start, 4) & " are " & marker.escape() &
      " and this build looks for " & SevPageListMarker.escape())
  let declaredLen = int(readLe(data, start + 4, 4))
  let revision = uint32(readLe(data, start + 8, 4))
  if revision != SevPageListRevision:
    launchFail(slcPageListRevision,
      "revision " & $revision & " against the " & $SevPageListRevision &
      " this build reads")
  # Two conditions, not one. They were written as a single test under a
  # single value, and the sentence that value carries is true of only the
  # first of them: a list that is long enough to be a list but reaches
  # past the end of the image was refused with "smaller than its own
  # header", which sends a reader looking at the wrong field.
  if declaredLen < SevPageListHeaderLen:
    launchFail(slcPageListSizeBelowHeader,
      "an overall length of " & $declaredLen & " where a header alone is " &
      $SevPageListHeaderLen)
  if start + declaredLen > data.len:
    launchFail(slcPageListRunsPastImage,
      "an overall length of " & $declaredLen & " at 0x" & toHex(start, 4) &
      " of a " & $data.len & "-byte image")
  let entryCount = int(readLe(data, start + 12, 4))
  if entryCount < 0 or
     SevPageListHeaderLen + entryCount * SevPageListEntryLen > declaredLen:
    launchFail(slcPageListEntriesExceedSize,
      $entryCount & " entries need " &
      $(SevPageListHeaderLen + entryCount * SevPageListEntryLen) &
      " bytes and the list states " & $declaredLen)
  for i in 0 ..< entryCount:
    let at = start + SevPageListHeaderLen + i * SevPageListEntryLen
    let gpa = uint32(readLe(data, at, 4))
    let size = uint32(readLe(data, at + 4, 4))
    let kindNumber = int(readLe(data, at + 8, 4))
    var kind = oskSecMem
    var known = false
    for k in OvmfSectionKinds:
      if ord(k) == kindNumber:
        kind = k
        known = true
    if not known:
      launchFail(slcUnknownPageKind,
        "entry " & $i & " names kind " & $kindNumber)
    if size == 0 or gpa mod uint32(SnpPageSize) != 0 or
       size mod uint32(SnpPageSize) != 0:
      launchFail(slcRegionNotPageAligned,
        "entry " & $i & " covers 0x" & toHex(int(size), 8) & " bytes at 0x" &
        toHex(int(gpa), 8))
    img.sections.add OvmfSection(gpa: gpa, size: size, kind: kind)
  img.hasPageList = true

proc parseOvmfImage*(data: openArray[byte];
                     withPageList = true): OvmfImage =
  ## Read a firmware image's GUID footer table and, if it publishes one,
  ## its confidential-launch page list.
  ##
  ## `withPageList` exists because this reader has two callers and only
  ## one of them is about this vendor. The GUID footer is a container
  ## format both vendors put their metadata in; the page list inside it
  ## is THIS vendor's, and the other vendor's measurement does not
  ## depend on a byte of it. Parsing it anyway is not merely wasted
  ## work — it is a refusal with the wrong subject, and a real one: a
  ## shipped trust-domain firmware in this repository's corpus carries
  ## a page list whose last two entries are zeroed, presumably because
  ## its builder does not support this vendor at all. Reading it made
  ## that firmware unmeasurable for a reason that had nothing to do
  ## with the measurement being asked for. The footer rules stay
  ## shared, because two readers disagreeing about where a firmware's
  ## table begins is a hazard this repository has already paid for
  ## once; the page list does not, because it is not shared.
  ##
  ## The table is walked from its end backwards, because that is how it
  ## is built: each entry states its own total length, and the entry
  ## before it ends where this one begins.
  ##
  ## A missing page list is not refused here. Two of the three launch
  ## shapes never consult it, so the refusal belongs to the shape that
  ## does — see `snpLaunchDigest`.
  let minimum = OvmfFooterTrailerLen + OvmfEntryHeaderLen
  if data.len < minimum:
    launchFail(slcFirmwareTooSmall,
      $data.len & " bytes against the " & $minimum & " a footer needs")
  result.data = newSeq[byte](data.len)
  for i in 0 ..< data.len: result.data[i] = data[i]
  result.gpa = FourGiB - uint64(data.len)

  let footerAt = data.len - OvmfFooterTrailerLen - OvmfEntryHeaderLen
  let footerGuid = guidLe(OvmfTableFooterGuid)
  var footerMatches = true
  for i in 0 ..< 16:
    if data[footerAt + 2 + i] != footerGuid[i]: footerMatches = false
  if not footerMatches:
    launchFail(slcNoGuidFooter,
      "the sixteen bytes at 0x" & toHex(footerAt + 2, 4) & " are " &
      guidCanonical(result.data[footerAt + 2 ..< footerAt + 18]))
  let footerSize = int(readLe(data, footerAt, 2))
  if footerSize < OvmfEntryHeaderLen:
    launchFail(slcFooterSizeBelowHeader,
      "the footer states " & $footerSize & " bytes and an entry header is " &
      $OvmfEntryHeaderLen)
  let tableSize = footerSize - OvmfEntryHeaderLen
  if tableSize > footerAt:
    launchFail(slcFooterTableStartsBeforeImage,
      "a " & $tableSize & "-byte table ending at 0x" & toHex(footerAt, 4))

  let tableStart = footerAt - tableSize
  var cursor = footerAt
  while cursor - tableStart >= OvmfEntryHeaderLen:
    let entryAt = cursor - OvmfEntryHeaderLen
    let entrySize = int(readLe(data, entryAt, 2))
    if entrySize < OvmfEntryHeaderLen:
      launchFail(slcEntrySizeBelowHeader,
        "the entry ending at 0x" & toHex(cursor, 4) & " states " &
        $entrySize & " bytes and an entry header is " & $OvmfEntryHeaderLen)
    if entrySize > cursor - tableStart:
      launchFail(slcEntryOverrunsTable,
        "the entry ending at 0x" & toHex(cursor, 4) & " states " &
        $entrySize & " bytes and only " & $(cursor - tableStart) &
        " remain")
    result.entries.add OvmfEntry(
      guid: guidCanonical(result.data[entryAt + 2 ..< entryAt + 18]),
      value: result.data[cursor - entrySize ..< entryAt])
    cursor -= entrySize

  if result.hasEntry(ParavisorInfoGuid):
    launchFail(slcParavisorNotMeasured,
      "the image publishes a supervisor information block")
  if withPageList and result.hasEntry(OvmfSevMetadataGuid):
    parsePageList(result, data)

proc resetVectorEip*(img: OvmfImage): uint32 =
  ## Where a processor other than the first begins executing. Zero means
  ## the image publishes none, and that is refused where it matters
  ## rather than here: a single-processor launch never needs one.
  let v = img.entryValue(SevEsResetBlockGuid)
  if v.len < 4: return 0
  uint32(readLe(v, 0, 4))

proc kernelDigestsTableGpa*(img: OvmfImage): uint32 =
  ## Where the firmware expects the table of kernel digests. Zero means
  ## it expects none.
  let v = img.entryValue(SevHashTableRvGuid)
  if v.len < 4: return 0
  uint32(readLe(v, 0, 4))

proc reservesKernelDigestRegion*(img: OvmfImage): bool =
  for s in img.sections:
    if s.kind == oskKernelDigests: return true
  false

# ---------------------------------------------------------------------
# The table of kernel digests
# ---------------------------------------------------------------------

const
  SevDigestTableHeaderGuid* = "9438d606-4f22-4cc9-b479-a793d411fd21"
  SevKernelEntryGuid* = "4de79437-abd2-427f-b835-d5b172d2045b"
  SevInitrdEntryGuid* = "44baf731-3a2f-4bd7-9af1-41e29169781d"
  SevCmdlineEntryGuid* = "97d02dd8-bd20-4c94-aa78-e7714d36ab2a"

  SevDigestEntryLen* = 16 + 2 + 32   ## an identifier, a length, a SHA-256.
  SevDigestTableLen* = 16 + 2 + 3 * SevDigestEntryLen
  SevDigestTablePaddedLen* = (SevDigestTableLen + 15) and not 15
    ## The hypervisor writes the table padded to a 16-byte boundary, and
    ## the padding is inside the measured page, so it is inside the
    ## digest. Rounding here rather than writing the rounded number keeps
    ## the table's size and the alignment separately visible.

type
  SnpKernelDigests* = object
    kernel*, initrd*, cmdline*: seq[byte]   ## SHA-256, 32 bytes each.

proc kernelDigestsFor*(kernel, initrd: openArray[byte];
                       cmdline: string): SnpKernelDigests =
  ## The three digests a measured direct boot puts in front of the
  ## firmware.
  ##
  ## The command line is hashed **with its terminating NUL**, and an
  ## empty command line hashes that NUL alone rather than nothing. This
  ## is not a detail: it is what the hypervisor does, and a calculator
  ## that hashed the empty string would produce a measurement no machine
  ## ever reports.
  result.kernel = sha256Of(kernel)
  result.initrd = sha256Of(initrd)
  var terminated = newSeq[byte](cmdline.len + 1)
  for i in 0 ..< cmdline.len: terminated[i] = byte(cmdline[i])
  terminated[cmdline.len] = 0
  result.cmdline = sha256Of(terminated)

proc kernelDigestTable*(h: SnpKernelDigests): seq[byte] =
  ## The table's bytes. The entry order is command line, initrd, kernel —
  ## the order the hypervisor writes them in, which is not the order
  ## anyone would choose and is therefore worth pinning.
  result = newSeq[byte](SevDigestTablePaddedLen)
  let header = guidLe(SevDigestTableHeaderGuid)
  for i in 0 ..< 16: result[i] = header[i]
  putLe(result, 16, uint64(SevDigestTableLen), 2)
  let entries = [(SevCmdlineEntryGuid, h.cmdline),
                 (SevInitrdEntryGuid, h.initrd),
                 (SevKernelEntryGuid, h.kernel)]
  for i, e in entries:
    let at = 18 + i * SevDigestEntryLen
    let g = guidLe(e[0])
    for j in 0 ..< 16: result[at + j] = g[j]
    putLe(result, at + 16, uint64(SevDigestEntryLen), 2)
    for j in 0 ..< 32: result[at + 18 + j] = e[1][j]

proc kernelDigestPage*(h: SnpKernelDigests; offsetInPage: int): seq[byte] =
  ## The whole measured page the table sits in, at its offset.
  let table = h.kernelDigestTable()
  if offsetInPage < 0 or offsetInPage + table.len > SnpPageSize:
    launchFail(slcKernelDigestsOverflowPage,
      "a " & $table.len & "-byte table at offset " & $offsetInPage &
      " of a " & $SnpPageSize & "-byte page")
  result = newSeq[byte](SnpPageSize)
  for i in 0 ..< table.len: result[offsetInPage + i] = table[i]

# ---------------------------------------------------------------------
# The VMSA page — one processor's initial register state
# ---------------------------------------------------------------------

const
  VmcbSegLen* = 16

  # `SEV_ES_SAVE_AREA`. Only the fields a launch sets are named; every
  # other byte of the page is zero. `SnpVmsaFieldOffsets` below is the
  # same list as data, so a gate can check these against the page it
  # produces rather than against this comment.
  OffVmsaEs* = 0x000
  OffVmsaCs* = 0x010
  OffVmsaSs* = 0x020
  OffVmsaDs* = 0x030
  OffVmsaFs* = 0x040
  OffVmsaGs* = 0x050
  OffVmsaGdtr* = 0x060
  OffVmsaLdtr* = 0x070
  OffVmsaIdtr* = 0x080
  OffVmsaTr* = 0x090
  OffVmsaEfer* = 0x0D0
  OffVmsaCr4* = 0x148
  OffVmsaCr0* = 0x158
  OffVmsaDr7* = 0x160
  OffVmsaDr6* = 0x168
  OffVmsaRflags* = 0x170
  OffVmsaRip* = 0x178
  OffVmsaGPat* = 0x268
  OffVmsaRdx* = 0x310
  OffVmsaSevFeatures* = 0x3B0
  OffVmsaXcr0* = 0x3E8
  OffVmsaMxcsr* = 0x408
  OffVmsaX87Fcw* = 0x410

  VmsaBspEip* = 0xFFFF_FFF0'u32
    ## The reset vector of the first processor. The others start at the
    ## address the firmware publishes.

type
  SnpVmmKind* = enum
    ## Which hypervisor will start the guest.
    ##
    ## A parameter and not a constant, because the initial register state
    ## is the hypervisor's choice rather than the architecture's. Three
    ## real ones disagree — in `%rdx`, in `MXCSR`, in the x87 control
    ## word, in the code- and stack-segment attributes, in the
    ## task-register attributes, in the page-attribute table, and in
    ## *which pages they place and in what order*. A measurement computed
    ## under the wrong one is wrong by a whole SHA-384.
    svkQemu = "qemu"
    svkEc2 = "ec2"
    svkGce = "gce"

  SevLaunchMode* = enum
    slmSev = "sev"
    slmSevEs = "sev-es"
    slmSevSnp = "sev-snp"

  VmsaSegment = object
    selector, attrib: uint16
    limit: uint32
    base: uint64

const
  KnownVmms*: array[3, string] = ["qemu", "ec2", "gce"]
    ## The hypervisors this build has initial register state for, as
    ## text, for the surfaces that take a name. Kept as data beside the
    ## enumeration rather than derived from it so that a caller-facing
    ## list cannot drift from the set that is actually implemented; a
    ## gate checks the two against each other in both directions.

proc vmmKindFor*(name: string): SnpVmmKind =
  ## The hypervisor a name refers to. Refuses an unknown one rather than
  ## defaulting, for the reason `SnpVmmKind` exists at all.
  for k in SnpVmmKind:
    if $k == name: return k
  launchFail(slcUnknownHypervisor,
    name.escape() & " is not one of " & KnownVmms.join(", "))

const
  SnpVmsaFieldOffsets*: array[23, tuple[name: string; at, len: int]] = [
    ("es", OffVmsaEs, VmcbSegLen), ("cs", OffVmsaCs, VmcbSegLen),
    ("ss", OffVmsaSs, VmcbSegLen), ("ds", OffVmsaDs, VmcbSegLen),
    ("fs", OffVmsaFs, VmcbSegLen), ("gs", OffVmsaGs, VmcbSegLen),
    ("gdtr", OffVmsaGdtr, VmcbSegLen), ("ldtr", OffVmsaLdtr, VmcbSegLen),
    ("idtr", OffVmsaIdtr, VmcbSegLen), ("tr", OffVmsaTr, VmcbSegLen),
    ("efer", OffVmsaEfer, 8), ("cr4", OffVmsaCr4, 8), ("cr0", OffVmsaCr0, 8),
    ("dr7", OffVmsaDr7, 8), ("dr6", OffVmsaDr6, 8),
    ("rflags", OffVmsaRflags, 8), ("rip", OffVmsaRip, 8),
    ("g_pat", OffVmsaGPat, 8), ("rdx", OffVmsaRdx, 8),
    ("sev_features", OffVmsaSevFeatures, 8), ("xcr0", OffVmsaXcr0, 8),
    ("mxcsr", OffVmsaMxcsr, 4), ("x87_fcw", OffVmsaX87Fcw, 2)]
    ## Every field a launch writes, as data. A gate walks this list and
    ## requires that the fields do not overlap, that each lies inside the
    ## page, and that the bytes the builder sets are exactly the union of
    ## them — so an offset typed wrongly here collides with its
    ## neighbour, or leaves a written byte outside the list, instead of
    ## quietly moving a value.

proc putSegment(page: var seq[byte]; at: int; seg: VmsaSegment) =
  putLe(page, at + 0, uint64(seg.selector), 2)
  putLe(page, at + 2, uint64(seg.attrib), 2)
  putLe(page, at + 4, uint64(seg.limit), 4)
  putLe(page, at + 8, seg.base, 8)

proc vmsaPage*(eip: uint32; sevFeatures: uint64; vcpuSignature: uint32;
               vmm: SnpVmmKind): seq[byte] =
  ## One processor's initial state, as the 4,096 bytes that get hashed.
  var csFlags = 0x9b'u16
  var ssFlags = 0x93'u16
  var trFlags = 0x8b'u16
  var gPat = 0x0007_0406_0007_0406'u64   ## AMD64 APM Vol 2 §A.3.
  var rdx = uint64(vcpuSignature)
  var mxcsr = 0x1f80'u32
  var fcw = 0x037f'u16
  case vmm
  of svkQemu: discard
  of svkEc2:
    # This one starts the FIRST processor with a code segment that is
    # not accessed yet, and the others with one that is.
    if eip == VmsaBspEip: csFlags = 0x9a'u16
    ssFlags = 0x92'u16
    trFlags = 0x83'u16
    rdx = 0x600'u64
    mxcsr = 0
    fcw = 0
  of svkGce:
    gPat = 0x0007_0106'u64
    rdx = 0x600'u64
    mxcsr = 0
    fcw = 0

  result = newSeq[byte](SnpPageSize)
  result.putSegment(OffVmsaEs,
    VmsaSegment(attrib: 0x93'u16, limit: 0xffff'u32))
  result.putSegment(OffVmsaCs,
    VmsaSegment(selector: 0xf000'u16, attrib: csFlags, limit: 0xffff'u32,
                base: uint64(eip and 0xffff_0000'u32)))
  result.putSegment(OffVmsaSs,
    VmsaSegment(attrib: ssFlags, limit: 0xffff'u32))
  result.putSegment(OffVmsaDs,
    VmsaSegment(attrib: 0x93'u16, limit: 0xffff'u32))
  result.putSegment(OffVmsaFs,
    VmsaSegment(attrib: 0x93'u16, limit: 0xffff'u32))
  result.putSegment(OffVmsaGs,
    VmsaSegment(attrib: 0x93'u16, limit: 0xffff'u32))
  result.putSegment(OffVmsaGdtr, VmsaSegment(limit: 0xffff'u32))
  result.putSegment(OffVmsaLdtr,
    VmsaSegment(attrib: 0x82'u16, limit: 0xffff'u32))
  result.putSegment(OffVmsaIdtr, VmsaSegment(limit: 0xffff'u32))
  result.putSegment(OffVmsaTr,
    VmsaSegment(attrib: trFlags, limit: 0xffff'u32))
  putLe(result, OffVmsaEfer, 0x1000'u64, 8)      ## the host enables SVME
  putLe(result, OffVmsaCr4, 0x40'u64, 8)         ## and machine-check
  putLe(result, OffVmsaCr0, 0x10'u64, 8)
  putLe(result, OffVmsaDr7, 0x400'u64, 8)
  putLe(result, OffVmsaDr6, 0xffff_0ff0'u64, 8)
  putLe(result, OffVmsaRflags, 0x2'u64, 8)
  putLe(result, OffVmsaRip, uint64(eip and 0xffff'u32), 8)
  putLe(result, OffVmsaGPat, gPat, 8)
  putLe(result, OffVmsaRdx, rdx, 8)
  putLe(result, OffVmsaSevFeatures, sevFeatures, 8)
  putLe(result, OffVmsaXcr0, 0x1'u64, 8)
  putLe(result, OffVmsaMxcsr, uint64(mxcsr), 4)
  putLe(result, OffVmsaX87Fcw, uint64(fcw), 2)

# ---------------------------------------------------------------------
# The whole calculation
# ---------------------------------------------------------------------

const
  MaxProcessors* = 1024

# ---------------------------------------------------------------------
# Which processor the hypervisor says it is
# ---------------------------------------------------------------------

proc cpuSignature*(family, model, stepping: int): uint32 =
  ## The 32-bit `CPUID Fn0000_0001_EAX` word, from the three numbers a
  ## machine model is usually quoted as.
  ##
  ## The packing is AMD's *CPUID Specification*, publication 25481: a
  ## family above 15 is split into a 4-bit low half pinned at 15 and an
  ## 8-bit extension, and a model is split into two nibbles that are not
  ## adjacent. Written out rather than tabulated because the split is the
  ## thing that goes wrong — a Genoa part quoted as "family 25 model 17"
  ## packs to `0x00a00f11`, and reading that back naively gives family 15.
  var familyLow = family
  var familyHigh = 0
  if family > 0xf:
    familyLow = 0xf
    familyHigh = (family - 0xf) and 0xff
  uint32((familyHigh shl 20) or (((model shr 4) and 0xf) shl 16) or
         (familyLow shl 8) or ((model and 0xf) shl 4) or (stepping and 0xf))

const
  SnpCpuModels*: array[16, tuple[name: string; family, model, stepping: int]] = [
    ("EPYC", 23, 1, 2),
    ("EPYC-v1", 23, 1, 2),
    ("EPYC-v2", 23, 1, 2),
    ("EPYC-IBPB", 23, 1, 2),
    ("EPYC-v3", 23, 1, 2),
    ("EPYC-v4", 23, 1, 2),
    ("EPYC-Rome", 23, 49, 0),
    ("EPYC-Rome-v1", 23, 49, 0),
    ("EPYC-Rome-v2", 23, 49, 0),
    ("EPYC-Rome-v3", 23, 49, 0),
    ("EPYC-Milan", 25, 1, 1),
    ("EPYC-Milan-v1", 25, 1, 1),
    ("EPYC-Milan-v2", 25, 1, 1),
    ("EPYC-Genoa", 25, 17, 0),
    ("EPYC-Genoa-v1", 25, 17, 0),
    ("EPYC-Turin", 26, 0, 0)]
    ## The machine models a hypervisor can be asked for, and what each
    ## one reports at reset. Several names share a signature — a model's
    ## revisions differ in features the guest sees, not in the word
    ## `%rdx` holds — so this is a list of NAMES and not a list of
    ## processors, which is why it is longer than it looks like it should
    ## be.
    ##
    ## The table is transcribed, and a gate does not take the
    ## transcription on trust: it re-derives every row from the reference
    ## implementation's own pinned table and requires the two to agree in
    ## BOTH directions, so a row invented here or dropped from here is a
    ## failure.

proc cpuSignatureFor*(name: string): uint32 =
  ## The signature a named machine model reports. Refuses an unknown
  ## name rather than defaulting: a default here is a measurement
  ## computed for a machine nobody asked for.
  for m in SnpCpuModels:
    if m.name == name: return cpuSignature(m.family, m.model, m.stepping)
  var known: seq[string] = @[]
  for m in SnpCpuModels: known.add m.name
  launchFail(slcUnknownProcessorModel,
    name.escape() & " is not one of " & known.join(", "))

type
  SevLaunchParameters* = object
    ## Everything a launch measurement depends on.
    mode*: SevLaunchMode
    firmware*: seq[byte]
      ## The firmware image, whole. Read even when `firmwareDigest`
      ## supplies its contribution, because its tables are what say what
      ## else gets placed and where.
    vcpus*: int
    vcpuSignature*: uint32
      ## The family/model/stepping word the hypervisor reports in `%rdx`
      ## at reset. A different machine model is a different measurement
      ## even with byte-identical software.
    guestFeatures*: uint64
      ## The feature word each VMSA carries. The two pre-SNP modes ignore
      ## it, because their VMSAs do not carry it; see
      ## `sevFeaturesInVmsaFor`.
    vmm*: SnpVmmKind
    hasKernel*: bool
      ## Whether this is a measured direct boot. A launch with no kernel
      ## leaves the digest region present but ZERO rather than absent,
      ## which is a different measurement — so this is a flag, and not
      ## "the kernel happens to be empty".
    kernel*, initrd*: seq[byte]
    cmdline*: string

proc sevFeaturesInVmsaFor*(mode: SevLaunchMode; declared: uint64): uint64 =
  ## What actually reaches the VMSA's feature word.
  ##
  ## Only an SNP launch sets it. The two earlier modes leave it zero
  ## whatever the caller declares. Stated as a function rather than
  ## buried in a branch, because a caller who hands a feature word to an
  ## `slmSevEs` launch and gets a digest back deserves to be able to find
  ## out that the word was not used.
  case mode
  of slmSevSnp: declared
  of slmSevEs, slmSev: 0'u64

proc snpFirmwareDigest*(firmware: openArray[byte]): seq[byte] =
  ## The firmware image's own contribution to an SNP launch measurement:
  ## the chain after its pages, and before anything else.
  let image = parseOvmfImage(firmware)
  var ctx = newSnpLaunchContext()
  ctx.updateNormalPages(image.gpa, firmware)
  ctx.ld

proc vmsaPagesFor(img: OvmfImage; p: SevLaunchParameters): seq[seq[byte]] =
  if p.vcpus < 1 or p.vcpus > MaxProcessors:
    launchFail(slcProcessorCountOutOfRange,
      $p.vcpus & " against a range of 1 to " & $MaxProcessors)
  let features = sevFeaturesInVmsaFor(p.mode, p.guestFeatures)
  result.add vmsaPage(VmsaBspEip, features, p.vcpuSignature, p.vmm)
  if p.vcpus > 1:
    let apEip = img.resetVectorEip()
    if apEip == 0:
      launchFail(slcNoResetVector, $p.vcpus & " processors were asked for")
    let ap = vmsaPage(apEip, features, p.vcpuSignature, p.vmm)
    for _ in 1 ..< p.vcpus: result.add ap

proc requireKernelDigestSupport(img: OvmfImage) =
  ## Two conditions, and they are genuinely two.
  ##
  ## The image must publish the ADDRESS the table goes at, and its page
  ## list must RESERVE the region containing that address. A firmware
  ## that does one without the other would have the digests written
  ## somewhere the measurement does not cover, or covered at a position
  ## nothing agrees on — either way the kernel is not measured, and
  ## producing a number anyway is the failure mode this refusal exists to
  ## prevent.
  if img.kernelDigestsTableGpa() == 0:
    launchFail(slcKernelDigestsNoAddress,
      "the published address is zero, and this launch would have written " &
      "the digests into a region its page list reserves")
  if not img.reservesKernelDigestRegion():
    launchFail(slcKernelDigestsNoRegion,
      "the page list has " & $img.sections.len & " entries and none of " &
      "them is that region")

proc kernelDigestPageFor(img: OvmfImage; p: SevLaunchParameters;
                         section: OvmfSection): seq[byte] =
  let digests = kernelDigestsFor(p.kernel, p.initrd, p.cmdline)
  let gpa = img.kernelDigestsTableGpa()
  let page = kernelDigestPage(digests, int(gpa) mod SnpPageSize)
  if int(section.size) != page.len:
    launchFail(slcKernelDigestsRegionSize,
      "the page list reserves 0x" & toHex(int(section.size), 8) &
      " bytes and the measured page is " & $page.len)
  page

proc snpLaunchDigest*(p: SevLaunchParameters;
                      firmwareDigest: openArray[byte] = []): seq[byte] =
  ## The `MEASUREMENT` an SEV-SNP part will report for this launch.
  ##
  ## `firmwareDigest`, if given, replaces the walk over the firmware's
  ## own pages with the value `snpFirmwareDigest` computed earlier. The
  ## image is still read, because its tables say what else is placed and
  ## where; only the page walk is skipped. The two routes produce the
  ## same number by construction, and a gate checks that they do rather
  ## than taking "by construction" for it.
  if p.mode != slmSevSnp:
    raise newException(ValueError,
      "snpLaunchDigest computes an " & $slmSevSnp &
      " measurement and was given " & $p.mode)
  let img = parseOvmfImage(p.firmware)
  if not img.hasPageList:
    launchFail(slcNoPageList,
      "the identifying table has " & $img.entries.len & " entries and " &
      "none of them points at a page list")
  var ctx = newSnpLaunchContext(firmwareDigest)
  if firmwareDigest.len == 0:
    ctx.updateNormalPages(img.gpa, p.firmware)
  if p.hasKernel: requireKernelDigestSupport(img)

  for s in img.sections:
    case s.kind
    of oskSecMem:
      # One hypervisor leaves this region UNMEASURED where the others
      # fold it in as zero. Those are two different page kinds and so
      # two different digests; this is exactly the divergence a
      # calculator with one hypervisor built in gets silently wrong.
      let kind = if p.vmm == svkGce: spkUnmeasured else: spkZero
      ctx.updateContentlessPages(kind, uint64(s.gpa), int(s.size))
    of oskSecrets:
      ctx.updateContentlessPages(spkSecrets, uint64(s.gpa), int(s.size))
    of oskCpuid:
      # One hypervisor places this page after everything else rather
      # than in list order, and the chain is order-sensitive, so where
      # it goes is part of the answer. Folded in below for that one.
      if p.vmm != svkEc2:
        ctx.updateContentlessPages(spkCpuid, uint64(s.gpa), int(s.size))
    of oskParavisorCallArea:
      ctx.updateContentlessPages(spkZero, uint64(s.gpa), int(s.size))
    of oskKernelDigests:
      if p.hasKernel:
        ctx.updateNormalPages(uint64(s.gpa), kernelDigestPageFor(img, p, s))
      else:
        ctx.updateContentlessPages(spkZero, uint64(s.gpa), int(s.size))
  if p.vmm == svkEc2:
    for s in img.sections:
      if s.kind == oskCpuid:
        ctx.updateContentlessPages(spkCpuid, uint64(s.gpa), int(s.size))

  for page in vmsaPagesFor(img, p):
    ctx.updateVmsaPage(page)
  ctx.ld

proc sevLaunchDigest*(p: SevLaunchParameters): seq[byte] =
  ## The launch digest of the two generations that predate SNP: a flat
  ## SHA-256 over the firmware image, then the table of kernel digests if
  ## there is one, then each processor's VMSA — and for `slmSev` no VMSA
  ## at all, because that generation does not measure register state.
  if p.mode == slmSevSnp:
    raise newException(ValueError,
      "sevLaunchDigest computes the pre-" & $slmSevSnp &
      " digest and was given " & $p.mode)
  let img = parseOvmfImage(p.firmware)
  var buf = p.firmware
  if p.hasKernel:
    if img.kernelDigestsTableGpa() == 0:
      # The same rule, at a second site, for a launch shape that appends
      # the table to the image instead of placing it in a page. The two
      # sites name themselves in the detail: a rule with two sites is a
      # rule a test can assert while only one of them works, which is
      # the way this tree's assertions have most often been defeated.
      launchFail(slcKernelDigestsNoAddress,
        "the published address is zero, and this launch would have " &
        "appended the digests to the firmware image")
    buf.add kernelDigestsFor(p.kernel, p.initrd, p.cmdline).kernelDigestTable()
  if p.mode == slmSevEs:
    for page in vmsaPagesFor(img, p): buf.add page
  sha256Of(buf)

proc launchDigest*(p: SevLaunchParameters): seq[byte] =
  ## The one entry point a caller that knows only the mode needs.
  case p.mode
  of slmSevSnp: snpLaunchDigest(p)
  of slmSevEs, slmSev: sevLaunchDigest(p)

proc launchDigestHex*(p: SevLaunchParameters): string =
  for b in launchDigest(p): result.add toHex(int(b), 2).toLowerAscii
