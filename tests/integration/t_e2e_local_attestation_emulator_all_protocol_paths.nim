## The local evidence emulator, driven through every protocol path, on
## valid evidence and on every structured fault.
##
## ## What this gate establishes
##
## One emulated machine produces one attestation. Four surfaces then
## reach a verdict about it — the agent that served it, the in-process
## library verifier, the command line, and a key-release broker — and
## they have to agree, on the unmutated attestation and on all eleven
## faults. Where they disagree there is a surface whose users are told
## something the others would not tell them, which is the failure this
## exists to find.
##
## ## What "four surfaces" honestly means
##
## It is not four implementations. Three of them call the same library,
## and saying otherwise would be the interesting-sounding version of a
## claim this gate does not support. What differs is the *surface*:
##
##   * the **agent** produces the document, over a real TCP socket, from
##     the real daemon, with the emulator behind the driver seam;
##   * the **in-process verifier** is ``verifyAttestationReport`` on a
##     ``VerificationRequest`` assembled in memory;
##   * the **command line** is ``repro attest verify``, with the report,
##     the policy, the manifest, the trust anchors and the revocation
##     lists all read off a filesystem by argument parsing that has its
##     own bugs to have — and its answer is an EXIT CODE, which is the
##     only part of a verdict a shell script reads;
##   * the **service verifier** is that same command line fetching the
##     document over HTTP from a listening server rather than reading it
##     from disk, which is a different transport and a different failure
##     surface;
##   * the **broker** is the key-release decision: it releases a secret
##     only on the NARROW acceptance, so a qualified acceptance that the
##     other three call "accepted" still releases nothing.
##
## The agreement asserted is therefore: the same accept/reject answer,
## the same exit code derived from it, and the same release decision.
##
## ## Why this file is a different binary
##
## It is compiled with ``-d:reproAttestSoftwareRootTestTrust``. The
## emulator's hierarchy carries the RFC 5280 §4.2 marker on every
## certificate and nothing without that define will accept it — which is
## the point of its companion gate. Here the marker is recognised, so a
## valid emulated attestation is ACCEPTED and every fault has something
## to be a fault against. A gate in which everything is refused measures
## the marker and nothing else.
##
## ## Mocking
##
## None. Real ECDSA signatures, real DER, a real event log, real replay,
## a real socket, and the real argument parser.
##
## The agent is configured with ``newMockKeySource``, and that is a
## backend rather than a mock of one: it is an implementation of the
## ephemeral-key seam for a key-encapsulation mechanism that does not
## exist in this build, named ``mock-not-a-kem`` in its own bytes so it
## cannot be mistaken for one. The key agreement it serves is what the
## release path needs in order to have a session at all; nothing about
## the attestation under test stands in for anything.

import std/[base64, json, net, options, os, posix, random, strutils,
            times, unittest]

import repro_attest
import repro_attest/x25519_kem
import repro_attest_agent
import repro_attest_verify
import repro_cli_support/attest

import ./emulator_scenarios
import ./evidence_emulator
import ./software_root_test_pki

let nowSeconds = getTime().toUnix
let nowMillis = nowSeconds * 1000

# ---------------------------------------------------------------------
# A listening server, for the two paths that need one
# ---------------------------------------------------------------------

type Served = object
  server: HttpServer
  thread: Thread[HttpServer]
  port: Port

proc serveThread(s: HttpServer) {.thread.} = s.serve()

proc anyCost(verb, path: string): int {.gcsafe, raises: [].} = 1

proc startServed(handler: RequestHandler): Served =
  result.server = newHttpServer("127.0.0.1", Port(0), defaultAgentLimits(),
                                handler, anyCost)
  result.port = result.server.boundPort
  createThread(result.thread, serveThread, result.server)

proc stopServed(s: var Served) =
  s.server.requestStop()
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", s.port)
    poke.close()
  except CatchableError:
    discard
  joinThread(s.thread)
  s.server.close()

