## The security-processor agent backend: the document it hands over, the
## bytes it insists that document answers for, and every rule it refuses
## on.
##
## ## The claim that matters, and how it is established
##
## **A driver must not hand on a report that binds somebody else's 64
## bytes.** Such a report is genuine, correctly signed, and chains to the
## vendor; it simply answers a question nobody here asked. A verifier
## cannot catch it, because the only thing a verifier can compare the
## report's bound bytes against is the ENVELOPE — and the envelope is
## written by the same agent that was handed the stale report. The
## machine is the only place the substitution is visible.
##
## The negative below is therefore not a string of zeroes. It is the
## OTHER genuine part's own bound bytes, out of the other genuine
## report: two real machines, two real 64-byte values, and the driver
## asked for one while its source offers the other. A negative built
## from zeroes would prove only that the comparison compares something.
##
## ## The two readers of one field, held together by measurement
##
## The agent does not link the verifier, so the offset at which the
## bound bytes sit is transcribed twice in this repository — once in
## `repro_attest/snp_backend`, which the agent uses, and once in
## `repro_attest_verify/snp_report`, which the verifier uses. Neither
## may reach for the other's constant: a check that compares a value
## against the constant that produced it passes however that constant is
## changed, which is a defeat shape this tree has been caught by.
##
## So the two are held together by reading every genuine report in the
## corpus with BOTH and requiring the answers equal. Its limit is stated
## rather than implied: this catches a transcription error and it does
## not catch two readers that are wrong the same way. What makes it
## worth something anyway is that the corpus is not degenerate on this
## field — the two reports carry DIFFERENT, non-zero bound bytes, and a
## locator pointing anywhere else in the document returns a value that
## is neither.
##
## ## The certificate table is minted here, and the certificates in it
## are not
##
## No genuine auxiliary blob is pinned in this repository, so the GUID
## table framing below is built by this gate from the vendor's published
## layout. **Every certificate inside it is genuine** — the endorsement
## certificates of two real parts, and the vendor's own signing key and
## root as its key-distribution service serves them. So what is minted
## is the twenty-four-byte-per-entry index, and what is read out of it
## is bytes a real vendor signed. That division is the honest one to
## state, and it is why the assertions are byte-identity with the
## genuine inputs rather than "it parsed".
##
## ## Mocking
##
## None. `CapturedTsmSource` reads real files; the reports in them were
## produced by real AMD parts, and the driver's checks run against those
## bytes exactly as they would against a device's.

import std/[options, os, strutils, unittest]

import nimcrypto/[hash, sha2]

import repro_attest
import repro_attest_verify/snp_report

include ./snp_vectors

# ---------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------

var reached: set[SnpBackendCondition] = {}

proc refuses(body: proc (): void): ref SnpBackendError =
  try:
    body()
  except SnpBackendError as err:
    reached.incl err.condition
    return err
  raise newException(ValueError, "nothing was refused")

proc cardOf(s: set[SnpBackendCondition]): int =
  for c in SnpBackendCondition:
    if c in s: inc result

const
  BackendSource = staticRead(
    "../../libs/repro_attest/src/repro_attest/snp_backend.nim")

proc raisedConditionsIn(source: string): seq[string] =
  ## Every ``snpFail(sbc…`` in a source, in order. The declaration of
  ## `snpFail` itself does not match, because it reads
  ## ``snpFail*(condition:``.
  result = @[]
  var i = 0
  const Needle = "snpFail(sbc"
  while i < source.len:
    let at = source.find(Needle, i)
    if at < 0: break
    var j = at + len("snpFail(")
    var name = ""
    while j < source.len and (source[j].isAlphaAscii or source[j].isDigit):
      name.add source[j]
      inc j
    result.add name
    i = j

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

proc stringOfHex(h: string): string =
  for b in bytesOfHex(h): result.add char(b)

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

proc pemCertificates(text: string): seq[string] =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    var der = ""
    for x in base64Decode(text[b + Begin.len ..< e]): der.add char(x)
    result.add der
    pos = e + End.len

