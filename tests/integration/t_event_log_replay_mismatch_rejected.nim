## A log with one event altered no longer reproduces the composite, and
## is rejected.
##
## ## What this case is worth, and what it is not
##
## The positive gate says a real log folds to the registers a real TPM
## held. That is necessary and nowhere near sufficient: a replay that
## returned a constant, ignored the log, or compared a value against
## itself would satisfy it just as well as a correct one. What makes the
## replay *useful* is that it must stop agreeing when the log stops
## describing the boot — and "stop agreeing" has to be demonstrated one
## alteration at a time, because an alteration that changes a register
## nobody quoted changes nothing a verifier would notice.
##
## So every case below takes the SAME real log and the SAME real signed
## quote as the positive gate, changes exactly one thing, and requires
## the answer to move. The alterations are the ones an attacker would
## actually reach for:
##
##   * one byte of one digest — the smallest possible lie about what was
##     measured;
##   * an event moved to a different register — the same digests, in the
##     same order, folded somewhere else;
##   * two events transposed — every digest still present, and only the
##     order changed, which is the alteration a set-based replay would
##     miss entirely;
##   * an event deleted, and an event added;
##   * an event's type changed to ``EV_NO_ACTION`` — the alteration that
##     tries to make a measurement *vanish* by exploiting the one rule
##     that says an entry is not extended.
##
## ## Every alteration is checked twice, and that is the point
##
## Each case asserts both that the replayed REGISTER moves and that
## ``explainsQuote`` returns false. Those are different failures: the
## first is about the fold, the second about the composite that a
## verifier compares against a signature. An alteration that moved a
## register the quote does not select would pass the second check while
## failing the first, and one of the cases below is exactly that shape —
## it is here to show the gate can tell them apart rather than to be
## rejected.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest
import ./tcg_event_log_vectors

proc hexOf(s: string): string =
  result = ""
  for c in s: result.add toHex(uint8(c), 2).toLowerAscii

proc le32(v: uint32): string =
  var w = initTpm2Writer("mutate")
  w.writeU32Le(v)
  w.bytes

proc entryBounds(log: string; index: int): (int, int) =
  ## Where entry `index` starts and ends in the raw log. Derived from a
  ## parse rather than from hard-coded offsets, so these cases stay
  ## correct if the fixture is ever recaptured.
  let parsed = parseEventLog(log)
  doAssert index >= 0 and index < parsed.events.len
  let start = parsed.events[index].wireOffset
  let stop =
    if index + 1 < parsed.events.len: parsed.events[index + 1].wireOffset
    else: log.len
  (start, stop)

