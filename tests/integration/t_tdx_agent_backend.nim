## The trust-domain agent backend: the quote it hands over, the bytes it
## insists that quote answers for, and every rule it refuses on.
##
## ## The claim that matters
##
## The same one its neighbour makes, for the same reason: **a driver
## must not hand on a quote that binds somebody else's 64 bytes.** Such
## a quote verifies end to end — three signatures, a chain to the
## vendor's root, a real measurement — and answers a question nobody
## here asked. The verifier compares the quote's bound bytes against the
## envelope, and the envelope is written by the same agent that was
## handed the stale quote. The machine is the only place it is visible.
##
## ## The corpus, and why it is the one that can say something
##
## **Five genuine quotes from five real trust domains**, across both
## quote versions this build reads:
##
##   * three pinned in `tdx_vectors`, two published by one project and
##     one by another;
##   * two fetched live from two unrelated operators' unauthenticated
##     endpoints, pinned in `tdx_launch_vectors` with the firmware that
##     produced their measurements.
##
## The vendor's own SAMPLE quote is published beside them and is NOT in
## the corpus, because its trust-domain report is all zeroes — a locator
## that returned sixty-four zero bytes would pass on it. It is kept as a
## control and the exclusion is asserted rather than left implicit.
##
## The five are not interchangeable and that is the point. The bound
## bytes differ between them, which is what stops a locator that
## returned a constant from passing; and they span version 4 and version
## 5, which is what stops a locator that ignored the six-byte report
## descriptor from passing — a version-5 quote puts every field after
## the header six bytes further along, so a reader that assumed would
## lift its 64 bytes out of the middle of a measurement.
##
## Three of the five arrive inside FIXED-SIZE buffers whose quote is a
## prefix. Where each ends is derived from the framing rather than
## transcribed, and the derivation is cross-checked against the two
## splits a sibling gate pins.
##
## ## The two readers of one field, held together by measurement
##
## The agent does not link the verifier, so the offsets are transcribed
## twice. Neither may reach for the other's constant — a check that
## compares a value against the constant that produced it passes however
## that constant is changed. They are held together instead by reading
## every genuine quote with BOTH and requiring the answers equal, and
## the limit of that is stated rather than implied: it catches a
## transcription error, and it does not catch two readers that are wrong
## the same way.
##
## ## Mocking
##
## None. `CapturedTsmSource` reads real files holding real quotes.

import std/[options, os, strutils, unittest]

import repro_attest
import repro_attest_verify/tdx_quote

include ./tdx_vectors
include ./tdx_launch_vectors

# ---------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------

var reached: set[TdxBackendCondition] = {}

proc refuses(body: proc (): void): ref TdxBackendError =
  try:
    body()
  except TdxBackendError as err:
    reached.incl err.condition
    return err
  raise newException(ValueError, "nothing was refused")

proc cardOf(s: set[TdxBackendCondition]): int =
  for c in TdxBackendCondition:
    if c in s: inc result

const
  BackendSource = staticRead(
    "../../libs/repro_attest/src/repro_attest/tdx_backend.nim")

proc raisedConditionsIn(source: string): seq[string] =
  ## Every ``tdxFail(tbc…`` in a source, in order. The declaration of
  ## `tdxFail` itself does not match, because it reads
  ## ``tdxFail*(condition:``.
  result = @[]
  var i = 0
  const Needle = "tdxFail(tbc"
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
# The corpus
# ---------------------------------------------------------------------

proc hexBytesOf(h: string): seq[byte] =
  var compact = ""
  for c in h:
    if c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: compact.add c
  doAssert compact.len mod 2 == 0
  result = newSeq[byte](compact.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(compact[2 * i .. 2 * i + 1]))

proc stringOfHex(h: string): string =
  for b in hexBytesOf(h): result.add char(b)