proc pemBlockAt(text: string; index: int): string =
  ## One armoured block, verbatim, armour included. Used to build a
  ## table entry in the shape a host that fetched the vendor's chain
  ## over HTTP would store it.
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  var n = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    if n == index: return text[b ..< e + End.len]
    inc n
    pos = e + End.len
  raise newException(ValueError, "no such armoured block")

proc le32(v: int): string =
  result.add char(v and 0xff)
  result.add char((v shr 8) and 0xff)
  result.add char((v shr 16) and 0xff)
  result.add char((v shr 24) and 0xff)

proc certTable(entries: seq[(string, string)];
               terminate = true; skew = 0): string =
  ## Build a table in the vendor's published layout: an index of
  ## twenty-four-byte entries, zero-terminated, followed by the
  ## payloads. ``skew`` pushes every declared offset past the end, which
  ## is how the bounds rule gets an input.
  let indexLen = (entries.len + (if terminate: 1 else: 0)) *
                 SnpCertTableEntryLen
  var index = ""
  var payloads = ""
  var at = indexLen
  for (guid, payload) in entries:
    index.add guidBytes(guid)
    index.add le32(at + skew)
    index.add le32(payload.len)
    payloads.add payload
    at += payload.len
  if terminate: index.add repeat('\x00', SnpCertTableEntryLen)
  result = index & payloads

let milanChain = pemCertificates(KdsMilanChainPem)

type Genuine = object
  name: string
  reportHex: string
  vcekDerHex: string

let genuineParts = @[
  Genuine(name: "virtee/sev's Milan part", reportHex: VirteeMilanReportHex,
          vcekDerHex: VirteeMilanVcekDerHex),
  Genuine(name: "go-sev-guest's Milan part", reportHex: GsgMilanReportHex,
          vcekDerHex: GsgMilanVcekDerHex)]

proc boundBytesOf(g: Genuine): string =
  agentSnpBoundBytes(stringOfHex(g.reportHex))

proc genuineTable(g: Genuine): string =
  ## The endorsement certificate raw, and the vendor's signing key and
  ## root armoured — the mixture a host really does end up with, because
  ## the endorsement certificate arrives as DER and the chain arrives as
  ## armoured text.
  certTable(@[(SnpVcekGuid, stringOfHex(g.vcekDerHex)),
              (SnpAskGuid, pemBlockAt(KdsMilanChainPem, 0)),
              (SnpArkGuid, pemBlockAt(KdsMilanChainPem, 1))])


# ---------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------

proc digestHex(s: string): string =
  ($sha256.digest(cast[seq[byte]](s))).toLowerAscii

type
  SnpCorpus* = enum
    ## Every byte corpus this gate reads, enumerated rather than listed.
    ##
    ## A corpus cannot exist without a row and a row cannot exist
    ## without a corpus: the accessor below is a `case` Nim refuses to
    ## leave incomplete, and the check walks the enumeration. **This
    ## change adds no new byte corpus to this repository** — every
    ## row here is already pinned by a sibling, and what this table adds
    ## is that THIS gate's reading of it is pinned too, so a corpus that
    ## changed under this gate is a failure here rather than a silently
    ## different measurement.
    scVirteeReport
    scGsgReport
    scVirteeVcek
    scGsgVcek
    scKdsMilanChain

  SnpCorpusRow* = object
    name*: string
    bytes*: int
    sha256*: string
    origin*: string

const
  SnpCorpora*: array[SnpCorpus, SnpCorpusRow] = [
    scVirteeReport: SnpCorpusRow(name: "VirteeMilanReportHex", bytes: 1184,
      sha256: "120d77b213c8868dd42f160ccb0114f05336ec715f6d51070f534b33c7e03f3b",
      origin: "virtee/sev tests/certs_data/report_milan.hex"),
    scGsgReport: SnpCorpusRow(name: "GsgMilanReportHex", bytes: 1184,
      sha256: "377e6241d3b373ab1df80c0f96978594e7e21f4797dd6ea95e2957e1c1e26060",
      origin: "google/go-sev-guest verify/testdata/attestation.bin"),
    scVirteeVcek: SnpCorpusRow(name: "VirteeMilanVcekDerHex", bytes: 1360,
      sha256: "3bbfb6ee259f75a95d13168cfdf2e034181bb93c7c016825731cbe8ea16c95e1",
      origin: "virtee/sev tests/certs_data/vcek_milan.der"),
    scGsgVcek: SnpCorpusRow(name: "GsgMilanVcekDerHex", bytes: 1360,
      sha256: "0d057f9b6e29a69eda9c0154b259567d291c1c08d73a11e9d31ace07c435b6d8",
      origin: "google/go-sev-guest verify/testdata/vcek.testcer"),
    scKdsMilanChain: SnpCorpusRow(name: "KdsMilanChainPem", bytes: 4602,
      sha256: "22e62f8d2c21a156470145fc75f7b5a377cb053ced3e97f0bd3f8d8ca5941ce6",
      origin: "the vendor key-distribution service, Milan cert_chain")]

