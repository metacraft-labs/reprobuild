## The security-processor backend: the document a confidential guest's
## firmware signs, and the driver that hands it over.
##
## ## What the agent's half of this is, and what it is not
##
## The document is produced whole by hardware the agent cannot inspect
## and signed by a key the agent does not hold. There is nothing here to
## assemble and nothing to compose: the evidence field IS the bytes the
## security processor produced, lifted verbatim. A driver that
## re-serialised them would be handing a verifier its own encoding of a
## document instead of the document.
##
## So the interesting half of this driver is entirely refusals, and
## there is one that matters more than the rest.
##
## ## The question and the answer
##
## **A report that binds someone else's 64 bytes is not an answer to
## this request**, and it is a report that VERIFIES. It has a real
## signature from a real part; its chain reaches the vendor; every field
## in it is true. It simply answers a question nobody here asked, and a
## verifier receiving it cannot tell — the verifier's own binding check
## compares the report's bound bytes against the ENVELOPE's, and the
## envelope is written by the same agent that was handed the stale
## report.
##
## The driver therefore reads the bound bytes out of the document it
## just obtained and compares them against the bytes it was handed. That
## is the same check `Tpm2Driver` makes against `qualifyingData`, for
## the same reason, and it is the one place on the machine where a stale
## or foreign report can be caught at all.
##
## ## The field is located here and read again by the verifier, and that
## is deliberate
##
## The agent does not link the verifier — see the driver seam's header
## for why — so the offsets below are this module's own and not a
## reference to the ones the verifier's reader uses. Two independent
## transcriptions of one published layout would ordinarily be a second
## opinion about which byte decides, which this tree refuses; a SHARED
## constant would be worse, because a check that compares a value
## against the constant that produced it passes however that constant is
## changed. The agreement is therefore established the third way: a gate
## reads the bound bytes out of every genuine report in the corpus with
## BOTH readers and requires the answers equal. That is a measurement
## over real documents rather than a promise, and its limit is stated
## plainly — it catches a transcription error, and it does not catch two
## readers that are wrong the same way.
##
## ## The auxiliary blob is the host's, and it is still worth carrying
##
## `auxblob` holds a certificate table the HOST loaded. Nothing in it is
## signed by the part, and a host that put rubbish there is a host whose
## guest cannot attest — which is the correct outcome and not a loss,
## because the certificates only matter to the extent that the vendor's
## signatures over them verify, and that is checked on the verifier's
## network against a root the verifier holds.
##
## What the table gives the verifier is the ability to check the
## report's signature AT ALL: the report carries no key, so a verifier
## with no chain has nothing to check it against. That is why this
## driver parses the table rather than passing it through — the envelope
## carries a list of DER certificates, and a GUID-indexed blob is not
## one.
##
## ## Mocking
##
## None. `CapturedTsmSource` reads documents a real part produced from
## files; every check below runs against those bytes, and a source
## returning a stale or foreign report is refused exactly as a
## misbehaving device would be.

import std/[base64, options, strutils]

import ./binding
import ./driver
import ./report
import ./tsm_report

const
  SnpDriverName* = "sev-snp"

  AgentSnpReportLen* = 0x4A0
    ## 1,184 bytes. The report is a fixed-width document; a different
    ## width is a different document and is refused rather than read at
    ## the offsets below.

  AgentSnpVersionOffset* = 0x000
  AgentSnpVmplOffset* = 0x030
  AgentSnpReportDataOffset* = 0x050
    ## Where the 64 bound bytes sit. This module's own transcription of
    ## the published layout; see the module header for how it is held to
    ## the verifier's.

  AgentSnpVersions* = [2'u32, 3'u32]
    ## The structure revisions this build hands on. A revision it has no
    ## layout for is refused here rather than read at these offsets,
    ## because reading a document whose shape you guessed is how a field
    ## comes to be lifted out of the middle of a different one.

  DefaultSnpPrivilegeLevel* = 0
    ## The privilege level a guest's own agent runs a report at when it
    ## is not told otherwise. Level 0 is the most privileged, and it is
    ## the one a guest with no paravisor occupies.