proc byteSeqOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc le32In(s: string; at: int): int =
  int(uint8(s[at])) or (int(uint8(s[at + 1])) shl 8) or
    (int(uint8(s[at + 2])) shl 16) or (int(uint8(s[at + 3])) shl 24)

proc declaredLengthOf(buffer: string): int =
  ## How long the quote in this buffer says it is.
  ##
  ## Derived rather than transcribed. Several of these fixtures are
  ## FIXED-SIZE buffers whose quote is a prefix — a transport pads the
  ## rest — and pinning each split as a number here would be a second
  ## copy of a fact two sibling gates already pin. The framing states
  ## it: the report is followed by a four-byte signature length, and
  ## the quote ends where that block ends. The two pinned splits are
  ## cross-checked against this derivation below, so the derivation and
  ## the pins hold each other up.
  let span = agentTdxReportSpan(buffer)
  let sigAt = span.at + span.width
  sigAt + 4 + le32In(buffer, sigAt)

type GenuineQuote = object
  name: string
  document: string

proc genuine(name, buffer: string): GenuineQuote =
  GenuineQuote(name: name, document: buffer[0 ..< declaredLengthOf(buffer)])

let genuineQuotes = @[
  genuine("go-tdx-guest's Sapphire Rapids domain",
          stringOfHex(GoTdxGuestSprQuoteHex)),
  genuine("go-tdx-guest's Emerald Rapids domain",
          stringOfHex(GoTdxGuestEmrQuoteHex)),
  genuine("trustee's version-5 domain", stringOfHex(TrusteeV5QuoteHex)),
  genuine("operator A's domain, fetched live",
          TdxLaunchVectors[lcOperatorA].quote),
  genuine("operator B's domain, fetched live",
          TdxLaunchVectors[lcOperatorB].quote)]

let notGenuine = stringOfHex(IntelSampleQuoteHex)
  ## The vendor's own SAMPLE quote, and it is deliberately NOT in the
  ## corpus above. Its trust-domain report is all zeroes, so a locator
  ## that returned sixty-four zero bytes would pass on it — see the
  ## degeneracy case, which states that rather than leaving the
  ## exclusion to look like an oversight.

proc boundBytesOf(q: GenuineQuote): string = agentTdxBoundBytes(q.document)


# ---------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------

type
  TdxCorpus* = enum
    ## Every byte corpus this gate reads, enumerated rather than listed,
    ## so a corpus cannot exist without a row and a row cannot exist
    ## without a corpus. **This change adds no new byte corpus to
    ## this repository**: every row is already pinned by a sibling, and
    ## what this table adds is that THIS gate's reading of it is pinned
    ## too. The last extension of the sibling corpus put 8.4 MB of raw
    ## binary into a public repository; this one puts none.
    tcSpr
    tcEmr
    tcTrusteeV5
    tcOperatorA
    tcOperatorB
    tcVendorSample

  TdxCorpusRow* = object
    name*: string
    bytes*: int
    sha256*: string
    origin*: string
    isGenuine*: bool
      ## Whether the domain that produced it is a real one. Recorded as
      ## a FIELD rather than left to the corpus's absence from a list,
      ## because the vendor's sample quote is published beside the real
      ## ones and is the control this gate keeps deliberately.

