## End to end: a measurement manifest, a running agent, a challenge over
## a real socket, and a verdict — with no special hardware anywhere.
##
## ## What "end to end" means here, and what it does not
##
## The chain exercised is the whole protocol plane minus the hardware:
##
##   measurement manifest (the emitter's own schema and renderer)
##     → an agent configured with it, listening on a real TCP port
##     → a nonce minted by `repro attest challenge`
##     → `GET /attestation?challenge=…` over that socket, through the
##       same fetch the command line uses for `--report-url`
##     → the report envelope, parsed by the frozen parser
##     → its mock evidence, read and its authentication code recomputed
##     → a verdict against a real policy document
##
## It does **not** build an image and it does not boot one. The image
## closure is priced in hours and there is no hardware root of trust on
## this machine, which is precisely the situation the mock backend exists
## for. What is proved is the protocol plane; what is not proved is that
## any real firmware would put the bytes where this backend does.
##
## ## The case this gate exists for
##
## Not the green path. It is "a driver that binds bytes other than the
## ones it was handed" — the driver seam is built so that a lying backend
## produces a report whose envelope and signed evidence disagree, and the
## agent that assembles the envelope cannot be tricked into papering over
## it. Nothing on the instance side can catch that, because catching it
## is the verifier's job; the ``report-data-binding`` case below does it,
## over the socket, end to end.
##
## ## Where the expected measurements come from
##
## The verifier's own disk, always. The last case makes that visible: the
## agent is configured with one manifest and the verifier is handed a
## different one, and the verdict reflects the verifier's copy. The
## agent's ``/measurement-manifest`` endpoint serves its copy correctly
## and the verifier does not read it, because a manifest served by the
## machine under verification is the suspect supplying the evidence.
##
## ## Mocking
##
## None. The daemon is the real daemon on a real socket; the backend is
## the mock *backend*, an implementation of the driver seam for a root of
## trust that is absent.

import std/[net, options, os, posix, strutils, times, unittest]

import repro_attest
import repro_attest_agent
import repro_attest_verify
import repro_attest_verify/fetch
import repro_cli_support/attest

include ./attestation_verifier_harness

type
  AgentHarness = object
    server: HttpServer
    thread: Thread[HttpServer]
    port: Port

  LyingDriver = ref object of AttestationDriver
    ## Signs bytes other than the ones it was handed. Not a mock of a
    ## driver — it is a driver, and it is the shape a fault-injecting
    ## emulator takes.

method driverProbe(d: LyingDriver): BackendReadiness =
  BackendReadiness(ready: true,
    detail: "a driver that binds bytes other than the ones it was handed")

