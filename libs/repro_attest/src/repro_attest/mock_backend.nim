## The mock backend: a root of trust that does not exist, and says so.
##
## ## What it is for
##
## The agent, the verifier, the provisioning protocol and every downstream
## integration test need to run on a laptop, in CI, and inside a container
## with no TPM and no confidential-computing extensions. The mock backend
## is what they run against. It produces a schema-valid report over
## evidence in a documented format, so the code paths exercised are the
## real ones — parsing, binding, session handling, transport — with only
## the hardware replaced.
##
## ## Why it is safe to ship
##
## Not because it is hidden, and not because it is disabled by default.
## It is safe because *nothing it produces can claim to be anything else*:
##
##   * Its backend is ``mock``, and a tier is never a driver's choice —
##     ``tierOf(abMock)`` is ``atMock`` and ``report`` refuses a backend
##     outside the tier naming it. A mock report is a ``mock``-tier report
##     however it is assembled, and a policy is written against the tier.
##     This is the load-bearing refusal; everything below is the belt to
##     its braces.
##   * Its signature is a MAC under a key that is a literal in this file
##     and is repeated inside the evidence itself. Anyone can forge it,
##     which is the point: it is *verifiable* — so a verifier can
##     implement a real check rather than a special case — and worth
##     nothing, so passing that check establishes nothing.
##   * Its certificate chain names its own root ``NOT-A-TRUST-ANCHOR`` in
##     the bytes, so a chain that reaches a log or a bug report is
##     self-describing.
##
## A verifier accepts mock evidence only when explicitly configured to,
## and that configuration is refused alongside pinned production
## measurements. Neither of those rules lives here — they are the
## verifier's, and a backend that could grant itself trust would not be a
## backend.
##
## ## The evidence format
##
## Line-oriented ASCII, because a mock's evidence is read by people::
##
##   reproos.mock-evidence.v1
##   backend: mock
##   launchMeasurement: <64 lower-case hex>
##   reportData: <128 lower-case hex>
##   keyIsPublished: <the signing key, in the clear>
##   signature: <128 lower-case hex>
##
## Every line ends with ``\n``, including the last. The signature is
## HMAC-SHA-512 under ``MockSigningKey`` over every preceding byte — the
## five lines above it, terminators included — so a truncated or reordered
## document does not verify.
##
## ``launchMeasurement`` is a published constant rather than a measurement
## of anything: the mock backend measures no boot, and a value derived
## from the running system would be a measurement in the sense that
## matters least — one the thing being measured chose.
##
## ## Mocking
##
## This module *is* the mock, and that is its declared purpose rather
## than a test convenience: it implements the backend interface for a
## root of trust that is absent, and nothing in it stands in for a
## component that exists. It performs no I/O, opens no device and reads
## nothing from the host, so it has nothing to stub out.

import std/[options, strutils]

import nimcrypto/[hash, hmac, sha2]

import ./binding
import ./driver
import ./report

const
  MockEvidenceSchema* = "reproos.mock-evidence.v1"
    ## Versioned like everything else on this wire. A change to the
    ## format is a new schema, not a new reading of this one.

  MockDriverName* = "mock"

  MockSigningKey* = "reproos-mock-attestation-key-not-secret"
    ## Published, deliberately. A secret here would be a lie about what a
    ## mock signature is worth; a caller who can read this file can forge
    ## every mock report ever produced, and should be able to.

  MockRootName* = "MOCK-ROOT-NOT-A-TRUST-ANCHOR"

  MockLaunchMeasurement* =
    "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    ## SHA-256 of the ASCII string ``test``, used here as a value that is
    ## obviously not a measurement of anything. Regenerable with
    ## ``printf 'test' | sha256sum``. A constant is the honest choice: the
    ## mock backend measures no boot, so any value it computed from the
    ## running system would be one the measured thing chose for itself.

  MockCertificateSchema* = "reproos.mock-certificate.v1"