const
  TdxCorpora*: array[TdxCorpus, TdxCorpusRow] = [
    tcSpr: TdxCorpusRow(name: "GoTdxGuestSprQuoteHex", bytes: 4974,
      sha256: "6dde5548bec99147fef832643301f113df99931547be26df8ac376c4eaa5b5a7",
      origin: "google/go-tdx-guest, a Sapphire Rapids domain",
      isGenuine: true),
    tcEmr: TdxCorpusRow(name: "GoTdxGuestEmrQuoteHex", bytes: 5006,
      sha256: "cf77a6e91e48291d5d338c5f3b5d0674225a4d13e7d83ff5e537a4914bf22e1d",
      origin: "google/go-tdx-guest, an Emerald Rapids domain",
      isGenuine: true),
    tcTrusteeV5: TdxCorpusRow(name: "TrusteeV5QuoteHex", bytes: 5006,
      sha256: "586c2be0dc38d3c5653ecf91a0a482d8dbfaf3d3a0bcea2947bc2d321c8108a2",
      origin: "confidential-containers/trustee, a version-5 domain",
      isGenuine: true),
    tcOperatorA: TdxCorpusRow(name: "QuoteOperatorA", bytes: 5247,
      sha256: "214e926b905c8541fbc9192d7d42ce38a1f53ba1d89fb8833fcf7ddb2828c1ab",
      origin: "operator A's unauthenticated endpoint, fetched 2026-09-22",
      isGenuine: true),
    tcOperatorB: TdxCorpusRow(name: "QuoteOperatorB", bytes: 5006,
      sha256: "585d61c63d162cd59fd42e4b53e8c6b9dac1bfdda49b42d60880f06d0f4db1b2",
      origin: "operator B's unauthenticated endpoint, fetched 2026-09-22",
      isGenuine: true),
    tcVendorSample: TdxCorpusRow(name: "IntelSampleQuoteHex", bytes: 3696,
      sha256: "aa2cafadb32b80c51b74222bba189e311a6a49e369adfde5add67609e781989e",
      origin: "the vendor's own sample data; NOT a real domain",
      isGenuine: false)]

proc corpusBuffer(c: TdxCorpus): string =
  ## A `case`, so a corpus added to the enumeration without bytes does
  ## not compile.
  case c
  of tcSpr: stringOfHex(GoTdxGuestSprQuoteHex)
  of tcEmr: stringOfHex(GoTdxGuestEmrQuoteHex)
  of tcTrusteeV5: stringOfHex(TrusteeV5QuoteHex)
  of tcOperatorA: TdxLaunchVectors[lcOperatorA].quote
  of tcOperatorB: TdxLaunchVectors[lcOperatorB].quote
  of tcVendorSample: stringOfHex(IntelSampleQuoteHex)

# ---------------------------------------------------------------------
# A bench of real files
# ---------------------------------------------------------------------

type Bench = object
  dir: string
  outblobPath, providerPath, auxblobPath: string

var benchSequence = 0

proc newBench(outblob: string; provider = TdxProviderName;
              auxblob = ""): Bench =
  inc benchSequence
  result.dir = getTempDir() / ("repro-tdx-backend-" &
                               $getCurrentProcessId() & "-" & $benchSequence)
  createDir(result.dir)
  result.outblobPath = result.dir / TsmOutblobAttr
  result.providerPath = result.dir / TsmProviderAttr
  result.auxblobPath = result.dir / TsmAuxblobAttr
  writeFile(result.outblobPath, outblob)
  writeFile(result.providerPath, provider & "\n")
  if auxblob.len > 0: writeFile(result.auxblobPath, auxblob)

proc driverOver(b: Bench): TdxDriver =
  newTdxDriver(newCapturedTsmSource(b.outblobPath, b.providerPath,
                                    b.auxblobPath))

# ---------------------------------------------------------------------

