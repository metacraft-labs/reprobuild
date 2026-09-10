## A stale or mismatched challenge fails.
##
## ## What "replay" means at an agent, and what it does not
##
## This gate is precise about a distinction that is easy to blur. The
## agent is not the party that decides whether a *report* is a replay —
## it did not mint the challenge, so it cannot know whether the one it is
## being handed is fresh. That verdict belongs to whoever issued it.
##
## What the agent owns is the state it created itself: a key agreement.
## Every ``POST /key-agreement`` mints a private key that lives in memory
## and binds a public key into signed evidence, and that session is
## exactly one thing — usable once, under the challenge it was issued
## with, for a bounded time. Those three are the agent's to enforce, and
## all three are exercised here in both polarities.
##
## Alongside them the gate checks the properties that make a *report*
## unreplayable at all: it answers one challenge and not another, and an
## envelope relabelled with a different challenge is refused rather than
## half-believed.
##
## ## What is deliberately NOT refused, and why the gate says so
##
## ``GET /attestation`` answers a challenge it has already answered. That
## is a decision, not an oversight, and it is asserted here so that
## someone who later "fixes" it has to delete a test that explains why.
## The challenge is the verifier's freshness input; refusing a repeat
## would let anyone who can observe a challenge deny the legitimate
## verifier its answer, while protecting nothing — the party who cares
## whether a report is fresh is the party who chose the nonce.
##
## ## What this gate does not prove
##
## Nothing here verifies evidence. A report that binds the right
## challenge may still be signed by nothing at all — this is the mock
## backend — and establishing that hardware signed those 64 bytes is the
## verifier's work.
##
## ## Mocking
##
## None. The one test that needs a clock in the future passes the time in
## as a parameter, because the endpoint layer takes it as one; nothing is
## stubbed and nothing sleeps.

import std/[json, net, strutils, unittest]

import repro_attest
import repro_attest_agent

include attestation_agent_harness

proc issueKeyAgreement(port: Port; challenge: string): AttestationReport =
  let response = post(port, "/key-agreement",
    $(%*{"challenge": challenge}))
  doAssert response.status == 200, "key agreement refused: " & response.body
  parseAttestationReport(response.body, "key agreement")

proc provisionBody(pub, challenge: string): string =
  $(%*{"ephemeralPub": pub, "challenge": challenge,
       "wrappedSecret": "c2VjcmV0"})

