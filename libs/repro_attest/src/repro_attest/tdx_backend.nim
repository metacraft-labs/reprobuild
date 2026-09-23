## The trust-domain backend: the quote a confidential guest's quoting
## enclave produces, and the driver that hands it over.
##
## ## Why this is a shorter module than its neighbour
##
## A trust-domain quote already carries its own endorsement chain,
## inside the signed document, as certification data. There is no
## separate blob for the host to load and therefore nothing for this
## driver to parse into an envelope's certificate list: the quote is the
## whole of the evidence, and the collateral a verifier additionally
## needs — the vendor's trusted-computing-base documents and its
## enclave-identity document — is fetched on the verifier's network from
## the vendor, never from the machine being judged.
##
## So `certificates` is `none` here, and that is a statement rather than
## an omission. `none` and an empty list are different answers and the
## envelope refuses the second, precisely so that "fetch your own
## collateral" cannot be read as "here is a chain".
##
## ## The question and the answer
##
## Everything the security-processor backend's header says about a
## document that binds somebody else's 64 bytes applies here word for
## word, and the same check answers it: the driver reads the bound bytes
## out of the quote it just obtained and compares them against the bytes
## it was handed. A quote that answers a different question verifies
## perfectly and says nothing about this request.
##
## ## Locating the field in two quote versions
##
## A version-4 quote states nothing about the shape of the report inside
## it: the header is followed immediately by a 584-byte report. A
## version-5 quote states both the shape and the width, in two fields
## that sit INSIDE the signed span so that a shape cannot be restated
## after the fact — and this driver reads them rather than assuming,
## because a version-5 quote carrying the wider report puts every field
## after the header six bytes further along and a reader that assumed
## would lift its 64 bytes out of the middle of a measurement.
##
## The offsets are this module's own transcription, for the reason the
## security-processor backend's header gives at length: the agent does
## not link the verifier, two transcriptions would be a second opinion,
## a shared constant would be worse, and the agreement is therefore
## established by a gate that reads every genuine quote in the corpus
## with both readers and requires the answers equal.
##
## ## Mocking
##
## None. `CapturedTsmSource` reads quotes real parts produced from
## files; every check below runs against those bytes.

import std/[options, strutils]

import ./binding
import ./driver
import ./report
import ./tsm_report

const
  TdxDriverName* = "tdx"

  AgentTdxHeaderLen* = 48
  AgentTdxVersionOffset* = 0
  AgentTdxTeeTypeOffset* = 4
  AgentTdxVersion4* = 4'u16
  AgentTdxVersion5* = 5'u16
  AgentTdxTeeType* = 0x81'u32
    ## A trust domain. Zero is an enclave, and reading a trust domain's
    ## offsets out of an enclave report is exactly the confusion the
    ## check exists to prevent.

  AgentTdxBodyTypeOffset* = AgentTdxHeaderLen
  AgentTdxBodySizeOffset* = AgentTdxHeaderLen + 2
  AgentTdxBodyDescriptorLen* = 6
    ## A version-5 quote's shape and width, in that order.

  AgentTdxBodyType10* = 2'u16
  AgentTdxBodyType15* = 3'u16
  AgentTdxBodyLen10* = 584
  AgentTdxBodyLen15* = 648
    ## The two report widths this build has a layout for. The second is
    ## the first followed by a preserved trusted-computing base and the
    ## measurement of a bound service domain.

  AgentTdxReportDataOffset* = 520
    ## Where the 64 bound bytes sit INSIDE the report, whichever width
    ## it has — the wider report appends, it does not re-lay-out.

type
  TdxBackendCondition* = enum
    ## One condition per rule, and exactly ONE RAISE SITE per condition
    ## — see the security-processor backend's enumeration for why the
    ## correspondence is the thing that matters and why the gate proves
    ## it by scanning the source.
    tbcNoSource
    tbcTooShortForADescriptor
    tbcUnsupportedQuoteVersion
    tbcNotATrustDomain
    tbcUnsupportedReportShape
    tbcShapeAndWidthDisagree
    tbcReportRunsPastTheEnd
    tbcWrongProvider
    tbcAuxiliaryMaterialOffered
    tbcAnswersADifferentQuestion
    tbcTransportRefused

  TdxBackendError* = object of DriverError
    ## Every refusal this module makes. It descends from `DriverError`
    ## for the reason its neighbour's does: a refusal that escaped past
    ## a caller catching `DriverError` is the difference between a
    ## machine that refuses and a machine that crashes.
    condition*: TdxBackendCondition

proc tdxFail*(condition: TdxBackendCondition; detail: string) {.noreturn.} =
  var e = newException(TdxBackendError, detail)
  e.condition = condition
  raise e

proc le16At(s: string; at: int): uint16 =
  uint16(uint8(s[at])) or (uint16(uint8(s[at + 1])) shl 8)

proc le32At(s: string; at: int): uint32 =
  uint32(uint8(s[at])) or (uint32(uint8(s[at + 1])) shl 8) or
    (uint32(uint8(s[at + 2])) shl 16) or (uint32(uint8(s[at + 3])) shl 24)

