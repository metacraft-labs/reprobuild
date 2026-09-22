## Two genuine trust-domain quotes, and the measurements they carry
## recomputed from the firmware their operators publish.
##
## ## Why this gate exists
##
## The neighbouring launch calculator was gated entirely against another
## calculator's published vectors — its own entry said so — and its
## review found the corpus so degenerate that a build reading neither
## the kernel nor the initial ramdisk reproduced every published number.
## The lesson filed was that agreement with a reference implementation
## proves conformance and not correctness.
##
## This gate is built to be the other thing. Its two positive vectors
## are fields of quotes that real machines signed, and each one's
## `MRTD` is recomputed here from a firmware image the operator of that
## machine publishes. Nothing in the chain is this repository's opinion:
## the operator says which firmware, the distribution ships the
## firmware, the machine reports the measurement, and this build
## computes it.
##
## ## What each part is for
##
##   1. **Provenance.** Every corpus is checked against a recorded size
##      and digest before anything reads it, and the table is indexed by
##      an enumeration so a row cannot be dropped and a corpus cannot be
##      added without one.
##   2. **The quotes are genuine, cryptographically.** Both are parsed,
##      all three of their signatures verified, the attestation key's
##      binding to the enclave report checked, and their embedded chains
##      required to end at the vendor root this repository already pins
##      from the sibling quote reader. A bit flipped inside the signed
##      span is refused.
##   3. **The headline.** For each quote, the measurement computed from
##      the published firmware equals the measurement the quote carries.
##   4. **Corroboration, kept separate.** Two further parties publish a
##      value for operator A's firmware. That is a different claim
##      resting on different evidence, and it is asserted separately
##      rather than averaged into the one above.
##   5. **The corpus is not degenerate, and that is asserted.** The two
##      firmwares' section tables DIFFER; the measured region is 892
##      pages and not one; exactly one section of each is folded in and
##      the others are not, so the distinction has an input; and the
##      three facts the calculation turns on — table order, per-page
##      interleaving, and which sections contribute contents — are each
##      shown to change the answer.
##   6. **The runtime registers.** Operator B serves its domain's
##      measurement record beside its quote. All four registers replay
##      from it, including the fourth, which both other quotes in this
##      repository leave at its reset value.
##
## ## Mocking
##
## None. Real quotes, real firmware, real SHA-384.

import std/[json, strutils, unittest]

import repro_attest
import repro_attest_verify/tdx_quote
import repro_attest_verify/x509

include ./tdx_launch_vectors
include ./tdx_vectors

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc sectionsOf(s: string): seq[TdvfSection] =
  readTdvfSections(bytesOf(s))

proc servedQuoteDocument(served: string; declared: int): string =
  ## The document inside a served buffer.
  ##
  ## Both endpoints answer with a fixed-size buffer and zero-pad it, so
  ## the served bytes are longer than the quote. Where the document ends
  ## is established two ways and both must hold: the document's own
  ## declared signature length, read through `tdx_quote`'s offsets, and
  ## the requirement that EVERY byte past that point is zero. The second
  ## is the one that makes the first safe — a declared length is a field
  ## of the document, so a shorter one would silently discard signed
  ## bytes, and here it cannot, because the discarded bytes have to be
  ## padding. Walking BACK over the zeroes instead would be wrong: the
  ## certification data inside the signature block is a
  ## null-terminated string and ends in one.
  let sigLenAt = TdxQuoteHeaderLen + TdReportLen
  var stated = 0
  for i in countdown(3, 0):
    stated = (stated shl 8) or int(uint8(served[sigLenAt + i]))
  let byDeclaration = sigLenAt + 4 + stated
  doAssert byDeclaration == declared
  doAssert byDeclaration <= served.len
  for i in byDeclaration ..< served.len:
    doAssert served[i] == '\0'
  served[0 ..< byDeclaration]

proc leafPointOf(q: TdxQuote): seq[byte] =
  let pk = parseCertificate(q.pckChain[0]).publicKey
  result = newSeq[byte](pk.len)
  for i in 0 ..< pk.len: result[i] = pk[i]