proc corpusBytes(c: SnpCorpus): string =
  ## A `case` rather than a table lookup, so a corpus added to the
  ## enumeration without bytes does not compile.
  case c
  of scVirteeReport: stringOfHex(VirteeMilanReportHex)
  of scGsgReport: stringOfHex(GsgMilanReportHex)
  of scVirteeVcek: stringOfHex(VirteeMilanVcekDerHex)
  of scGsgVcek: stringOfHex(GsgMilanVcekDerHex)
  of scKdsMilanChain: KdsMilanChainPem

# ---------------------------------------------------------------------
# A bench of real files
# ---------------------------------------------------------------------

type Bench = object
  dir: string
  outblobPath, providerPath, auxblobPath: string

var benchSequence = 0

proc newBench(outblob: string; provider = SevSnpProviderName;
              auxblob = ""): Bench =
  inc benchSequence
  result.dir = getTempDir() / ("repro-snp-backend-" &
                               $getCurrentProcessId() & "-" & $benchSequence)
  createDir(result.dir)
  result.outblobPath = result.dir / TsmOutblobAttr
  result.providerPath = result.dir / TsmProviderAttr
  result.auxblobPath = result.dir / TsmAuxblobAttr
  writeFile(result.outblobPath, outblob)
  writeFile(result.providerPath, provider & "\n")
  if auxblob.len > 0: writeFile(result.auxblobPath, auxblob)

proc driverOver(b: Bench; level = DefaultSnpPrivilegeLevel): SnpDriver =
  newSnpDriver(newCapturedTsmSource(b.outblobPath, b.providerPath,
                                    b.auxblobPath), level)

# ---------------------------------------------------------------------

suite "the two readers of the bound bytes agree on genuine reports":

  test "both readers return the same 64 bytes for every genuine report":
    for g in genuineParts:
      let raw = bytesOfHex(g.reportHex)
      let byTheVerifier = parseSnpReport(raw)
      let byTheAgent = agentSnpBoundBytes(stringOfHex(g.reportHex))
      check byTheAgent.len == LenReportData
      check hexOfBytes(byTheVerifier.reportData) == hexOfBytes(
        cast[seq[byte]](byTheAgent))

  test "and on the privilege level, which is a second field":
    # One agreeing field could agree because both readers return the
    # same constant. Two fields at different offsets cannot.
    for g in genuineParts:
      let byTheVerifier = parseSnpReport(bytesOfHex(g.reportHex))
      check agentSnpPrivilegeLevel(stringOfHex(g.reportHex)) ==
        byTheVerifier.vmpl

  test "the corpus is not degenerate on the field being read":
    # Two genuine reports whose bound bytes DIFFER, neither of them
    # zero, and neither equal to the measurement that sits sixty-four
    # bytes further on. A corpus that failed any of these would let a
    # locator pointing at the wrong field pass.
    let a = boundBytesOf(genuineParts[0])
    let b = boundBytesOf(genuineParts[1])
    check a != b
    check a != repeat('\x00', LenReportData)
    check b != repeat('\x00', LenReportData)
    for g in genuineParts:
      let parsed = parseSnpReport(bytesOfHex(g.reportHex))
      check hexOfBytes(cast[seq[byte]](boundBytesOf(g))) !=
        hexOfBytes(parsed.measurement)

