## A quote, its signature and the log that explains it survive one blob
## — and the blob fits the envelope that has to carry it.
##
## ## What this case is worth
##
## The composite exists so a verifier receives one opaque field and can
## still perform the join: replay the log, recompute the register digest,
## compare it against the digest the TPM signed. If the encoding loses a
## byte of any member that join stops being possible, and it stops being
## possible *silently* — a log that is one byte different replays to
## registers that are entirely different, which reads exactly like a
## tampered machine.
##
## So the round trip is asserted member by member against the pinned
## bytes, and then the join is performed on the decoded members. Three
## things make that more than a self-check:
##
##   1. **The members are real.** The event log is the copy firmware
##      wrote; the attest and the signature are a real ``TPM2_Quote``
##      taken from the same TPM in the same boot. See
##      ``tcg_event_log_vectors`` for the capture recipe and for what
##      those fixtures deliberately do not cover.
##   2. **The framing is asserted by a second encoder.** This file builds
##      the composite's bytes itself, from the format's written
##      description, and requires them to equal what ``composeTpm2Evidence``
##      produces. A round trip through one implementation proves that the
##      implementation agrees with itself, which it would do just as
##      happily if the framing were wrong; two encoders that agree is a
##      statement about the format.
##   3. **The join has a negative control.** A composite carrying a
##      different machine's log must NOT explain the quote. Without it
##      "the log explains the quote" is satisfied by a function that
##      answers yes.
##
## ## The size claim is measured, not assumed
##
## The report envelope bounds ``evidence`` at ``MaxEvidenceBase64``
## base64 characters. This file measures the real composite against that
## bound rather than asserting it fits, and it measures the bound itself
## against ``std/base64`` rather than against the arithmetic that derived
## it.
##
## ## Mocking
##
## None. Real firmware bytes, a real signed quote, real digests.

import std/[base64, strutils, unittest]

import repro_attest
import ./tcg_event_log_vectors
import ./tpm2_evidence_framing