suite "the corpus is five genuine quotes and is not degenerate":

  test "every one of them parses as a quote under BOTH readers":
    check genuineQuotes.len == 5
    for q in genuineQuotes:
      let byTheVerifier = parseTdxQuote(byteSeqOf(q.document))
      let span = agentTdxReportSpan(q.document)
      check span.width in [AgentTdxBodyLen10, AgentTdxBodyLen15]
      check byTheVerifier.teeType == AgentTdxTeeType

  test "both quote versions are represented, which the locator needs":
    # A corpus of one version cannot exercise the six-byte report
    # descriptor at all, and a reader that ignored it would pass.
    var versions: seq[int] = @[]
    for q in genuineQuotes:
      let v = int(parseTdxQuote(byteSeqOf(q.document)).version)
      if v notin versions: versions.add v
    check int(AgentTdxVersion4) in versions
    check int(AgentTdxVersion5) in versions
    check versions.len == 2

  test "the report starts six bytes later in a version-5 quote":
    # Stated as a measurement over the corpus rather than as a rule the
    # reader asserts about itself.
    for q in genuineQuotes:
      let version = parseTdxQuote(byteSeqOf(q.document)).version
      let span = agentTdxReportSpan(q.document)
      if version == AgentTdxVersion4:
        check span.at == AgentTdxHeaderLen
      else:
        check span.at == AgentTdxHeaderLen + AgentTdxBodyDescriptorLen

  test "the derived split agrees with the two splits a sibling pins":
    # The derivation above and the numbers `tdx_launch_vectors` records
    # are two independent statements about where a quote ends, and they
    # are made to agree here rather than one being trusted.
    for c in TdxLaunchCase:
      check declaredLengthOf(TdxLaunchVectors[c].quote) ==
        TdxLaunchVectors[c].documentBytes
    # And the buffers really are longer than the quotes in them, so the
    # split is doing work rather than being a no-op on every input.
    for c in TdxLaunchCase:
      check TdxLaunchVectors[c].quote.len > TdxLaunchVectors[c].documentBytes

  test "the vendor's SAMPLE quote is excluded, and here is why":
    # It is published beside the genuine ones and it is not one. Its
    # trust-domain report is all zeroes, which is exactly the shape that
    # would let a locator returning a constant pass — so it is named as
    # a control rather than quietly left out.
    check agentTdxBoundBytes(notGenuine) == repeat('\x00', ReportDataSize)
    for q in genuineQuotes:
      check boundBytesOf(q) != agentTdxBoundBytes(notGenuine)

  test "no two of them bind the same bytes":
    # A locator that returned a constant, or read a field every domain
    # leaves at its reset value, would pass a corpus that did not have
    # this property.
    var seen: seq[string] = @[]
    for q in genuineQuotes:
      let bound = boundBytesOf(q)
      check bound.len == ReportDataSize
      check bound notin seen
      seen.add bound

suite "the two readers of the bound bytes agree on every genuine quote":

  test "both readers return the same 64 bytes":
    for q in genuineQuotes:
      let byTheVerifier = parseTdxQuote(byteSeqOf(q.document))
      check hexOfBytes(byTheVerifier.body.reportData) ==
        hexOfBytes(byteSeqOf(boundBytesOf(q)))

  test "and the bound bytes are not the measurement beside them":
    # Two fields at different offsets. One agreeing field could agree
    # because both readers returned the same constant.
    for q in genuineQuotes:
      let byTheVerifier = parseTdxQuote(byteSeqOf(q.document))
      check hexOfBytes(byteSeqOf(boundBytesOf(q))) !=
        hexOfBytes(byTheVerifier.body.mrTd)

suite "the driver hands over what the quoting enclave produced":

  test "the evidence is the quote, byte for byte":
    for q in genuineQuotes:
      let b = newBench(q.document)
      let got = acquireQuote(b.driverOver(), boundBytesOf(q))
      check got.evidence == q.document
      check got.evidence == readFile(b.outblobPath)

  test "and it bundles NONE, because the chain is inside the quote":
    for q in genuineQuotes:
      let b = newBench(q.document)
      check acquireQuote(b.driverOver(), boundBytesOf(q)).certificates.isNone

  test "the driver names the evidence format and derives its tier":
    let b = newBench(genuineQuotes[0].document)
    let d = b.driverOver()
    check d.backend == abTdx
    check d.driverName == TdxDriverName
    check d.tier == tierOf(abTdx)

  test "a machine with no captured quote is not ready, and says which":
    let b = newBench(genuineQuotes[0].document)
    removeFile(b.outblobPath)
    let p = b.driverOver().driverProbe()
    check not p.ready
    check b.outblobPath in p.detail