suite "the driver hands over what the part produced":

  test "the evidence is the document, byte for byte":
    for g in genuineParts:
      let b = newBench(stringOfHex(g.reportHex))
      let got = acquireQuote(b.driverOver(), boundBytesOf(g))
      check got.evidence == stringOfHex(g.reportHex)
      check got.evidence.len == AgentSnpReportLen
      # Nothing was re-serialised: a verifier checks a signature against
      # the document, never against a decoder's re-encoding of it.
      check got.evidence == readFile(b.outblobPath)

  test "the driver names the evidence format and derives its tier":
    let b = newBench(stringOfHex(genuineParts[0].reportHex))
    let d = b.driverOver()
    check d.backend == abSevSnp
    check d.driverName == SnpDriverName
    check d.tier == tierOf(abSevSnp)
    check d.configuredPrivilegeLevel == DefaultSnpPrivilegeLevel

  test "a machine with no captured document is not ready, and says which":
    let b = newBench(stringOfHex(genuineParts[0].reportHex))
    removeFile(b.outblobPath)
    let p = b.driverOver().driverProbe()
    check not p.ready
    check b.outblobPath in p.detail

suite "a document that answers a different question is refused":

  test "the other genuine part's own bound bytes are refused":
    # Both values are real, both are non-zero, and they belong to two
    # different machines.
    let b = newBench(stringOfHex(genuineParts[0].reportHex))
    let e = refuses(proc () =
      discard acquireQuote(b.driverOver(), boundBytesOf(genuineParts[1])))
    check e.condition == sbcAnswersADifferentQuestion
    check "answers a different question" in e.msg
    check SnpDriverName in e.msg

  test "and so is a single bit of the right answer":
    # The bound from the other side. One bit, at the first byte and at
    # the last, so the comparison is over the whole field rather than
    # over a prefix of it.
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex))
    for at in [0, LenReportData - 1]:
      var asked = boundBytesOf(g)
      asked[at] = char(uint8(asked[at]) xor 0x01'u8)
      let e = refuses(proc () = discard acquireQuote(b.driverOver(), asked))
      check e.condition == sbcAnswersADifferentQuestion

  test "the request that IS the document's own answer is accepted":
    let g = genuineParts[1]
    let b = newBench(stringOfHex(g.reportHex))
    check acquireQuote(b.driverOver(), boundBytesOf(g)).evidence.len ==
      AgentSnpReportLen

suite "a document this build cannot identify is not read at its offsets":

  test "a document of the wrong width is refused":
    let g = genuineParts[0]
    for doc in [stringOfHex(g.reportHex)[0 ..< AgentSnpReportLen - 1],
                stringOfHex(g.reportHex) & "\x00"]:
      let b = newBench(doc)
      let e = refuses(proc () =
        discard acquireQuote(b.driverOver(), boundBytesOf(g)))
      check e.condition == sbcWrongDocumentWidth
      check $AgentSnpReportLen in e.msg

  test "a structure revision this build has no layout for is refused":
    let g = genuineParts[0]
    var doc = stringOfHex(g.reportHex)
    doc[AgentSnpVersionOffset] = '\x09'
    let b = newBench(doc)
    let e = refuses(proc () =
      discard acquireQuote(b.driverOver(), boundBytesOf(g)))
    check e.condition == sbcUnsupportedRevision
    check "revision 9" in e.msg

  test "both revisions this build DOES have a layout for are read":
    # The other side of that bound. Revision 3 differs from 2 only in
    # three bytes well past the field being read, so the same document
    # under either revision must yield the same bound bytes.
    let g = genuineParts[0]
    for revision in AgentSnpVersions:
      var doc = stringOfHex(g.reportHex)
      doc[AgentSnpVersionOffset] = char(revision)
      check agentSnpBoundBytes(doc) == boundBytesOf(g)

  test "the other root of trust's provider is refused":
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex), provider = TdxProviderName)
    let e = refuses(proc () =
      discard acquireQuote(b.driverOver(), boundBytesOf(g)))
    check e.condition == sbcWrongProvider
    check TdxProviderName in e.msg
    check SevSnpProviderName in e.msg

  test "a document from a privilege level nobody chose is refused":
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex))
    let e = refuses(proc () =
      discard acquireQuote(b.driverOver(level = 1), boundBytesOf(g)))
    check e.condition == sbcWrongPrivilegeLevel
    check "configured for level 1" in e.msg

  test "a transport refusal reaches the seam as this driver's refusal":
    # The transport has its own vocabulary and it is not re-spelled
    # here; what is asserted is that a caller catching the seam's error
    # catches it, and that the message names the driver.
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex))
    writeFile(b.providerPath, "some_other_guest\n")
    let e = refuses(proc () =
      discard acquireQuote(b.driverOver(), boundBytesOf(g)))
    check e.condition == sbcTransportRefused
    check SnpDriverName in e.msg
    # And it is a `DriverError`, which is what the agent catches.
    var caughtAsDriverError = false
    try:
      discard acquireQuote(b.driverOver(), boundBytesOf(g))
    except DriverError:
      caughtAsDriverError = true
    check caughtAsDriverError