proc goodMembers(): seq[(uint32, string)] =
  @[(1'u32, agileQuoteAttest()),
    (2'u32, agileQuoteSignature()),
    (3'u32, agileLog())]

suite "the tpm2 evidence composite round-trips and joins up":

  setup:
    let evidence = Tpm2Evidence(
      attestBytes: agileQuoteAttest(),
      signatureBytes: agileQuoteSignature(),
      eventLogBytes: agileLog())
    let blob = composeTpm2Evidence(evidence)

  test "the composite equals a second encoder's bytes, exactly":
    # The load-bearing case for everything below: if this file's encoder
    # and the library's agree byte for byte, then every malformed input
    # the negative gate builds is a mutation of the real format rather
    # than of one implementation's idea of it.
    let independent = frame(Tpm2EvidenceSchema, 3, goodMembers())
    if blob != independent:
      checkpoint("composed " & $blob.len & " bytes, this file framed " &
                 $independent.len)
      checkpoint("composed  : " & hexOf(blob[0 .. min(63, blob.high)]))
      checkpoint("framed    : " &
                 hexOf(independent[0 .. min(63, independent.high)]))
    check blob == independent

  test "the version tag is in the BYTES, not only in a constant":
    # A format that versions itself inside the blob has to have the
    # version inside the blob. Asserting the constant would assert that
    # the constant is spelled the way it is spelled.
    check blob.len > 4 + Tpm2EvidenceSchema.len
    check blob[0 .. 3] == be32(uint32(Tpm2EvidenceSchema.len))
    check blob[4 ..< 4 + Tpm2EvidenceSchema.len] == Tpm2EvidenceSchema
    check Tpm2EvidenceSchema == "reproos.tpm2-evidence.v1"

  test "compose then parse returns every member byte for byte":
    let back = parseTpm2Evidence(blob)
    check back.attestBytes == agileQuoteAttest()
    check back.signatureBytes == agileQuoteSignature()
    check back.eventLogBytes == agileLog()
    check back == evidence
    # And re-composing the parsed value reproduces the same bytes, so
    # the encoding is a function of the members and not of anything the
    # first pass happened to be holding.
    check composeTpm2Evidence(back) == blob

  test "the decoded members are the structures they claim to be":
    let back = parseTpm2Evidence(blob)
    let q = tpm2EvidenceQuote(back)
    # The signature covers the attest bytes as they arrived, so the
    # composite must preserve them rather than a re-serialisation.
    check q.attestBytes == agileQuoteAttest()
    check q.attestBytes == serializeAttest(q.attest)
    check q.signatureBytes == agileQuoteSignature()
    check q.signature.kind == tskEcc
    check hexOf(q.qualifyingData) == AgileQuoteQualifyingHex

    let log = tpm2EvidenceLog(back)
    check log.format == lfCryptoAgile
    check log.events.len == 32
    check banks(log) == @[TpmAlgSha1, TpmAlgSha256, TpmAlgSha384, TpmAlgSha512]

  test "the log inside the composite explains the quote inside it":
    # The join the whole format exists to make possible: replaying the
    # carried log reproduces the register digest the carried quote was
    # SIGNED over.
    check logExplainsQuote(parseTpm2Evidence(blob))

    # And the registers are the TPM's own, not merely self-consistent.
    let bank = replayBank(tpm2EvidenceLog(parseTpm2Evidence(blob)),
                          TpmAlgSha256)
    for i in 0 ..< NumPcrs:
      check hexOf(bank.pcrs[i].value) == AgilePcrsSha256[i]

  test "a composite carrying another machine's log does NOT explain it":
    # The negative control. `logExplainsQuote` returning true above says
    # nothing unless it can return false — or refuse — for a log that
    # does not describe this boot. The legacy fixture is a different
    # machine, a different firmware and a SHA-1-only TPM, so the refusal
    # names the missing bank rather than answering.
    let foreign = Tpm2Evidence(
      attestBytes: agileQuoteAttest(),
      signatureBytes: agileQuoteSignature(),
      eventLogBytes: legacyLog())
    let round = parseTpm2Evidence(composeTpm2Evidence(foreign))
    check round.eventLogBytes == legacyLog()
    expect Tpm2EvidenceError:
      discard logExplainsQuote(round)
    try:
      discard logExplainsQuote(round)
    except Tpm2EvidenceError as e:
      check "carries no sha256 bank" in e.msg

  test "a composite whose log was ALTERED answers FALSE, not merely refuses":
    # The case above is a refusal — a log that CANNOT answer. This is the
    # other half, and it is here because without it this gate had no
    # input on which `logExplainsQuote` returns FALSE: a version that
    # answered TRUE for every log it could read passed every other case
    # in this file. That was measured by mutating it, not suspected.
    #
    # One flipped bit in one real measurement's SHA-256 digest. The log
    # still parses and still replays; it lands on a register the TPM
    # never held.
    let whole = parseEventLog(agileLog())
    check whole.events.len > 1
    let sha256DigestAt = whole.events[1].wireOffset + 12 + 2 + 20 + 2
    var altered = agileLog()
    altered[sha256DigestAt] = char(uint8(altered[sha256DigestAt]) xor 0x01'u8)
    check altered != agileLog()

    let tampered = parseTpm2Evidence(composeTpm2Evidence(Tpm2Evidence(
      attestBytes: agileQuoteAttest(),
      signatureBytes: agileQuoteSignature(),
      eventLogBytes: altered)))
    check tampered.eventLogBytes == altered
    check not logExplainsQuote(tampered)

    # The positive control in the same case, so "answers FALSE" cannot be
    # satisfied by a function that answers FALSE for everything.
    check logExplainsQuote(parseTpm2Evidence(blob))

  test "the register bitmap is pinned BY VALUE, on asymmetric selections":
    # The round trip below is necessary and not sufficient, measured
    # rather than assumed: `DefaultQuotedPcrs` fills a whole byte, so a
    # bitmap packed with the bits the other way round produces the
    # IDENTICAL byte and survives any round trip through `selectedPcrs`.
    # These selections do not fill a byte, so they see it.
    check pcrSelection(TpmAlgSha256, [0]).selections[0].select ==
          "\x01\x00\x00"
    check pcrSelection(TpmAlgSha256, [7]).selections[0].select ==
          "\x80\x00\x00"
    check pcrSelection(TpmAlgSha256, [11]).selections[0].select ==
          "\x00\x08\x00"
    check pcrSelection(TpmAlgSha256, [23]).selections[0].select ==
          "\x00\x00\x80"
    check pcrSelection(TpmAlgSha256, [0, 3, 11]).selections[0].select ==
          "\x09\x08\x00"
    check pcrSelection(TpmAlgSha256, DefaultQuotedPcrs).selections[0].select ==
          "\xFF\x00\x00"
    var got: seq[int] = @[]
    for e in selectedPcrs(pcrSelection(TpmAlgSha256, [0, 3, 11])):
      got.add e.index
    check got == @[0, 3, 11]

  test "a selection the platform cannot hold is refused":
    var empty: seq[int] = @[]
    expect Tpm2CodecError: discard pcrSelection(TpmAlgSha256, [24])
    expect Tpm2CodecError: discard pcrSelection(TpmAlgSha256, [-1])
    expect Tpm2CodecError: discard pcrSelection(TpmAlgSha256, [0, 0])
    expect Tpm2CodecError: discard pcrSelection(TpmAlgSha256, empty)

  test "the quoted PCR selection round-trips through its own bitmap":
    # `pcrSelection` is the inverse of `selectedPcrs` and the driver's
    # configuration is built with it, so a bitmap packed the other way
    # round would configure a driver to check a selection no quote has.
    let sel = pcrSelection(TpmAlgSha256, DefaultQuotedPcrs)
    var indices: seq[int] = @[]
    for entry in selectedPcrs(sel):
      check entry.bank == TpmAlgSha256
      indices.add entry.index
    check indices == @DefaultQuotedPcrs
    # The real quote selects exactly this.
    let q = tpm2EvidenceQuote(parseTpm2Evidence(blob))
    check selectedPcrs(q.attest.quote.pcrSelect) == selectedPcrs(sel)

suite "the composite fits the envelope that has to carry it":

  setup:
    let evidence = Tpm2Evidence(
      attestBytes: agileQuoteAttest(),
      signatureBytes: agileQuoteSignature(),
      eventLogBytes: agileLog())
    let blob = composeTpm2Evidence(evidence)

  test "the raw bound is what the envelope's base64 bound means":
    # Measured against an encoder rather than derived from the same
    # arithmetic twice: N raw bytes become 4*ceil(N/3) base64
    # characters, so the largest composite that fits is the one whose
    # encoding is exactly the cap, and one byte more must exceed it.
    check MaxTpm2EvidenceBytes == (MaxEvidenceBase64 div 4) * 3
    check encode(newString(MaxTpm2EvidenceBytes)).len == MaxEvidenceBase64
    check encode(newString(MaxTpm2EvidenceBytes + 1)).len > MaxEvidenceBase64

  test "the measured composite, and the margin":
    # The framing is 4 + len(schema) + 4 for the header and 8 per member.
    let framingBytes = 4 + Tpm2EvidenceSchema.len + 4 + 3 * 8
    check blob.len == framingBytes + agileQuoteAttest().len +
                      agileQuoteSignature().len + agileLog().len
    checkpoint("composite            " & $blob.len & " bytes")
    checkpoint("  framing            " & $framingBytes)
    checkpoint("  attest             " & $agileQuoteAttest().len)
    checkpoint("  signature          " & $agileQuoteSignature().len)
    checkpoint("  event log          " & $agileLog().len)
    checkpoint("envelope raw bound   " & $MaxTpm2EvidenceBytes)
    checkpoint("margin               " & $(MaxTpm2EvidenceBytes - blob.len))
    checkpoint("base64 characters    " & $encode(blob).len & " of " &
               $MaxEvidenceBase64)
    check blob.len < MaxTpm2EvidenceBytes
    check encode(blob).len <= MaxEvidenceBase64
    # Pinned, because a framing that quietly grew per member is a change
    # worth seeing rather than absorbing into a margin.
    check blob.len == 7187

  test "the composite survives a real report envelope, end to end":
    # The bound exists because the composite has to travel inside a
    # ``reproos.attestation-report.v1``. Asserting the arithmetic says the
    # number is right; this case says the transport works — base64 into a
    # real envelope, the envelope rendered to its canonical bytes, parsed
    # back by the strict parser, the evidence decoded, and the result
    # still a composite whose log still explains its own quote.
    #
    # It does NOT claim the report is ACCEPTABLE, and the last assertion
    # makes that explicit rather than leaving it to be assumed. The
    # envelope's ``reportData`` is derived from the challenge; the pinned
    # quote's ``qualifyingData`` is 64 bytes drawn from the capture host's
    # /dev/urandom long before any challenge existed. They disagree, which
    # is precisely the failure a verifier is there to catch — and a case
    # that quietly produced an acceptable-looking report from a quote that
    # binds something else would be teaching the wrong lesson.
    let report = attestationReport(
      abTpm2,
      "2026-01-01T00:00:00Z",
      bytesToHex("a-32-byte-freshness-nonce-value!"),
      ReportBindings(purpose: bpAttest, ephemeralPub: ""),
      blob,
      UnverifiedClaims(
        unverifiedGeneration: "gate",
        unverifiedConfigFingerprint: "gate",
        unverifiedVerityRootHash: repeat('0', 64)))
    let document = renderAttestationReport(report)
    let back = parseAttestationReport(document, "the round-trip gate")
    check back.tier == atTpm
    check back.backend == abTpm2

    let carried = base64.decode(back.evidence)
    check carried == blob
    check parseTpm2Evidence(carried) == evidence
    check logExplainsQuote(parseTpm2Evidence(carried))

    checkpoint("envelope document   " & $document.len & " bytes")
    checkpoint("evidence base64     " & $back.evidence.len & " of " &
               $MaxEvidenceBase64)
    check back.evidence.len <= MaxEvidenceBase64

    # The honest negative: this evidence answers a different question.
    check back.reportData !=
          hexOf(tpm2EvidenceQuote(parseTpm2Evidence(carried)).qualifyingData)

  test "how much room the event log has, measured from this log's own shape":
    # The log is the member that grows: firmware measures every UEFI
    # variable it consults, and on a machine with signature databases
    # enrolled those events are the bulk of it. The headroom is exact —
    # everything else in the composite is fixed-size — and the per-event
    # cost is measured from the entries this log actually carries rather
    # than recalled.
    let headroom = MaxTpm2EvidenceBytes - (blob.len - agileLog().len)
    checkpoint("event log headroom   " & $headroom & " bytes (" &
               $(headroom div agileLog().len) & "x this log)")

    let log = tpm2EvidenceLog(parseTpm2Evidence(blob))
    # A crypto-agile entry costs a fixed header plus its payload. Derive
    # the fixed part from consecutive entries rather than asserting it:
    # pcrIndex+eventType+digestCount (12) + four (alg,digest) pairs +
    # eventSize (4).
    var overheads: seq[int] = @[]
    for i in 0 ..< log.events.len - 1:
      let span = log.events[i + 1].wireOffset - log.events[i].wireOffset
      overheads.add span - log.events[i].data.len
    var fixed = overheads[1]
    for o in overheads[1 .. ^1]:
      # Entry 0 is the Spec ID header, which carries one SHA-1 digest
      # rather than the four banks, so it is excluded.
      check o == fixed
    checkpoint("per-entry overhead   " & $fixed & " bytes (4 banks)")
    checkpoint("so a variable event carrying an N-byte signature list " &
               "costs N + " & $fixed)
    # Four banks: 12 + (2+20) + (2+32) + (2+48) + (2+64) + 4.
    check fixed == 12 + 22 + 34 + 50 + 66 + 4

    # The entries this firmware wrote for the signature databases are
    # present and EMPTY — no keys are enrolled in the capture — which is
    # exactly why the headroom above is the number that matters.
    var variableEvents = 0
    var variablePayload = 0
    for e in log.events:
      if e.eventType == EvEfiVariableDriverConfig:
        inc variableEvents
        variablePayload += e.data.len
    check variableEvents > 0
    checkpoint("variable-config events " & $variableEvents & ", " &
               $variablePayload & " bytes of payload between them")
    # The headroom swallows a signature database two orders of magnitude
    # larger than anything in this capture.
    check headroom > 700_000
