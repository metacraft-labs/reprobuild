## The confidential-computing evidence emulators, driven through every
## protocol path, on valid evidence and on every structured fault.
##
## ## What this gate establishes
##
## Two emulated machines — one a security processor, one a trust domain
## — each produce one attestation carrying a measurement this build's
## own calculator computed over a real image. Four surfaces then reach a
## verdict about it: the agent that served it over a real socket, the
## in-process library verifier, the command line reading files off a
## filesystem, and the command line fetching the document over HTTP.
## They have to agree, on the unmutated attestation and on all nine
## faults, about the whole **check vector** and not merely about
## accept-or-reject.
##
## ## The measurement half is not this build's own invention, and that
## ## is the point of the first case
##
## The obvious way to write this gate is to compute a measurement, feed
## it to an emulator, and assert that the reader gives it back. That is
## a check whose two sides come from one source: it would pass however
## wrong the calculator was.
##
## So neither measurement originates here.
##
##   * The security processor's is the launch digest a REFERENCE
##     IMPLEMENTATION states for a named launch shape, parsed out of
##     that project's own test file rather than transcribed — and this
##     build's calculator is required to reproduce it from the same
##     firmware before a report is minted over it.
##   * The trust domain's is the ``MRTD`` a GENUINE QUOTE from a real
##     operator's machine carries, together with the four runtime
##     registers that operator's own measurement record replays to.
##     Both are required to equal what this build computes from the
##     firmware that operator publishes.
##
## So the value inside the emulated document is a value a real part
## signed, or one an unrelated implementation published. What is
## emulated is who signed it.
##
## ## Why the baseline is a rejection, and why that does not make this
## ## gate vacuous
##
## No emulated confidential-computing report can be accepted by this
## build — see ``cvm_evidence_emulator``'s header and the companion
## gate. A gate that compared only the decision would therefore be
## comparing four ways of saying no.
##
## What is compared is every row. Of the thirteen, two are SKIPPED on
## both backends — the policy states no evidence clause and requires no
## transparency-log inclusion, so neither question is asked — which
## leaves eleven performed. On the unmutated run TEN of those eleven
## PASS for the security processor and NINE for the trust domain: the
## signature over the evidence verifies under the bundled endorsement
## key, the measurement equals the manifest's expectation, the 64 bound
## bytes are the ones the challenge and the bindings produce, the
## challenge is fresh, the manifest is the one the policy pinned, and
## the platform version clears the policy's floor. The rows that fail
## are named, per backend, as a value. A verifier that refused
## everything would fail those ten too.
##
## ## Mocking
##
## None. Real ECDSA P-384, P-256 and RSASSA-PSS signatures, real DER,
## real PEM, the vendors' own byte layouts, a real socket, the real
## daemon and the real argument parser.
##
## The agent is configured with the shipped X25519 key source and a real
## secret store on a filesystem with no backing store, so nothing about
## the daemon is stood in for.

import std/[base64, json, net, options, os, posix, random, sequtils,
            strutils, tables, times, unittest]

import nimcrypto/[hash, sha2]

import repro_attest
import repro_attest/x25519_kem
import repro_attest/snp_launch
import repro_attest_agent
import repro_attest_verify
import repro_attest_verify/tdx_quote
import repro_cli_support/attest

import ./cvm_evidence_emulator
import ./cvm_emulator_scenarios

from ./tdx_launch_vectors import TdxLaunchVectors, QuoteOperatorB,
  RegisterLogOperatorB, lcOperatorB

include ./snp_digest_corpus

const
  SnpUpstreamShape = "test_snp_default"
    ## The named launch shape whose digest the reference implementation
    ## states. Named rather than indexed, so this gate quotes a row of
    ## upstream's file and not a position in it.

let nowSeconds = 1_790_000_000'i64
  ## A fixed instant. A gate that read the host's clock would begin
  ## failing on a date nobody chose, and the emulated hierarchies'
  ## validity windows are minted around this value.
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
  ## hand-written: this file has to be able to send exactly what it
  ## means to send.
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

proc bodyOf(raw: string): string =
  let at = raw.find("\r\n\r\n")
  if at < 0: "" else: raw[at + 4 .. ^1]

# ---------------------------------------------------------------------
# The two measurements, neither of them this build's own invention
# ---------------------------------------------------------------------

let snpStatedDigest = statedDigestFor(SnpUpstreamShape)
let snpComputedDigest =
  launchDigestHex(parametersFor(statedShapeFor(SnpUpstreamShape)))

