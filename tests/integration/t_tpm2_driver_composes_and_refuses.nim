## The tpm2 arm of the backend seam: what it produces, and the four
## things it refuses to produce.
##
## ## What this case is worth
##
## The seam's contract is that a driver is handed 64 bytes and returns
## evidence carrying them. For a measured-boot backend "carrying them" is
## three artifacts that have to agree with each other and with the
## request, and the interesting half of the driver is the refusals:
##
##   * a quote that binds someone else's 64 bytes — a stale or replayed
##     one — is not an answer to this request;
##   * a quote over a register set nobody configured can be a quote over
##     the registers that say nothing;
##   * an event log that cannot answer for the quoted bank explains
##     nothing;
##   * an event log that answers and DISAGREES describes a different boot.
##
## Each of those produces evidence that is schema-valid and worthless, so
## each is refused on the machine, where an operator can read why, rather
## than at the verifier on somebody else's network.
##
## ## Mocking
##
## None, and the distinction matters here. ``CapturedTpm2Source`` reads
## the attest, the signature and the event log from real files on a real
## filesystem; every byte in them was produced by a real TPM and real
## firmware (see ``tcg_event_log_vectors`` for the capture). It is not a
## stand-in for a device — it synthesizes nothing, and the driver's
## checks run against the same bytes a device would hand over. The cases
## that must see a driver REFUSE are built by writing different real
## bytes to those files, not by making anything pretend.
##
## What no case here does is issue a TPM command. The transaction is the
## seam ``Tpm2Source`` names and is not implemented in this build.

import std/[options, os, random, strutils, times, unittest]

import repro_attest
import ./tcg_event_log_vectors
import ./tpm2_evidence_framing

proc driverRefusal(body: proc (): void): string =
  try:
    body()
  except DriverError as e:
    return e.msg
  raise newException(ValueError,
    "expected a DriverError and the call returned normally")

proc evidenceRefusal(body: proc (): void): string =
  try:
    body()
  except Tpm2EvidenceError as e:
    return e.msg
  raise newException(ValueError,
    "expected a Tpm2EvidenceError and the call returned normally")