proc driveEveryOtherGenuineDomainSOwnBoundBytesAreRefused() =
  ## The body of test
  ##   "every other genuine domain's own bound bytes are refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Twenty ordered pairs of two real domains' real bound bytes. Not
  # a string of zeroes: a negative built from zeroes proves only that
  # the comparison compares something.
  var pairs = 0
  for i, mine in genuineQuotes:
    let b = newBench(mine.document)
    for j, theirs in genuineQuotes:
      if i == j: continue
      inc pairs
      let e = refuses(proc () =
        discard acquireQuote(b.driverOver(), boundBytesOf(theirs)))
      check e.condition == tbcAnswersADifferentQuestion
      check TdxDriverName in e.msg
  check pairs == 20

proc driveAndSoIsASingleBitOfTheRightAnswer() =
  ## The body of test
  ##   "and so is a single bit of the right answer"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let q = genuineQuotes[0]
  let b = newBench(q.document)
  for at in [0, ReportDataSize - 1]:
    var asked = boundBytesOf(q)
    asked[at] = char(uint8(asked[at]) xor 0x01'u8)
    let e = refuses(proc () = discard acquireQuote(b.driverOver(), asked))
    check e.condition == tbcAnswersADifferentQuestion

suite "a quote that answers a different question is refused":

  test "every other genuine domain's own bound bytes are refused":
    driveEveryOtherGenuineDomainSOwnBoundBytesAreRefused()

  test "and so is a single bit of the right answer":
    driveAndSoIsASingleBitOfTheRightAnswer()

proc driveADocumentTooShortForAHeaderAndADescriptorIsRefused() =
  ## The body of test
  ##   "a document too short for a header and a descriptor is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () =
    discard agentTdxReportSpan(genuineQuotes[0].document[0 ..< 50]))
  check e.condition == tbcTooShortForADescriptor
  check "50" in e.msg

proc driveAQuoteVersionThisBuildHasNoLayoutForIsRefused() =
  ## The body of test
  ##   "a quote version this build has no layout for is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var doc = genuineQuotes[0].document
  doc[AgentTdxVersionOffset] = '\x03'
  let e = refuses(proc () = discard agentTdxReportSpan(doc))
  check e.condition == tbcUnsupportedQuoteVersion
  check "version 3" in e.msg

proc driveAnEnclaveReportWearingATrustDomainSClothesIsRefused() =
  ## The body of test
  ##   "an enclave report wearing a trust domain's clothes is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Type zero is an enclave. Reading a trust domain's offsets out of
  # one is exactly the confusion this rule exists to prevent.
  var doc = genuineQuotes[0].document
  for i in AgentTdxTeeTypeOffset ..< AgentTdxTeeTypeOffset + 4:
    doc[i] = '\x00'
  let e = refuses(proc () = discard agentTdxReportSpan(doc))
  check e.condition == tbcNotATrustDomain
  check "0x00000081" in e.msg

proc driveAVersion5ReportShapeThisBuildDoesNotReadIsRefused() =
  ## The body of test
  ##   "a version-5 report shape this build does not read is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var doc = ""
  for q in genuineQuotes:
    if parseTdxQuote(byteSeqOf(q.document)).version == AgentTdxVersion5:
      doc = q.document
      break
  check doc.len > 0
  doc[AgentTdxBodyTypeOffset] = '\x09'
  let e = refuses(proc () = discard agentTdxReportSpan(doc))
  check e.condition == tbcUnsupportedReportShape
  check "report shape 9" in e.msg