proc startAgent(a: AttestationAgent): Served =
  result.server = newAgentServer(a, "127.0.0.1", Port(0))
  result.port = result.server.boundPort
  createThread(result.thread, serveThread, result.server)

proc httpExchange(port: Port; verb, target, body: string): string =
  ## A hand-written client, for the same reason the daemon's server is
  ## hand-written: this file has to be able to send exactly what it means
  ## to send.
  result = ""
  var s: Socket
  try:
    s = newSocket(buffered = false)
    s.connect("127.0.0.1", port)
    var payload = verb & " " & target & " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if body.len > 0 or verb == "POST":
      payload.add "Content-Type: application/json\r\n"
      payload.add "Content-Length: " & $body.len & "\r\n"
    payload.add "\r\n"
    payload.add body
    discard s.trySend(payload)
    while true:
      var chunk = ""
      var got = 0
      try:
        got = s.recv(chunk, 8_192, 4_000)
      except CatchableError:
        break
      if got <= 0: break
      result.add chunk[0 ..< got]
  except CatchableError:
    discard
  finally:
    try: s.close()
    except CatchableError: discard

proc statusOf(raw: string): int =
  if raw.len == 0: return 0
  let parts = raw.split("\r\n")[0].split(' ')
  if parts.len < 2: return 0
  try: parseInt(parts[1])
  except ValueError: 0

proc bodyOf(raw: string): string =
  let at = raw.find("\r\n\r\n")
  if at < 0: "" else: raw[at + 4 .. ^1]

# ---------------------------------------------------------------------
# The emulated machine
# ---------------------------------------------------------------------

var emulatorSecrets = ""

proc emulatorSecretsDir(): string =
  ## A directory on a filesystem with no backing store, found on the
  ## machine running the gate. The agent refuses anything else.
  if emulatorSecrets.len > 0: return emulatorSecrets
  for base in ["/dev/shm", "/run/user/" & $getuid(), getTempDir()]:
    if not dirExists(base): continue
    let candidate = base / ("repro-emulator-secrets-" &
      $getCurrentProcessId())
    try:
      createDir(candidate)
      setFilePermissions(candidate, {fpUserRead, fpUserWrite, fpUserExec})
      discard newProvisionedSecretStore(candidate)
      emulatorSecrets = candidate
      return candidate
    except CatchableError:
      removeDir(candidate)
  doAssert false,
    "this gate needs a filesystem with no backing store and found none"

proc emulatorAgent(d: EmulatedTpm2Driver): AttestationAgent =
  ## The real daemon, with the emulator behind the driver seam and the
  ## honest manifest loaded. The identity is taken from the manifest by
  ## the agent itself, which is why only the generation is passed.
  ## The key source is the SHIPPED mechanism and the secrets directory
  ## is a real filesystem with no backing store, so the release path
  ## below is the one a deployment runs. It was a published
  ## non-mechanism while `/provision` answered 501; now that the
  ## endpoint really releases, an agent that could not would make the
  ## broker case read the same refusal whatever the verdict was.
  newAttestationAgent(
    driver = d,
    identity = AgentIdentity(generation: EmulatorGeneration),
    keySource = newX25519KeySource(),
    secretStore = newProvisionedSecretStore(emulatorSecretsDir()),
    manifestText = emulatorManifestText())

proc scratchDir(): string =
  result = getTempDir() / "repro-emulator-paths-" &
    $getCurrentProcessId() & "-" & $rand(1_000_000)
  createDir(result)

# ---------------------------------------------------------------------
# The four answers
# ---------------------------------------------------------------------

type
  PathAnswers = object
    inProcess: Verdict
    cliExit: int
    serviceExit: int
    brokerReleases: bool
    cliVerdictText: string

