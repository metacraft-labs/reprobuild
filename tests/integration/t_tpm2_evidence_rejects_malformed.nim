## Every way a tpm2 evidence composite can be wrong, refused — and each
## refusal required to NAME the rule it broke.
##
## ## The shape this gate exists to forbid
##
## A parser that catches its own bounds error and returns an empty
## document instead of raising makes every malformed input "parse". The
## composite then carries no members, nothing disagrees with anything,
## and a check over it passes. That is the failure mode attestation code
## has to be built against, because it is indistinguishable from success
## at every layer above it: the report is schema-valid, the verifier
## finds no contradiction, and the machine attests to nothing.
##
## Three properties keep this gate from being satisfied by a parser that
## refuses everything:
##
##   * a **positive control** — the real composite parses and yields its
##     three members;
##   * the truncation sweep asserts the **count** of refusals and that
##     exactly one input is accepted, so "refuse everything" and "accept
##     everything" both fail;
##   * every refusal is matched against a **phrase only its own rule can
##     produce**, so deleting one rule and letting another catch the same
##     input reddens rather than passing.
##
## ## Mocking
##
## None. The well-formed inputs are the real captured bytes; the
## malformed ones are those bytes reframed by ``tpm2_evidence_framing``,
## which is an independent encoder rather than a stand-in for one.

import std/[strutils, unittest]

import repro_attest
import ./tcg_event_log_vectors
import ./tpm2_evidence_framing

proc refusal(body: proc (): void): string =
  ## Run `body`, require a refusal, and return its message so a case can
  ## assert WHICH rule fired. A body that does not raise fails here
  ## rather than returning an empty string a later `in` would quietly
  ## accept.
  try:
    body()
  except Tpm2EvidenceError as e:
    return e.msg
  raise newException(ValueError,
    "expected a Tpm2EvidenceError and the call returned normally")

proc parseRefusal(blob: string): string =
  refusal(proc () = discard parseTpm2Evidence(blob))