suite "trust-domain launch measurement":

  test "every pinned corpus matches its recorded size and digest":
    # Both directions. The table is `array[TdxFixtureName, …]`, so a row
    # exists for every corpus by construction and `fixtureBytes` is a
    # `case` Nim refuses to leave incomplete. What is asserted here is
    # that every row is actually CHECKED — the defect filed against the
    # sibling corpus was a table that documented checking all
    # thirty-one of its rows and checked five, with the headline
    # constant among the twenty-six it did not.
    var checked = 0
    for name in TdxFixtureName:
      let row = TdxFixtureProvenances[name]
      let bytes = fixtureBytes(name)
      check bytes.len == row.bytes
      check row.sha256.len == 64
      check sha256Hex(bytes) == row.sha256
      check row.origin.len > 0
      inc checked
    check checked == 6
    check ord(high(TdxFixtureName)) + 1 == 6

  test "a live quote's bytes are dated, and a published file's are not":
    # A re-fetch of either endpoint returns a DIFFERENT quote over fresh
    # report data. Recording the date beside those rows is what stops a
    # later reader from taking a digest mismatch for a refutation.
    check TdxFixtureProvenances[fxQuoteA].observed == "2026-09-22"
    check TdxFixtureProvenances[fxQuoteB].observed == "2026-09-22"
    check TdxFixtureProvenances[fxRegisterLogB].observed == "2026-09-22"
    check TdxFixtureProvenances[fxFirmwareA].observed == ""
    check TdxFixtureProvenances[fxFirmwareB].observed == ""

  test "both quotes are genuine: three signatures, a binding, a root":
    for c in TdxLaunchCase:
      let v = TdxLaunchVectors[c]
      let q = parseTdxQuote(bytesOf(servedQuoteDocument(v.quote,
        v.documentBytes)))
      check q.version == TdxQuoteVersion4
      check q.teeType == TdxTeeType
      check q.attestationKeyType == TdxAttestationKeyTypeEcdsaP256
      check verifyQuoteSignature(q)
      check verifyQeReportSignature(q, leafPointOf(q))
      check isBound(qeReportBindsAttestationKey(q))
      # The chain inside the quote ends at the vendor root this
      # repository pins from the sibling quote reader, byte for byte.
      check q.pckChain.len == TdxChainElements
      check hexOf(q.pckChain[q.pckChain.len - 1]).toLowerAscii ==
        IntelSgxRootCaDerHex.toLowerAscii

  test "a bit moved inside a signed span is refused, and says which":
    for c in TdxLaunchCase:
      let v = TdxLaunchVectors[c]
      var raw = bytesOf(servedQuoteDocument(v.quote, v.documentBytes))
      # Byte 200 is byte sixteen of the INITIAL-MEMORY MEASUREMENT
      # itself, which the quote signature covers and the enclave
      # signature does not. So the field this gate reproduces is a field
      # a real part signed, and moving it is what the signature refuses.
      # This was also confirmed out of band, by an implementation
      # sharing no code with this one: a from-scratch ECDSA P-256 over
      # the same span, self-tested against RFC 6979 A.2.5 with a
      # negative control, verifies both quotes and refuses both when
      # this byte moves.
      raw[200] = raw[200] xor 0x01'u8
      let q = parseTdxQuote(raw)
      check not verifyQuoteSignature(q)
      check verifyQeReportSignature(q, leafPointOf(q))
      check isBound(qeReportBindsAttestationKey(q))

  test "each quote's measurement is recomputed from published firmware":
    # The headline. Three values per case and they are three different
    # things: what the machine reported, what this build computes, and
    # what the corpus records. A gate comparing only two of them could
    # be comparing this build with itself.
    for c in TdxLaunchCase:
      let v = TdxLaunchVectors[c]
      let q = parseTdxQuote(bytesOf(servedQuoteDocument(v.quote,
        v.documentBytes)))
      let reported = hexOf(q.body.mrTd).toLowerAscii
      let computed = tdxMrtdHex(bytesOf(v.firmware), v.order)
      check reported == v.mrtd
      check computed == v.mrtd
      check computed == reported
      check sha256Hex(v.firmware) == v.firmwareSha256
      check v.firmwareOrigin.len > 0

  test "the two quotes report DIFFERENT measurements":
    # Otherwise one firmware would be doing the work of two and the
    # second case would be free.
    check TdxLaunchVectors[lcOperatorA].mrtd !=
      TdxLaunchVectors[lcOperatorB].mrtd
    check TdxLaunchVectors[lcOperatorA].firmwareSha256 !=
      TdxLaunchVectors[lcOperatorB].firmwareSha256

  test "two further parties publish operator A's measurement":
    # Corroboration, and a separate claim from the one above: these are
    # published EXPECTATIONS, not observed fields of any quote.
    var publishers = 0
    for p in TdxMrtdPublisher:
      check PublishedMrtd[p].value == TdxLaunchVectors[lcOperatorA].mrtd
      check PublishedMrtd[p].where.len > 0
      inc publishers
    check publishers == 2
    # And they do not corroborate operator B, which has no published
    # expectation anywhere in reach. Said by value rather than omitted.
    for p in TdxMrtdPublisher:
      check PublishedMrtd[p].value != TdxLaunchVectors[lcOperatorB].mrtd

  test "the section tables are read, in order, and they differ":
    let a = sectionsOf(FirmwareUbuntu)
    let b = sectionsOf(FirmwareDstack)
    check a.len == 6
    check b.len == 6
    for i in 0 ..< 6:
      check ord(a[i].kind) == SectionKindsA[i]
      check a[i].memoryAddress == SectionAddressesA[i]
      check a[i].memorySize == SectionSizesA[i]
      check a[i].measured == MeasuredSectionsBoth[i]
      check ord(b[i].kind) == SectionKindsB[i]
      check b[i].memoryAddress == SectionAddressesB[i]
      check b[i].memorySize == SectionSizesB[i]
      check b[i].measured == MeasuredSectionsBoth[i]
    # The dimension a one-firmware corpus would have left with no input.
    var differs = false
    for i in 0 ..< 6:
      if a[i].memoryAddress != b[i].memoryAddress or
         a[i].memorySize != b[i].memorySize: differs = true
    check differs

  test "the corpus is not single-anything":
    for c in TdxLaunchCase:
      let secs = sectionsOf(TdxLaunchVectors[c].firmware)
      var measured = 0
      var unmeasuredWithContents = 0
      var blank = 0
      var pages = 0
      for s in secs:
        if s.measured:
          inc measured
          check int(s.memorySize div 4096) == MeasuredPagesBoth
        elif s.rawSize > 0'u32: inc unmeasuredWithContents
        else: inc blank
        pages += int(s.memorySize div 4096)
      check measured == 1
      check unmeasuredWithContents == 1
      check blank == 4
      check pages == (if c == lcOperatorA: PlacedPagesA else: PlacedPagesB)
    check PlacedPagesA != PlacedPagesB
    check MeasuredPagesBoth > 1

  test "table order is an input: address order gives another value":
    let secs = sectionsOf(FirmwareUbuntu)
    var byAddress = secs
    for i in 0 ..< byAddress.len:
      for j in i + 1 ..< byAddress.len:
        if byAddress[j].memoryAddress < byAddress[i].memoryAddress:
          swap(byAddress[i], byAddress[j])
    let image = bytesOf(FirmwareUbuntu)
    let order = TdxLaunchVectors[lcOperatorA].order
    check toHexLower(mrtdOf(secs, image, order)) ==
      TdxLaunchVectors[lcOperatorA].mrtd
    check toHexLower(mrtdOf(byAddress, image, order)) !=
      TdxLaunchVectors[lcOperatorA].mrtd
    # And under the OTHER host order too, so the two facts are not
    # entangled: address ordering is wrong however the pages are folded.
    check toHexLower(mrtdOf(byAddress, image, thoExtendAfterTheRegion)) !=
      TdxLaunchVectors[lcOperatorA].mrtd
    # And the two orders really are different orders, so the check above
    # is not comparing a list with itself.
    var reordered = false
    for i in 0 ..< secs.len:
      if secs[i].memoryAddress != byAddress[i].memoryAddress:
        reordered = true
    check reordered

  test "the two hosts fold in different orders, and each is wrong for the other":
    # The finding. Two genuine quotes, two orders, and the cross terms
    # are both refuted — so neither value is reachable by the other
    # order and a build with one order compiled in is wrong for one of
    # these two real operators.
    check TdxLaunchVectors[lcOperatorA].order !=
      TdxLaunchVectors[lcOperatorB].order
    for c in TdxLaunchCase:
      let v = TdxLaunchVectors[c]
      let image = bytesOf(v.firmware)
      for o in TdxHostOrder:
        let got = tdxMrtdHex(image, o)
        if o == v.order:
          check got == v.mrtd
        else:
          check got != v.mrtd
    # Both orders are named, and the names are the ones a caller writes.
    check tdxHostOrderFor("per-page") == thoExtendAfterEachPage
    check tdxHostOrderFor("per-region") == thoExtendAfterTheRegion
    expect TdxLaunchError:
      discard tdxHostOrderFor("per-page ")

  test "a measured section's bytes are in, an unmeasured one's are not":
    # The rule the sibling calculator's corpus could not exercise at
    # all: there, every image was one page and nothing had contents, so
    # a build that read no contents produced every published number.
    let secs = sectionsOf(FirmwareUbuntu)
    var measuredAt, unmeasuredAt = -1
    for s in secs:
      if s.measured: measuredAt = int(s.dataOffset)
      elif s.rawSize > 0'u32: unmeasuredAt = int(s.dataOffset)
    check measuredAt >= 0
    check unmeasuredAt >= 0

    let order = TdxLaunchVectors[lcOperatorA].order
    var flippedMeasured = bytesOf(FirmwareUbuntu)
    flippedMeasured[measuredAt] = flippedMeasured[measuredAt] xor 0x01'u8
    check tdxMrtdHex(flippedMeasured, order) !=
      TdxLaunchVectors[lcOperatorA].mrtd

    var flippedUnmeasured = bytesOf(FirmwareUbuntu)
    flippedUnmeasured[unmeasuredAt] =
      flippedUnmeasured[unmeasuredAt] xor 0x01'u8
    check tdxMrtdHex(flippedUnmeasured, order) ==
      TdxLaunchVectors[lcOperatorA].mrtd

    # And the last byte of the measured region, so the walk is shown to
    # reach the end of it rather than stopping after the first page.
    var flippedLast = bytesOf(FirmwareUbuntu)
    let lastAt = measuredAt + MeasuredPagesBoth * 4096 - 1
    flippedLast[lastAt] = flippedLast[lastAt] xor 0x01'u8
    check tdxMrtdHex(flippedLast, order) != TdxLaunchVectors[lcOperatorA].mrtd

  test "a page's address is in the measurement as much as its bytes":
    var secs = sectionsOf(FirmwareUbuntu)
    let image = bytesOf(FirmwareUbuntu)
    for i in 0 ..< secs.len:
      if not secs[i].measured:
        # Move an UNMEASURED region. Its contents never enter the
        # digest, so if the answer changes it can only be the address.
        var moved = secs
        moved[i].memoryAddress = moved[i].memoryAddress + 0x100000'u64
        check toHexLower(mrtdOf(moved, image,
          TdxLaunchVectors[lcOperatorA].order)) !=
          TdxLaunchVectors[lcOperatorA].mrtd
        break