suite "the driver refuses to be built wrong":

  test "a driver with no source is refused":
    let e = refuses(proc () = discard newSnpDriver(nil))
    check e.condition == sbcNoSource

  test "a privilege level outside the range is refused":
    for level in [-1, 4, 255]:
      let e = refuses(proc () =
        discard newSnpDriver(newCapturedTsmSource("/dev/null", "/dev/null"),
                             level))
      check e.condition == sbcPrivilegeLevelOutOfRange
      check $level in e.msg

  test "every level in the range is accepted":
    for level in 0 .. 3:
      let d = newSnpDriver(newCapturedTsmSource("/dev/null", "/dev/null"),
                           level)
      check d.configuredPrivilegeLevel == level

suite "the host's certificate table becomes the envelope's chain":

  test "the three genuine certificates come back byte for byte":
    for g in genuineParts:
      let table = parseSnpCertificateTable(genuineTable(g))
      check table.certificates[scsEndorsement] == stringOfHex(g.vcekDerHex)
      check table.certificates[scsSigningKey] == milanChain[0]
      check table.certificates[scsRoot] == milanChain[1]
      check table.ignoredGuids.len == 0

  test "an armoured entry is un-armoured and a raw one is passed through":
    # The two shapes are in the wild together, and the envelope carries
    # one of them. The assertion is byte-identity with the DER the
    # vendor's own armour decodes to, not merely "it is a sequence".
    let g = genuineParts[0]
    let table = parseSnpCertificateTable(genuineTable(g))
    for slot in SnpCertificateSlot:
      check table.certificates[slot].len > 0
      check uint8(table.certificates[slot][0]) == DerSequenceTag
    check table.certificates[scsSigningKey] !=
      pemBlockAt(KdsMilanChainPem, 0)

  test "the driver bundles them in the order a verifier reads them":
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex), auxblob = genuineTable(g))
    let got = acquireQuote(b.driverOver(), boundBytesOf(g))
    check got.certificates.isSome
    let chain = got.certificates.get
    check chain.len == ord(high(SnpCertificateSlot)) + 1
    check chain[0] == stringOfHex(g.vcekDerHex)
    check chain[1] == milanChain[0]
    check chain[2] == milanChain[1]

  test "a machine with no table bundles NONE, not a chain of nothing":
    # `none` and an empty list are different answers; the envelope
    # refuses the second, so "fetch your own collateral" cannot be read
    # as "here is a chain".
    let g = genuineParts[0]
    let b = newBench(stringOfHex(g.reportHex))
    check acquireQuote(b.driverOver(), boundBytesOf(g)).certificates.isNone

  test "an entry this build has no use for is NAMED, not dropped":
    const CrlGuid = "92f81bc3-5811-4d3d-97ff-d19f88dc67ea"
    let g = genuineParts[0]
    let blob = certTable(@[
      (SnpVcekGuid, stringOfHex(g.vcekDerHex)),
      (CrlGuid, "a revocation list this build does not consume"),
      (SnpAskGuid, milanChain[0]),
      (SnpArkGuid, milanChain[1])])
    let table = parseSnpCertificateTable(blob)
    check table.ignoredGuids == @[CrlGuid]
    check table.certificates[scsEndorsement] == stringOfHex(g.vcekDerHex)

  test "the endorsement slot takes the other endorsement key too":
    # A part may be endorsed by the vendor's per-part key or by its
    # per-tenant one, and the slot is the same slot.
    let g = genuineParts[0]
    let blob = certTable(@[(SnpVlekGuid, stringOfHex(g.vcekDerHex)),
                           (SnpAskGuid, milanChain[0]),
                           (SnpArkGuid, milanChain[1])])
    check parseSnpCertificateTable(blob).certificates[scsEndorsement] ==
      stringOfHex(g.vcekDerHex)

