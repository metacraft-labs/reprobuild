## Oversized bodies and burst traffic are refused or limited, without the
## daemon failing — and it still serves valid requests afterwards.
##
## ## The clause that matters
##
## Every case below ends the same way: a full challenge-to-report
## exchange succeeds *after* the abuse. That is the whole point of the
## gate. A daemon that answers 413 and then dies has refused the request
## and lost the machine, and a test that only checked the status code
## would call that a pass. So the abuse and the recovery are asserted
## together, in one connectionless sequence against one long-lived
## server, and the final ``joinThread`` in the harness is what turns "the
## accept loop is still running" into something measured rather than
## assumed: a loop that had died would already have been joined, and one
## that had wedged would never join at all.
##
## ## The bounds, and where each is enforced
##
## The refusals happen at different points in the read, and the gate
## separates them because they protect against different things:
##
##   * an oversized ``Content-Length`` is refused **before the body is
##     read**, so the bytes never arrive;
##   * a request line or header block over its bound is refused while it
##     is being consumed, so an unterminated one costs the bound and not
##     memory;
##   * a chunked body is refused outright, because its size is not known
##     until it has arrived;
##   * a caller that connects and says nothing, or dribbles, is dropped
##     by the two clocks rather than holding the single-threaded loop.
##
## ## Rate limiting, and why the two-bucket logic is exercised separately
##
## Every connection in this test binary arrives from ``127.0.0.1``, so
## over a socket there is only ever one client and the per-client bucket
## and the global one refuse at the same moment. Address diversity is
## therefore driven directly against ``RateLimiter``, with the clock
## passed in — a pure function with synthetic client names, which is the
## honest way to test a property the loopback cannot express, and needs
## nothing stubbed.
##
## ## What this gate does not prove
##
## It does not establish a throughput figure, and it is not a load test.
## It says nothing about behaviour under an attacker with many source
## addresses beyond what the limiter's own logic guarantees, and nothing
## about kernel-level exhaustion — a listen backlog filled by a SYN flood
## is not something a userspace daemon can answer.
##
## ## Mocking
##
## None. Real sockets, real malformed bytes, and the limiter's clock is a
## parameter rather than an injected fake.

import std/[json, nativesockets, net, os, posix, strutils, times, unittest]

import repro_attest
import repro_attest_agent

include attestation_agent_harness

proc stillServes(port: Port): bool =
  ## The clause. A full exchange — challenge in, schema-valid envelope
  ## out, with the 64 bytes recomputed here — not merely a 200.
  let response = get(port, "/attestation?challenge=" & ChallengeA)
  if response.status != 200: return false
  let report =
    try:
      parseAttestationReport(response.body, "after abuse")
    except CatchableError:
      return false
  report.reportData == reportDataHexFor(
    ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeA) and
    report.bindsChallenge(ChallengeA)