suite "attestation agent — a stale or mismatched challenge fails":

  test "a challenge below the freshness floor is refused":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let short = get(h.port, "/attestation?challenge=" & ShortChallenge)
    check short.status == 400
    check "freshness" in short.body

    let notHex = get(h.port, "/attestation?challenge=NOTHEX")
    check notHex.status == 400

    # The positive polarity, so the refusals above are discriminating.
    check get(h.port, "/attestation?challenge=" & ChallengeA).status == 200

  test "a report answers its own challenge and refuses to be relabelled":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let body = get(h.port, "/attestation?challenge=" & ChallengeA).body
    let report = parseAttestationReport(body, "for A")
    check report.bindsChallenge(ChallengeA)
    check not report.bindsChallenge(ChallengeB)

    # Take the report that answered A and relabel it as an answer to B,
    # leaving the 64 bytes alone. That is the whole of a naive replay,
    # and the envelope refuses it because the report now disagrees with
    # itself about what it bound.
    let relabelled = body.replace(
      "\"challenge\": \"" & ChallengeA & "\"",
      "\"challenge\": \"" & ChallengeB & "\"")
    check relabelled != body
    expect ReportError:
      discard parseAttestationReport(relabelled, "relabelled")

  test "a key agreement is usable once, and the replay is refused":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let report = issueKeyAgreement(h.port, ChallengeA)
    let pub = report.bindings.ephemeralPub

    # Every binding check passes, so the session is spent. This build
    # cannot unwrap, and says so — but the session is gone either way.
    let first = post(h.port, "/provision", provisionBody(pub, ChallengeA))
    check first.status == 501

    let replay = post(h.port, "/provision", provisionBody(pub, ChallengeA))
    check replay.status == 404
    check "already been used once" in replay.body

  test "a key agreement is refused under a challenge it was not issued with":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let report = issueKeyAgreement(h.port, ChallengeA)
    let pub = report.bindings.ephemeralPub

    let mismatched = post(h.port, "/provision", provisionBody(pub, ChallengeB))
    check mismatched.status == 409
    check "different challenge" in mismatched.body

    # And the session survived the mismatch: a caller who guesses wrong
    # must not be able to destroy an agreement someone else is
    # completing. This is the positive polarity of the check above and
    # the reason the four checks are ordered as they are.
    let honest = post(h.port, "/provision", provisionBody(pub, ChallengeA))
    check honest.status == 501

  test "a public key that was never issued is refused":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let never = post(h.port, "/provision",
      provisionBody(repeat("ab", 32), ChallengeA))
    check never.status == 404

    # Not because provisioning is refused wholesale: a key that WAS
    # issued reaches the next stage.
    let report = issueKeyAgreement(h.port, ChallengeA)
    check post(h.port, "/provision",
      provisionBody(report.bindings.ephemeralPub, ChallengeA)).status == 501

  test "a key agreement expires, and the expiry is what refuses it":
    # Driven through the endpoint layer rather than the socket, because
    # the socket cannot be asked what time it is. `handleRequest` takes
    # the clock as a parameter, so this is the real code path with a real
    # clock value, not a stubbed one.
    const ttlMs = 60_000
    let agent = newAttestationAgent(
      driver = newMockDriver(), identity = sampleIdentity(),
      keySource = newMockKeySource(), sessionTtlMs = ttlMs)
    const issuedAt = 1_000_000'i64

    let issued = agent.handleRequest(HttpRequest(verb: "POST",
      path: "/key-agreement", peer: "127.0.0.1",
      body: $(%*{"challenge": ChallengeA})), issuedAt)
    check issued.status == 200
    let pub = parseAttestationReport(issued.body, "issued").
      bindings.ephemeralPub
    check agent.openSessions == 1

    # One millisecond before the deadline it is still live.
    let justInTime = agent.handleRequest(HttpRequest(verb: "POST",
      path: "/provision", peer: "127.0.0.1",
      body: provisionBody(pub, ChallengeA)), issuedAt + ttlMs - 1)
    check justInTime.status == 501

    # A second agreement, and this time the clock passes the deadline.
    let second = agent.handleRequest(HttpRequest(verb: "POST",
      path: "/key-agreement", peer: "127.0.0.1",
      body: $(%*{"challenge": ChallengeB})), issuedAt)
    check second.status == 200
    let pub2 = parseAttestationReport(second.body, "second").
      bindings.ephemeralPub
    let tooLate = agent.handleRequest(HttpRequest(verb: "POST",
      path: "/provision", peer: "127.0.0.1",
      body: provisionBody(pub2, ChallengeB)), issuedAt + ttlMs)
    check tooLate.status == 404
    # The private key went with it rather than lingering for the boot.
    check agent.openSessions == 0

  test "two agreements under one challenge are two sessions":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let first = issueKeyAgreement(h.port, ChallengeA)
    let second = issueKeyAgreement(h.port, ChallengeA)
    check first.bindings.ephemeralPub != second.bindings.ephemeralPub
    check first.reportData != second.reportData

    # Spending one leaves the other usable. A session is a key, not a
    # challenge, and conflating them would let one caller's provisioning
    # cancel another's.
    check post(h.port, "/provision",
      provisionBody(first.bindings.ephemeralPub, ChallengeA)).status == 501
    check post(h.port, "/provision",
      provisionBody(second.bindings.ephemeralPub, ChallengeA)).status == 501

  test "a key agreement cannot be minted by a GET, so the key is the agent's":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let refused = get(h.port,
      "/attestation?challenge=" & ChallengeA & "&purpose=key-agreement")
    check refused.status == 400
    check "/key-agreement" in refused.body

    # An unknown purpose is refused the same way rather than defaulting.
    check get(h.port,
      "/attestation?challenge=" & ChallengeA & "&purpose=whatever").
      status == 400
    # And the purpose that IS produced here still is.
    check get(h.port,
      "/attestation?challenge=" & ChallengeA & "&purpose=attest").
      status == 200

  test "a build with no key source refuses agreements rather than faking one":
    var h = startHarness(sampleAgent(withKeySource = false))
    defer: stopHarness(h)

    let refused = post(h.port, "/key-agreement",
      $(%*{"challenge": ChallengeA}))
    check refused.status == 501
    check "private half" in refused.body
    # Plain attestation is unaffected, so the refusal is about the key
    # and not about the agent being unable to answer anything.
    check get(h.port, "/attestation?challenge=" & ChallengeA).status == 200

  test "an empty wrapped secret is refused, and does not spend the session":
    # The fourth of the four binding checks, and the one no other case
    # reaches. It matters twice: a caller must not be able to spend
    # someone's single-use agreement by posting nothing, and "released
    # against an empty secret" must not be a state this build can enter.
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let report = issueKeyAgreement(h.port, ChallengeA)
    let pub = report.bindings.ephemeralPub
    let empty = post(h.port, "/provision",
      $(%*{"ephemeralPub": pub, "challenge": ChallengeA,
           "wrappedSecret": ""}))
    check empty.status == 400
    check "wrappedSecret" in empty.body

    # The session survived, so the refusal cost the holder nothing.
    check post(h.port, "/provision",
      provisionBody(pub, ChallengeA)).status == 501

  test "the session table is bounded, sessions being minted by strangers":
    # Every key agreement is a private key in memory, minted by an
    # unauthenticated caller, so the table has to be bounded or it is the
    # attack. Driven through the endpoint layer with a fixed clock, so
    # nothing expires underneath the count.
    # The SHIPPED default first, pinned as a literal. Every line below
    # builds a table of its own, which says nothing about what a
    # deployment gets — and a default large enough to be no bound is the
    # attack this table exists to stop.
    check DefaultMaxSessions == 64
    check DefaultSessionTtlMs == 300_000

    const cap = 2
    let agent = newAttestationAgent(
      driver = newMockDriver(), identity = sampleIdentity(),
      keySource = newMockKeySource(), maxSessions = cap)
    const at = 5_000_000'i64
    proc agree(): HttpResponse =
      agent.handleRequest(HttpRequest(verb: "POST", path: "/key-agreement",
        peer: "127.0.0.1", body: $(%*{"challenge": ChallengeA})), at)

    var pubs: seq[string] = @[]
    for i in 0 ..< cap:
      let r = agree()
      check r.status == 200
      pubs.add parseAttestationReport(r.body, "issued").bindings.ephemeralPub
    check agent.openSessions == cap

    # The next one is refused rather than served by evicting a live
    # session someone is waiting on.
    let over = agree()
    check over.status == 429
    check agent.openSessions == cap

    # And it is a bound rather than a wall: spending one makes room, so
    # the refusal above is about capacity and not about the endpoint
    # having stopped working.
    check agent.handleRequest(HttpRequest(verb: "POST", path: "/provision",
      peer: "127.0.0.1", body: provisionBody(pubs[0], ChallengeA)),
      at).status == 501
    check agent.openSessions == cap - 1
    check agree().status == 200

  test "a repeated challenge on /attestation is ANSWERED, deliberately":
    # Recorded as a test because it is a decision someone will later
    # mistake for a missing check. Refusing a repeated challenge would
    # let anyone who can observe one deny the verifier its answer, and
    # would protect nothing: the party that cares whether a report is
    # fresh is the party that chose the nonce.
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let first = get(h.port, "/attestation?challenge=" & ChallengeA)
    let second = get(h.port, "/attestation?challenge=" & ChallengeA)
    check first.status == 200
    check second.status == 200
    # And both bind the same 64 bytes, because the discipline is a
    # function of the challenge and the bindings alone.
    check parseAttestationReport(first.body, "first").reportData ==
      parseAttestationReport(second.body, "second").reportData
