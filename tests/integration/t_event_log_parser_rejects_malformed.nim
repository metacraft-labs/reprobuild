## Every byte string this parser will not accept as a TCG event log,
## and the one failure mode it exists to make unspellable.
##
## ## The failure this gate is built against
##
## An event log has no length field, no entry count and no terminator.
## It ends where the buffer ends. That makes one particular bug
## catastrophic and easy to write: a parser that stops at the first
## thing it does not understand, returns the events it managed to read,
## and lets the caller replay those. In the limit it returns NO events,
## the replay produces the reset values, and a comparison against a
## register that is also at its reset value AGREES. A log that could not
## be parsed becomes a log that explains everything.
##
## So the rule is that nothing here degrades. Every refusal is a raised
## ``TcgEventLogError``; no path returns a short log, an empty bank or a
## ``false`` a caller might read as a verdict; a log with no extendable
## entry is refused rather than replayed to a constant; and the
## truncation sweep below checks not only that broken prefixes are
## refused but that the refusal is the ONLY thing that happens to them.
##
## ## The truncation sweep, and why it is not "every prefix fails"
##
## Most prefixes of a log are malformed — they end in the middle of a
## header, a digest or a payload. But a prefix that ends exactly on an
## entry boundary is a perfectly good, shorter log, and a parser that
## refused it would be wrong. The sweep therefore derives the entry
## boundaries from a parse of the whole log and requires:
##
##   * every prefix ending ON a boundary to PARSE, and to yield exactly
##     the entries that fit;
##   * every other prefix to be REFUSED.
##
## That is a stronger statement than either half alone. "All prefixes
## fail" would be satisfied by a parser that refuses everything; "the
## real log parses" would be satisfied by one that refuses nothing. The
## sweep is 7,584 prefixes across the two fixtures and it counts both
## outcomes, so neither degenerate parser survives it.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest
import ./tcg_event_log_vectors

proc le16(v: uint16): string =
  var w = initTpm2Writer("mutate")
  w.writeU16Le(v)
  w.bytes

proc le32(v: uint32): string =
  var w = initTpm2Writer("mutate")
  w.writeU32Le(v)
  w.bytes

proc boundaries(log: string): seq[int] =
  ## The offset at which each entry begins, plus the end of the log.
  let parsed = parseEventLog(log)
  result = @[]
  for e in parsed.events: result.add e.wireOffset
  result.add log.len

template refuses(wanted: string; body: untyped) =
  ## The construct every case here uses: the operation must raise
  ## ``TcgEventLogError``, and the message must NAME the rule that was
  ## broken. Asserting only "it raised" would be satisfied by a parser
  ## that raises for a different reason than the one under test. A
  ## malformed structure usually fails several ways at once, so "it
  ## raised" is nearly free and says almost nothing.
  var raised = false
  try:
    body
  except TcgEventLogError as e:
    raised = true
    if wanted notin e.msg:
      checkpoint("refused, but for the wrong reason: " & e.msg)
    check wanted in e.msg
  check raised