suite "attestation agent — abuse bounds":

  test "an oversized declared body is refused before the body is read":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    # Declared far over the bound, and NOT sent. If the server were
    # reading before checking, it would block here until its read clock
    # expired and answer nothing.
    let started = epochTime()
    var payload = "POST /provision HTTP/1.1\r\nHost: x\r\n"
    payload.add "Content-Type: application/json\r\n"
    payload.add "Content-Length: " & $(AbuseMaxBodyBytes * 64) & "\r\n\r\n"
    let refused = parseRawResponse(rawExchange(h.port, payload))
    let elapsed = epochTime() - started

    check refused.status == 413
    check $AbuseMaxBodyBytes in refused.body
    # Refused promptly rather than after waiting for a body that was
    # never coming: the read timeout is the floor a "read first, check
    # later" implementation could not beat.
    check elapsed < float(AbuseReadTimeoutMs) / 1000.0

    # And with the body actually sent, the answer is the same and the
    # daemon is unharmed.
    var withBody = "POST /provision HTTP/1.1\r\nHost: x\r\n"
    withBody.add "Content-Type: application/json\r\n"
    withBody.add "Content-Length: " & $(AbuseMaxBodyBytes * 4) & "\r\n\r\n"
    withBody.add repeat('A', AbuseMaxBodyBytes * 4)
    check parseRawResponse(rawExchange(h.port, withBody)).status == 413

    check stillServes(h.port)

  test "a body inside the bound is read, so the bound is a bound":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    # The positive polarity of the case above. A refusal that fired on
    # every body would pass that test and be useless.
    let ok = post(h.port, "/provision",
      $(%*{"ephemeralPub": repeat("cd", 32), "challenge": ChallengeA,
           "wrappedSecret": "c2VjcmV0"}))
    check ok.status == 404          # no such session — but the body was read
    check "key agreement" in ok.body
    check stillServes(h.port)

  test "an oversized request line and header block are refused":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    let longTarget = "/health?x=" & repeat('q', AbuseMaxRequestLineBytes * 2)
    let tooLong = parseRawResponse(rawExchange(h.port,
      "GET " & longTarget & " HTTP/1.1\r\nHost: x\r\n\r\n"))
    check tooLong.status == 414

    var manyHeaders = "GET /health HTTP/1.1\r\nHost: x\r\n"
    for i in 0 .. AbuseMaxHeaderCount + 4:
      manyHeaders.add "X-Pad-" & $i & ": v\r\n"
    manyHeaders.add "\r\n"
    check parseRawResponse(rawExchange(h.port, manyHeaders)).status == 431

    var fatHeader = "GET /health HTTP/1.1\r\nHost: x\r\n"
    fatHeader.add "X-Pad: " & repeat('z', AbuseMaxHeaderBytes * 2) & "\r\n\r\n"
    check parseRawResponse(rawExchange(h.port, fatHeader)).status == 431

    # The AGGREGATE block bound, which is a third bound and not either of
    # the two above: every line here is comfortably inside the per-line
    # limit and there are fewer of them than the count allows, so only
    # their sum can refuse this. A thousand short headers costs what one
    # long one does, and a surface bounded per line has not bounded that.
    var manyMedium = "GET /health HTTP/1.1\r\nHost: x\r\n"
    let fieldLen = AbuseMaxHeaderBytes div 4
    for i in 0 ..< AbuseMaxHeaderCount - 2:
      manyMedium.add "X-M" & $i & ": " & repeat('m', fieldLen) & "\r\n"
    manyMedium.add "\r\n"
    check fieldLen < AbuseMaxHeaderBytes          # each line is inside
    check (AbuseMaxHeaderCount - 2) < AbuseMaxHeaderCount   # so is the count
    check parseRawResponse(rawExchange(h.port, manyMedium)).status == 431

    check stillServes(h.port)

  test "a chunked body is refused, its size being unknowable in advance":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    var chunked = "POST /provision HTTP/1.1\r\nHost: x\r\n"
    chunked.add "Transfer-Encoding: chunked\r\n\r\n"
    let refused = parseRawResponse(rawExchange(h.port, chunked))
    check refused.status == 411
    check "Content-Length" in refused.body
    check stillServes(h.port)

  test "a silent client and a dribbling one are dropped, not tolerated":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    # Connect and say nothing. The read clock ends it.
    block:
      let s = newSocket(buffered = false)
      s.connect("127.0.0.1", h.port)
      sleep(AbuseReadTimeoutMs + 200)
      try: s.close()
      except CatchableError: discard

    # Send a request line that never terminates, one byte at a time,
    # refreshing the read window each time. The connection deadline is
    # what stops this, and it does not reset.
    block:
      let started = epochTime()
      let s = newSocket(buffered = false)
      s.connect("127.0.0.1", h.port)
      check clientSend(s, "GET /health HT")
      var i = 0
      while epochTime() - started <
            float(AbuseConnectionDeadlineMs) / 1000.0 * 3.0:
        if not clientSend(s, "T"):
          break
        sleep(AbuseReadTimeoutMs div 3)
        inc i
      try: s.close()
      except CatchableError: discard
      # Two bounds, and the upper one is the case.
      #
      # The lower says the connection really did outlive several read
      # windows, so this is about the deadline and not the read timeout.
      # The upper says the daemon CUT IT OFF: the loop would run to
      # completion if nothing ever stopped it, and it does not, because
      # the write fails once the server has closed. Without the second
      # bound this check passes whether or not the connection deadline
      # exists at all, which is the shape of a check that cannot fail.
      let rounds = int(float(AbuseConnectionDeadlineMs) / 1000.0 * 3.0 /
                       (float(AbuseReadTimeoutMs div 3) / 1000.0))
      check i > 3
      check i < rounds

    check stillServes(h.port)

  test "a client that hangs up before reading its answer does not wedge it":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    # A complete, valid request, and then the socket is closed without
    # reading a byte of the response. The daemon is left writing to a
    # peer that is gone, which is the cheapest thing an attacker can do
    # and — before this was measured — the most expensive: the write
    # never completes and never fails, and a single-threaded accept loop
    # spins at 100% of a core forever.
    for i in 0 ..< 8:
      let s = newSocket(buffered = false)
      s.connect("127.0.0.1", h.port)
      discard clientSend(s, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
      try: s.close()
      except CatchableError: discard

    # Bounded in TIME, not just in outcome: a daemon that survived by
    # spinning would still answer eventually, and this is the difference.
    let started = epochTime()
    check stillServes(h.port)
    check epochTime() - started < float(AbuseConnectionDeadlineMs) / 1000.0

  test "a peer that vanishes mid-response does not wedge the daemon":
    # The case above closes before reading a SMALL response, and a small
    # response fits in the socket buffer whole: the write succeeds, the
    # reset arrives afterwards, and nothing is ever attempted twice. That
    # is not the dangerous shape.
    #
    # This is. The response is about a megabyte -- sixteen bundled
    # certificates, which is what the envelope's own bound allows and
    # what a real confidential-computing instance sends -- and the peer
    # is gone with a shrunken receive buffer. The write therefore
    # completes PARTIALLY and then fails, and that is the condition under
    # which `std/net`'s string `send` loops forever: it retries until
    # every byte is written, and reports the failure through a path that
    # swallows exactly the disconnection errors meaning no byte ever
    # will be.
    var l = abuseLimits()
    l.rateCapacity = 10_000.0
    l.rateRefillPerSecond = 10_000.0
    l.perClientCapacity = 10_000.0
    l.perClientRefillPerSecond = 10_000.0
    var agent = newAttestationAgent(driver = newBigChainDriver(),
      identity = sampleIdentity())
    var h = startHarness(agent, l)
    defer: stopHarness(h)

    for i in 0 ..< 4:
      let s = newSocket(buffered = false)
      # A small receive window, so the sender cannot empty its own buffer
      # into ours and must block partway through.
      s.getFd().setSockOptInt(cint(SOL_SOCKET), cint(SO_RCVBUF), 2048)
      s.connect("127.0.0.1", h.port)
      discard clientSend(s,
        "GET /attestation?challenge=" & ChallengeA & " HTTP/1.1\r\n" &
        "Host: x\r\n\r\n")
      try: s.close()
      except CatchableError: discard

    # Bounded in TIME. A daemon spinning on an unfinishable write answers
    # nothing, ever; one that gave up per the connection deadline answers
    # promptly. Four abandoned connections may each cost up to a deadline,
    # so the budget is generous -- but it is finite, and an unbounded
    # spin is not.
    let started = epochTime()
    check stillServes(h.port)
    let elapsed = epochTime() - started
    check elapsed < float(AbuseConnectionDeadlineMs) / 1000.0 * 6.0

  test "garbage and empty connections do not end the daemon":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    discard rawExchange(h.port, "")
    discard rawExchange(h.port, "\x00\x01\x02\xff\xfe not http at all\r\n\r\n")
    discard rawExchange(h.port, "GET\r\n\r\n")
    discard rawExchange(h.port, "GET /health\r\n\r\n")
    discard rawExchange(h.port, "GET /health HTTP/1.1\r\nnocolon\r\n\r\n")
    discard rawExchange(h.port,
      "GET /health HTTP/1.1\r\nContent-Length: banana\r\n\r\n")
    discard rawExchange(h.port,
      "POST /health HTTP/1.1\r\nContent-Length: -5\r\n\r\n")
    discard rawExchange(h.port, "BREW /health HTTP/1.1\r\n\r\n")

    check stillServes(h.port)

  test "the strict parsers refuse rather than guess, and say so":
    # The catalogue case below sends all of these and discards what comes
    # back, which shows the daemon survives them and nothing at all about
    # whether they were refused. Each one is a place where a lenient
    # reader would believe something nobody said, so the STATUS is the
    # claim here.
    var l = abuseLimits()
    l.rateCapacity = 40_000.0
    l.rateRefillPerSecond = 40_000.0
    l.perClientCapacity = 40_000.0
    l.perClientRefillPerSecond = 40_000.0
    var h = startHarness(sampleAgent(), l)
    defer: stopHarness(h)

    # A repeated query parameter: there is no rule saying which wins, so
    # there is no answer that is not a guess.
    let repeated = get(h.port,
      "/attestation?challenge=" & ChallengeA & "&challenge=" & ChallengeB)
    check repeated.status == 400
    check "repeats" in repeated.body

    # Percent-encoding is refused rather than decoded. Every value here
    # is hex or a fixed word, so a decoder would exist only to be wrong.
    let encoded = get(h.port, "/attestation?challenge=%41%42")
    check encoded.status == 400
    check "percent-encoded" in encoded.body

    # An unknown query parameter, and an unknown body field.
    check get(h.port,
      "/attestation?challenge=" & ChallengeA & "&novel=1").status == 400
    let unknownField = post(h.port, "/key-agreement",
      $(%*{"challenge": ChallengeA, "novel": "1"}))
    check unknownField.status == 400
    check "unknown field" in unknownField.body

    # A body that is not JSON, and one that is JSON but not an object.
    check post(h.port, "/key-agreement", "not json").status == 400
    check post(h.port, "/key-agreement", "[1,2,3]").status == 400
    # A field of the right name and the wrong type.
    check post(h.port, "/key-agreement", $(%*{"challenge": 17})).status == 400

    # The positive polarity for every refusal above: the same endpoints
    # answer a well-formed request.
    check get(h.port, "/attestation?challenge=" & ChallengeA &
      "&purpose=attest").status == 200
    check post(h.port, "/key-agreement",
      $(%*{"challenge": ChallengeA})).status == 200
    check stillServes(h.port)

  test "a response is uncacheable and ends its connection, as it says":
    # Two header values that are load-bearing rather than decorative. The
    # connection is closed after one request BECAUSE a pre-authentication
    # caller holding one open holds the single-threaded loop, so a
    # response advertising keep-alive would be a lie a client acts on;
    # and a report is an answer to one nonce, so an intermediary that
    # cached it would serve a stale answer to a fresh challenge.
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    let raw = get(h.port, "/health").raw
    check "Connection: close" in raw
    check "keep-alive" notin raw
    check "Cache-Control: no-store" in raw
    check "max-age" notin raw

  test "a burst is limited rather than served, and service returns":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    var admitted = 0
    var refused = 0
    for i in 0 ..< 60:
      let r = get(h.port, "/health")
      if r.status == 200: inc admitted
      elif r.status == 429: inc refused

    # Capacity is 20 cheap units and refill is 2 per second, so a burst
    # that takes well under a second admits about the capacity and no
    # more. The bounds are loose enough not to be a timing assertion and
    # tight enough that "no limiting at all" fails.
    check admitted >= 15
    check admitted <= 30
    check refused >= 20
    check admitted + refused == 60

    # Refill is real: after enough seconds the bucket has tokens again
    # and a full attestation exchange — cost 10 — succeeds.
    sleep(6_000)
    check stillServes(h.port)

  test "a quote costs more than a probe, so probes cannot exhaust the device":
    var h = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h)

    # Two quotes spend this client's whole 20-unit share; the third is
    # refused, and the refusal names the per-client bucket rather than
    # the machine being busy.
    check get(h.port, "/attestation?challenge=" & ChallengeA).status == 200
    check get(h.port, "/attestation?challenge=" & ChallengeB).status == 200
    let third = get(h.port, "/attestation?challenge=" & ChallengeA)
    check third.status == 429
    check "this client is asking faster" in third.body

    # The same three requests against the cheap route are all served, so
    # the difference is the cost and not the moment.
    var h2 = startHarness(sampleAgent(), abuseLimits())
    defer: stopHarness(h2)
    check get(h2.port, "/health").status == 200
    check get(h2.port, "/health").status == 200
    check get(h2.port, "/health").status == 200

  test "the limiter charges both buckets, and its table is bounded":
    # Address diversity, driven directly because every socket in this
    # binary arrives from one address. The clock is a parameter, so
    # nothing sleeps and nothing is stubbed.
    # The SHIPPED defaults first. Every other case in this test builds
    # limits of its own, which means none of them says anything about
    # what a deployment actually gets — and a per-client allowance equal
    # to the machine's is decorative, because it drains at the same
    # moment the global one does and so never refuses first.
    let shipped = defaultAgentLimits()
    check shipped.perClientCapacity < shipped.rateCapacity
    check shipped.perClientCapacity * 2.0 <= shipped.rateCapacity
    check shipped.perClientRefillPerSecond < shipped.rateRefillPerSecond
    check shipped.perClientCapacity >= float(CostQuote)

    var l = defaultAgentLimits()
    l.rateCapacity = 40.0
    l.rateRefillPerSecond = 1.0
    l.perClientCapacity = 20.0
    l.perClientRefillPerSecond = 1.0
    l.maxTrackedClients = 4
    var rl = newRateLimiter(l, 0)

    # One client cannot take more than its own share, and the refusal
    # names the bucket that made it.
    check rl.charge("a", 10, 0) == rdAdmitted
    check rl.charge("a", 10, 0) == rdAdmitted
    check rl.charge("a", 10, 0) == rdRefusedClient

    # A second client is still served, which is what makes the per-client
    # bucket load-bearing rather than decorative: had the two buckets
    # shared a capacity, "a" would have drained the global one at the
    # same moment and this would be refused.
    check rl.charge("b", 10, 0) == rdAdmitted
    check rl.charge("b", 10, 0) == rdAdmitted

    # The global bucket is now empty, and that refuses everyone —
    # including a client that has never been seen. This is the half a
    # per-client limiter alone does not have.
    check rl.charge("never-seen", 10, 0) == rdRefusedGlobal

    # A per-client allowance at or above the global one is refused as a
    # configuration error, because it could never be the bucket that
    # refuses first.
    var wide = defaultAgentLimits()
    wide.perClientCapacity = wide.rateCapacity + 1.0
    expect ValueError:
      validateAgentLimits(wide)

    # The table does not grow without bound, whatever the caller does.
    var rl2 = newRateLimiter(l, 0)
    for i in 0 ..< 200:
      discard rl2.charge("client-" & $i, 1, int64(i))
    check rl2.trackedClients <= l.maxTrackedClients

    # Eviction is a SECOND branch, and the bound above holds with or
    # without it — a table that simply refuses to admit anyone new is
    # bounded too. What distinguishes them is whether a new client gets a
    # bucket once the residents have recovered: with eviction, it does
    # and can then be refused per-client; without it, the newcomer is
    # only ever seen by the global bucket. Checking the size alone would
    # not have told those apart.
    var roomy = defaultAgentLimits()
    roomy.rateCapacity = 100_000.0       # the global bucket, out of the way
    roomy.rateRefillPerSecond = 100_000.0
    roomy.perClientCapacity = 10.0
    roomy.perClientRefillPerSecond = 1.0
    roomy.maxTrackedClients = 3
    var rl3 = newRateLimiter(roomy, 0)
    for i in 0 ..< 3:
      check rl3.charge("resident-" & $i, 10, 0) == rdAdmitted
    check rl3.trackedClients == 3

    # Every resident bucket is drained, so there is nothing to evict and
    # the newcomer is admitted on the global bucket alone — repeatedly,
    # because it has no bucket of its own to spend.
    for i in 0 ..< 5:
      check rl3.charge("newcomer", 10, 0) == rdAdmitted
    check rl3.trackedClients == 3

    # Ten seconds on, the residents have refilled to capacity. Now there
    # IS something to evict, the newcomer gets a bucket, and spending it
    # twice is refused BY THAT BUCKET.
    check rl3.charge("newcomer", 10, 10_000) == rdAdmitted
    check rl3.charge("newcomer", 10, 10_000) == rdRefusedClient
    check rl3.trackedClients == 3

    # And refill restores service rather than the first burst being the
    # last traffic ever served.
    check rl.availableGlobalTokens(20_000) > 0.0
    check rl.charge("a", 10, 20_000) == rdAdmitted

  test "everything above, then the daemon is still the same daemon":
    # One server, the whole catalogue of abuse, and a working exchange at
    # each end. Separate from the cases above because those each get a
    # fresh server, and a daemon that survived eight short lives has not
    # been shown to survive one long one.
    # The rate limiter is lifted out of the way here on purpose: this
    # case is about whether the daemon SURVIVES the whole catalogue, and
    # a 429 partway through would end the sequence early and prove less.
    # Limiting is what the two cases above are for.
    var l = abuseLimits()
    l.rateCapacity = 40_000.0
    l.rateRefillPerSecond = 40_000.0
    l.perClientCapacity = 40_000.0
    l.perClientRefillPerSecond = 40_000.0
    var h = startHarness(sampleAgent(), l)
    defer: stopHarness(h)

    check stillServes(h.port)
    let servedBefore = h.server.servedRequests

    for round in 0 ..< 3:
      discard rawExchange(h.port, "GET " & repeat('x', 4_000) & " HTTP/1.1\r\n\r\n")
      discard rawExchange(h.port,
        "POST /provision HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n")
      discard rawExchange(h.port,
        "POST /provision HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
      discard rawExchange(h.port, "\xff\xfe\xfd")
      discard rawExchange(h.port, "")
      discard get(h.port, "/no-such-endpoint")
      discard post(h.port, "/key-agreement", "not json")
      discard post(h.port, "/key-agreement", $(%*{"unknown": "field"}))
      discard get(h.port, "/attestation?challenge=&challenge=" & ChallengeA)
      discard get(h.port, "/attestation?challenge=%41%42")
      check stillServes(h.port)

    check h.server.servedRequests > servedBefore
    check h.server.refusedRequests > 0
