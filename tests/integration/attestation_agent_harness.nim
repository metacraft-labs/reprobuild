## Shared driving code for the attestation-agent gates.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``tc5_cert_signing_helpers.nim`` follows — and ``include``d rather than
## imported, so each gate compiles one binary with no extra edge.
##
## ## What it is, and what it deliberately is not
##
## It is a real listening socket and a real HTTP client. The daemon runs
## in a thread inside the test binary and is spoken to over TCP on
## loopback, so every gate exercises the transport, its bounds and the
## endpoint logic together. Nothing here stands in for the server: there
## is no in-process shortcut around ``httpd``, because the request-size
## bounds and the rate limiter live inside the read loop and a test that
## called the handler directly would prove nothing about either.
##
## The client is hand-written for the same reason the server is. Two of
## the three gates need to send bytes that are not a valid request — a
## request line longer than the bound, a ``Content-Length`` that lies, a
## header block that never ends — and an HTTP client library exists
## precisely to stop a caller doing that.
##
## ## Mocking
##
## None. The backend under test is the mock *backend* — an implementation
## of the driver interface for a root of trust that is absent — which is
## the thing under test rather than a substitute for it.

import std/[net, options, strutils, times]

import repro_attest
import repro_attest_agent

type
  AgentHarness = object
    server: HttpServer
    thread: Thread[HttpServer]
    port: Port

  RawResponse = object
    status: int
    reason: string
    body: string
    raw: string

const
  # Deliberately small, so each bound can be reached in a test without
  # sending megabytes and without waiting five seconds for a read to give
  # up. Used ONLY by the abuse gate, and passed explicitly there: the
  # functional gates run against `defaultAgentLimits()`, which is what a
  # deployment gets, so they also show that the shipped defaults do not
  # refuse ordinary use.
  AbuseReadTimeoutMs = 300
  AbuseConnectionDeadlineMs = 1_200
  AbuseMaxBodyBytes = 1_024
  AbuseMaxRequestLineBytes = 512
  AbuseMaxHeaderBytes = 1_024
  AbuseMaxHeaderCount = 8
  AbuseRateCapacity = 40.0
  AbuseRateRefillPerSecond = 4.0
  AbusePerClientCapacity = 20.0
  AbusePerClientRefillPerSecond = 2.0

  SampleGeneration = "gen-2026-09-10-0001"
  SampleFingerprint = "reproos-attested-uefi:sample"
  SampleVerityRootHash =
    "1111111111111111111111111111111111111111111111111111111111111111"

  # 32 bytes, comfortably over the 128-bit floor.
  ChallengeA = "a1b2c3d4e5f60718293a4b5c6d7e8f90" &
               "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
  ChallengeB = "0011223344556677" & "8899aabbccddeeff" &
               "ffeeddccbbaa9988" & "7766554433221100"
  ShortChallenge = "0011223344556677"  # 8 bytes, below the floor

proc abuseLimits(): AgentLimits =
  result = defaultAgentLimits()
  result.readTimeoutMs = AbuseReadTimeoutMs
  result.connectionDeadlineMs = AbuseConnectionDeadlineMs
  result.maxBodyBytes = AbuseMaxBodyBytes
  result.maxRequestLineBytes = AbuseMaxRequestLineBytes
  result.maxHeaderBytes = AbuseMaxHeaderBytes
  result.maxHeaderCount = AbuseMaxHeaderCount
  result.rateCapacity = AbuseRateCapacity
  result.rateRefillPerSecond = AbuseRateRefillPerSecond
  result.perClientCapacity = AbusePerClientCapacity
  result.perClientRefillPerSecond = AbusePerClientRefillPerSecond

proc sampleIdentity(): AgentIdentity =
  AgentIdentity(generation: SampleGeneration,
                configFingerprint: SampleFingerprint,
                verityRootHash: SampleVerityRootHash)

proc sampleAgent(withKeySource = true): AttestationAgent =
  newAttestationAgent(
    driver = newMockDriver(),
    identity = sampleIdentity(),
    keySource = (if withKeySource: newMockKeySource() else: nil))