suite "the TCG event log parser refuses what it cannot read":

  test "the real logs parse — the control the refusals below need":
    # Without this every case here is satisfied by a parser that refuses
    # every input, which refuses correctly and reads nothing.
    let agile = parseEventLog(agileLog())
    check agile.format == lfCryptoAgile
    check agile.events.len == 32
    let legacy = parseEventLog(legacyLog())
    check legacy.format == lfLegacy
    check legacy.events.len == 15

  test "an empty log is refused rather than read as a boot that measured nothing":
    refuses "the absence of evidence":
      discard parseEventLog("")

  test "every truncation is refused, and every entry boundary is not":
    var refusedCount = 0
    var acceptedCount = 0
    for (name, log) in [("crypto-agile", agileLog()), ("legacy", legacyLog())]:
      let bounds = boundaries(log)
      for cut in 1 ..< log.len:
        let prefix = log[0 ..< cut]
        if cut in bounds:
          # A prefix that ends on an entry boundary is a shorter log,
          # and it must parse to exactly the entries that fit.
          let parsed = parseEventLog(prefix)
          var expected = 0
          for b in bounds:
            if b < cut: inc expected
          if parsed.events.len != expected:
            checkpoint(name & ": prefix of " & $cut & " bytes yielded " &
                       $parsed.events.len & " entries, expected " & $expected)
          check parsed.events.len == expected
          inc acceptedCount
        else:
          var raised = false
          try:
            discard parseEventLog(prefix)
          except TcgEventLogError:
            raised = true
          if not raised:
            checkpoint(name & ": a " & $cut &
                       "-byte truncation was ACCEPTED as a whole log")
          check raised
          inc refusedCount
    # 6,881 + 703 prefixes, of which 31 + 14 land on a boundary.
    check refusedCount == 7539
    check acceptedCount == 45

  test "a truncation in the middle of the Spec ID header is refused by name":
    # Named separately from the sweep because this is the one place a
    # short read would corrupt EVERY later entry rather than one: the
    # header's algorithm table is what each entry's digest length comes
    # from.
    let log = agileLog()
    let headerEnd = parseEventLog(log).events[1].wireOffset
    refuses "event[0].event needs":
      discard parseEventLog(log[0 ..< headerEnd - 4])

  test "a truncation in the middle of a digest is refused":
    let log = agileLog()
    let second = parseEventLog(log).events[1].wireOffset
    # 12 bytes of entry header, 2 of algorithm id, then a 20-byte SHA-1
    # digest: cut ten bytes into it.
    refuses "digests[0].digest needs":
      discard parseEventLog(log[0 ..< second + 12 + 2 + 10])

  test "bytes appended after a complete log are refused":
    # A log declares no length, so appended bytes are not a "trailing
    # bytes" case the way they are for a TPM2 structure — they are a
    # TRUNCATED FINAL ENTRY, and that is what the refusal says. The
    # distinction is worth pinning because it is the reason
    # `parseEventLog` has no `finish` call: the walk already runs until
    # the buffer is exactly consumed, and anything left over is an entry
    # it could not complete.
    refuses "event[32].pcrIndex":
      discard parseEventLog(agileLog() & "\x00")
    refuses "event[15].pcrIndex":
      discard parseEventLog(legacyLog() & "\xFF\xFF\xFF")

  test "a digest count that disagrees with the digests present is refused":
    let log = agileLog()
    let start = parseEventLog(log).events[1].wireOffset
    # The count sits 8 bytes into the entry. The fixture's entries carry
    # four digests.
    check log[start + 8 ..< start + 12] == le32(4'u32)
    # One too few: the fourth digest's first bytes are then read as the
    # event size, and the walk leaves the structure.
    var short = log
    short[start + 8 ..< start + 12] = le32(3'u32)
    var raisedShort = false
    try:
      discard parseEventLog(short)
    except TcgEventLogError:
      raisedShort = true
    check raisedShort
    # One too many: the event size is read as an algorithm identifier,
    # which the Spec ID Event did not declare.
    var long = log
    long[start + 8 ..< start + 12] = le32(5'u32)
    refuses "Spec ID Event declared":
      discard parseEventLog(long)
    # And zero, which is the shape that would let an entry measure
    # nothing while still occupying the log.
    var none = log
    none[start + 8 ..< start + 12] = le32(0'u32)
    refuses "declares no digests":
      discard parseEventLog(none)

  test "a digest count above the bank bound is refused BY NAME":
    # FOUND BY MUTATION, and the check did not exist before it. Removing
    # the `count > MaxPcrBanks` bound left this gate GREEN, because the
    # "one too many" case above sets the count to 5 — well under the
    # bound — and is caught by the undeclared-algorithm rule instead. A
    # bound nothing tests against is a constant, not a check.
    #
    # Both values are refused even WITHOUT the bound, by running off the
    # end of the buffer; what the bound buys is refusing them for the
    # right reason and before reading 4 billion elements. So the
    # assertion is on the MESSAGE, which is the only thing that
    # distinguishes the two.
    let log = agileLog()
    let start = parseEventLog(log).events[1].wireOffset
    for bad in [17'u32, 0xFFFFFFFF'u32]:
      var raw = log
      raw[start + 8 ..< start + 12] = le32(bad)
      refuses "digests, but a TPM carries at most 16 banks":
        discard parseEventLog(raw)

  test "a Spec ID Event declaring more banks than a TPM has is refused":
    # The same bound one structure up, and it was equally untested.
    let log = agileLog()
    let countAt = 32 + 16 + 4 + 4
    for bad in [17'u32, 0xFFFFFFFF'u32]:
      var raw = log
      raw[countAt ..< countAt + 4] = le32(bad)
      refuses "algorithms, but a TPM carries at most 16 banks":
        discard parseEventLog(raw)

  test "a digest algorithm the Spec ID Event did not declare is refused":
    # An unknown TPM_ALG_ID has no known digest length, so the entries
    # after it cannot be located. Guessing is the under-read.
    let log = agileLog()
    let start = parseEventLog(log).events[1].wireOffset
    check log[start + 12 ..< start + 14] == le16(uint16(TpmAlgSha1))
    var raw = log
    raw[start + 12 ..< start + 14] = le16(0x1234'u16)
    refuses "Spec ID Event declared":
      discard parseEventLog(raw)

  test "one bank appearing twice in one digest list is refused":
    let log = agileLog()
    let start = parseEventLog(log).events[1].wireOffset
    var raw = log
    # The second digest's algorithm id sits after the first digest.
    raw[start + 12 + 2 + 20 ..< start + 12 + 2 + 20 + 2] =
      le16(uint16(TpmAlgSha1))
    refuses "appears twice in one digest list":
      discard parseEventLog(raw)

  test "a PCR index outside the platform's registers is refused":
    for badIndex in [uint32(NumPcrs), 0xFFFFFFFF'u32]:
      block:
        let log = agileLog()
        let start = parseEventLog(log).events[1].wireOffset
        var raw = log
        raw[start ..< start + 4] = le32(badIndex)
        refuses "outside the 24 registers":
          discard parseEventLog(raw)
      block:
        let log = legacyLog()
        var raw = log
        raw[0 ..< 4] = le32(badIndex)
        refuses "outside the 24 registers":
          discard parseEventLog(raw)

  test "a Spec ID Event declaring a wrong digest size is refused":
    # The header and the algorithm registry disagree, and one of them is
    # a lie. Accepting the header's number would walk every entry in the
    # log from an offset that is off by the difference.
    let log = agileLog()
    # The SHA-256 row of the algorithm table: signature(16) +
    # platformClass(4) + 4 version bytes + count(4) = 28 into the
    # payload, which itself starts 32 bytes into the log; SHA-1 is the
    # first row, SHA-256 the second.
    let payloadAt = 32
    let sha256RowAt = payloadAt + 28 + 4
    check log[sha256RowAt ..< sha256RowAt + 2] == le16(uint16(TpmAlgSha256))
    var raw = log
    raw[sha256RowAt + 2 ..< sha256RowAt + 4] = le16(33'u16)
    refuses "disagree":
      discard parseEventLog(raw)

  test "a Spec ID Event declaring no algorithms is refused":
    let log = agileLog()
    let countAt = 32 + 16 + 4 + 4
    check log[countAt ..< countAt + 4] == le32(4'u32)
    var raw = log
    raw[countAt ..< countAt + 4] = le32(0'u32)
    refuses "declares no algorithms":
      discard parseEventLog(raw)

  test "a Spec ID Event with an impossible uintnSize is refused":
    let log = agileLog()
    let uintnAt = 32 + 16 + 4 + 3
    check uint8(log[uintnAt]) == 2'u8
    var raw = log
    raw[uintnAt] = char(7'u8)
    refuses "uintnSize":
      discard parseEventLog(raw)

  test "a Spec ID Event claiming another major version is refused":
    let log = agileLog()
    let majorAt = 32 + 16 + 4 + 1
    check uint8(log[majorAt]) == 2'u8
    var raw = log
    raw[majorAt] = char(3'u8)
    refuses "specVersionMajor":
      discard parseEventLog(raw)

  test "a second Spec ID Event later in the log is refused":
    # Scoping a rule to "the header" is not enough if the header can
    # appear twice and a parser is free to prefer either one: two
    # implementations that disagree about which wins then disagree about
    # what the same bytes mean.
    let log = agileLog()
    let firstEnd = parseEventLog(log).events[1].wireOffset
    let header = log[0 ..< firstEnd]
    # Re-emit the header's payload as a well-formed TCG_PCR_EVENT2.
    let payload = log[32 ..< firstEnd]
    var entry = le32(0'u32) & le32(uint32(EvNoAction)) & le32(4'u32)
    for (alg, size) in [(TpmAlgSha1, 20), (TpmAlgSha256, 32),
                        (TpmAlgSha384, 48), (TpmAlgSha512, 64)]:
      entry.add le16(uint16(alg))
      entry.add repeat('\0', size)
    entry.add le32(uint32(payload.len))
    entry.add payload
    refuses "second Spec ID Event03":
      discard parseEventLog(header & entry & log[firstEnd .. ^1])

  test "an event payload above the ceiling is refused":
    let log = agileLog()
    let start = parseEventLog(log).events[1].wireOffset
    let sizeAt = start + 12 + (2 + 20) + (2 + 32) + (2 + 48) + (2 + 64)
    var raw = log
    raw[sizeAt ..< sizeAt + 4] = le32(0x7FFFFFFF'u32)
    refuses "ceiling":
      discard parseEventLog(raw)

  test "a log of nothing but EV_NO_ACTION refuses to replay":
    # The degenerate case this whole gate is named for. The log PARSES —
    # a Spec ID Event03 header alone is a well-formed log — and the
    # replay must still refuse, because reporting 24 reset values as a
    # successful replay is how a log that explains nothing comes to
    # agree with everything.
    let log = agileLog()
    let headerOnly = parseEventLog(log[0 ..< parseEventLog(log).events[1].wireOffset])
    check headerOnly.events.len == 1
    check headerOnly.events[0].eventType == EvNoAction
    refuses "all EV_NO_ACTION":
      discard replayBank(headerOnly, TpmAlgSha256)

  test "a StartupLocality record is refused rather than silently skipped":
    # Not implemented, and therefore a refusal BY NAME. A StartupLocality
    # record changes PCR 0's RESET VALUE; treating it as an ordinary
    # EV_NO_ACTION would replay PCR 0 from the wrong initial value and
    # produce a mismatch that looks exactly like a tampered log.
    let log = agileLog()
    let boundary = parseEventLog(log).events[1].wireOffset
    var entry = le32(0'u32) & le32(uint32(EvNoAction)) & le32(4'u32)
    for (alg, size) in [(TpmAlgSha1, 20), (TpmAlgSha256, 32),
                        (TpmAlgSha384, 48), (TpmAlgSha512, 64)]:
      entry.add le16(uint16(alg))
      entry.add repeat('\0', size)
    let payload = "StartupLocality\0" & "\x03"
    entry.add le32(uint32(payload.len))
    entry.add payload
    let spliced = parseEventLog(log[0 ..< boundary] & entry &
                                log[boundary .. ^1])
    check spliced.events.len == 33
    refuses "StartupLocality":
      discard replayBank(spliced, TpmAlgSha256)

  test "replaying a bank the log does not carry is refused":
    # Not "returns the reset values", which is the answer that looks
    # like a successful replay of a machine that measured nothing.
    #
    # FOUND BY MUTATION: this case first asked for the substring
    # "carries no sha256", and that was satisfied by the WRONG message.
    # With the bank-presence check deleted the replay walks on and the
    # per-EVENT rule refuses instead, saying the event "carries no
    # sha256 digest" — so the gate stayed green with the check gone.
    # The phrase is now the one only the bank rule can produce. The
    # general shape is worth naming, because it is not specific to this
    # file: a by-name assertion is only as strong as the uniqueness of
    # the name, and a substring two different refusals both satisfy is
    # not a by-name assertion at all.
    let legacy = parseEventLog(legacyLog())
    check banks(legacy) == @[TpmAlgSha1]
    refuses "this log carries no sha256 bank":
      discard replayBank(legacy, TpmAlgSha256)

  test "an entry missing a digest for the requested bank is refused":
    # FOUND BY MUTATION, and there was no case for it before. Both
    # fixtures carry a digest for every declared bank in every entry, so
    # the per-event rule could be deleted and nothing noticed.
    #
    # A log like this is well formed: the TCG shape lets an entry's
    # digest list be shorter than the Spec ID Event's algorithm table,
    # and this parser deliberately allows it rather than requiring
    # equality. What it must NOT do is quietly skip such an entry when
    # replaying the missing bank, because the register would then be
    # short one extend and would be a value the TPM never held.
    let log = agileLog()
    let boundary = parseEventLog(log).events[1].wireOffset
    # An entry carrying SHA-1 and SHA-256 only.
    var entry = le32(0'u32) & le32(uint32(EvAction)) & le32(2'u32)
    for (alg, size) in [(TpmAlgSha1, 20), (TpmAlgSha256, 32)]:
      entry.add le16(uint16(alg))
      entry.add repeat('\x77', size)
    entry.add le32(4'u32)
    entry.add "part"
    let spliced = parseEventLog(log[0 ..< boundary] & entry &
                                log[boundary .. ^1])
    check spliced.events.len == 33
    check spliced.events[1].digests.len == 2
    # The banks it DOES carry replay, so the log is genuinely readable…
    check replayBank(spliced, TpmAlgSha1).extendsApplied == 32
    check replayBank(spliced, TpmAlgSha256).extendsApplied == 32
    # …and the two it does not are refused rather than skipped.
    refuses "carries no sha384 digest":
      discard replayBank(spliced, TpmAlgSha384)
    refuses "carries no sha512 digest":
      discard replayBank(spliced, TpmAlgSha512)

  test "a log with no entries at all is refused rather than replayed":
    # FOUND BY MUTATION, and the guard had no reachable input before it.
    # `parseEventLog` refuses a zero-entry log at the door, so the only
    # way to hold one is to CONSTRUCT it — which is not hypothetical: a
    # default-initialised `TcgEventLog` is what an unset field, a
    # cleared variable or a future caller's early return looks like.
    # Without this case the guard was a constant rather than a check:
    # deleting it, so that a log with no entries replays to 24 reset
    # values, changed nothing anywhere in the suite.
    var empty = TcgEventLog(
      format: lfCryptoAgile,
      specId: TcgSpecIdEvent(algorithms: @[
        TcgAlgorithmSize(alg: TpmAlgSha256, digestSize: 32)]),
      events: @[])
    check empty.events.len == 0
    # …and the BANK rule must not be what refuses, or this case would be
    # asserting a different refusal than the one it names.
    check banks(empty) == @[TpmAlgSha256]
    refuses "the log has no entries":
      discard replayBank(empty, TpmAlgSha256)

  test "replaying under an algorithm this codec cannot hash is refused":
    let log = parseEventLog(agileLog())
    refuses "so the log cannot be folded under it":
      discard replayBank(log, TpmAlgId(0x1234'u16))

  test "an extend with a wrong-length digest or register is refused":
    # The two lengths guard the fold itself: either one being wrong
    # still hashes to something, and that something is a register value
    # indistinguishable from a correct one.
    refuses "the register holds 31":
      discard extendPcr(TpmAlgSha256, repeat('\0', 31), repeat('\0', 32))
    refuses "the event's digest is 20":
      discard extendPcr(TpmAlgSha256, repeat('\0', 32), repeat('\0', 20))

  test "the reset value of a register outside the platform is refused":
    refuses "outside the 24 registers":
      discard initialPcrValue(NumPcrs, 32)
    refuses "outside the 24 registers":
      discard initialPcrValue(-1, 32)