let tdxGenuine = TdxLaunchVectors[lcOperatorB]
let tdxComputedMrtd = tdxMrtdHex(
  toOpenArrayByte(tdxGenuine.firmware, 0, tdxGenuine.firmware.len - 1),
  tdxGenuine.order)
let tdxReplay =
  foldTdxRegisters(readTdxMeasurementRecord(RegisterLogOperatorB))
let tdxGenuineQuote = parseTdxQuote(
  toOpenArrayByte(QuoteOperatorB, 0, tdxGenuine.documentBytes - 1))

proc replayedRegisters(): array[TdxRtMrCount, string] =
  for i in 0 ..< TdxRtMrCount:
    result[i] = toHexLower(tdxReplay.registers[i])

let measurements = CvmMeasurements(
  snpMeasurementHex: snpStatedDigest,
  tdxMrtdHex: tdxGenuine.mrtd,
  tdxRtmrHex: replayedRegisters(),
  ovmfDigest: DigestPrefix &
    sha256Hex(cvmStringOf(firmwareFor(statedShapeFor(SnpUpstreamShape)))),
  vcpus: statedShapeFor(SnpUpstreamShape).vcpus,
  vcpuType: "Milan")

# ---------------------------------------------------------------------
# The emulated machines
# ---------------------------------------------------------------------

var emulatorSecrets = ""