type
  SnpBackendCondition* = enum
    ## One condition per rule, and exactly ONE RAISE SITE per condition.
    ##
    ## The correspondence is what makes the gate's census a census over
    ## SITES rather than over kinds, and it is proved by scanning this
    ## source rather than assumed: a condition raised at two sites lets
    ## a site reached twice pay for a site reached never, which is the
    ## defect that has been found in this tree's censuses before.
    sbcNoSource
    sbcPrivilegeLevelOutOfRange
    sbcMalformedTableKey
    sbcTableEntryEmpty
    sbcTableEntryNotACertificate
    sbcArmourNotClosed
    sbcArmourDoesNotDecode
    sbcArmourDecodesToSomethingElse
    sbcTableTooShort
    sbcTableEntryRunsPastTheEnd
    sbcTwoEndorsementCertificates
    sbcTableNotTerminated
    sbcTableIncomplete
    sbcWrongDocumentWidth
    sbcUnsupportedRevision
    sbcWrongProvider
    sbcAnswersADifferentQuestion
    sbcWrongPrivilegeLevel
    sbcTransportRefused

  SnpBackendError* = object of DriverError
    ## Every refusal this module makes.
    ##
    ## It descends from `DriverError` rather than sitting beside it, and
    ## that is the seam's contract rather than a convenience: whoever
    ## reads the message is looking at a machine that would not attest,
    ## and an exception of this module's own type escaping past a caller
    ## catching `DriverError` would be the difference between a machine
    ## that refuses and a machine that crashes. Descending also keeps
    ## the condition attached all the way out, so a caller that wants to
    ## know WHICH rule refused does not have to match on prose.
    condition*: SnpBackendCondition

  SnpCertificateSlot* = enum
    ## The three certificates the envelope carries, in the order a
    ## verifier reads them: the key that endorsed this part, the
    ## vendor's signing key, and the vendor's root.
    scsEndorsement
    scsSigningKey
    scsRoot

  SnpCertificateTable* = object
    ## What one auxiliary blob decoded to.
    certificates*: array[SnpCertificateSlot, string]
      ## RAW DER per slot. A table whose entry arrived armoured is
      ## un-armoured here, because the envelope carries DER and nothing
      ## downstream should have to guess which it got.
    ignoredGuids*: seq[string]
      ## Every entry this build has no use for, named rather than
      ## dropped. The table is the host's and may carry revocation
      ## lists and vendor extensions; a reader that silently discarded
      ## them would leave an operator unable to tell an unexpected table
      ## from an expected one.

const
  SnpVcekGuid* = "63da758d-e664-4564-adc5-f4b93be8accd"
  SnpVlekGuid* = "a8074bc2-a25a-483e-aae6-39c045a0b8a1"
  SnpAskGuid* = "4ab7b379-bbac-4fe4-a02f-05aef327c782"
  SnpArkGuid* = "c0b406a4-a803-4952-9743-3fb6014cd0ae"
    ## The vendor's table keys, written as the text its own tooling
    ## parses. The bytes on the wire are those hex digits in the order
    ## they are written — the form ``uuid_parse`` produces — and
    ## `guidBytes` is the single place that conversion happens.

  SnpCertTableEntryLen* = 24
    ## Sixteen bytes of key, then a four-byte offset and a four-byte
    ## length, both little-endian.

  PemCertificateOpen* = "-----BEGIN CERTIFICATE-----"
  PemCertificateClose* = "-----END CERTIFICATE-----"
  DerSequenceTag* = 0x30'u8
    ## Every certificate is a DER ``SEQUENCE``. It is the one byte that
    ## distinguishes a certificate the envelope can carry from whatever
    ## else a host may have left in the table.

proc snpFail*(condition: SnpBackendCondition; detail: string)
    {.noreturn.} =
  var e = newException(SnpBackendError, detail)
  e.condition = condition
  raise e