# ---------------------------------------------------------------------
# The daemon, in a thread
# ---------------------------------------------------------------------

proc serveThread(s: HttpServer) {.thread.} =
  s.serve()

proc startHarness(agent: AttestationAgent;
                  l = defaultAgentLimits()): AgentHarness =
  ## Port 0, so a test never collides with a port something else on this
  ## host is using and never has to guess whether it did.
  result.server = newAgentServer(agent, "127.0.0.1", Port(0), l)
  result.port = result.server.boundPort
  createThread(result.thread, serveThread, result.server)

proc stopHarness(h: var AgentHarness) =
  ## Set the flag, then open one connection so the blocked ``accept``
  ## returns and the loop sees it. ``joinThread`` afterwards is what
  ## makes "the daemon is still alive" a measured claim rather than an
  ## assumed one: a loop that had died would have been joined already,
  ## and one that had wedged would never join.
  h.server.requestStop()
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", h.port)
    poke.close()
  except CatchableError:
    discard
  joinThread(h.thread)
  h.server.close()

# ---------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------

proc clientSend(s: Socket; payload: string): bool =
  ## The client half of the same problem the daemon has, and it bit this
  ## harness before it was written down. ``std/net``'s string ``send``
  ## retries until every byte is written and swallows disconnection
  ## errors, so writing to a socket the daemon has already closed spins
  ## forever instead of failing. Every gate below writes to sockets the
  ## daemon is expected to close, so the test client uses the daemon's
  ## own bounded writer.
  sendFully(s, payload, epochTime() + 5.0)

proc rawExchange(port: Port; payload: string;
                 timeoutMs = 4_000): string =
  ## Send exactly these bytes, read until the server closes. Returns the
  ## empty string when the server answered nothing, which is itself an
  ## outcome a gate asserts.
  result = ""
  var s: Socket
  try:
    s = newSocket(buffered = false)
  except CatchableError:
    return ""
  try:
    s.connect("127.0.0.1", port)
    if payload.len > 0 and not clientSend(s, payload): return ""
    while true:
      var chunk = ""
      var got = 0
      try:
        got = s.recv(chunk, 8_192, timeoutMs)
      except TimeoutError:
        break
      except OSError:
        break
      if got <= 0: break
      result.add chunk[0 ..< got]
  except CatchableError:
    discard
  finally:
    try: s.close()
    except CatchableError: discard

proc parseRawResponse(raw: string): RawResponse =
  result.raw = raw
  result.status = 0
  if raw.len == 0: return
  let headEnd = raw.find("\r\n\r\n")
  let head = (if headEnd < 0: raw else: raw[0 ..< headEnd])
  result.body = (if headEnd < 0: "" else: raw[headEnd + 4 .. ^1])
  let firstLine = head.split("\r\n")[0]
  let parts = firstLine.split(' ')
  if parts.len >= 2:
    try:
      result.status = parseInt(parts[1])
    except ValueError:
      result.status = 0
  if parts.len >= 3:
    result.reason = parts[2 .. ^1].join(" ")

proc request(port: Port; verb, target: string; body = "";
             extraHeaders: seq[string] = @[]): RawResponse =
  var payload = verb & " " & target & " HTTP/1.1\r\n"
  payload.add "Host: 127.0.0.1\r\n"
  for h in extraHeaders: payload.add h & "\r\n"
  if body.len > 0 or verb == "POST":
    payload.add "Content-Type: application/json\r\n"
    payload.add "Content-Length: " & $body.len & "\r\n"
  payload.add "\r\n"
  payload.add body
  parseRawResponse(rawExchange(port, payload))

proc get(port: Port; target: string): RawResponse =
  request(port, "GET", target)

proc post(port: Port; target, body: string): RawResponse =
  request(port, "POST", target, body)

# ---------------------------------------------------------------------
# A measurement manifest to serve
# ---------------------------------------------------------------------