proc emulatorSecretsDir(): string =
  ## A directory on a filesystem with no backing store, found on the
  ## machine running the gate. The agent refuses anything else.
  if emulatorSecrets.len > 0: return emulatorSecrets
  for base in ["/dev/shm", "/run/user/" & $getuid(), getTempDir()]:
    if not dirExists(base): continue
    let candidate = base / ("repro-cvm-emulator-secrets-" &
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

proc emulatorAgent(d: AttestationDriver;
                   backend: CvmBackendUnderTest): AttestationAgent =
  ## The real daemon, with an emulator behind the driver seam and the
  ## honest manifest loaded.
  newAttestationAgent(
    driver = d,
    identity = AgentIdentity(generation: CvmGeneration),
    keySource = newX25519KeySource(),
    secretStore = newProvisionedSecretStore(emulatorSecretsDir()),
    manifestText = cvmManifestText(backend, measurements))

proc scratchDir(): string =
  result = getTempDir() / "repro-cvm-emulator-paths-" &
    $getCurrentProcessId() & "-" & $rand(1_000_000)
  createDir(result)

# ---------------------------------------------------------------------
# The four answers
# ---------------------------------------------------------------------

type
  PathAnswers = object
    inProcess: Verdict
    overSocket: Verdict
    cliExit: int
    serviceExit: int
    cliVerdictText: string
    servedDocument: string

proc rfc3339Of(ms: int64): string =
  utc(fromUnix(ms div 1000)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc cliArgsFor(run: CvmEmulatedRun; dir: string;
                reportArg: seq[string]): seq[string] =
  ## Exactly what a person would type.
  result = @["verify"]
  result.add reportArg
  result.add @["--policy", dir / "policy.toml",
               "--manifest", dir / "manifest.toml",
               "--challenge", run.expectedChallengeHex,
               "--challenge-issued-at", rfc3339Of(run.challengeIssuedAtMs),
               "--out", dir / "verdict.txt"]
  for i in 0 ..< run.vendorCrlDer.len:
    result.add @["--vendor-revocation-list",
                 dir / ("vendor-crl-" & $i & ".der")]

proc writeRunFiles(run: CvmEmulatedRun; dir: string) =
  writeFile(dir / "report.json", run.reportText)
  writeFile(dir / "policy.toml", run.policyText)
  writeFile(dir / "manifest.toml", run.manifestText)
  for i, der in run.vendorCrlDer:
    writeFile(dir / ("vendor-crl-" & $i & ".der"), der)

proc answersFor(backend: CvmBackendUnderTest;
                mutation: CvmEmulatorMutation;
                dir: string): tuple[run: CvmEmulatedRun, a: PathAnswers] =
  ## The same emulated machine, through every surface.
  ##
  ## The agent path and the in-process path share ONE driver instance,
  ## because the trust-domain driver mints its attestation key per
  ## instance: two instances are two machines, and comparing them would
  ## be comparing two attestations rather than two readings of one.
  let driver = cvmDriverFor(backend, measurements, mutation, nowSeconds)
  var agent = startAgent(emulatorAgent(driver, backend))
  var served = ""
  try:
    served = bodyOf(httpExchange(agent.port, "GET",
      "/attestation?challenge=" & CvmChallenge, ""))
  finally:
    stopServed(agent)
  result.a.servedDocument = served

  result.run = buildCvmRun(backend, measurements, mutation, nowSeconds,
                           withDriver = driver)
  writeRunFiles(result.run, dir)

  result.a.inProcess =
    verifyAttestationReport(cvmVerificationRequestFor(result.run))

  # The socket path: the document the DAEMON produced, verified with
  # everything else held fixed. The verification-layer faults are
  # applied to it too, exactly as they are to the renderer's document,
  # so the two paths answer the same question.
  var socketRun = buildCvmRun(backend, measurements, mutation, nowSeconds,
                              reportText = served, withDriver = driver)
  result.a.overSocket =
    verifyAttestationReport(cvmVerificationRequestFor(socketRun))

  result.a.cliExit = runAttestCommand(cliArgsFor(result.run, dir,
    @["--report-file", dir / "report.json"]))
  result.a.cliVerdictText = readFile(dir / "verdict.txt")

  # The service path: the SAME document, fetched over HTTP. The server
  # serves the RUN's bytes rather than the agent's, because three of
  # the faults are things an active party does to a document after the
  # machine produced it.
  let payload = result.run.reportText
  let handler = proc (req: HttpRequest): HttpResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      HttpResponse(status: 200, contentType: "application/json",
                   body: payload)
  var docServer = startServed(handler)
  try:
    result.a.serviceExit = runAttestCommand(cliArgsFor(result.run, dir,
      @["--report-url", "http://127.0.0.1:" & $uint16(docServer.port) &
        "/attestation"]))
  finally:
    stopServed(docServer)

proc failingSet(v: Verdict): set[VerifierCheck] =
  for c in VerifierCheck:
    if v.checks[c].outcome == coFailed: result.incl c

suite "confidential-computing evidence emulators: every protocol path":

  test "the nine faults are the nine this fixture set declares":
    ## The fixture set is constrained by its own gate. The ``case``
    ## functions over ``CvmEmulatorMutation`` already refuse to compile
    ## when a fault is added without a decision — but a build that does
    ## not compile measures nothing, so the enum is ALSO pinned here by
    ## a value that can go red: the count, and every spelling.
    var faults: seq[string] = @[]
    for m in CvmEmulatorMutation:
      if m != cemNone: faults.add $m
    check faults.len == CvmFaultCount
    check faults == @CvmFaultNames
    # And every fault has a site, with the two sets disjoint and
    # exhaustive.
    var evidenceSite, verificationSite = 0
    for m in CvmEmulatorMutation:
      case cvmFaultSite(m)
      of cfsEvidence: inc evidenceSite
      of cfsVerification: inc verificationSite
    check evidenceSite + verificationSite == CvmFaultCount + 1
    check verificationSite == 4

  test "neither measurement originates in this build":
    ## The premise the whole gate rests on, and the thing that stops it
    ## being a check whose two sides come from one source.
    ##
    ## The security processor's measurement is the digest a reference
    ## implementation states for a named launch shape, PARSED out of
    ## that project's own test file. The trust domain's is the MRTD a
    ## genuine quote carries, and the four runtime registers are the
    ## ones that operator's own measurement record replays to — checked
    ## against the registers inside the quote, which is a second
    ## publisher of the same four values.
    check snpStatedDigest.len == 96
    check snpComputedDigest == snpStatedDigest
    check tdxComputedMrtd == tdxGenuine.mrtd
    check tdxGenuineQuote.version == 4'u16
    let replayed = replayedRegisters()
    for i in 0 ..< TdxRtMrCount:
      checkpoint("rtmr" & $i)
      check replayed[i] == cvmHexOf(tdxGenuineQuote.body.rtMr[i])
    # The registers are not degenerate: a corpus in which they were all
    # the reset value would make the comparison above true of every
    # trust domain that ever existed.
    let reset = toHexLower(initialRtmr())
    for i in 0 ..< TdxRtMrCount:
      check replayed[i] != reset
    check tdxGenuine.mrtd != snpStatedDigest

  test "the unmutated run fails exactly the structural rows":
    ## The non-vacuity control. Every row a verifier could pass on
    ## emulated evidence DOES pass; the ones that fail are the two the
    ## pinned vendor roots make unreachable, named per backend as a
    ## value.
    for backend in CvmBackendUnderTest:
      checkpoint($backend)
      let run = buildCvmRun(backend, measurements, cemNone, nowSeconds)
      let v = verifyAttestationReport(cvmVerificationRequestFor(run))
      check not v.decision.isAcceptance
      check failingSet(v) == cvmBaselineFailures(backend)
      # Spelled out as well as compared, so a reader of a failure sees
      # which rows were expected to carry the weight.
      check v.checks[vcNativeEvidence].outcome == coPassed
      check v.checks[vcMeasurementMatch].outcome == coPassed
      check v.checks[vcReportDataBinding].outcome == coPassed
      check v.checks[vcManifestPinned].outcome == coPassed
      check v.checks[vcChallengeMatch].outcome == coPassed
      check v.checks[vcChallengeFreshness].outcome == coPassed
      check v.checks[vcCertificateChain].outcome == coFailed
      # The reading named the key it checked the signature under, which
      # is what separates "this parsed" from "a certified key said it".
      let report = parseAttestationReport(run.reportText, "<run>")
      let reading = readAuthoritativeEvidence(report)
      check reading.inputs.attestationKeySubject.isSome
      check reading.inputs.readerName in BuiltInReaders
      check reading.inputs.launchMeasurement.isSome
      case backend
      of cbSnp:
        check reading.inputs.launchMeasurement.get == snpStatedDigest
        check v.checks[vcTcbFloor].outcome == coPassed
        check reading.inputs.sevSnpTcb.isSome
      of cbTdx:
        check reading.inputs.launchMeasurement.get == tdxGenuine.mrtd
        check v.checks[vcTcbFloor].outcome == coFailed

  test "every fault moves exactly the rows it declares":
    for backend in CvmBackendUnderTest:
      let baseline = cvmBaselineFailures(backend)
      for mutation in CvmEmulatorMutation:
        if mutation == cemNone: continue
        checkpoint($backend & " / " & $mutation)
        let run = buildCvmRun(backend, measurements, mutation, nowSeconds)
        let v = verifyAttestationReport(cvmVerificationRequestFor(run))
        let expected = cvmExpectedDetection(backend, mutation)
        check not v.decision.isAcceptance
        check failingSet(v) == baseline + expected.adds
        if expected.caught:
          check v.checks[expected.check].outcome == coFailed
          check run.distinguisher.len > 0
          check run.distinguisher in v.checks[expected.check].detail

  test "a fault declared uncaught changes no byte of the evidence":
    ## The mechanical half of a declaration that would otherwise be a
    ## hope. ``cemTcb`` has no trust-domain expression — a trust
    ## domain's platform version is judged against vendor documents the
    ## verifier holds — and the way to prove "nothing happened" is to
    ## show the bytes are the same, not to observe that no row moved.
    ##
    ## The security processor's ``cemTcb`` is the control: there the
    ## fault DOES move bytes, so a comparison that passed for both
    ## would be comparing nothing.
    for backend in CvmBackendUnderTest:
      checkpoint($backend)
      let driver = cvmDriverFor(backend, measurements, cemNone, nowSeconds)
      let faulted = cvmDriverFor(backend, measurements, cemTcb, nowSeconds)
      let bytes = acquireQuote(driver, hexToBytes("reportData",
        reportDataHexFor(ReportBindings(purpose: bpAttest,
                                        ephemeralPub: ""), CvmChallenge)))
      let faultedBytes = acquireQuote(faulted, hexToBytes("reportData",
        reportDataHexFor(ReportBindings(purpose: bpAttest,
                                        ephemeralPub: ""), CvmChallenge)))
      let declared = cvmExpectedDetection(backend, cemTcb)
      case backend
      of cbTdx:
        check not declared.caught
        check bytes.evidence == faultedBytes.evidence
      of cbSnp:
        check declared.caught
        check bytes.evidence != faultedBytes.evidence

  test "each fault's distinguisher belongs to it alone":
    ## A distinguisher that appeared in two faults' details would let
    ## one of them keep passing after it stopped working.
    for backend in CvmBackendUnderTest:
      var details = initTable[CvmEmulatorMutation, string]()
      var marks = initTable[CvmEmulatorMutation, string]()
      for mutation in CvmEmulatorMutation:
        let run = buildCvmRun(backend, measurements, mutation, nowSeconds)
        let v = verifyAttestationReport(cvmVerificationRequestFor(run))
        var all = ""
        for c in VerifierCheck: all.add v.checks[c].detail & "\n"
        details[mutation] = all
        marks[mutation] = run.distinguisher
      for mutation in CvmEmulatorMutation:
        if marks[mutation].len == 0: continue
        checkpoint($backend & " / " & $mutation & ": " & marks[mutation])
        check marks[mutation] in details[mutation]
        for other in CvmEmulatorMutation:
          if other == mutation: continue
          checkpoint("  also in " & $other & "?")
          check marks[mutation] notin details[other]

  test "every protocol path agrees, on every fault":
    ## The headline. Four surfaces, one attestation, and the comparison
    ## is of the whole check vector rather than of a boolean — the
    ## command line's contribution being its EXIT STATUS, which is the
    ## only part of a verdict a shell script reads.
    let dir = scratchDir()
    try:
      for backend in CvmBackendUnderTest:
        for mutation in CvmEmulatorMutation:
          checkpoint($backend & " / " & $mutation)
          let (run, a) = answersFor(backend, mutation, dir)
          check not a.inProcess.decision.isAcceptance
          check failingSet(a.overSocket) == failingSet(a.inProcess)
          check a.overSocket.decision == a.inProcess.decision
          # A rejected verdict is a non-zero exit on both command-line
          # surfaces, and the two agree with each other.
          check a.cliExit != 0
          check a.serviceExit == a.cliExit
          check a.cliVerdictText.len > 0
          check "rejected" in a.cliVerdictText
          # The command line's own text names the rows that failed, so
          # the exit status is not the only thing the two surfaces are
          # compared on.
          for c in failingSet(a.inProcess):
            checkpoint("  cli names " & $c)
            check $c in a.cliVerdictText
          discard run
    finally:
      removeDir(dir)

  test "the agent adds nothing to what the driver produced":
    ## The report the daemon serves over a socket and the report the
    ## renderer produces in process are the same attestation. Asserted
    ## field by field rather than as a byte comparison, because the
    ## informational timestamp comes from the daemon's clock and is the
    ## one field that legitimately differs.
    for backend in CvmBackendUnderTest:
      checkpoint($backend)
      let driver = cvmDriverFor(backend, measurements, cemNone, nowSeconds)
      var agent = startAgent(emulatorAgent(driver, backend))
      var served = ""
      try:
        served = bodyOf(httpExchange(agent.port, "GET",
          "/attestation?challenge=" & CvmChallenge, ""))
      finally:
        stopServed(agent)
      check served.len > 0
      let overSocket = parseAttestationReport(served, "<socket>")
      let inProcess = parseAttestationReport(
        emulatedCvmReportText(driver, cvmBackendOf(backend), CvmChallenge),
        "<renderer>")
      check overSocket.backend == inProcess.backend
      check overSocket.tier == atCvm
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

  test "the emulated documents are the vendors' own wire formats":
    ## The readers accept them, which is most of the statement — but a
    ## reader that accepted anything would accept them too. So the
    ## document's own structural invariants are checked against the
    ## format's constants rather than against what the emulator wrote.
    let snpDriver = cvmDriverFor(cbSnp, measurements, cemNone, nowSeconds)
    let snpQuote = acquireQuote(snpDriver, hexToBytes("reportData",
      reportDataHexFor(ReportBindings(purpose: bpAttest, ephemeralPub: ""),
                       CvmChallenge)))
    check snpQuote.evidence.len == SnpReportLen
    let report = parseSnpReport(toOpenArrayByte(snpQuote.evidence, 0,
      snpQuote.evidence.len - 1))
    check report.version in SnpSupportedVersions
    check report.signatureAlgo == SnpSignatureAlgoEcdsaP384Sha384
    check report.signingKey == skkVcek
    check report.measurement.len == LenMeasurement
    check report.chipId.len == LenChipId
    check cvmHexOf(report.measurement) == snpStatedDigest
    check snpQuote.certificates.isSome
    check snpQuote.certificates.get.len == AmdChainElements

    let tdxDriver = cvmDriverFor(cbTdx, measurements, cemNone, nowSeconds)
    let tdxQuoteBytes = acquireQuote(tdxDriver, hexToBytes("reportData",
      reportDataHexFor(ReportBindings(purpose: bpAttest, ephemeralPub: ""),
                       CvmChallenge)))
    let quote = parseTdxQuote(toOpenArrayByte(tdxQuoteBytes.evidence, 0,
      tdxQuoteBytes.evidence.len - 1))
    check quote.version == TdxQuoteVersion4
    check quote.teeType == TdxTeeType
    check quote.attestationKeyType == TdxAttestationKeyTypeEcdsaP256
    check quote.pckChain.len == TdxChainElements
    check cvmHexOf(quote.body.mrTd) == tdxGenuine.mrtd
    for i in 0 ..< TdxRtMrCount:
      check cvmHexOf(quote.body.rtMr[i]) == measurements.tdxRtmrHex[i]
    # The three signatures and the binding, checked here as well as in
    # the reader, because the reader is the thing whose agreement with
    # this emulator the gate is about.
    check verifyQuoteSignature(quote)
    check verifyQeReportSignature(quote,
      parseCertificate(quote.pckChain[0]).publicKey)
    check qeReportBindsAttestationKey(quote).isBound