suite "every way a certificate table can be wrong":

  test "a blob too short to hold one entry is refused":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(repeat('\x00',
        SnpCertTableEntryLen - 1)))
    check e.condition == sbcTableTooShort

  test "an entry whose payload runs past the end is refused":
    # Reading it would read whatever follows the blob in memory, which
    # is the one thing a reader of somebody else's format must not do.
    let g = genuineParts[0]
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, stringOfHex(g.vcekDerHex)),
          (SnpAskGuid, milanChain[0]),
          (SnpArkGuid, milanChain[1])], skew = 1_000_000)))
    check e.condition == sbcTableEntryRunsPastTheEnd
    check "at offset 1000096" in e.msg

  test "a table that never terminates is refused":
    # The index has to fill the blob EXACTLY for this rule to be the
    # one that fires: an index followed by payload bytes is an index
    # whose next entry is garbage, and garbage is refused by the bounds
    # rule one line earlier. So the fixture is a single well-formed
    # entry, of a kind this build ignores, with no terminator after it.
    const UnknownGuid = "11111111-2222-3333-4444-555555555555"
    let blob = certTable(@[(UnknownGuid, "")], terminate = false)
    check blob.len == SnpCertTableEntryLen
    let e = refuses(proc () = discard parseSnpCertificateTable(blob))
    check e.condition == sbcTableNotTerminated

  test "a table offering two endorsement keys is refused":
    let g = genuineParts[0]
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, stringOfHex(g.vcekDerHex)),
          (SnpVlekGuid, stringOfHex(genuineParts[1].vcekDerHex)),
          (SnpAskGuid, milanChain[0]),
          (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcTwoEndorsementCertificates

  test "a table missing any one of the three is refused, and names it":
    let g = genuineParts[0]
    let all = @[(SnpVcekGuid, stringOfHex(g.vcekDerHex)),
                (SnpAskGuid, milanChain[0]),
                (SnpArkGuid, milanChain[1])]
    for drop in 0 .. 2:
      var kept: seq[(string, string)] = @[]
      for i, entry in all:
        if i != drop: kept.add entry
      let e = refuses(proc () =
        discard parseSnpCertificateTable(certTable(kept)))
      check e.condition == sbcTableIncomplete
      check "carries no" in e.msg

  test "an empty entry is refused":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, ""), (SnpAskGuid, milanChain[0]),
          (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcTableEntryEmpty

  test "an entry that is neither a sequence nor armour is refused":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, "not a certificate at all"),
          (SnpAskGuid, milanChain[0]), (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcTableEntryNotACertificate

  test "armour that never closes is refused":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, "-----BEGIN CERTIFICATE-----\nMIIB"),
          (SnpAskGuid, milanChain[0]), (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcArmourNotClosed

  test "armour whose body is not base64 is refused":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, "-----BEGIN CERTIFICATE-----\n!!!!\n" &
                        "-----END CERTIFICATE-----"),
          (SnpAskGuid, milanChain[0]), (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcArmourDoesNotDecode

  test "armour that decodes to something that is not a certificate":
    let e = refuses(proc () =
      discard parseSnpCertificateTable(certTable(
        @[(SnpVcekGuid, "-----BEGIN CERTIFICATE-----\nAAAA\n" &
                        "-----END CERTIFICATE-----"),
          (SnpAskGuid, milanChain[0]), (SnpArkGuid, milanChain[1])])))
    check e.condition == sbcArmourDecodesToSomethingElse

  test "a table key that is not sixteen bytes of hex is refused":
    let e = refuses(proc () = discard guidBytes("not-a-guid"))
    check e.condition == sbcMalformedTableKey

  test "the four keys this build knows are the vendor's own spellings":
    # Each is thirty-two hex digits with four separators, and each
    # converts to sixteen bytes. A key that had drifted would not be
    # caught by the table cases above, because those build their tables
    # with the same constant they then look up.
    for key in [SnpVcekGuid, SnpVlekGuid, SnpAskGuid, SnpArkGuid]:
      check key.len == 36
      check guidBytes(key).len == 16
    check SnpVcekGuid == "63da758d-e664-4564-adc5-f4b93be8accd"
    check SnpVlekGuid == "a8074bc2-a25a-483e-aae6-39c045a0b8a1"
    check SnpAskGuid == "4ab7b379-bbac-4fe4-a02f-05aef327c782"
    check SnpArkGuid == "c0b406a4-a803-4952-9743-3fb6014cd0ae"

  test "and the sixteen wire bytes are pinned, not merely the text":
    # Without this the byte order would be a CONSTANT USED ON BOTH
    # SIDES: every table above is built with `guidBytes` and then read
    # back with `guidBytes`, so re-ordering the conversion — the
    # mixed-endian form some tooling uses for the same text — would
    # leave every case green while putting sixteen wrong bytes on the
    # wire. The vendor's own tooling parses these with `uuid_parse`,
    # which emits the digits in the order they are written.
    var wire = ""
    for c in guidBytes(SnpVcekGuid): wire.add toHex(int(uint8(c)), 2)
    check wire.toLowerAscii == "63da758de6644564adc5f4b93be8accd"
    var arkWire = ""
    for c in guidBytes(SnpArkGuid): arkWire.add toHex(int(uint8(c)), 2)
    check arkWire.toLowerAscii ==
      "c0b406a4a8034952" & "97433fb6014cd0ae"


suite "provenance":

  test "every corpus this gate reads is the size and the bytes recorded":
    var seen = 0
    for c in SnpCorpus:
      let row = SnpCorpora[c]
      inc seen
      check row.name.len > 0
      check row.origin.len > 0
      # A digest field of the wrong width could hide as an empty string
      # and pass a comparison nobody made.
      check row.sha256.len == 64
      let bytes = corpusBytes(c)
      check bytes.len == row.bytes
      check digestHex(bytes) == row.sha256
    check seen == ord(high(SnpCorpus)) + 1
    check seen == 5

  test "and the corpora this gate USES are the corpora it pins":
    # The other direction: a table constrained by nothing is a list. The
    # two reports and two endorsement certificates the cases above drive
    # are reached THROUGH this table's accessor, so a row that drifted
    # would move the measurements as well as the digest.
    for g in genuineParts:
      var pinned = false
      for c in SnpCorpus:
        if corpusBytes(c) == stringOfHex(g.reportHex): pinned = true
      check pinned
    var chainPinned = false
    for c in SnpCorpus:
      if corpusBytes(c) == KdsMilanChainPem: chainPinned = true
    check chainPinned

  test "every corpus row names where its bytes came from":
    # The provenance obligation this gate can actually discharge: each
    # row carries an origin, so a corpus cannot be added without saying
    # whose it is. It does NOT establish that no corpus was added — a
    # new row with an origin passes — and the title no longer says it
    # does. That stronger claim is a property of a diff, and the place
    # to check it is the diff.
    for c in SnpCorpus:
      check SnpCorpora[c].origin.len > 0

suite "the census":

  test "every rule has a site, and every site has exactly one rule":
    let found = raisedConditionsIn(BackendSource)
    check found.len == 19
    check ord(high(SnpBackendCondition)) + 1 == 19
    for c in SnpBackendCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      check seen == 1
    for n in found:
      var known = false
      for c in SnpBackendCondition:
        if n == $c: known = true
      check known

  test "every rule was reached, and the count is an EQUALITY":
    # Not `>=`. Under an inequality a rule reached twice pays for a rule
    # reached never, and the census cannot notice the one thing it
    # exists to notice.
    var missing: seq[string] = @[]
    for c in SnpBackendCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    check cardOf(reached) == 19
    check cardOf(reached) == ord(high(SnpBackendCondition)) + 1