type
  MockDriver* = ref object of AttestationDriver
    ## The driver. It has no state, no handles and nothing to close.

  MockEvidence* = object
    ## A parsed ``reproos.mock-evidence.v1`` document.
    launchMeasurement*: string
    reportDataHex*: string
    signatureHex*: string

  MockEvidenceError* = object of CatchableError
    ## Raised for a document this codec will not read. Parsing is strict
    ## for the same reason the envelope's is: a lenient reader of
    ## attestation evidence believes things nobody said.

# ---------------------------------------------------------------------
# The signature
# ---------------------------------------------------------------------

proc hmacSha512Hex(key, data: string): string =
  var ctx: HMAC[sha512]
  ctx.init(key)
  ctx.update(data)
  result = toLowerAscii($ctx.finish())
  ctx.clear()

proc mockSignedBody(reportDataHex: string): string =
  ## Everything the signature covers: the document up to but not
  ## including the signature line.
  result = MockEvidenceSchema & "\n"
  result.add "backend: " & $abMock & "\n"
  result.add "launchMeasurement: " & MockLaunchMeasurement & "\n"
  result.add "reportData: " & reportDataHex & "\n"
  result.add "keyIsPublished: " & MockSigningKey & "\n"

proc mockEvidenceSignatureFor*(reportDataHex: string): string =
  ## The MAC a well-formed mock document carries for these 64 bytes.
  ##
  ## Exposed so a reader can recompute it instead of comparing against a
  ## constant it was handed. What recomputing establishes is that the
  ## document is *well-formed*, and nothing whatever about whether it is
  ## trustworthy — the key is three lines up in this file.
  hmacSha512Hex(MockSigningKey, mockSignedBody(reportDataHex))

proc renderMockEvidence*(reportDataHex: string): string =
  ## The bytes a mock quote consists of.
  if reportDataHex.len != ReportDataHexLen or not isLowerHex(reportDataHex):
    raise newException(MockEvidenceError,
      "mock evidence carries " & $ReportDataHexLen &
      " lower-case hex characters of report data, got " &
      reportDataHex.escape())
  result = mockSignedBody(reportDataHex)
  result.add "signature: " & mockEvidenceSignatureFor(reportDataHex) & "\n"

proc parseMockEvidence*(text: string): MockEvidence =
  ## Read a mock document. Strict: exactly six lines, in order, each with
  ## its expected key, and a signature that recomputes.
  ##
  ## This is the backend's serialization half, which is the backend's to
  ## own. It reaches no verdict and there is deliberately no call here
  ## that could be mistaken for one.
  let lines = text.split('\n')
  # Six content lines plus the empty string after the final terminator.
  if lines.len != 7 or lines[6].len != 0:
    raise newException(MockEvidenceError,
      "mock evidence is six newline-terminated lines; got " &
      $(lines.len - 1) & " and " &
      (if lines.len > 0 and lines[^1].len != 0: "no final terminator"
       else: "a final terminator"))
  if lines[0] != MockEvidenceSchema:
    raise newException(MockEvidenceError,
      "mock evidence begins " & lines[0].escape() & "; this build reads " &
      MockEvidenceSchema.escape())

  proc field(idx: int; key: string): string =
    let want = key & ": "
    if not lines[idx].startsWith(want):
      raise newException(MockEvidenceError,
        "mock evidence line " & $(idx + 1) & " must begin " & want.escape() &
        ", got " & lines[idx].escape())
    lines[idx][want.len .. ^1]

  let backend = field(1, "backend")
  if backend != $abMock:
    raise newException(MockEvidenceError,
      "mock evidence names backend " & backend.escape() &
      "; this format carries " & ($abMock).escape() & " and nothing else")
  result.launchMeasurement = field(2, "launchMeasurement")
  result.reportDataHex = field(3, "reportData")
  let publishedKey = field(4, "keyIsPublished")
  result.signatureHex = field(5, "signature")

  if result.launchMeasurement != MockLaunchMeasurement:
    raise newException(MockEvidenceError,
      "mock evidence carries launch measurement " &
      result.launchMeasurement.escape() & "; this build publishes " &
      MockLaunchMeasurement)
  if result.reportDataHex.len != ReportDataHexLen or
     not isLowerHex(result.reportDataHex):
    raise newException(MockEvidenceError,
      "mock evidence reportData must be " & $ReportDataHexLen &
      " lower-case hex characters, got " & result.reportDataHex.escape())
  if publishedKey != MockSigningKey:
    raise newException(MockEvidenceError,
      "mock evidence names signing key " & publishedKey.escape() &
      "; this build signs with " & MockSigningKey.escape())
  let expected = mockEvidenceSignatureFor(result.reportDataHex)
  if result.signatureHex != expected:
    raise newException(MockEvidenceError,
      "mock evidence signature is " & result.signatureHex.escape() &
      " but the document's own contents are signed as " & expected)

