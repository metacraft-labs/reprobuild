## The attestation fixture ledger, as data.
##
## Three checked-in tables sit beside this file and this module is their
## reader:
##
##   * `attestation-fixture-ledger.tsv` — one row per pinned artifact,
##     its class, its publisher, its digest, and the window it states.
##   * `attestation-fixture-publishers.tsv` — who serves each one, and
##     the command that refreshes it.
##   * `attestation-corpus-census.tsv` — every file in this directory
##     carrying pinned bytes, and whether those bytes have a lifecycle
##     at all. This is the stable-versus-refreshed separation.
##
## ## Why tables rather than Nim constants
##
## Two readers need the same facts and only one of them is Nim. The
## scheduled collateral monitor is a script that re-fetches from the
## publishers and compares digests; it cannot link this library, and a
## second hand-kept copy of sixty-seven digests in another language is
## a guarantee that the two will disagree. One file, two readers, and a
## gate that checks the file against the bytes.
##
## ## What the tables are NOT
##
## They are not the source of any value. `t_attestation_fixture_lifecycle`
## re-derives every digest from the constants and every date from the
## artifact's own bytes, and compares. A digest edited to make that gate
## pass has inverted the file's purpose.
##
## The one thing here that IS a source is the enumeration of rows: the
## gate proves it complete against a directory scan and against the
## constants declared by the corpus modules, in both directions, so a
## corpus cannot gain a member that nothing tracks.
##
## ## Mocking
##
## None. Real tables, real bytes.

import std/[os, strutils]

include ./snp_vectors
include ./tdx_vectors
include ./nitro_vectors

type
  LedgerRow* = object
    name*: string
    module*: string
    class*: string
    publisher*: string
    observed*: string
    bytes*: int
    sha256*: string
    window*: string
    notBefore*: string
    notAfter*: string

  PublisherRow* = object
    id*: string
    what*: string
    url*: string
    refreshWith*: string

  CensusRow* = object
    path*: string
    kind*: string
    refresh*: string
    note*: string

const
  LedgerText* = staticRead("attestation-fixture-ledger.tsv")
  PublishersText* = staticRead("attestation-fixture-publishers.tsv")
  CensusText* = staticRead("attestation-corpus-census.tsv")

  LedgerReferenceInstant* = 1_790_640_000'i64
    ## 2026-09-29T00:00:00Z. The instant the corpus census cases judge
    ## the pinned material at.
    ##
    ## PINNED, and that is deliberate rather than lazy. A case that
    ## judged the corpus at the wall clock would change its answer every
    ## day and would eventually fail for a reason that is not a defect —
    ## which is how a gate gets disabled. The calendar belongs to the
    ## scheduled monitor, which uses the wall clock precisely because
    ## noticing the calendar is its whole job. This constant moves when
    ## somebody refreshes the corpus, and moving it is a decision with a
    ## diff.

proc tsvRows(text: string; columns: int; what: string): seq[seq[string]] =
  ## Every non-comment, non-blank line of a table, split on tabs.
  ##
  ## A row with the wrong number of columns is a failure rather than a
  ## row padded with empties: a table whose reader silently accepted a
  ## short row would accept one that lost its remedy.
  for raw in text.splitLines():
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if line.len == 0 or line.startsWith("#"): continue
    let f = line.split('\t')
    if f.len != columns:
      raise newException(ValueError,
        what & " row " & f[0].escape() & " has " & $f.len &
        " columns and this table has " & $columns)
    result.add f

proc ledgerRows*(): seq[LedgerRow] =
  for f in tsvRows(LedgerText, 10, "the fixture ledger"):
    result.add LedgerRow(
      name: f[0], module: f[1], class: f[2], publisher: f[3],
      observed: f[4], bytes: parseInt(f[5]), sha256: f[6],
      window: f[7], notBefore: f[8], notAfter: f[9])

proc publisherRows*(): seq[PublisherRow] =
  for f in tsvRows(PublishersText, 4, "the publisher table"):
    result.add PublisherRow(id: f[0], what: f[1], url: f[2], refreshWith: f[3])

proc censusRows*(): seq[CensusRow] =
  for f in tsvRows(CensusText, 4, "the corpus census"):
    result.add CensusRow(path: f[0], kind: f[1], refresh: f[2], note: f[3])