proc flipByte(s: string; at: int): string =
  result = s
  result[at] = char(uint8(result[at]) xor 0x01'u8)

suite "an altered TCG event log no longer explains the quote":

  setup:
    let baseLog = agileLog()
    let quote = parseQuote(agileQuoteAttest(), agileQuoteSignature())
    let goodLog = parseEventLog(baseLog)
    let goodBank = replayBank(goodLog, TpmAlgSha256)

  test "the unaltered log is accepted — the control every case below needs":
    # Without this, every rejection below could be a replay that rejects
    # everything, which is not a replay.
    check explainsQuote(goodLog, quote)
    for i in 0 ..< NumPcrs:
      check hexOf(goodBank.pcrs[i].value) == AgilePcrsSha256[i]

  test "one flipped bit in one event's SHA-256 digest is rejected":
    # Entry 1 is the first real measurement (EV_S_CRTM_VERSION into PCR
    # 0). Its digest list is SHA-1 then SHA-256; the SHA-256 digest
    # starts 12 bytes (pcrIndex, eventType, count) + 2 (alg) + 20
    # (sha1) + 2 (alg) into the entry.
    let (start, _) = entryBounds(baseLog, 1)
    let sha256DigestAt = start + 12 + 2 + 20 + 2
    let altered = parseEventLog(flipByte(baseLog, sha256DigestAt))
    let bank = replayBank(altered, TpmAlgSha256)
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check not explainsQuote(altered, quote)
    # Nothing else moves: one event, one register.
    for i in 1 ..< NumPcrs:
      check hexOf(bank.pcrs[i].value) == AgilePcrsSha256[i]

  test "one flipped bit in the SHA-1 digest of the same event is rejected":
    # The same alteration one bank over. It must move the SHA-1 replay
    # and must NOT move the SHA-256 one — otherwise the banks are not
    # independent and a digest is being read from the wrong offset.
    let (start, _) = entryBounds(baseLog, 1)
    let sha1DigestAt = start + 12 + 2
    let altered = parseEventLog(flipByte(baseLog, sha1DigestAt))
    let sha1Bank = replayBank(altered, TpmAlgSha1)
    let sha256Bank = replayBank(altered, TpmAlgSha256)
    check hexOf(sha1Bank.pcrs[0].value) != AgilePcrsSha1[0]
    check hexOf(sha256Bank.pcrs[0].value) == AgilePcrsSha256[0]
    # The quote selects the SHA-256 bank, so this alteration is one a
    # quote over SHA-256 cannot see. Saying so is the honest result, and
    # it is what makes the other cases' rejections meaningful.
    check explainsQuote(altered, quote)

  test "an event moved to a different register is rejected":
    # Every digest in the log is still present and still in order. Only
    # the PCRIndex of entry 1 changes, from 0 to 12.
    let (start, _) = entryBounds(baseLog, 1)
    var raw = baseLog
    raw[start ..< start + 4] = le32(12'u32)
    let altered = parseEventLog(raw)
    let bank = replayBank(altered, TpmAlgSha256)
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check bank.pcrs[12].state == prExtended
    check hexOf(bank.pcrs[12].value) != AgilePcrsSha256[12]
    check not explainsQuote(altered, quote)

  test "two events of the same register, transposed, are rejected":
    # The alteration a replay that collected digests into a SET rather
    # than folding them in order would miss completely: the multiset of
    # digests is identical and only their order differs.
    var pcr0Entries: seq[int] = @[]
    for i, e in goodLog.events:
      if e.pcrIndex == 0 and e.eventType != EvNoAction:
        pcr0Entries.add i
    check pcr0Entries.len >= 2
    let a = pcr0Entries[0]
    let b = pcr0Entries[1]
    check b == a + 1  # adjacent, so a straight swap is well-formed
    let (aStart, aStop) = entryBounds(baseLog, a)
    let (bStart, bStop) = entryBounds(baseLog, b)
    check aStop == bStart
    let raw = baseLog[0 ..< aStart] & baseLog[bStart ..< bStop] &
              baseLog[aStart ..< aStop] & baseLog[bStop .. ^1]
    check raw.len == baseLog.len
    let altered = parseEventLog(raw)
    check altered.events.len == goodLog.events.len
    let bank = replayBank(altered, TpmAlgSha256)
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check not explainsQuote(altered, quote)

  test "a deleted event is rejected":
    let (start, stop) = entryBounds(baseLog, 1)
    let raw = baseLog[0 ..< start] & baseLog[stop .. ^1]
    let altered = parseEventLog(raw)
    check altered.events.len == goodLog.events.len - 1
    let bank = replayBank(altered, TpmAlgSha256)
    check bank.extendsApplied == goodBank.extendsApplied - 1
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check not explainsQuote(altered, quote)

  test "a duplicated event is rejected":
    let (start, stop) = entryBounds(baseLog, 1)
    let raw = baseLog[0 ..< stop] & baseLog[start ..< stop] &
              baseLog[stop .. ^1]
    let altered = parseEventLog(raw)
    check altered.events.len == goodLog.events.len + 1
    let bank = replayBank(altered, TpmAlgSha256)
    check bank.extendsApplied == goodBank.extendsApplied + 1
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check not explainsQuote(altered, quote)

  test "retyping a real measurement as EV_NO_ACTION is rejected":
    # The attack the EV_NO_ACTION rule invites: leave the digests
    # exactly where they are and relabel the entry so a replay skips it.
    # The log still parses, still carries every byte it did, and the
    # register no longer reaches the value the TPM signed.
    let (start, _) = entryBounds(baseLog, 1)
    var raw = baseLog
    raw[start + 4 ..< start + 8] = le32(uint32(EvNoAction))
    let altered = parseEventLog(raw)
    check altered.events.len == goodLog.events.len
    check altered.events[1].eventType == EvNoAction
    let bank = replayBank(altered, TpmAlgSha256)
    check bank.extendsApplied == goodBank.extendsApplied - 1
    check hexOf(bank.pcrs[0].value) != AgilePcrsSha256[0]
    check not explainsQuote(altered, quote)

  test "the legacy log rejects the same single-bit alteration":
    # The other wire shape gets the same treatment, because a rejection
    # that only works on the agile path leaves the legacy path unproved.
    let legacy = parseEventLog(legacyLog())
    let good = replayBank(legacy, TpmAlgSha1)
    for i in 0 ..< NumPcrs:
      check hexOf(good.pcrs[i].value) == LegacyPcrsSha1[i]
    let (start, _) = entryBounds(legacyLog(), 0)
    let altered = parseEventLog(flipByte(legacyLog(), start + 8))
    let bank = replayBank(altered, TpmAlgSha1)
    check hexOf(bank.pcrs[altered.events[0].pcrIndex].value) !=
          LegacyPcrsSha1[altered.events[0].pcrIndex]

  test "a quote whose every selected register the log never touched is refused":
    # Fail-closed, and the specific closure that matters: registers the
    # log is silent about hold their reset values, which are the same on
    # every machine. A composite over nothing else would agree with a
    # stored copy of itself forever while saying nothing about any boot,
    # so it is a refusal rather than a verdict.
    # PCRs 10, 11 and 12 in the SHA-256 bank: present in the log's
    # banks, and never extended by it.
    var selection = TpmlPcrSelection(selections: @[
      TpmsPcrSelection(hashAlg: TpmAlgSha256,
                       select: "\x00\x1C\x00")])
    check selectedPcrs(selection).len == 3
    for s in selectedPcrs(selection):
      check s.bank == TpmAlgSha256
      check goodBank.pcrs[s.index].state == prNeverExtended
    var refused = false
    try:
      discard selectedFromReplay(goodLog, selection)
      # Producing the values is fine; it is the VERDICT that must not be
      # reachable. Build a quote-shaped question and ask it.
      var altered = quote
      altered.attest.quote.pcrSelect = selection
      discard explainsQuote(goodLog, altered)
    except TcgEventLogError as e:
      refused = true
      check "extends none of them" in e.msg
    check refused