# ---------------------------------------------------------------------
# The runtime registers
# ---------------------------------------------------------------------

proc operatorBEvents(): seq[TdxMeasuredEvent] =
  ## Operator B's record, as the fold takes it. The record is JSON and
  ## the fold is the library's; this reads the published shape and hands
  ## over the two things a fold uses, so there is no second
  ## implementation of the hash chain anywhere in this gate.
  result = @[]
  for e in parseJson(RegisterLogOperatorB).elems:
    result.add TdxMeasuredEvent(
      register: e["imr"].getInt,
      digest: bytesOf(hexToBytes(e["digest"].getStr)))

suite "trust-domain runtime registers":

  test "all four of a genuine quote's registers replay from its record":
    let q = parseTdxQuote(bytesOf(servedQuoteDocument(QuoteOperatorB,
      TdxLaunchVectors[lcOperatorB].documentBytes)))
    let replay = foldTdxRegisters(operatorBEvents())
    var reached = 0
    for r in 0 ..< TdxRuntimeRegisterCount:
      check toHexLower(replay.registers[r]) ==
        hexOf(q.body.rtMr[r]).toLowerAscii
      if replay.reached[r]: inc reached
    check reached == OperatorBRegistersReached
    check reached == 4

  test "the fourth register is not a reset value here":
    # Both trust-domain quotes the sibling reader's corpus pinned leave
    # it at zero, so until this corpus it had no input at all.
    let q = parseTdxQuote(bytesOf(servedQuoteDocument(QuoteOperatorB,
      TdxLaunchVectors[lcOperatorB].documentBytes)))
    var allZero = true
    for b in q.body.rtMr[3]:
      if b != 0'u8: allZero = false
    check not allZero

  test "the record is not degenerate: every register has entries":
    var perRegister: array[TdxRuntimeRegisterCount, int]
    for e in operatorBEvents():
      inc perRegister[e.register]
    for r in 0 ..< TdxRuntimeRegisterCount:
      check perRegister[r] > 0
    var total = 0
    for r in 0 ..< TdxRuntimeRegisterCount: total += perRegister[r]
    check total == 30

  test "one moved bit in one entry moves exactly one register":
    let base = foldTdxRegisters(operatorBEvents())
    var events = operatorBEvents()
    let target = events[0].register
    events[0].digest[0] = events[0].digest[0] xor 0x01'u8
    let moved = foldTdxRegisters(events)
    for r in 0 ..< TdxRuntimeRegisterCount:
      if r == target:
        check moved.registers[r] != base.registers[r]
      else:
        check moved.registers[r] == base.registers[r]

  test "the order within a register is an input":
    var events = operatorBEvents()
    var first, second = -1
    for i, e in events:
      if e.register == 0:
        if first < 0: first = i
        elif second < 0: second = i
    check first >= 0
    check second >= 0
    swap(events[first], events[second])
    let swapped = foldTdxRegisters(events)
    let base = foldTdxRegisters(operatorBEvents())
    check swapped.registers[0] != base.registers[0]

  test "which register an entry names is an input":
    var events = operatorBEvents()
    var moved = -1
    for i, e in events:
      if e.register == 1: moved = i
    check moved >= 0
    let base = foldTdxRegisters(operatorBEvents())
    events[moved].register = 2
    let after = foldTdxRegisters(events)
    check after.registers[1] != base.registers[1]
    check after.registers[2] != base.registers[2]
    check after.registers[0] == base.registers[0]
    check after.registers[3] == base.registers[3]

  test "the binary-log front end folds the same way the record does":
    # One fold, two shapes on the wire. A log that names indices 1..4
    # must produce what the same digests produce through the record
    # path, or the two front ends have drifted.
    let log = syntheticRegisterLog([1, 2, 3, 4, 1])
    let viaLog = replayTdxRegisters(parseEventLog(log))
    var events: seq[TdxMeasuredEvent] = @[]
    for n, index in [1, 2, 3, 4, 1]:
      events.add TdxMeasuredEvent(register: index - 1,
        digest: bytesOf(digest384(
          "trust-domain log entry " & $n & " index " & $index)))
    let viaRecord = foldTdxRegisters(events)
    for r in 0 ..< TdxRuntimeRegisterCount:
      check viaLog.registers[r] == viaRecord.registers[r]
      check viaLog.reached[r] == viaRecord.reached[r]
    check viaLog.extendsApplied == viaRecord.extendsApplied

  test "a register the record never reaches is reported as such":
    let replay = foldTdxRegisters(@[
      TdxMeasuredEvent(register: 0, digest: bytesOf(digest384("only")))])
    check replay.reached[0]
    check not replay.reached[1]
    check not replay.reached[2]
    check not replay.reached[3]
    for r in 1 ..< TdxRuntimeRegisterCount:
      check replay.registers[r] == initialRtmr()