proc flipByte(s: string; at: int): string =
  result = s
  result[at] = char(uint8(result[at]) xor 0x01'u8)

proc sha256DigestOffsetOfEntry1(log: string): int =
  ## Entry 1 is the first real measurement. Its digest list is SHA-1
  ## then SHA-256; the SHA-256 digest starts 12 bytes (pcrIndex,
  ## eventType, digest count) + 2 (alg) + 20 (sha1) + 2 (alg) into the
  ## entry. Derived from a parse rather than hard-coded, so this stays
  ## correct if the fixture is recaptured.
  let parsed = parseEventLog(log)
  doAssert parsed.events.len > 1
  parsed.events[1].wireOffset + 12 + 2 + 20 + 2

type Bench = object
  ## One temporary directory holding the three artifacts a machine would
  ## expose, plus the source that reads them.
  dir: string
  attestPath, signaturePath, logPath, certPath: string

proc newBench(): Bench =
  result.dir = getTempDir() / "repro-tpm2-backend-" & $getCurrentProcessId() &
               "-" & $epochTime().int64 & "-" & $rand(1_000_000)
  createDir(result.dir)
  result.attestPath = result.dir / "quote.attest"
  result.signaturePath = result.dir / "quote.sig"
  result.logPath = result.dir / "binary_bios_measurements"
  result.certPath = result.dir / "ak.der"
  writeFile(result.attestPath, agileQuoteAttest())
  writeFile(result.signaturePath, agileQuoteSignature())
  writeFile(result.logPath, agileLog())

proc source(b: Bench; certs: seq[string] = @[]): CapturedTpm2Source =
  newCapturedTpm2Source(b.attestPath, b.signaturePath, b.logPath, certs)

proc noActionEntry(payloadLen: int): string =
  ## A well-formed crypto-agile ``EV_NO_ACTION`` entry for the four banks
  ## this log declares.
  ##
  ## It is the one entry type a replay must NOT extend, so appending any
  ## number of them leaves every register exactly where the firmware left
  ## it. That is what makes it the honest way to grow a log without
  ## changing what the log says — the padded log still explains the same
  ## quote, so a refusal over it is a refusal about SIZE and not about
  ## validity.
  var w = initTpm2Writer("padding")
  w.writeU32Le(0'u32)                      # pcrIndex
  w.writeU32Le(uint32(EvNoAction))         # eventType
  w.writeU32Le(4'u32)                      # one digest per declared bank
  for (alg, size) in [(TpmAlgSha1, 20), (TpmAlgSha256, 32),
                      (TpmAlgSha384, 48), (TpmAlgSha512, 64)]:
    w.writeU16Le(uint16(alg))
    w.writeBytes(repeat('\x00', size))
  w.writeU32Le(uint32(payloadLen))
  w.writeBytes(repeat('p', payloadLen))
  result = w.bytes

type
  UnimplementedSource = ref object of Tpm2Source
    ## A subclass that overrides nothing, so the base seam's refusals
    ## have an input. Without one they are rules nothing can reach, which
    ## is a constant rather than a check.

  UnlabelledSource = ref object of Tpm2Source

suite "the tpm2 driver's identity is not its own to choose":

  test "the backend is tpm2 and the tier follows from it":
    let b = newBench()
    defer: removeDir(b.dir)
    let d = newTpm2Driver(source(b))
    check d.backend == abTpm2
    check d.tier == atTpm
    check d.tier == tierOf(abTpm2)
    check d.driverName == Tpm2DriverName
    check d.driverName == "tpm2"
    # There is no spelling of the constructor that produces another
    # backend, which is what makes the tier structural rather than
    # documented.

  test "a driver that quotes no register is refused at construction":
    let b = newBench()
    defer: removeDir(b.dir)
    check "digest of the empty string" in driverRefusal(proc () =
      discard newTpm2Driver(source(b), TpmlPcrSelection(selections: @[])))

  test "a driver with no source is refused at construction":
    check "needs a source" in driverRefusal(proc () =
      discard newTpm2Driver(nil))

  test "a source that does not label itself is refused":
    # The shipped constructor always supplies a label, so this rule's
    # only reachable input is one a CALLER constructs. A rule with no
    # reachable input is a constant, not a check, so this case builds
    # one directly rather than leaving the guard unexercised.
    check "must label itself" in evidenceRefusal(proc () =
      let s = UnlabelledSource()
      initTpm2Source(s, ""))

  test "a source that implements nothing refuses rather than returning nothing":
    let s = UnimplementedSource()
    initTpm2Source(s, "implements-nothing")
    check s.label == "implements-nothing"
    check "does not implement sourceProbe" in evidenceRefusal(proc () =
      discard s.sourceProbe())
    check "does not implement sourceQuote" in evidenceRefusal(proc () =
      discard s.sourceQuote(agileQuoteQualifying()))
    check "does not implement sourceEventLog" in evidenceRefusal(proc () =
      discard s.sourceEventLog())
    # The chain is the one base method with an answer, and its answer is
    # "none held" rather than a refusal — the envelope distinguishes the
    # two, so the default must be the one that means nothing is claimed.
    check s.sourceCertificates().len == 0

suite "the tpm2 driver probes without consuming a quote":

  test "a machine with no evidence says WHICH artifact is missing":
    let b = newBench()
    defer: removeDir(b.dir)
    removeFile(b.attestPath)
    removeFile(b.logPath)
    let readiness = newTpm2Driver(source(b)).driverProbe()
    check not readiness.ready
    # The paths, not merely the fact that something is absent: an
    # operator reading "not ready" would go looking for them.
    check b.attestPath in readiness.detail
    check b.logPath in readiness.detail
    check b.signaturePath notin readiness.detail

  test "a machine with all three is ready, and names them":
    let b = newBench()
    defer: removeDir(b.dir)
    let readiness = newTpm2Driver(source(b)).driverProbe()
    check readiness.ready
    check b.attestPath in readiness.detail
    check b.signaturePath in readiness.detail
    check b.logPath in readiness.detail

suite "the tpm2 driver composes evidence that joins up":

  test "acquireQuote returns a composite carrying all three artifacts":
    let b = newBench()
    defer: removeDir(b.dir)
    let d = newTpm2Driver(source(b))
    let res = acquireQuote(d, agileQuoteQualifying())

    let ev = parseTpm2Evidence(res.evidence)
    check ev.attestBytes == agileQuoteAttest()
    check ev.signatureBytes == agileQuoteSignature()
    check ev.eventLogBytes == agileLog()
    check res.evidence == frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()),
        (2'u32, agileQuoteSignature()),
        (3'u32, agileLog())])

    # The join, end to end through the seam rather than through the
    # codec: the log this driver shipped explains the quote it shipped.
    check logExplainsQuote(ev)
    check hexOf(tpm2EvidenceQuote(ev).qualifyingData) ==
          AgileQuoteQualifyingHex

  test "a machine holding no chain returns none, not an empty sequence":
    let b = newBench()
    defer: removeDir(b.dir)
    check acquireQuote(newTpm2Driver(source(b)),
                       agileQuoteQualifying()).certificates.isNone

  test "a machine holding a chain returns it":
    let b = newBench()
    defer: removeDir(b.dir)
    writeFile(b.certPath, "\x30\x82not-a-real-certificate")
    let res = acquireQuote(newTpm2Driver(source(b, @[b.certPath])),
                           agileQuoteQualifying())
    check res.certificates.isSome
    check res.certificates.get == @["\x30\x82not-a-real-certificate"]

suite "the tpm2 driver refuses evidence that answers a different question":

  test "a quote binding somebody else's 64 bytes is refused":
    # The replay case: the artifacts on disk are a real quote from a
    # real TPM, and they answer a challenge that is not this one.
    let b = newBench()
    defer: removeDir(b.dir)
    let other = flipByte(agileQuoteQualifying(), 0)
    check other.len == ReportDataSize
    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), other))
    check "the quote binds" in msg
    check AgileQuoteQualifyingHex in msg
    check bytesToHex(other) in msg

  test "the seam refuses a request that is not 64 bytes, before the driver runs":
    let b = newBench()
    defer: removeDir(b.dir)
    let d = newTpm2Driver(source(b))
    check "the discipline binds exactly 64" in driverRefusal(proc () =
      discard acquireQuote(d, agileQuoteQualifying()[0 ..< 63]))
    check "the discipline binds exactly 64" in driverRefusal(proc () =
      discard acquireQuote(d, ""))

  test "a quote over a register set this driver did not configure is refused":
    let b = newBench()
    defer: removeDir(b.dir)
    # The pinned quote covers sha256:0-7. A driver configured for seven
    # of those eight must refuse it rather than accept a narrower or
    # wider answer than the one it asked for.
    let narrow = newTpm2Driver(source(b), pcrSelection(TpmAlgSha256, [0, 1, 2, 3, 4, 5, 6]))

    # Pinned by IDENTITY and not by cardinality. Seven registers is the
    # same count whether they are 0-6 or 1-7, and the refusal message
    # below says "7" either way — so a selection built with the bitmap
    # packed the other way round left this case GREEN. That was measured
    # rather than suspected, and this is the assertion that sees it.
    var configured: seq[int] = @[]
    for e in selectedPcrs(narrow.quotedSelection()):
      check e.bank == TpmAlgSha256
      configured.add e.index
    check configured == @[0, 1, 2, 3, 4, 5, 6]

    var byDefault: seq[int] = @[]
    for e in selectedPcrs(newTpm2Driver(source(b)).quotedSelection()):
      check e.bank == DefaultQuotedPcrBank
      byDefault.add e.index
    check byDefault == @DefaultQuotedPcrs
    check byDefault == @[0, 1, 2, 3, 4, 5, 6, 7]

    let msg = driverRefusal(proc () =
      discard acquireQuote(narrow, agileQuoteQualifying()))
    check "configured to quote 7" in msg
    check "the quote covers 8" in msg
    # A different BANK is the same refusal: a SHA-1 selection is not the
    # SHA-256 one even over the same register numbers.
    let wrongBank = newTpm2Driver(source(b),
                                  pcrSelection(TpmAlgSha1, DefaultQuotedPcrs))
    check "the quote covers" in driverRefusal(proc () =
      discard acquireQuote(wrongBank, agileQuoteQualifying()))

  test "an event log that cannot answer for the quoted bank is refused":
    # A real log from a real firmware — a different machine's, SHA-1
    # only. It parses; it simply has nothing to say about the bank the
    # quote covers, and answering anyway would be answering from reset
    # values that are identical on every machine.
    let b = newBench()
    defer: removeDir(b.dir)
    writeFile(b.logPath, legacyLog())
    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "cannot answer for its own quote" in msg
    check "carries no sha256 bank" in msg

  test "an event log that answers and DISAGREES is refused":
    # One flipped bit in one measurement's SHA-256 digest. The log still
    # parses, still replays, and lands on a register the TPM never held.
    let b = newBench()
    defer: removeDir(b.dir)
    writeFile(b.logPath,
              flipByte(agileLog(), sha256DigestOffsetOfEntry1(agileLog())))
    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "does not reproduce the register digest" in msg
    check "cannot answer" notin msg

  test "an event log this codec cannot read is refused":
    let b = newBench()
    defer: removeDir(b.dir)
    writeFile(b.logPath, repeat('\xFF', 64))
    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "the event log does not decode" in msg
    check "driver tpm2" in msg

  test "an attest that is not a TPM's is refused":
    let b = newBench()
    defer: removeDir(b.dir)
    writeFile(b.attestPath, repeat('\x00', agileQuoteAttest().len))
    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "the quote does not decode" in msg
    check "driver tpm2" in msg

  test "an event log that outgrew the envelope is refused, and says so":
    # The bound the report envelope imposes, reached through the driver
    # on a log that is otherwise perfect. The padding is EV_NO_ACTION
    # entries, which a replay does not extend, so the padded log still
    # explains the same quote — the refusal is therefore about SIZE and
    # nothing else, which is the only way to test the bound without also
    # changing what the evidence says.
    let b = newBench()
    defer: removeDir(b.dir)
    let entry = noActionEntry(4096)
    var padded = agileLog()
    while padded.len < MaxTpm2EvidenceBytes: padded.add entry
    writeFile(b.logPath, padded)

    # The padded log is a real log, and it still explains the quote.
    let grown = parseEventLog(padded)
    check grown.events.len > parseEventLog(agileLog()).events.len
    check explainsQuote(grown, parseQuote(agileQuoteAttest(),
                                          agileQuoteSignature()))

    let msg = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "the report envelope carries at most" in msg
    check $MaxTpm2EvidenceBytes in msg
    check $padded.len in msg

  test "a missing or empty artifact is refused by name":
    let b = newBench()
    defer: removeDir(b.dir)
    removeFile(b.signaturePath)
    let missing = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "does not exist" in missing
    check b.signaturePath in missing
    check "driver tpm2" in missing
    writeFile(b.signaturePath, "")
    let empty = driverRefusal(proc () =
      discard acquireQuote(newTpm2Driver(source(b)), agileQuoteQualifying()))
    check "is empty" in empty
    check "driver tpm2" in empty