proc rfc3339Of(ms: int64): string =
  utc(fromUnix(ms div 1000)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc cliArgsFor(run: EmulatedRun; dir: string;
                reportArg: seq[string]): seq[string] =
  ## Exactly what a person would type. In particular the challenge and
  ## the instant it was issued are passed, because a command line that
  ## was told a challenge and not when it was issued fails the freshness
  ## clause under any policy that sets a window — which would be a
  ## disagreement about the harness rather than about the report.
  result = @["verify"]
  result.add reportArg
  result.add @["--policy", dir / "policy.toml",
               "--manifest", dir / "manifest.toml",
               "--challenge", run.expectedChallengeHex,
               "--challenge-issued-at", rfc3339Of(run.challengeIssuedAtMs),
               "--out", dir / "verdict.txt"]
  for i in 0 ..< run.anchorDer.len:
    result.add @["--trust-anchor", dir / ("anchor-" & $i & ".der")]
  for i in 0 ..< run.crlDer.len:
    result.add @["--revocation-list", dir / ("crl-" & $i & ".der")]

proc writeRunFiles(run: EmulatedRun; dir: string) =
  writeFile(dir / "report.json", run.reportText)
  writeFile(dir / "policy.toml", run.policyText)
  writeFile(dir / "manifest.toml", run.manifestText)
  for i, der in run.anchorDer: writeFile(dir / ("anchor-" & $i & ".der"), der)
  for i, der in run.crlDer: writeFile(dir / ("crl-" & $i & ".der"), der)

proc answersFor(run: EmulatedRun; dir: string): PathAnswers =
  ## The same run, through every surface.
  ##
  ## The command line is invoked with the arguments a person would type
  ## and its answer is taken from its exit status, not from a function it
  ## happens to call — a differential test that compared two callers of
  ## one function would agree by construction.
  writeRunFiles(run, dir)

  result.inProcess = verifyAttestationReport(verificationRequestFor(run))

  result.cliExit = runAttestCommand(cliArgsFor(run, dir,
    @["--report-file", dir / "report.json"]))
  result.cliVerdictText = readFile(dir / "verdict.txt")

  # The service path: the SAME document, fetched over HTTP. The server
  # serves the run's bytes rather than the agent's, because three of the
  # faults are things an active party does to a document AFTER the
  # machine produced it, and a path that could only ever see the
  # machine's own bytes could not see those faults at all.
  let served = run.reportText
  let handler = proc (req: HttpRequest): HttpResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      HttpResponse(status: 200, contentType: "application/json", body: served)
  var docServer = startServed(handler)
  try:
    result.serviceExit = runAttestCommand(cliArgsFor(run, dir,
      @["--report-url", "http://127.0.0.1:" & $uint16(docServer.port) &
        "/attestation"]))
  finally:
    stopServed(docServer)

  # The broker releases on the NARROW acceptance only. A qualified
  # acceptance is an acceptance the other surfaces report as one, and it
  # is still not a reason to hand somebody a secret.
  #
  # It runs its OWN verification rather than reading the verdict computed
  # above. That is not ceremony: comparing this flag against
  # `result.inProcess.decision` would compare a value against the value it
  # was assigned from, and such a check passes whatever either surface
  # does. The comparison the case below makes is against the COMMAND
  # LINE's exit status, which is a separate invocation that read its
  # inputs off a filesystem.
  result.brokerReleases =
    verifyAttestationReport(verificationRequestFor(run)).decision == vdAccepted

suite "local attestation emulator: every protocol path, every fault":

  test "the eleven faults are the eleven this fixture set declares":
    ## The fixture set is constrained by its own gate.
    ##
    ## The ``case`` functions over ``EmulatorMutation`` already refuse to
    ## compile when a fault is added without a decision — but a build that
    ## does not compile measures nothing, so the enum is ALSO pinned here
    ## by a value that can go red: the count, and every spelling.
    var faults: seq[string] = @[]
    for m in EmulatorMutation:
      if m == emNone: continue
      faults.add $m
    check faults.len == EmulatorFaultCount
    check faults == @EmulatorFaultNames
    check $emNone == "none"
    # And the partition is total and non-trivial in both directions: a
    # fault the driver injects is not one the harness injects.
    var byDriver = 0
    var byVerification = 0
    for m in EmulatorMutation:
      if m == emNone: continue
      case faultSite(m)
      of fsEvidence: inc byDriver
      of fsVerification: inc byVerification
    check byDriver == 6
    check byVerification == 5
    check byDriver + byVerification == EmulatorFaultCount

  test "every fault is actually applied, measured in the evidence itself":
    ## A mutation that did not fire falsifies nothing. Each evidence-site
    ## fault is therefore checked BY VALUE in the bytes the emulator
    ## produced, not by "the output differs" — two emulators mint two
    ## hierarchies and their output differs whatever the scenario says, so
    ## a difference test here would be satisfied by the key material.
    ##
    ## The TCB fault is the one this case exists for: nothing in this
    ## build catches it, so "declared uncaught" and "never applied" would
    ## be indistinguishable without a measurement of its own.
    let bindings = ReportBindings(purpose: bpAttest)
    let wantedHex = reportDataHexFor(bindings, EmulatorChallenge)
    let wanted = hexToBytes("reportData", wantedHex)
    for m in EmulatorMutation:
      checkpoint($m)
      let d = newEmulatedTpm2Driver(defaultEmulatorScenario(m), nowSeconds)
      let quote = acquireQuote(d, wanted)
      let ev = parseTpm2Evidence(quote.evidence)
      let q = tpm2EvidenceQuote(ev)
      let leaf = parseCertificateBytes(d.emulatedChain[0])
      var r = newSeq[byte](q.signature.signatureR.len)
      for i in 0 ..< r.len: r[i] = byte(q.signature.signatureR[i])
      var sg = newSeq[byte](q.signature.signatureS.len)
      for i in 0 ..< sg.len: sg[i] = byte(q.signature.signatureS[i])
      var message = newSeq[byte](q.attestBytes.len)
      for i in 0 ..< message.len: message[i] = byte(q.attestBytes[i])
      let signatureHolds =
        verifyEcdsaSha256Raw(message, r, sg, leaf.publicKey)
      let bundled = quote.certificates.get
      let replayedPcr11 = bytesToHex(pcrValue(
        replayBank(tpm2EvidenceLog(ev), TpmAlgSha256), Pcr11))
      let manifestPcr11 = emulatorManifest().tpm[0].pcr11

      case m
      of emNone:
        check signatureHolds
        check bundled.len == 3
        check q.attest.firmwareVersion == EmulatedFirmwareVersion
        check qualifyingData(q) == wanted
        check explainsQuote(tpm2EvidenceLog(ev), q)
        check replayedPcr11 == manifestPcr11
      of emSignature:
        # Only the signature moved: everything else about the evidence
        # is still exactly the unmutated instance's.
        check not signatureHolds
        check q.attest.firmwareVersion == EmulatedFirmwareVersion
        check qualifyingData(q) == wanted
        check explainsQuote(tpm2EvidenceLog(ev), q)
        check replayedPcr11 == manifestPcr11
      of emChain:
        check bundled.len == 2
        check signatureHolds
        check parseCertificateBytes(bundled[1]).subjectCn == RootCn
      of emMeasurement:
        check signatureHolds
        check explainsQuote(tpm2EvidenceLog(ev), q)
        check replayedPcr11 != manifestPcr11
      of emEventLog:
        # The structure still verifies under the key — the log was
        # altered AFTER it was signed — and the replay no longer reaches
        # the digest the structure carries. That separation is what lets
        # a forged log and a forged quote be told apart.
        check signatureHolds
        check not explainsQuote(tpm2EvidenceLog(ev), q)
      of emTcb:
        check q.attest.firmwareVersion == 0'u64
        check EmulatedFirmwareVersion != 0'u64
        check signatureHolds
        check explainsQuote(tpm2EvidenceLog(ev), q)
        check replayedPcr11 == manifestPcr11
      of emNonce:
        check qualifyingData(q) != wanted
        check qualifyingData(q).len == wanted.len
        check signatureHolds
      of emPolicy, emEphemeralKey, emTranscript, emTime, emReplay:
        # Not the driver's to inject, and it did not: the evidence is
        # the unmutated instance's on every axis.
        check faultSite(m) == fsVerification
        check signatureHolds
        check bundled.len == 3
        check q.attest.firmwareVersion == EmulatedFirmwareVersion
        check qualifyingData(q) == wanted
        check replayedPcr11 == manifestPcr11

  test "the emulator is deterministic and the agent adds nothing to it":
    ## The report the daemon serves over a socket and the report the
    ## renderer produces in process are the same attestation. Asserted
    ## field by field rather than as a byte comparison, because the
    ## informational timestamp comes from the daemon's clock and is the
    ## one field that legitimately differs.
    let d = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone), nowSeconds)
    var agent = startAgent(emulatorAgent(d))
    var served = ""
    try:
      served = bodyOf(httpExchange(agent.port, "GET",
        "/attestation?challenge=" & EmulatorChallenge, ""))
    finally:
      stopServed(agent)
    check served.len > 0
    let overSocket = parseAttestationReport(served, "<socket>")
    let inProcess = parseAttestationReport(
      emulatedReportText(d, EmulatorChallenge), "<renderer>")
    check overSocket.backend == inProcess.backend
    check overSocket.tier == inProcess.tier
    check overSocket.challenge == inProcess.challenge
    check overSocket.reportData == inProcess.reportData
    check authoritativeEvidence(overSocket) ==
      authoritativeEvidence(inProcess)
    check overSocket.certificatesForCrossCheck ==
      inProcess.certificatesForCrossCheck
    # The evidence is not trivially short, so "equal" is a statement
    # about a composite rather than about two empty strings.
    check authoritativeEvidence(overSocket).len > 1_000

  test "a valid emulated attestation is accepted and names the key that signed it":
    ## The positive control, and the one fact this work adds to the
    ## verification path: the signature over the attestation structure
    ## was verified under the public key of the leaf of the report's own
    ## bundled chain.
    let d = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone), nowSeconds)
    let run = buildRun(d, emNone, nowMillis)
    let v = verifyAttestationReport(verificationRequestFor(run))
    checkpoint($v.decision & " failed: " & $v.failedChecks)
    checkpoint(v.checks[vcNativeEvidence].detail)
    check v.decision == vdAccepted
    check v.failedChecks.len == 0
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcCertificateChain].outcome == coPassed
    check SignatureCheckedNotePrefix in v.checks[vcNativeEvidence].detail
    check AkCn in v.checks[vcNativeEvidence].detail
    # And the caveat that rides a reading in which nobody checked a
    # signature is ABSENT, because somebody did. Both directions matter:
    # the caveat present on every measured-boot verdict would say nothing,
    # and absent on every one would say nothing either.
    for c in v.caveats:
      check NoSignatureCheckedNote notin c
    check NoSignatureCheckedNote notin renderVerdictText(v)

    # The same evidence, with the chain removed from the envelope, is a
    # reading in which there was no key to check against — and the caveat
    # comes back. This is the other direction of the same rule, and it is
    # here rather than in a separate case so the two cannot drift apart.
    let report = parseAttestationReport(run.reportText, "<chainless>")
    let chainless = renderAttestationReport(attestationReport(
      report.backend, EmulatorTimestamp, report.challenge, report.bindings,
      authoritativeEvidence(report), report.claims, none(seq[string])))
    var chainlessRun = run
    chainlessRun.reportText = chainless
    let v2 = verifyAttestationReport(verificationRequestFor(chainlessRun))
    check v2.checks[vcNativeEvidence].outcome == coPassed
    # Asserted over the CAVEAT LIST and not over the rendered verdict.
    # The note has TWO producers — the caveat, and the reader's own
    # finding, which ends with it — so a search of the rendering is
    # satisfied by either. Measured: deleting the caveat entirely left
    # that search green. The caveat is a channel of its own and is the
    # one a reader of an acceptance consults.
    var statedAsCaveat = false
    for c in v2.caveats:
      if NoSignatureCheckedNote in c: statedAsCaveat = true
    check statedAsCaveat
    check SignatureCheckedNotePrefix notin v2.checks[vcNativeEvidence].detail

  test "the certified key is the emulator's own key, by value":
    ## "A certificate parsed and a signature verified" is not the claim.
    ## The claim is that the certificate the reader verified under is the
    ## certificate for the key this emulator signs with — so the two are
    ## compared as bytes, in both directions.
    let d = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone), nowSeconds)
    let leaf = parseCertificateBytes(d.emulatedChain[0])
    let mine = d.emulatedAkPublicKey
    check mine.len == leaf.publicKey.len
    var same = true
    for i in 0 ..< mine.len:
      if mine[i] != leaf.publicKey[i]: same = false
    check same
    # A second emulator in this same process signs with a different key,
    # so the comparison above is about key material and not about a
    # constant every emulator would satisfy.
    let other = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone),
                                      nowSeconds)
    let otherLeaf = parseCertificateBytes(other.emulatedChain[0])
    check otherLeaf.publicKey != leaf.publicKey
    # And this emulator's evidence does NOT verify under that one's key:
    # the join is a join and not a formality.
    let report = parseAttestationReport(
      emulatedReportText(d, EmulatorChallenge), "<mine>")
    var swapped = report.certificatesForCrossCheck
    swapped[0] = other.emulatedChain[0]
    let crossed = renderAttestationReport(attestationReport(
      report.backend, EmulatorTimestamp, report.challenge, report.bindings,
      authoritativeEvidence(report), report.claims, some(swapped)))
    var crossedRun = buildRun(d, emNone, nowMillis)
    crossedRun.reportText = crossed
    let v = verifyAttestationReport(verificationRequestFor(crossedRun))
    check v.checks[vcNativeEvidence].outcome == coFailed
    check "does not verify under the public key of the leaf" in
      v.checks[vcNativeEvidence].detail

  test "every fault trips the check it is declared to trip, and only that set":
    let dir = scratchDir()
    var details: seq[(EmulatorMutation, string, string)] = @[]
    try:
      for m in EmulatorMutation:
        checkpoint($m)
        let d = newEmulatedTpm2Driver(defaultEmulatorScenario(m), nowSeconds)
        let run = buildRun(d, m, nowMillis)
        let v = verifyAttestationReport(verificationRequestFor(run))
        let want = expectedDetection(m)
        var failing: set[VerifierCheck] = {}
        for chk in v.failedChecks: failing.incl chk
        checkpoint($v.decision & " failed: " & $v.failedChecks)
        check failing == want.failing
        if want.caught:
          check not v.decision.isAcceptance
          check want.check in failing
          let detail = v.checks[want.check].detail
          checkpoint(detail)
          check run.distinguisher.len > 0
          check run.distinguisher in detail
          details.add (m, detail, run.distinguisher)
        else:
          # Declared uncaught. It is an ACCEPTANCE, and the assertion is
          # what makes a build that grew a rule for it redden here rather
          # than quietly disagreeing with this file's own account.
          check v.decision == vdAccepted
    finally:
      removeDir(dir)

    # No two refusals hide behind one another. Each fault's distinguisher
    # must be absent from every other fault's detail — the measurement
    # that tells "this rule fired" apart from "something fired". The
    # distinguishers were collected in the pass above rather than
    # recomputed, so this compares the strings that were actually
    # asserted and not a second derivation of them.
    check details.len == EmulatorFaultCount - 1   # the TCB fault is uncaught
    for (m, detail, mine) in details:
      for (other, _, theirs) in details:
        if other == m: continue
        checkpoint($m & " must not carry " & $other & "'s mark: " & theirs)
        check theirs notin detail

  test "agent, CLI, service verifier and broker agree on every fault":
    ## The differential. One run per fault, four answers, and the
    ## agreement asserted is the answer each surface gives its own users:
    ## a decision, an exit status, and a release.
    for m in EmulatorMutation:
      checkpoint($m)
      let dir = scratchDir()
      try:
        let d = newEmulatedTpm2Driver(defaultEmulatorScenario(m), nowSeconds)
        let run = buildRun(d, m, nowMillis)
        let a = answersFor(run, dir)
        checkpoint("in-process " & $a.inProcess.decision & ", cli " &
          $a.cliExit & ", service " & $a.serviceExit & ", broker " &
          $a.brokerReleases)
        # The exit status is DERIVED from the decision by the command's
        # own total function, so this compares two channels of one verdict
        # rather than a value against itself.
        check a.cliExit == ord(attestExitCodeFor(a.inProcess.decision))
        check a.serviceExit == a.cliExit
        # The broker's release, against the command line's exit status —
        # two channels of two separate verifications, not a value against
        # the value it came from.
        check a.brokerReleases == (a.cliExit == AttestExitAccepted)
        # And the command line's rendered verdict names the same decision
        # its exit status encodes.
        check ("verdict: " & $a.inProcess.decision) in a.cliVerdictText
        let want = expectedDetection(m)
        if want.caught:
          check a.cliExit == AttestExitRejected
          check run.distinguisher in a.cliVerdictText
        else:
          check a.cliExit == AttestExitAccepted
      finally:
        removeDir(dir)

  test "the emulator's own diagnostic channels are read by somebody":
    ## Two channels this driver writes into, and a message nobody
    ## consumes is an absence wearing a log line.
    ##
    ## ``driverProbe``'s detail is what an operator looking at a machine
    ## that will not attest reads, and it reaches them through the
    ## daemon's ``/health`` body — so it is read HERE off the socket
    ## rather than off the record, because a field the daemon dropped on
    ## the way out would still look right in the record.
    let d = newEmulatedTpm2Driver(defaultEmulatorScenario(emEventLog),
                                  nowSeconds)
    var agent = startAgent(emulatorAgent(d))
    var health = ""
    try:
      health = bodyOf(httpExchange(agent.port, "GET", "/health", ""))
    finally:
      stopServed(agent)
    checkpoint(health)
    check "\"driver\": \"" & EmulatorDriverName & "\"" in health
    check "\"backendReady\": true" in health
    # The injected fault is NAMED in the body, which is the half that
    # could not be satisfied by a constant string.
    check ("injected fault: " & $emEventLog) in health
    check ("injected fault: " & $emNone) notin health

    # And the seam's own refusal: an emulator configured to quote no
    # register would sign the digest of the empty string, which is the
    # same on every machine. Without a case that asks for one, that rule
    # has no reachable input.
    var scenario = defaultEmulatorScenario()
    scenario.quotedRegisters = @[]
    var refused = ""
    try:
      discard newEmulatedTpm2Driver(scenario, nowSeconds)
    except DriverError as err:
      refused = err.msg
    checkpoint(refused)
    check "would sign the digest of the empty string" in refused
    # The positive control: the same constructor with the configured set
    # succeeds, so the refusal is about the set and not about the call.
    check newEmulatedTpm2Driver(defaultEmulatorScenario(),
      nowSeconds).emulatedChain.len == 3

  test "the broker completes a real key release against the real agent":
    ## The release decision above is a boolean, and a boolean nobody acts
    ## on is not a path. Here it is acted on: a key agreement is
    ## established against the running daemon, the report it answers with
    ## is verified, and the secret is presented only because the verdict
    ## was the narrow acceptance.
    let d = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone), nowSeconds)
    var agent = startAgent(emulatorAgent(d))
    try:
      let raw = httpExchange(agent.port, "POST", "/key-agreement",
        $(%*{"challenge": EmulatorChallenge}))
      check statusOf(raw) == 200
      let reportText = bodyOf(raw)
      let report = parseAttestationReport(reportText, "<key agreement>")
      check report.bindings.purpose == bpKeyAgreement
      check report.bindings.ephemeralPub.len > 0

      var run = buildRun(d, emNone, nowMillis, reportText = reportText)
      let v = verifyAttestationReport(verificationRequestFor(run))
      checkpoint($v.decision & " failed: " & $v.failedChecks)
      check v.decision == vdAccepted

      # Released, because the verdict was the narrow acceptance: the
      # secret is encrypted to the key THIS report bound, under the
      # context that session established, and the daemon decrypts it
      # into its runtime directory.
      let wrapped = base64.encode(wrapSecretForEphemeral(
        hexToBytes("ephemeralPub", report.bindings.ephemeralPub),
        hexToBytes("challenge", EmulatorChallenge),
        "broker-released", "a secret the broker holds",
        repeat('b', SeedBytes)))
      let released = httpExchange(agent.port, "POST", "/provision",
        $(%*{"ephemeralPub": report.bindings.ephemeralPub,
             "challenge": EmulatorChallenge,
             "name": "broker-released",
             "wrappedSecret": wrapped}))
      check statusOf(released) == 200
      check readFile(emulatorSecretsDir() / "broker-released") ==
            "a secret the broker holds"

      # And the single use is spent: the same release presented twice is
      # refused, so "released" is a state change rather than a message.
      let again = httpExchange(agent.port, "POST", "/provision",
        $(%*{"ephemeralPub": report.bindings.ephemeralPub,
             "challenge": EmulatorChallenge,
             "name": "broker-released",
             "wrappedSecret": wrapped}))
      check statusOf(again) == 404
    finally:
      stopServed(agent)

  test "the emulator cannot be steered by a caller, only constructed":
    ## The scenario is taken at construction. A request carries the 64
    ## bytes and nothing else, and this pins that the driver seam was not
    ## widened to carry a scenario — which is the change that would turn
    ## the emulator into something a remote caller could aim.
    ##
    ## Asserted as the request type's FIELD SET rather than as
    ## ``not compiles(QuoteRequest(mutation: ...))``. From outside, a
    ## field that does not exist and a field whose name was mistyped are
    ## the same compile error, so such a pin passes however it is
    ## misspelled; a field list the compiler had to produce cannot.
    static:
      var fields: seq[string] = @[]
      for name, _ in QuoteRequest().fieldPairs: fields.add name
      doAssert fields == @["reportData"], "QuoteRequest carries " & $fields

    # And the scenario DOES decide, which is what stops the paragraph
    # above from being a statement about an inert type. Measured on a
    # field of the signed structure rather than on "the bytes differ":
    # two emulators mint two hierarchies, so their output differs
    # whatever their scenarios say.
    let bytes = hexToBytes("reportData",
      reportDataHexFor(ReportBindings(purpose: bpAttest), EmulatorChallenge))
    let honest = newEmulatedTpm2Driver(defaultEmulatorScenario(emNone),
                                       nowSeconds)
    let faulty = newEmulatedTpm2Driver(defaultEmulatorScenario(emTcb),
                                       nowSeconds)
    proc firmwareOf(d: EmulatedTpm2Driver): uint64 =
      tpm2EvidenceQuote(parseTpm2Evidence(
        acquireQuote(d, bytes).evidence)).attest.firmwareVersion
    check firmwareOf(honest) == EmulatedFirmwareVersion
    check firmwareOf(faulty) == 0'u64
    # And one driver answers the same question the same way twice, so a
    # difference between two drivers is a difference between scenarios
    # and not between two calls.
    check acquireQuote(honest, bytes).evidence ==
      acquireQuote(honest, bytes).evidence