proc agentTdxReportSpan*(quote: string): tuple[at, width: int] =
  ## Where the report sits in this quote, and how wide it is.
  ##
  ## Split out from the field read below because it is the whole of what
  ## the two versions differ by, and a reader that could not say where
  ## the report starts has no business reading a field out of it.
  if quote.len < AgentTdxHeaderLen + AgentTdxBodyDescriptorLen:
    tdxFail(tbcTooShortForADescriptor,
            "a trust-domain quote is at least a header and a report " &
            "descriptor, which is " &
            $(AgentTdxHeaderLen + AgentTdxBodyDescriptorLen) &
            " bytes, and this document is " & $quote.len)

  let version = le16At(quote, AgentTdxVersionOffset)
  if version != AgentTdxVersion4 and version != AgentTdxVersion5:
    tdxFail(tbcUnsupportedQuoteVersion,
            "the document states quote version " & $version &
            " and this build has a layout for " & $AgentTdxVersion4 &
            " and " & $AgentTdxVersion5)

  let tee = le32At(quote, AgentTdxTeeTypeOffset)
  if tee != AgentTdxTeeType:
    tdxFail(tbcNotATrustDomain,
            "the document states type 0x" & toHex(int(tee), 8) &
            " and a trust domain is 0x" & toHex(int(AgentTdxTeeType), 8))

  if version == AgentTdxVersion4:
    result = (at: AgentTdxHeaderLen, width: AgentTdxBodyLen10)
  else:
    let stated = le16At(quote, AgentTdxBodyTypeOffset)
    let width =
      if stated == AgentTdxBodyType10: AgentTdxBodyLen10
      elif stated == AgentTdxBodyType15: AgentTdxBodyLen15
      else:
        tdxFail(tbcUnsupportedReportShape,
                "the document states report shape " & $stated &
                " and this build reads " & $AgentTdxBodyType10 & " and " &
                $AgentTdxBodyType15)
    let declared = int(le32At(quote, AgentTdxBodySizeOffset))
    if declared != width:
      tdxFail(tbcShapeAndWidthDisagree,
              "the document states report shape " & $stated & " (" &
              $width & " bytes) and declares " & $declared &
              "; a shape and a width that disagree describe no document")
    result = (at: AgentTdxHeaderLen + AgentTdxBodyDescriptorLen,
              width: width)

  if result.at + result.width > quote.len:
    tdxFail(tbcReportRunsPastTheEnd,
            "the report occupies bytes " & $result.at & " to " &
            $(result.at + result.width) & " and this document is " &
            $quote.len & " bytes")

proc agentTdxBoundBytes*(quote: string): string =
  ## The 64 bytes this quote says were bound into it.
  let span = agentTdxReportSpan(quote)
  let at = span.at + AgentTdxReportDataOffset
  result = quote[at ..< at + ReportDataSize]

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

type
  TdxDriver* = ref object of AttestationDriver
    ## The trust-domain arm of the backend seam.
    source: TsmSource

proc newTdxDriver*(source: TsmSource): TdxDriver =
  if source.isNil:
    tdxFail(tbcNoSource,
      "a trust-domain driver needs a source; a driver with none would " &
      "have nothing to report and no way to say so")
  result = TdxDriver(source: source)
  initAttestationDriver(result, abTdx, TdxDriverName)

method driverProbe*(d: TdxDriver): BackendReadiness =
  d.source.sourceProbe()

proc quoteImpl(d: TdxDriver; req: QuoteRequest): QuoteResult =
  let got = readTsmReport(d.source, req.reportData)

  if got.provider != tsmTdx:
    tdxFail(tbcWrongProvider,
      "the report entry names provider " &
      ($got.provider).escape() & " and this driver reads " &
      ($tsmTdx).escape() &
      "; a document read at one root of trust's offsets is not the " &
      "other's document")

  if got.auxblob.isSome:
    tdxFail(tbcAuxiliaryMaterialOffered,
      "the report entry offered " &
      $got.auxblob.get.len & " bytes of auxiliary material, and a " &
      "trust-domain quote carries its own endorsement chain inside the " &
      "signed document; material offered beside it is material nothing " &
      "signed, and bundling it would put a chain in the envelope that " &
      "the quote does not answer for")

  let bound = agentTdxBoundBytes(got.outblob)
  if bound != req.reportData:
    tdxFail(tbcAnswersADifferentQuestion,
      "the document binds " &
      bytesToHex(bound) & " and this request binds " &
      bytesToHex(req.reportData) &
      "; evidence that answers a different question is not an answer " &
      "to this one")

  result = QuoteResult(evidence: got.outblob,
                       certificates: none(seq[string]))

method driverQuote*(d: TdxDriver; req: QuoteRequest): QuoteResult =
  ## Acquire, check, hand over. Every refusal leaves here as a
  ## `DriverError` naming this driver; see the security-processor
  ## backend's `driverQuote` for why that is the seam's contract and not
  ## a convenience.
  try:
    result = quoteImpl(d, req)
  except TdxBackendError as e:
    e.msg = "driver " & d.driverName & ": " & e.msg
    raise e
  except TsmError as e:
    tdxFail(tbcTransportRefused, "driver " & d.driverName & ": " & e.msg)