proc integrationDir*(): string =
  ## This directory, located from this file rather than from the working
  ## directory, so the gate reads the same bytes whatever it is run from.
  currentSourcePath().parentDir

proc fixtureFile*(relative: string): string =
  readFile(integrationDir() / relative)

proc unhexOf*(h: string): string =
  var clean = newStringOfCap(h.len)
  for c in h:
    if c in HexDigits: clean.add c
  doAssert clean.len mod 2 == 0,
    "a hexadecimal corpus with an odd number of digits"
  result = newString(clean.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(clean[2 * i .. 2 * i + 1]))

proc bytesOf*(name: string): string =
  ## The artifact behind a ledger row.
  ##
  ## Written out one arm at a time rather than resolved by a naming
  ## rule. A rule that derived the decoding from the constant's suffix
  ## would be one more undocumented convention, and the arm is where a
  ## reader finds out that two of the enclave documents are pinned as
  ## their DECODED bytes rather than as the transport their publishers
  ## chose.
  case name
  of "KdsMilanChainPem"                          : KdsMilanChainPem
  of "KdsMilanCrlDerHex"                         : unhexOf(KdsMilanCrlDerHex)
  of "KdsGenoaChainPem"                          : KdsGenoaChainPem
  of "KdsGenoaCrlDerHex"                         : unhexOf(KdsGenoaCrlDerHex)
  of "KdsTurinChainPem"                          : KdsTurinChainPem
  of "KdsTurinCrlDerHex"                         : unhexOf(KdsTurinCrlDerHex)
  of "GsgMilanVlekChainPem"                      : GsgMilanVlekChainPem
  of "VirteeMilanVcekDerHex"                     : unhexOf(VirteeMilanVcekDerHex)
  of "VirteeMilanReportHex"                      : unhexOf(VirteeMilanReportHex)
  of "GsgMilanVcekDerHex"                        : unhexOf(GsgMilanVcekDerHex)
  of "GsgMilanReportHex"                         : unhexOf(GsgMilanReportHex)
  of "VirteeTurinVcekDerHex"                     : unhexOf(VirteeTurinVcekDerHex)
  of "ImpostorArkHex"                            : unhexOf(ImpostorArkHex)
  of "ImpostorAskHex"                            : unhexOf(ImpostorAskHex)
  of "ImpostorVcekHex"                           : unhexOf(ImpostorVcekHex)
  of "ImpostorReportHex"                         : unhexOf(ImpostorReportHex)
  of "GoTdxGuestSprQuoteHex"                     : unhexOf(GoTdxGuestSprQuoteHex)
  of "GoTdxGuestEmrQuoteHex"                     : unhexOf(GoTdxGuestEmrQuoteHex)
  of "TrusteeV5QuoteHex"                         : unhexOf(TrusteeV5QuoteHex)
  of "IntelSgxRootCaDerHex"                      : unhexOf(IntelSgxRootCaDerHex)
  of "IntelTcbSigningCertDerHex"                 : unhexOf(IntelTcbSigningCertDerHex)
  of "PcsPckCrlPlatformDerHex"                   : unhexOf(PcsPckCrlPlatformDerHex)
  of "PcsPckCrlProcessorDerHex"                  : unhexOf(PcsPckCrlProcessorDerHex)
  of "IntelRootCrlDerHex"                        : unhexOf(IntelRootCrlDerHex)
  of "IntelSampleRootDerHex"                     : unhexOf(IntelSampleRootDerHex)
  of "IntelSampleCaDerHex"                       : unhexOf(IntelSampleCaDerHex)
  of "IntelSampleLeafDerHex"                     : unhexOf(IntelSampleLeafDerHex)
  of "IntelSampleQuoteHex"                       : unhexOf(IntelSampleQuoteHex)
  of "ImpostorQuoteHex"                          : unhexOf(ImpostorQuoteHex)
  of "ImpostorRootDerHex"                        : unhexOf(ImpostorRootDerHex)
  of "ImpostorCaDerHex"                          : unhexOf(ImpostorCaDerHex)
  of "ImpostorLeafDerHex"                        : unhexOf(ImpostorLeafDerHex)
  of "ImpostorCaNotAnAuthorityDerHex"            : unhexOf(ImpostorCaNotAnAuthorityDerHex)
  of "ImpostorCaWithoutCertSignDerHex"           : unhexOf(ImpostorCaWithoutCertSignDerHex)
  of "ImpostorLeafWithoutPlatformDerHex"         : unhexOf(ImpostorLeafWithoutPlatformDerHex)
  of "ImpostorLeafWithoutFmspcDerHex"            : unhexOf(ImpostorLeafWithoutFmspcDerHex)
  of "ImpostorLeafWithoutTcbDerHex"              : unhexOf(ImpostorLeafWithoutTcbDerHex)
  of "ImpostorLeafWithUnknownCriticalDerHex"     : unhexOf(ImpostorLeafWithUnknownCriticalDerHex)
  of "PcsPckCrlPlatformWithoutNextUpdateDerHex"  : unhexOf(PcsPckCrlPlatformWithoutNextUpdateDerHex)
  of "GtgTcbInfoSprJson"                         : GtgTcbInfoSprJson
  of "GtgTcbInfoEmrJson"                         : GtgTcbInfoEmrJson
  of "GtgQeIdentityJson"                         : GtgQeIdentityJson
  of "PcsTcbInfoSprJson"                         : PcsTcbInfoSprJson
  of "PcsTcbInfoEmrJson"                         : PcsTcbInfoEmrJson
  of "PcsTdxQeIdentityJson"                      : PcsTdxQeIdentityJson
  of "PcsSgxQeIdentityJson"                      : PcsSgxQeIdentityJson
  of "PcsSgxTcbInfoJson"                         : PcsSgxTcbInfoJson
  of "AwsDocumentedPcr4Input"                    : AwsDocumentedPcr4Input
  of "AwsDocumentedPcr4Output"                   : AwsDocumentedPcr4Output
  of "AwsDocumentedPcr3Input"                    : AwsDocumentedPcr3Input
  of "AwsDocumentedPcr3Output"                   : AwsDocumentedPcr3Output
  of "AwsSample2023DocHex"                       : unhexOf(AwsSample2023DocHex)
  of "ZkvEuWest2022DocHex"                       : unhexOf(ZkvEuWest2022DocHex)
  of "ZkvEuWest2026DocHex"                       : unhexOf(ZkvEuWest2026DocHex)
  of "OgUsEast2026DocHex"                        : unhexOf(OgUsEast2026DocHex)
  of "SyndUsEast2025DocHex"                      : unhexOf(SyndUsEast2025DocHex)
  of "NitroRootG1DerHex"                         : unhexOf(NitroRootG1DerHex)
  of "AwsSample2023LeafPointHex"                 : unhexOf(AwsSample2023LeafPointHex)
  of "ZkvEuWest2022LeafPointHex"                 : unhexOf(ZkvEuWest2022LeafPointHex)
  of "ZkvEuWest2026LeafPointHex"                 : unhexOf(ZkvEuWest2026LeafPointHex)
  of "OgUsEast2026LeafPointHex"                  : unhexOf(OgUsEast2026LeafPointHex)
  of "SyndUsEast2025LeafPointHex"                : unhexOf(SyndUsEast2025LeafPointHex)
  of "fixtures/tdx/ovmf-ubuntu-2025.02-3ubuntu2.fd": fixtureFile("fixtures/tdx/ovmf-ubuntu-2025.02-3ubuntu2.fd")
  of "fixtures/tdx/ovmf-dstack-0.5.9.fd"         : fixtureFile("fixtures/tdx/ovmf-dstack-0.5.9.fd")
  of "fixtures/tdx/quote-operator-a.bin"         : fixtureFile("fixtures/tdx/quote-operator-a.bin")
  of "fixtures/tdx/quote-operator-b.bin"         : fixtureFile("fixtures/tdx/quote-operator-b.bin")
  of "fixtures/tdx/dstack-0.5.9-register-log.json": fixtureFile("fixtures/tdx/dstack-0.5.9-register-log.json")
  else:
    raise newException(ValueError,
      "the fixture ledger names " & name.escape() &
      " and this module has no bytes for it; a row without bytes is a " &
      "row nothing checks")