method driverQuote(d: LyingDriver; req: QuoteRequest): QuoteResult =
  var mutated = req.reportData
  mutated[0] = char(uint8(mutated[0]) xor 0xFF'u8)
  QuoteResult(evidence: renderMockEvidence(bytesToHex(mutated)),
              certificates: some(mockCertificateChain()))

proc newLyingDriver(): LyingDriver =
  result = LyingDriver()
  initAttestationDriver(result, abMock, "lying-mock")

type
  ForgedChainDriver = ref object of AttestationDriver
    ## Mock evidence, bundled with a chain that does NOT say it is
    ## worthless. The interesting half of a certificate check: a mock
    ## backend that bundled something looking like an X.509 chain would
    ## be a mock offering a chain someone might try to validate, and a
    ## verifier that shrugged at it would be one that never read the
    ## chain at all.

method driverProbe(d: ForgedChainDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "bundles a chain that lies")

method driverQuote(d: ForgedChainDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(
    evidence: renderMockEvidence(bytesToHex(req.reportData)),
    certificates: some(@[
      "-----BEGIN CERTIFICATE-----\nsubject=attestation-key\n",
      "-----BEGIN CERTIFICATE-----\nsubject=AMD-SEV-Root-CA\n"]))

proc newForgedChainDriver(): ForgedChainDriver =
  result = ForgedChainDriver()
  initAttestationDriver(result, abMock, "forged-chain")

proc serveThread(s: HttpServer) {.thread.} =
  s.serve()

proc startAgent(driver: AttestationDriver; manifestText: string):
    AgentHarness =
  ## Port 0, so a test never collides with something else on this host.
  let agent = newAttestationAgent(
    driver = driver,
    identity = AgentIdentity(generation: SampleGeneration),
    manifestText = manifestText)
  result.server = newAgentServer(agent, "127.0.0.1", Port(0))
  result.port = result.server.boundPort
  createThread(result.thread, serveThread, result.server)

proc stopAgent(h: var AgentHarness) =
  h.server.requestStop()
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", h.port)
    poke.close()
  except CatchableError:
    discard
  joinThread(h.thread)
  h.server.close()

proc baseUrl(h: AgentHarness): string =
  "http://127.0.0.1:" & $int(h.port)

let scratch = getTempDir() / ("reproos-attest-verify-" & $getCurrentProcessId())

proc scratchFile(name, content: string): string =
  createDir(scratch)
  result = scratch / name
  writeFile(result, content)

suite "manifest to agent to verdict, over a socket, with no hardware":

  test "a minted challenge answered by the agent verifies":
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)

    let minted = mintChallenge(int64(epochTime() * 1000.0))
    # Pinned as a literal, and the constant checked against the same
    # literal separately: a length compared against the constant that
    # produced it is satisfied by any value of that constant.
    check minted.challengeHex.len == 64
    check ChallengeBytes == 32
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)

    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText,
      reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: int64(epochTime() * 1000.0)))

    check v.decision == vdAcceptedNoRootOfTrust
    check v.checks[vcReportSchema].outcome == coPassed
    check v.checks[vcTierAccepted].outcome == coPassed
    check v.checks[vcBackendAccepted].outcome == coPassed
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcReportDataBinding].outcome == coPassed
    check v.checks[vcChallengeMatch].outcome == coPassed
    check v.checks[vcChallengeFreshness].outcome == coPassed
    check v.checks[vcCertificateChain].outcome == coPassed
    check v.checks[vcManifestPinned].outcome == coSkipped
    check v.checks[vcMeasurementMatch].outcome == coSkipped
    check v.checks[vcTcbFloor].outcome == coSkipped
    check v.failedChecks.len == 0
    check MockCaveat in v.caveats
    check UnpinnedManifestCaveat in v.caveats

  test "a driver that binds other bytes is caught, end to end":
    # The case this whole gate exists for. The agent computes the
    # envelope's report data itself and this driver signs something else,
    # so the envelope and the evidence disagree — a report that is
    # internally well formed and that the frozen parser accepts.
    var h = startAgent(newLyingDriver(), sampleManifestText())
    defer: stopAgent(h)

    let minted = mintChallenge(int64(epochTime() * 1000.0))
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)

    # The parser accepts it: nothing about the envelope is wrong.
    let report = parseAttestationReport(reportText, "over the socket")
    check report.bindsChallenge(minted.challengeHex)

    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: int64(epochTime() * 1000.0)))

    check v.decision == vdRejected
    check v.checks[vcReportDataBinding].outcome == coFailed
    check "the envelope and the bytes the backend signed disagree" in
      v.checks[vcReportDataBinding].detail
    # And everything else still reports, which is the point of running
    # every check rather than stopping at the first failure.
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcChallengeMatch].outcome == coPassed
    for chk in VerifierCheck:
      check v.checks[chk].outcome != coNotReached

  test "a report answering somebody else's challenge is refused":
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)

    let mine = mintChallenge(int64(epochTime() * 1000.0))
    let theirs = mintChallenge(int64(epochTime() * 1000.0))
    check mine.challengeHex != theirs.challengeHex
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & theirs.challengeHex)

    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: mine.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(mine.issuedAt)),
      nowMs: int64(epochTime() * 1000.0)))
    check v.decision == vdRejected
    check v.checks[vcChallengeMatch].outcome == coFailed
    check mine.challengeHex in v.checks[vcChallengeMatch].detail

  test "a challenge older than the policy's window is refused":
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)

    let now = int64(epochTime() * 1000.0)
    let minted = mintChallenge(now)
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)

    # The policy's window is 120 s; this verifier answers 10 minutes on.
    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: parseIssuedAtMs(minted.issuedAt) + 600_000))
    check v.decision == vdRejected
    check v.checks[vcChallengeFreshness].outcome == coFailed
    check "the policy accepts at most 120 s" in
      v.checks[vcChallengeFreshness].detail
    # The rest of the report is fine, which is what makes the freshness
    # window the thing that decided this.
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcReportDataBinding].outcome == coPassed
    check v.checks[vcChallengeMatch].outcome == coPassed

  test "the verifier compares against ITS copy of the manifest":
    # The agent is configured with one manifest and the verifier is
    # handed another. Nothing in the verifier reaches for the machine's
    # copy — a manifest served by the machine under verification is the
    # suspect supplying the evidence — so the verdict is computed against
    # the verifier's, and the claims the agent took from ITS manifest are
    # reported as disagreeing.
    let agentManifest = sampleManifestText(SampleVerityRootHash)
    let verifierManifest = sampleManifestText(OtherVerityRootHash)
    check agentManifest != verifierManifest

    var h = startAgent(newMockDriver(), agentManifest)
    defer: stopAgent(h)

    # The endpoint works, and serves the agent's copy byte for byte.
    check httpGet(h.baseUrl & "/measurement-manifest") == agentManifest

    let minted = mintChallenge(int64(epochTime() * 1000.0))
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)
    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(verifierManifest),
      manifestSource: "<the verifier's own copy>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: int64(epochTime() * 1000.0)))

    var sawDisagreement = false
    for note in v.claimNotes:
      if "DISAGREES with the manifest's " & OtherVerityRootHash in note:
        sawDisagreement = true
    check sawDisagreement
    # And it did not change the decision, because claims never do.
    check v.decision == vdAcceptedNoRootOfTrust

  test "a bundled chain that does not say it is worthless is refused":
    var h = startAgent(newForgedChainDriver(), sampleManifestText())
    defer: stopAgent(h)
    let minted = mintChallenge(int64(epochTime() * 1000.0))
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)
    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: int64(epochTime() * 1000.0)))
    check v.checks[vcCertificateChain].outcome == coFailed
    check "does not begin" in v.checks[vcCertificateChain].detail
    check v.decision == vdRejected
    # Everything else about this report is fine, so the chain is what
    # decided it.
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcReportDataBinding].outcome == coPassed

  test "a challenge record this build would not have written is refused":
    let good = renderChallengeRecord(mintChallenge(0))
    discard parseChallengeRecord(good, "<good>")   # the control
    proc refused(text: string): bool =
      try:
        discard parseChallengeRecord(text, "<case>")
        false
      except ChallengeError:
        true
    check refused(good.replace("attestation-challenge.v1",
                               "attestation-challenge.v2"))
    check refused(good.replace("\"issuedAt\"", "\"issued_at\""))
    check refused(good.replace("1970-01-01T00:00:00Z", "1970-01-01"))
    check refused(good.replace("1970-01-01T00:00:00Z",
                               "1970-01-01T00:00:00+02:00"))
    check refused(good.replace("}\n", ",\n  \"extra\": \"x\"\n}\n"))
    # A nonce below the discipline's 128-bit floor is refused by the
    # record reader too, not only by the minter.
    check refused(good.replace(parseChallengeRecord(good, "<g>").challengeHex,
                               "00112233445566778899aabbccdd"))

  test "a challenge issued in the future is refused":
    # A verifier whose own clock disagrees with its own record cannot
    # bound anything, and a negative age must not read as "younger than
    # the window".
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)
    let now = int64(epochTime() * 1000.0)
    let minted = mintChallenge(now)
    let reportText = httpGet(h.baseUrl &
      "/attestation?challenge=" & minted.challengeHex)
    let v = verifyAttestationReport(VerificationRequest(
      reportText: reportText, reportSource: "over the socket",
      policy: parseAttestationPolicy(MockDevPolicy, "<dev>"),
      policySource: "<dev>",
      manifestText: some(sampleManifestText()),
      manifestSource: "<local manifest>",
      expectedChallengeHex: minted.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(minted.issuedAt)),
      nowMs: parseIssuedAtMs(minted.issuedAt) - 60_000))
    check v.checks[vcChallengeFreshness].outcome == coFailed
    check "in the future" in v.checks[vcChallengeFreshness].detail
    check v.decision == vdRejected

  test "the issuance-time reader's guards each say what they caught":
    # `parseIssuedAtMs` layers three guards — the RFC 3339 shape, the
    # whole-seconds-UTC spelling, and the parse itself — and the last
    # catches everything the first two do. So each was individually
    # removable while the refusal stayed a refusal. What the first two
    # are FOR is the message, and the messages are pinned here.
    proc refusalFor(issuedAt: string): string =
      try:
        discard parseIssuedAtMs(issuedAt)
        ""
      except ChallengeError as err:
        err.msg
    # A shape RFC 3339 does not define: the month is 13.
    check "not RFC 3339" in refusalFor("1970-13-01T00:00:00Z")
    # A valid instant in a spelling this build does not write: an offset
    # rather than Z. Reading it approximately would put a freshness
    # window hours out.
    check "whole seconds in UTC" in refusalFor("1970-01-01T00:00:00+02:00")
    # And the control: the spelling this build writes round-trips.
    check parseIssuedAtMs(formatIssuedAt(86_400_000)) == 86_400_000

  test "an endpoint that is not a report is refused, not verified":
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)
    var raised = false
    try:
      discard httpGet(h.baseUrl & "/no-such-endpoint")
    except FetchError as err:
      raised = true
      check "404" in err.msg
    check raised

  test "https is refused rather than served by a TLS stack this build lacks":
    var raised = false
    try:
      discard httpGet("https://example.invalid/attestation")
    except FetchError as err:
      raised = true
      check "plain HTTP only" in err.msg
    check raised

  # -- the same chain, through the command line ----------------------

  test "`repro attest challenge` and `repro attest verify` drive it":
    var h = startAgent(newMockDriver(), sampleManifestText())
    defer: stopAgent(h)

    let challengePath = scratch / "challenge.json"
    check runAttestCommand(@["challenge", "--out", challengePath]) ==
      AttestExitAccepted
    let minted = parseChallengeRecord(readFile(challengePath), challengePath)

    let policyPath = scratchFile("policy.toml", MockDevPolicy)
    let manifestPath = scratchFile("manifest.json", sampleManifestText())
    let verdictPath = scratch / "verdict.txt"

    # A mock-tier acceptance is NOT exit 0. A shell script that tested
    # for success would otherwise read "the documents agree with each
    # other" as "the machine is what it says it is".
    #
    # The codes are pinned as literals here as well as by name: a check
    # against the constant that produced the value passes whatever that
    # constant is changed to.
    check AttestExitAccepted == 0
    check AttestExitRejected == 1
    check AttestExitUsage == 2
    check AttestExitAcceptedNoRootOfTrust == 3
    check runAttestCommand(@["verify",
      "--report-url", h.baseUrl & "/attestation?challenge=" &
        minted.challengeHex,
      "--policy", policyPath,
      "--manifest", manifestPath,
      "--challenge-file", challengePath,
      "--out", verdictPath]) == AttestExitAcceptedNoRootOfTrust
    let verdictText = readFile(verdictPath)
    check "verdict: accepted-without-a-root-of-trust" in verdictText
    for chk in VerifierCheck:
      check ($chk) in verdictText
    check verdictText.count("skipped") >= 3

    # The machine-readable half.
    let jsonPath = scratch / "verdict.json"
    check runAttestCommand(@["verify",
      "--report-url", h.baseUrl & "/attestation?challenge=" &
        minted.challengeHex,
      "--policy=" & policyPath,
      "--manifest=" & manifestPath,
      "--challenge-file=" & challengePath,
      "--json", "--out", jsonPath]) == AttestExitAcceptedNoRootOfTrust
    let jsonText = readFile(jsonPath)
    check "\"schema\": \"reproos.attestation-verdict.v1\"" in jsonText
    check jsonText.count("\"check\":") == 11

  test "the command line refuses the shapes that have no right answer":
    # Asserting the exit CODE is not enough and that is not a theory:
    # every refusal on this path exits 2, so with any one guard removed
    # the command falls through to the next refusal and exits 2 anyway.
    # Four guards were individually removable under a code-only
    # assertion. Each is now pinned to what it SAYS.
    let policyPath = scratchFile("policy.toml", MockDevPolicy)

    proc refusal(args: seq[string]): tuple[code: int; err: string] =
      ## Run the command with the process's real stderr redirected to a
      ## file, so the refusal a user would read is the thing asserted.
      let path = scratch / "cli-stderr.txt"
      let saved = dup(2)
      let fd = posix.open(path.cstring,
                          O_WRONLY or O_CREAT or O_TRUNC, 0o644.Mode)
      doAssert saved >= 0 and fd >= 0
      discard dup2(fd, 2)
      var code = 0
      try:
        code = runAttestCommand(args)
      finally:
        stderr.flushFile()
        discard dup2(saved, 2)
        discard close(fd)
        discard close(saved)
      (code: code, err: readFile(path))

    # The control: a well-formed invocation is NOT refused, so the
    # refusals below are refusals of something rather than of everything.
    let manifestOk = scratchFile("m-ok.json", sampleManifestText())
    let challengeOk = scratch / "c-ok.json"
    check runAttestCommand(@["challenge", "--out", challengeOk]) ==
      AttestExitAccepted

    # No report at all.
    let noReport = refusal(@["verify", "--policy", policyPath])
    check noReport.code == AttestExitUsage
    check "no report; pass --report-file" in noReport.err

    # Two reports, and no rule saying which one wins.
    let twoReports = refusal(@["verify", "--report-file", "a",
      "--report-url", "http://b", "--policy", policyPath])
    check twoReports.code == AttestExitUsage
    check "--report-file and --report-url both name a report" in
      twoReports.err

    # No policy: a verifier with no policy has no grounds to accept
    # anything, and defaulting to one would be this build deciding what
    # the operator trusts.
    let noPolicy = refusal(@["verify", "--report-file", "a"])
    check noPolicy.code == AttestExitUsage
    check "--policy is required" in noPolicy.err

    # An unknown flag is a refusal, not a default. In particular there is
    # no flag that fetches a measurement manifest from the machine under
    # verification, and asking for one says so rather than being ignored.
    let unknownFlag = refusal(@["verify", "--manifest-url", "http://b",
      "--policy", policyPath])
    check unknownFlag.code == AttestExitUsage
    check "unknown `repro attest` flag: --manifest-url" in unknownFlag.err

    # Two challenge sources.
    let twoChallenges = refusal(@["verify", "--report-file", "a",
      "--policy", policyPath, "--challenge", "ab", "--challenge-file", "c"])
    check twoChallenges.code == AttestExitUsage
    check "--challenge and --challenge-file both name a challenge" in
      twoChallenges.err

    # A policy the parser refuses stops the command, and says which
    # clause it could not honour.
    let badPolicy = scratchFile("bad.toml",
      MockDevPolicy & "\nunexpected_key = 1\n")
    let refusedPolicy = refusal(@["verify", "--report-file", manifestOk,
      "--policy", badPolicy, "--challenge-file", challengeOk])
    check refusedPolicy.code == AttestExitUsage
    check "unexpected_key" in refusedPolicy.err

  test "a rejected verdict exits 1 through the command line":
    var h = startAgent(newLyingDriver(), sampleManifestText())
    defer: stopAgent(h)
    let challengePath = scratch / "challenge2.json"
    check runAttestCommand(@["challenge", "--out", challengePath]) ==
      AttestExitAccepted
    let minted = parseChallengeRecord(readFile(challengePath), challengePath)
    let policyPath = scratchFile("policy.toml", MockDevPolicy)
    let verdictPath = scratch / "verdict-rejected.txt"
    check runAttestCommand(@["verify",
      "--report-url", h.baseUrl & "/attestation?challenge=" &
        minted.challengeHex,
      "--policy", policyPath,
      "--challenge-file", challengePath,
      "--out", verdictPath]) == AttestExitRejected
    check "verdict: rejected" in readFile(verdictPath)

  test "the scratch directory is removed":
    removeDir(scratch)
    check not dirExists(scratch)