proc sampleManifestText(): string =
  ## Built as a record and rendered by the library, so the bytes are the
  ## canonical spelling of the schema rather than a literal that could
  ## drift away from it. The expectation lists are empty on purpose: what
  ## is under test here is that the agent serves the published bytes and
  ## takes its claims from them, not what any backend expects.
  renderAttestedImageManifest(AttestedImageManifest(
    configFingerprint: SampleFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix &
        "3333333333333333333333333333333333333333333333333333333333333333",
      verityImage: DigestPrefix &
        "4444444444444444444444444444444444444444444444444444444444444444",
      verityRootHash: SampleVerityRootHash)))

# ---------------------------------------------------------------------
# Drivers that misbehave, so the seam's refusals are shown to fire
# ---------------------------------------------------------------------

type
  LyingDriver = ref object of AttestationDriver
    ## Signs bytes other than the ones it was handed. Not a mock of a
    ## driver — it is a driver, and it is the shape a fault-injecting
    ## emulator takes.

  EmptyEvidenceDriver = ref object of AttestationDriver
  EmptyChainDriver = ref object of AttestationDriver

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

method driverProbe(d: EmptyEvidenceDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "returns nothing")

method driverQuote(d: EmptyEvidenceDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(evidence: "", certificates: none(seq[string]))

proc newEmptyEvidenceDriver(): EmptyEvidenceDriver =
  result = EmptyEvidenceDriver()
  initAttestationDriver(result, abMock, "empty-evidence")

method driverProbe(d: EmptyChainDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "returns a chain of nothing")

method driverQuote(d: EmptyChainDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(evidence: renderMockEvidence(bytesToHex(req.reportData)),
              certificates: some(newSeq[string]()))

proc newEmptyChainDriver(): EmptyChainDriver =
  result = EmptyChainDriver()
  initAttestationDriver(result, abMock, "empty-chain")

type
  BigChainDriver = ref object of AttestationDriver
    ## Bundles the largest chain the envelope will carry.
    ##
    ## Not a curiosity: an SEV-SNP instance really does bundle a
    ## certificate chain, and the envelope's own bounds are sixteen
    ## certificates of sixty-four kilobytes. A response near that size is
    ## far larger than a socket buffer, which is the only way a write can
    ## complete PARTIALLY and then fail -- and a partial-then-failing
    ## write is the exact condition under which the standard library's
    ## `send` never terminates.

method driverProbe(d: BigChainDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "bundles a maximal chain")

method driverQuote(d: BigChainDriver; req: QuoteRequest): QuoteResult =
  var chain: seq[string] = @[]
  for i in 0 ..< MaxCertificates:
    chain.add repeat(char(ord('A') + i), 48_000)
  QuoteResult(evidence: renderMockEvidence(bytesToHex(req.reportData)),
              certificates: some(chain))

proc newBigChainDriver(): BigChainDriver =
  result = BigChainDriver()
  initAttestationDriver(result, abMock, "big-chain")

type
  CvmShapedDriver = ref object of AttestationDriver
    ## Produces SEV-SNP-shaped evidence without being the SEV-SNP driver.
    ##
    ## The shape a software-root emulator takes, and the only shape in
    ## which the seam's "the tier is never a driver's to choose" claim can
    ## be checked at all: for the mock, ``tierOf(abMock)`` IS ``atMock``,
    ## so a seam that returned a constant tier would agree with a seam
    ## that derived it, and no mock-backed check could tell them apart.

  HugeEvidenceDriver = ref object of AttestationDriver
    ## Returns more evidence than the envelope will carry.

method driverProbe(d: CvmShapedDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "a test root wearing SNP's shape")

method driverQuote(d: CvmShapedDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(evidence: req.reportData, certificates: none(seq[string]))

proc newCvmShapedDriver(): CvmShapedDriver =
  result = CvmShapedDriver()
  initAttestationDriver(result, abSevSnp, "software-root-emulator")

method driverProbe(d: HugeEvidenceDriver): BackendReadiness =
  BackendReadiness(ready: true, detail: "returns more than fits")

method driverQuote(d: HugeEvidenceDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(evidence: repeat('E', (MaxEvidenceBase64 div 4) * 3 + 1),
              certificates: none(seq[string]))

proc newHugeEvidenceDriver(): HugeEvidenceDriver =
  result = HugeEvidenceDriver()
  initAttestationDriver(result, abMock, "huge-evidence")