proc guidBytes*(text: string): string =
  ## The 16 wire bytes of a table key, from the text form.
  ##
  ## Written out rather than pinned as a byte array so the constants
  ## above stay in the form a reader can compare against the vendor's
  ## own headers without re-ordering anything in their head.
  var hex = ""
  for c in text:
    if c == '-': continue
    hex.add c
  if hex.len != 32:
    snpFail(sbcMalformedTableKey,
            "a table key is 32 hex digits and " & text.escape() & " has " &
            $hex.len)
  for i in countup(0, hex.len - 2, 2):
    result.add char(parseHexInt(hex[i .. i + 1]))

proc le32At(s: string; at: int): uint32 =
  uint32(uint8(s[at])) or (uint32(uint8(s[at + 1])) shl 8) or
    (uint32(uint8(s[at + 2])) shl 16) or (uint32(uint8(s[at + 3])) shl 24)

proc hexGuid(s: string; at: int): string =
  ## One table key back in its text form, for a diagnostic.
  var digits = ""
  for i in 0 ..< 16: digits.add toHex(int(uint8(s[at + i])), 2).toLowerAscii
  digits[0 .. 7] & "-" & digits[8 .. 11] & "-" & digits[12 .. 15] & "-" &
    digits[16 .. 19] & "-" & digits[20 .. 31]

proc derOf(entry, whose: string): string =
  ## One table entry's certificate as DER.
  ##
  ## A host may store the vendor's certificates armoured — the service
  ## that publishes them serves PEM — and store the part's endorsement
  ## certificate raw. Both shapes are in the wild, so both are read, and
  ## anything that is neither is refused rather than passed on as a
  ## certificate somebody downstream will fail to parse.
  if entry.len == 0:
    snpFail(sbcTableEntryEmpty,
            "the " & whose & " entry of the certificate table is empty")
  if uint8(entry[0]) == DerSequenceTag:
    return entry
  let text = entry.strip()
  if not text.startsWith(PemCertificateOpen):
    snpFail(sbcTableEntryNotACertificate,
            "the " & whose & " entry of the certificate table begins 0x" &
            toHex(int(uint8(entry[0])), 2) & " and a certificate is " &
            "either a DER sequence (0x" & toHex(int(DerSequenceTag), 2) &
            ") or armoured text beginning " &
            PemCertificateOpen.escape())
  let closeAt = text.find(PemCertificateClose)
  if closeAt < 0:
    snpFail(sbcArmourNotClosed,
            "the " & whose & " entry of the certificate table opens " &
            "armour and never closes it, so there is no way to know " &
            "where the certificate ends")
  var body = ""
  for c in text[PemCertificateOpen.len ..< closeAt]:
    if c notin {' ', '\t', '\r', '\n'}: body.add c
  try:
    result = base64.decode(body)
  except CatchableError as e:
    snpFail(sbcArmourDoesNotDecode,
            "the " & whose & " entry of the certificate table is " &
            "armoured and its body does not decode: " & e.msg)
  if result.len == 0 or uint8(result[0]) != DerSequenceTag:
    snpFail(sbcArmourDecodesToSomethingElse,
            "the " & whose & " entry of the certificate table decodes to " &
            $result.len & " bytes that are not a DER sequence")

proc slotName(slot: SnpCertificateSlot): string =
  case slot
  of scsEndorsement: "endorsement key"
  of scsSigningKey: "vendor signing key"
  of scsRoot: "vendor root"