proc mockCertificateChain*(): seq[string] =
  ## The well-known non-genuine chain, leaf first.
  ##
  ## It is not X.509 and does not pretend to be. A chain that parsed as a
  ## certificate would be a chain something might try to validate, and
  ## the shape a verifier should reach for when it wants a real chain
  ## signed by a root production can never trust is a test PKI — which is
  ## a different thing from a mock, built separately, in production
  ## encodings.
  @[MockCertificateSchema & " subject=mock-attestation-key issuer=" &
      "mock-intermediate\n",
    MockCertificateSchema & " subject=mock-intermediate issuer=" &
      MockRootName & "\n",
    MockCertificateSchema & " subject=" & MockRootName & " issuer=" &
      MockRootName & " selfSigned=true\n"]

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

method driverProbe*(d: MockDriver): BackendReadiness =
  BackendReadiness(ready: true,
    detail: "mock backend: no root of trust, evidence signed with the " &
      "published key " & MockSigningKey)

method driverQuote*(d: MockDriver; req: QuoteRequest): QuoteResult =
  QuoteResult(
    evidence: renderMockEvidence(bytesToHex(req.reportData)),
    certificates: some(mockCertificateChain()))

proc newMockDriver*(): MockDriver =
  ## The only constructor, and it takes no backend argument: a mock
  ## driver is a ``mock``-backend driver and there is no spelling of this
  ## call that produces another one.
  result = MockDriver()
  initAttestationDriver(result, abMock, MockDriverName)

# ---------------------------------------------------------------------
# The mock key source
# ---------------------------------------------------------------------

const
  MockKeyAlgorithm* = "mock-not-a-kem"
    ## Named so it cannot be mistaken for a key-encapsulation mechanism
    ## anyone should encrypt to. It is not X25519 and does not claim the
    ## name: a 32-byte string that *looks* like an X25519 public key but
    ## has no private half would be worse than an obvious placeholder,
    ## because a secret encapsulated to it is a secret destroyed.

  MockEphemeralSecret* = "reproos-mock-ephemeral-secret-not-secret"

type
  MockKeySource* = ref object of EphemeralKeySource
    ## Deterministic, published, and clearly not a KEM.
    ##
    ## It exists so the key-agreement endpoint, the binding of the public
    ## key into the evidence, and the single-use session lifecycle can be
    ## exercised end to end without a key-encapsulation mechanism being
    ## implemented first. Those three are what this library owes; the
    ## mechanism is built separately and plugs in here.
    counter: int

method generateEphemeralKeyPair*(s: MockKeySource): EphemeralKeyPair =
  ## A fresh pair per call — fresh so two sessions are two sessions, and
  ## derived rather than random so a test can say which one it got.
  inc s.counter
  let seed = MockEphemeralSecret & ":" & $s.counter
  let priv = $sha512.digest(seed)
  let pub = $sha256.digest("public:" & seed)
  EphemeralKeyPair(publicKey: parseHexStr(toLowerAscii(pub)),
                   privateKey: parseHexStr(toLowerAscii(priv)))

proc newMockKeySource*(): MockKeySource =
  result = MockKeySource()
  initEphemeralKeySource(result, MockKeyAlgorithm)