proc driveAVersion5ShapeAndWidthThatDisagreeAreRefused() =
  ## The body of test
  ##   "a version-5 shape and width that disagree are refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var doc = ""
  for q in genuineQuotes:
    if parseTdxQuote(byteSeqOf(q.document)).version == AgentTdxVersion5:
      doc = q.document
      break
  check doc.len > 0
  doc[AgentTdxBodySizeOffset] = char(uint8(doc[AgentTdxBodySizeOffset]) xor
                                     0x01'u8)
  let e = refuses(proc () = discard agentTdxReportSpan(doc))
  check e.condition == tbcShapeAndWidthDisagree

proc driveAReportThatRunsPastTheEndOfItsDocumentIsRefused() =
  ## The body of test
  ##   "a report that runs past the end of its document is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Truncated one byte inside the report, so the header and the
  # descriptor still read and only the span check can catch it.
  let q = genuineQuotes[0]
  let span = agentTdxReportSpan(q.document)
  let e = refuses(proc () =
    discard agentTdxReportSpan(q.document[0 ..< span.at + span.width - 1]))
  check e.condition == tbcReportRunsPastTheEnd

proc driveTheOtherRootOfTrustSProviderIsRefused() =
  ## The body of test
  ##   "the other root of trust's provider is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let q = genuineQuotes[0]
  let b = newBench(q.document, provider = SevSnpProviderName)
  let e = refuses(proc () =
    discard acquireQuote(b.driverOver(), boundBytesOf(q)))
  check e.condition == tbcWrongProvider
  check SevSnpProviderName in e.msg
  check TdxProviderName in e.msg

proc driveAuxiliaryMaterialOfferedBesideTheQuoteIsRefused() =
  ## The body of test
  ##   "auxiliary material offered beside the quote is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A trust-domain quote carries its own chain inside the signed
  # document. Material offered beside it is material nothing signed,
  # and bundling it would put a chain in the envelope that the quote
  # does not answer for.
  let q = genuineQuotes[0]
  let b = newBench(q.document, auxblob = "a chain nobody signed")
  let e = refuses(proc () =
    discard acquireQuote(b.driverOver(), boundBytesOf(q)))
  check e.condition == tbcAuxiliaryMaterialOffered
  check "21 bytes of auxiliary material" in e.msg

proc driveATransportRefusalReachesTheSeamAsThisDriverSRefusal() =
  ## The body of test
  ##   "a transport refusal reaches the seam as this driver's refusal"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let q = genuineQuotes[0]
  let b = newBench(q.document)
  writeFile(b.providerPath, "some_other_guest\n")
  let e = refuses(proc () =
    discard acquireQuote(b.driverOver(), boundBytesOf(q)))
  check e.condition == tbcTransportRefused
  check TdxDriverName in e.msg
  var caughtAsDriverError = false
  try:
    discard acquireQuote(b.driverOver(), boundBytesOf(q))
  except DriverError:
    caughtAsDriverError = true
  check caughtAsDriverError

proc driveADriverWithNoSourceIsRefused() =
  ## The body of test
  ##   "a driver with no source is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let e = refuses(proc () = discard newTdxDriver(nil))
  check e.condition == tbcNoSource

suite "a document this build cannot identify is not read at its offsets":

  test "a document too short for a header and a descriptor is refused":
    driveADocumentTooShortForAHeaderAndADescriptorIsRefused()

  test "a quote version this build has no layout for is refused":
    driveAQuoteVersionThisBuildHasNoLayoutForIsRefused()

  test "an enclave report wearing a trust domain's clothes is refused":
    driveAnEnclaveReportWearingATrustDomainSClothesIsRefused()

  test "a version-5 report shape this build does not read is refused":
    driveAVersion5ReportShapeThisBuildDoesNotReadIsRefused()

  test "a version-5 shape and width that disagree are refused":
    driveAVersion5ShapeAndWidthThatDisagreeAreRefused()

  test "a report that runs past the end of its document is refused":
    driveAReportThatRunsPastTheEndOfItsDocumentIsRefused()

  test "the other root of trust's provider is refused":
    driveTheOtherRootOfTrustSProviderIsRefused()

  test "auxiliary material offered beside the quote is refused":
    driveAuxiliaryMaterialOfferedBesideTheQuoteIsRefused()

  test "a transport refusal reaches the seam as this driver's refusal":
    driveATransportRefusalReachesTheSeamAsThisDriverSRefusal()

  test "a driver with no source is refused":
    driveADriverWithNoSourceIsRefused()

suite "provenance":

  test "every corpus this gate reads is the size and the bytes recorded":
    var seen = 0
    for c in TdxCorpus:
      let row = TdxCorpora[c]
      inc seen
      check row.name.len > 0
      check row.origin.len > 0
      check row.sha256.len == 64
      let buffer = corpusBuffer(c)
      check buffer.len == row.bytes
      check sha256Hex(buffer) == row.sha256
    check seen == ord(high(TdxCorpus)) + 1
    check seen == 6

  test "the genuine rows are exactly the corpus the cases drive":
    # A table constrained by nothing is a list. Five rows say genuine
    # and there are five genuine quotes; the sixth says it is not and is
    # the degeneracy control.
    var genuineRows = 0
    for c in TdxCorpus:
      if TdxCorpora[c].isGenuine: inc genuineRows
    check genuineRows == genuineQuotes.len
    check genuineRows == 5
    for q in genuineQuotes:
      var pinned = false
      for c in TdxCorpus:
        let buffer = corpusBuffer(c)
        if TdxCorpora[c].isGenuine and buffer.len >= q.document.len and
           buffer[0 ..< q.document.len] == q.document:
          pinned = true
      check pinned
    check corpusBuffer(tcVendorSample) == notGenuine

# Every case whose outcomes the coverage case(s) below observe. The
# suite runner executes each case in its own process (`--run
# suite::test`), so the coverage case drives these itself rather than
# reading what earlier cases left in process-global state.
const ConditionDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("every other genuine domain's own bound bytes are refused",
    driveEveryOtherGenuineDomainSOwnBoundBytesAreRefused),
  ("and so is a single bit of the right answer",
    driveAndSoIsASingleBitOfTheRightAnswer),
  ("a document too short for a header and a descriptor is refused",
    driveADocumentTooShortForAHeaderAndADescriptorIsRefused),
  ("a quote version this build has no layout for is refused",
    driveAQuoteVersionThisBuildHasNoLayoutForIsRefused),
  ("an enclave report wearing a trust domain's clothes is refused",
    driveAnEnclaveReportWearingATrustDomainSClothesIsRefused),
  ("a version-5 report shape this build does not read is refused",
    driveAVersion5ReportShapeThisBuildDoesNotReadIsRefused),
  ("a version-5 shape and width that disagree are refused",
    driveAVersion5ShapeAndWidthThatDisagreeAreRefused),
  ("a report that runs past the end of its document is refused",
    driveAReportThatRunsPastTheEndOfItsDocumentIsRefused),
  ("the other root of trust's provider is refused",
    driveTheOtherRootOfTrustSProviderIsRefused),
  ("auxiliary material offered beside the quote is refused",
    driveAuxiliaryMaterialOfferedBesideTheQuoteIsRefused),
  ("a transport refusal reaches the seam as this driver's refusal",
    driveATransportRefusalReachesTheSeamAsThisDriverSRefusal),
  ("a driver with no source is refused", driveADriverWithNoSourceIsRefused)]

suite "the census":

  test "every rule has a site, and every site has exactly one rule":
    let found = raisedConditionsIn(BackendSource)
    check found.len == 11
    check ord(high(TdxBackendCondition)) + 1 == 11
    for c in TdxBackendCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      check seen == 1
    for n in found:
      var known = false
      for c in TdxBackendCondition:
        if n == $c: known = true
      check known

  test "every rule was reached, and the count is an EQUALITY":
    # Driven HERE, from reset state: the runner executes every case in
    # its own process, so this case observes only what it runs itself.
    reached = {}
    for (name, drive) in ConditionDrivers:
      checkpoint("driving " & name)
      drive()
    var missing: seq[string] = @[]
    for c in TdxBackendCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    check cardOf(reached) == 11
    check cardOf(reached) == ord(high(TdxBackendCondition)) + 1