proc parseSnpCertificateTable*(blob: string): SnpCertificateTable =
  ## Read the host's GUID-indexed certificate table.
  ##
  ## Strict about the framing and permissive about the contents, which
  ## is the right way round for a structure somebody else defines: an
  ## entry running past the end of the blob is refused, because reading
  ## it would read whatever follows in memory, while an entry this build
  ## has no use for is NAMED and carried past. The table is the vendor's
  ## format and it is allowed to grow; the envelope is this project's
  ## and is not.
  if blob.len < SnpCertTableEntryLen:
    snpFail(sbcTableTooShort,
            "a certificate table is at least one " &
            $SnpCertTableEntryLen & "-byte entry and its terminator, " &
            "and this blob is " & $blob.len & " bytes")

  let vcek = guidBytes(SnpVcekGuid)
  let vlek = guidBytes(SnpVlekGuid)
  let ask = guidBytes(SnpAskGuid)
  let ark = guidBytes(SnpArkGuid)
  let terminator = repeat('\x00', 16)

  var found: array[SnpCertificateSlot, string]
  var seenEndorsementKind = ""
  var at = 0
  var terminated = false
  while at + SnpCertTableEntryLen <= blob.len:
    let key = blob[at ..< at + 16]
    if key == terminator:
      terminated = true
      break
    let offset = int(le32At(blob, at + 16))
    let length = int(le32At(blob, at + 20))
    if offset < 0 or length < 0 or offset > blob.len or
       length > blob.len - offset:
      snpFail(sbcTableEntryRunsPastTheEnd,
              "the " & hexGuid(blob, at) & " entry of the certificate " &
              "table declares " & $length & " bytes at offset " & $offset &
              ", against " & $blob.len & " bytes supplied")
    let payload = blob[offset ..< offset + length]

    if key == vcek or key == vlek:
      let kind = if key == vcek: "VCEK" else: "VLEK"
      if seenEndorsementKind.len > 0:
        snpFail(sbcTwoEndorsementCertificates,
                "the certificate table carries both a " &
                seenEndorsementKind & " and a " & kind &
                " endorsement certificate; a part is endorsed by one key " &
                "and a table offering two does not say which endorsed " &
                "this report")
      seenEndorsementKind = kind
      found[scsEndorsement] = derOf(payload, slotName(scsEndorsement))
    elif key == ask:
      found[scsSigningKey] = derOf(payload, slotName(scsSigningKey))
    elif key == ark:
      found[scsRoot] = derOf(payload, slotName(scsRoot))
    else:
      result.ignoredGuids.add hexGuid(blob, at)
    at += SnpCertTableEntryLen

  if not terminated:
    snpFail(sbcTableNotTerminated,
            "the certificate table runs to the end of the blob without a " &
            "terminating entry, so there is no way to know whether it is " &
            "complete")

  var missing: seq[string] = @[]
  for slot in SnpCertificateSlot:
    if found[slot].len == 0: missing.add slotName(slot)
  if missing.len > 0:
    snpFail(sbcTableIncomplete,
            "the certificate table carries no " & missing.join(", no ") &
            "; a verifier holding part of a chain can check no signature " &
            "with it, so a partial table is refused here rather than " &
            "bundled for somebody else to fail on")

  result.certificates = found

# ---------------------------------------------------------------------
# Reading the document
# ---------------------------------------------------------------------

proc agentSnpBoundBytes*(outblob: string): string =
  ## The 64 bytes this document says were bound into it.
  ##
  ## Raises when the document is not one this build has a layout for,
  ## because reading a field out of a structure you could not identify
  ## is how a value from the middle of a different document comes to be
  ## compared against a request.
  if outblob.len != AgentSnpReportLen:
    snpFail(sbcWrongDocumentWidth,
            "a security-processor report is " & $AgentSnpReportLen &
            " bytes and this document is " & $outblob.len)
  let version = le32At(outblob, AgentSnpVersionOffset)
  var known = false
  for v in AgentSnpVersions:
    if version == v: known = true
  if not known:
    var supported: seq[string] = @[]
    for v in AgentSnpVersions: supported.add $v
    snpFail(sbcUnsupportedRevision,
            "the document states structure revision " & $version &
            " and this build has a layout for " & supported.join(", "))
  result = outblob[AgentSnpReportDataOffset ..<
                   AgentSnpReportDataOffset + ReportDataSize]