proc goodMembers(): seq[(uint32, string)] =
  @[(1'u32, agileQuoteAttest()),
    (2'u32, agileQuoteSignature()),
    (3'u32, agileLog())]

suite "a tpm2 evidence composite is refused unless it is whole":

  setup:
    let blob = frame(Tpm2EvidenceSchema, 3, goodMembers())

  test "the real composite parses — the control every case below needs":
    # Without this, every refusal below is satisfied by a parser that
    # refuses everything, which is not a parser.
    let ev = parseTpm2Evidence(blob)
    check ev.attestBytes == agileQuoteAttest()
    check ev.signatureBytes == agileQuoteSignature()
    check ev.eventLogBytes == agileLog()

  test "an unknown version tag is refused rather than attempted":
    let other = "reproos.tpm2-evidence.v2"
    check other.len == Tpm2EvidenceSchema.len
    let msg = parseRefusal(frame(other, 3, goodMembers()))
    check "this build reads" in msg
    check Tpm2EvidenceSchema in msg

  test "a version tag of a different length is refused too":
    # The equal-length case above could be passed by a comparison that
    # only looked at a prefix; this one could be passed by one that only
    # looked at the length.
    check "this build reads" in
      parseRefusal(frame("reproos.tpm2-evidence.v10", 3, goodMembers()))
    check "this build reads" in
      parseRefusal(frame("reproos.tpm2-evidence.v", 3, goodMembers()))
    check "this build reads" in
      parseRefusal(frame("", 3, goodMembers()))

    # And the refusal's own bound, which no case above reaches. The
    # schema field's length is declared by the document being refused, so
    # quoting it whole would let a hostile blob choose the size of the
    # diagnostic. Pinned BY VALUE: 4096 bytes in, 64 shown, 4032 counted.
    let long = parseRefusal(frame(repeat('Z', 4096), 3, goodMembers()))
    check "this build reads" in long
    check "(and 4032 more bytes)" in long
    check long.len < 400

  test "a schema length that overruns the blob is refused":
    # The length field is read before the bytes it governs, so a
    # declared length larger than the document must be refused by the
    # cursor rather than clamped.
    var overrun = be32(0xFFFF_FFFF'u32)
    overrun.add blob[4 .. ^1]
    check "schema" in parseRefusal(overrun)

  test "every proper prefix is refused and only the whole blob parses":
    # Two-sided on purpose. There is no legitimate shorter composite —
    # the members are all required — so exactly one input in this sweep
    # is acceptable, and the counts say so. "All prefixes fail" alone
    # would be satisfied by a parser that refuses everything.
    var refused = 0
    var accepted = 0
    for n in 0 ..< blob.len:
      try:
        discard parseTpm2Evidence(blob[0 ..< n])
        inc accepted
      except Tpm2EvidenceError:
        inc refused
    check refused == blob.len
    check accepted == 0
    check refused == 7187
    # And the whole thing still parses, in the same sweep.
    discard parseTpm2Evidence(blob)

  test "a truncation inside the HEADER is refused, named":
    # Three distinct positions, because "the header" is three fields.
    check "schema.size" in parseRefusal(blob[0 ..< 2])
    check "field schema needs" in parseRefusal(blob[0 ..< 10])
    check "memberCount" in parseRefusal(blob[0 ..< 4 + Tpm2EvidenceSchema.len + 2])

  test "a truncation inside a MEMBER is refused, named":
    let headerLen = 4 + Tpm2EvidenceSchema.len + 4
    # Inside the first member's tag.
    check "members[0].tag" in parseRefusal(blob[0 ..< headerLen + 2])
    # Inside the first member's size.
    check "members[0].size" in parseRefusal(blob[0 ..< headerLen + 6])
    # Inside the first member's payload.
    check "members[0].attest" in parseRefusal(blob[0 ..< headerLen + 20])
    # Inside the LAST member's payload — the one a lenient reader that
    # stopped when it had enough members would never notice was short.
    check "members[2].eventLog" in parseRefusal(blob[0 ..< blob.len - 1])

  test "a member whose declared length exceeds the bytes present is refused":
    let members = @[(1'u32, agileQuoteAttest()),
                    (2'u32, agileQuoteSignature()),
                    (3'u32, agileLog())]
    var built = frame(Tpm2EvidenceSchema, 3, members)
    # Bump the last member's declared size by one without adding a byte.
    let sizeAt = built.len - agileLog().len - 4
    built[sizeAt ..< sizeAt + 4] = be32(uint32(agileLog().len + 1))
    let msg = parseRefusal(built)
    check "members[2].eventLog needs" in msg
    check "remain" in msg

  test "a member whose declared length is SHORTER than the bytes present is refused":
    # The mirror, and the one a bounds check alone does not catch: every
    # read succeeds and a byte is left over. A composite with anything
    # extra in it is not the composite that was assembled.
    var built = frame(Tpm2EvidenceSchema, 3, goodMembers())
    let sizeAt = built.len - agileLog().len - 4
    built[sizeAt ..< sizeAt + 4] = be32(uint32(agileLog().len - 1))
    check "trailing byte" in parseRefusal(built)

  test "bytes appended to a complete composite are refused":
    check "trailing byte" in parseRefusal(blob & "\x00")
    check "trailing byte" in parseRefusal(blob & agileLog())

  test "a member present twice is refused, and named as a repetition":
    let msg = parseRefusal(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()),
        (1'u32, agileQuoteAttest()),
        (2'u32, agileQuoteSignature())]))
    check "attest member appears twice" in msg

  test "members out of order are refused, and named as an ordering":
    # A different rule from the one above, with a different message, so
    # deleting either is visible.
    let msg = parseRefusal(frame(Tpm2EvidenceSchema, 3,
      @[(2'u32, agileQuoteSignature()),
        (1'u32, agileQuoteAttest()),
        (3'u32, agileLog())]))
    check "members ascend by tag" in msg
    check "appears twice" notin msg

  test "a zero-length member is refused for each member in turn":
    # An empty member is an absent one wearing a present member's tag,
    # and the rule has to hold for all three rather than for whichever
    # one a case happened to pick.
    check "attest member is empty" in parseRefusal(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, ""), (2'u32, agileQuoteSignature()), (3'u32, agileLog())]))
    check "signature member is empty" in parseRefusal(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()), (2'u32, ""), (3'u32, agileLog())]))
    check "eventLog member is empty" in parseRefusal(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()), (2'u32, agileQuoteSignature()), (3'u32, "")]))

  test "an unknown member tag is refused rather than skipped":
    for badTag in [0'u32, 4'u32, 0xFFFF_FFFF'u32]:
      let msg = parseRefusal(frame(Tpm2EvidenceSchema, 3,
        @[(badTag, agileQuoteAttest()),
          (2'u32, agileQuoteSignature()),
          (3'u32, agileLog())]))
      check "which this schema does not define" in msg
      check $badTag in msg

  test "a member count above what the schema defines is refused":
    # The bound is tested ABOVE it — a bound exercised with a value under
    # it is not exercised — and at a value a hostile document would carry.
    let four = parseRefusal(frame(Tpm2EvidenceSchema, 4, goodMembers()))
    check "and this schema defines 3" in four
    let huge = parseRefusal(
      frameWithRawCount(Tpm2EvidenceSchema, 0xFFFF_FFFF'u32, goodMembers()))
    check "and this schema defines 3" in huge
    check "4294967295" in huge
    # And the bound accepts its own edge, so it is a bound rather than a
    # refusal of everything.
    discard parseTpm2Evidence(frame(Tpm2EvidenceSchema, 3, goodMembers()))

  test "a declared count BELOW the members present is refused":
    check "trailing byte" in
      parseRefusal(frame(Tpm2EvidenceSchema, 2, goodMembers()))

  test "a missing member is refused and named":
    let one = parseRefusal(frame(Tpm2EvidenceSchema, 2,
      @[(1'u32, agileQuoteAttest()), (2'u32, agileQuoteSignature())]))
    check "no eventLog member" in one
    let two = parseRefusal(frame(Tpm2EvidenceSchema, 1,
      @[(1'u32, agileQuoteAttest())]))
    check "no signature, eventLog member" in two

  test "a composite with NO MEMBERS does not trivially validate":
    # The headline. A parser that degraded a failure into an empty
    # document would produce exactly this value, and everything above it
    # would agree with everything.
    let msg = parseRefusal(frame(Tpm2EvidenceSchema, 0, @[]))
    check "no attest, signature, eventLog member" in msg
    check "would validate while carrying nothing" in msg

suite "the composer refuses what the parser would refuse":

  test "an empty member is refused on the way OUT as well as in":
    check "attest member is empty" in refusal(proc () =
      discard composeTpm2Evidence(Tpm2Evidence(
        attestBytes: "", signatureBytes: agileQuoteSignature(),
        eventLogBytes: agileLog())))
    check "signature member is empty" in refusal(proc () =
      discard composeTpm2Evidence(Tpm2Evidence(
        attestBytes: agileQuoteAttest(), signatureBytes: "",
        eventLogBytes: agileLog())))
    check "eventLog member is empty" in refusal(proc () =
      discard composeTpm2Evidence(Tpm2Evidence(
        attestBytes: agileQuoteAttest(),
        signatureBytes: agileQuoteSignature(), eventLogBytes: "")))

  test "the envelope's bound is refused from above and accepted at its edge":
    # A bound tested only with a value under it is not tested. The
    # framing is fixed, so the exact event-log length that lands on the
    # bound is computable — and one byte more must refuse.
    let framing = 4 + Tpm2EvidenceSchema.len + 4 + 3 * 8
    let fixed = framing + agileQuoteAttest().len + agileQuoteSignature().len
    let atBound = MaxTpm2EvidenceBytes - fixed
    let edge = composeTpm2Evidence(Tpm2Evidence(
      attestBytes: agileQuoteAttest(),
      signatureBytes: agileQuoteSignature(),
      eventLogBytes: repeat('x', atBound)))
    check edge.len == MaxTpm2EvidenceBytes

    let msg = refusal(proc () =
      discard composeTpm2Evidence(Tpm2Evidence(
        attestBytes: agileQuoteAttest(),
        signatureBytes: agileQuoteSignature(),
        eventLogBytes: repeat('x', atBound + 1))))
    check "the report envelope carries at most" in msg
    check $MaxTpm2EvidenceBytes in msg
    check $(MaxTpm2EvidenceBytes + 1) in msg

suite "a well-framed composite is not a valid one":

  test "framing right, attest bytes wrong — the quote is refused":
    # The framing says nothing about the structures inside it. A
    # composite whose members are the right LENGTH and the wrong BYTES
    # parses as a composite and must still be refused as a quote.
    let ev = parseTpm2Evidence(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, repeat('\x00', agileQuoteAttest().len)),
        (2'u32, agileQuoteSignature()),
        (3'u32, agileLog())]))
    check ev.attestBytes.len == agileQuoteAttest().len
    check "the quote does not decode" in
      refusal(proc () = discard tpm2EvidenceQuote(ev))

  test "framing right, log bytes wrong — the log is refused":
    let ev = parseTpm2Evidence(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()),
        (2'u32, agileQuoteSignature()),
        (3'u32, repeat('\xFF', 64))]))
    check "the event log does not decode" in
      refusal(proc () = discard tpm2EvidenceLog(ev))

  test "a log truncated to a valid SHORTER log still fails the join":
    # The nastiest of the three: the member is a perfectly good event
    # log, the composite is perfectly well framed, and the machine it
    # describes is not the one that signed the quote. Only the join
    # catches it, which is why the framing is not allowed to stand in
    # for the join.
    let whole = parseEventLog(agileLog())
    let cut = whole.events[^1].wireOffset
    check cut > 0 and cut < agileLog().len
    let shorter = agileLog()[0 ..< cut]
    discard parseEventLog(shorter)  # it really is a valid log
    let ev = parseTpm2Evidence(frame(Tpm2EvidenceSchema, 3,
      @[(1'u32, agileQuoteAttest()),
        (2'u32, agileQuoteSignature()),
        (3'u32, shorter)]))
    check not logExplainsQuote(ev)