proc agentSnpPrivilegeLevel*(outblob: string): uint32 =
  ## The privilege level the document was taken at. Read after the width
  ## and revision have been established, for the reason above.
  discard agentSnpBoundBytes(outblob)
  le32At(outblob, AgentSnpVmplOffset)

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

type
  SnpDriver* = ref object of AttestationDriver
    ## The security-processor arm of the backend seam.
    source: TsmSource
    privilegeLevel: int

proc newSnpDriver*(source: TsmSource;
                   privilegeLevel = DefaultSnpPrivilegeLevel): SnpDriver =
  ## The privilege level is configuration and never a request field, for
  ## the reason a TPM driver's register selection is: a caller that
  ## could choose it could choose the level whose report says the least.
  if source.isNil:
    snpFail(sbcNoSource,
      "a security-processor driver needs a source; a driver with none " &
      "would have nothing to report and no way to say so")
  if privilegeLevel < 0 or privilegeLevel > 3:
    snpFail(sbcPrivilegeLevelOutOfRange,
      "a security-processor privilege level is 0 to 3 and this driver " &
      "was configured with " & $privilegeLevel)
  result = SnpDriver(source: source, privilegeLevel: privilegeLevel)
  initAttestationDriver(result, abSevSnp, SnpDriverName)

proc configuredPrivilegeLevel*(d: SnpDriver): int = d.privilegeLevel

method driverProbe*(d: SnpDriver): BackendReadiness =
  d.source.sourceProbe()

proc quoteImpl(d: SnpDriver; req: QuoteRequest): QuoteResult =
  let got = readTsmReport(d.source, req.reportData)

  if got.provider != tsmSevSnp:
    snpFail(sbcWrongProvider,
      "the report entry names provider " &
      ($got.provider).escape() & " and this driver reads " &
      ($tsmSevSnp).escape() &
      "; a document read at one root of trust's offsets is not the " &
      "other's document")

  let bound = agentSnpBoundBytes(got.outblob)
  if bound != req.reportData:
    snpFail(sbcAnswersADifferentQuestion,
      "the document binds " &
      bytesToHex(bound) & " and this request binds " &
      bytesToHex(req.reportData) &
      "; evidence that answers a different question is not an answer " &
      "to this one")

  let level = agentSnpPrivilegeLevel(got.outblob)
  if level != uint32(d.privilegeLevel):
    snpFail(sbcWrongPrivilegeLevel,
      "the document was taken at privilege " &
      "level " & $level & " and this driver is configured for level " &
      $d.privilegeLevel &
      "; a report from a level nobody chose can be a report from the " &
      "level that says the least")

  var chain = none(seq[string])
  if got.auxblob.isSome:
    let table = parseSnpCertificateTable(got.auxblob.get)
    var ordered: seq[string] = @[]
    for slot in SnpCertificateSlot: ordered.add table.certificates[slot]
    chain = some(ordered)

  result = QuoteResult(evidence: got.outblob, certificates: chain)

method driverQuote*(d: SnpDriver; req: QuoteRequest): QuoteResult =
  ## Acquire, check, hand over.
  ##
  ## EVERY refusal leaves here as a `DriverError` naming this driver.
  ## That is the seam's contract rather than a convenience: whoever
  ## reads the message is looking at a machine that would not attest,
  ## and an exception of the transport's own type escaping the seam
  ## would be a refusal a caller catching `DriverError` does not catch —
  ## which is the difference between a machine that refuses and a
  ## machine that crashes.
  try:
    result = quoteImpl(d, req)
  except SnpBackendError as e:
    # Re-raised rather than re-wrapped, so the condition survives the
    # boundary. Only the sentence grows, and it grows by the one fact
    # the refusal sites cannot know: which driver was asked.
    e.msg = "driver " & d.driverName & ": " & e.msg
    raise e
  except TsmError as e:
    # The transport's vocabulary is its own and is not re-spelled in
    # this module's: a rule that had two names would be a rule a census
    # counts twice.
    snpFail(sbcTransportRefused, "driver " & d.driverName & ": " & e.msg)
