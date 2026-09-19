## The attestation agent: what each endpoint means, and what it refuses.
##
## ## The shape of this module
##
## Every endpoint is a pure function of a request, the agent's state and
## the current time. Nothing here opens a socket, and the clock is a
## parameter rather than something read from the environment. That is not
## a testing convenience — it is what lets the whole endpoint surface be
## exercised, including a session expiring, without a stub standing in
## for anything and without a test that sleeps.
##
## ## The API, and the decisions inside it
##
## ``GET /health`` — liveness, with the root of trust's availability
## *reported* rather than signalled by the status code. It answers 200
## even when the backend is unavailable, deliberately: a health endpoint
## that answers 503 gets wired to a supervisor that restarts the process,
## and restarting the agent does not conjure a TPM. What an operator
## needs is the daemon saying, in the body, which piece is missing.
##
## ``GET /attestation`` — a report bound to a caller-supplied challenge.
## It deliberately does **not** refuse a challenge it has already
## answered. That would look like replay protection and is not: the
## challenge is the *verifier's* freshness input, so refusing a repeat
## hands anyone who can observe a challenge a way to deny the legitimate
## verifier its answer, while protecting nothing — a replayed report is
## caught by the verifier noticing it did not issue that challenge.
## Freshness is minted, not policed.
##
## ``POST /key-agreement`` — the endpoint that *does* hold state, and
## therefore the one where replay is the agent's business. Each call
## mints an ephemeral pair, binds the public half into the evidence, and
## records a session. That session is bound to the challenge it was
## issued under, expires, and may be consumed once.
##
## ``POST /provision`` — the four checks in the paragraph above, enforced
## here, and then the release itself. **No failure consumes the session**,
## including a ciphertext that does not open. That rule is worth stating
## in the negative, because the obvious alternative is worse: the
## ephemeral public key and the challenge are both *published* in the
## report, so anything that consumed a session on a bad request would
## hand every reader of that report a way to destroy the key agreement
## the legitimate holder of the secret is in the middle of completing. A
## wrong ciphertext is refused by the AEAD and costs the attacker a round
## trip; it does not cost the verifier its session. The session is
## consumed exactly when a secret is really released, and the private
## half goes with it.
##
## What the release *is*: the blob is opened by the key source that
## minted the key — the mechanism and the key are one seam, so a build
## cannot acquire half of either — under a context rebuilt from the
## session this agent holds rather than from the request that arrived.
## The plaintext is then written to the provisioned-secrets directory,
## which ``secrets`` will not let be anything but a filesystem with no
## backing store. A build with no mechanism, or no such directory,
## answers 501 and releases nothing.
##
## ``GET /measurement-manifest`` — the baked-in document, byte for byte
## as the build published it. Informational and never authoritative: a
## verifier that took its expected measurements from the machine being
## measured would be asking the suspect to supply the evidence.
##
## ## Identity, and why it is not configurable alongside a manifest
##
## The ``claims`` of a report are the instance's own statements about
## itself, and a verifier derives nothing from them. They are still worth
## getting right, because a claim that disagrees with the manifest beside
## it wastes the time of whoever is reading a log to find out why a
## machine was refused. So when a measurement manifest is configured, the
## configuration fingerprint and the verity root hash are *taken from
## it*, and passing them separately is refused as the contradiction it
## is. The generation is the one identity the manifest cannot supply,
## because it names which of several images this boot is running.
##
## ## Mocking
##
## None. The backend and the key source are real implementations of the
## driver seam — the mock backend is a backend for a root of trust that
## is absent, not a stand-in for one that is present — and the clock is a
## parameter rather than an injected fake.

import std/[base64, json, net, strutils, tables, times]

import repro_attest

import ./httpd
import ./limits
import ./secrets

const
  AgentHealthSchema* = "reproos.attestation-agent-health.v1"
    ## This daemon's own document, not one of the frozen wire schemas. It is
    ## versioned anyway: an operator surface that a monitoring system
    ## parses is a wire format whether or not anyone called it one.

  PathHealth* = "/health"
  PathAttestation* = "/attestation"
  PathKeyAgreement* = "/key-agreement"
  PathProvision* = "/provision"
  PathMeasurementManifest* = "/measurement-manifest"

  DefaultSessionTtlMs* = 300_000
    ## Five minutes between a key agreement and the secret released
    ## against it. Long enough for a verifier to check a quote against a
    ## policy and reach whoever holds the secret; short enough that an
    ## abandoned session's private key does not sit in memory for the
    ## life of the boot.

  DefaultMaxSessions* = 64
    ## Sessions are created by unauthenticated callers, so the table has
    ## to be bounded or it is the attack. Expired entries are pruned
    ## first; a request that still finds no room is refused rather than
    ## served by evicting a live session someone is waiting on.

  JsonContentType* = "application/json"
  TextContentType* = "text/plain"

  AgentReleaseSchema* = "reproos.attestation-agent-release.v1"
    ## What a successful ``POST /provision`` answers with. Versioned for
    ## the reason the health document is: anything a caller parses is a
    ## wire format.

  MaxWrappedSecretBase64* = ((MaxWrappedCiphertextBytes +
                              MaxEncapsulatedKeyBytes + 256) div 3 + 1) * 4
    ## The ceiling on the ``wrappedSecret`` field, derived from the
    ## document bounds ``provision`` enforces rather than chosen. A field
    ## bound that disagrees with the document bound would refuse blobs
    ## the format admits, or admit blobs it does not.

type
  AgentIdentity* = object
    ## What the instance says about itself. These become ``claims``, and
    ## a verifier derives nothing from them.
    generation*: string
    configFingerprint*: string
    verityRootHash*: string

  KeySession = object
    privateKey: string
    challengeHex: string
    issuedAtMs: int64

  AgentError* = object of CatchableError
    ## Raised for a configuration this agent will not run with. Every one
    ## of these is a start-up failure, never a request failure.

  AttestationAgent* = ref object
    driver: AttestationDriver
    keySource: EphemeralKeySource
    secretStore: ProvisionedSecretStore
    identity: AgentIdentity
    manifestText: string
    hasManifest: bool
    sessions: Table[string, KeySession]
    sessionTtlMs: int
    maxSessions: int

proc rfc3339At(nowMs: int64): string =
  ## Whole seconds, UTC, ``Z``. Informational, and formatted from the
  ## same clock the caller passed in so that nothing here reads a clock
  ## of its own.
  let t = utc(fromUnix(nowMs div 1000))
  t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

# ---------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------

proc newAttestationAgent*(driver: AttestationDriver;
                          identity: AgentIdentity;
                          keySource: EphemeralKeySource = nil;
                          secretStore: ProvisionedSecretStore = nil;
                          manifestText = "";
                          sessionTtlMs = DefaultSessionTtlMs;
                          maxSessions = DefaultMaxSessions): AttestationAgent =
  ## Everything that can be wrong with a configuration is wrong here,
  ## before the socket is bound.
  ##
  ## ``secretStore`` is a *constructed* store rather than a path, so the
  ## filesystem it writes to has already been checked by the time this
  ## agent exists. A daemon that would refuse every release is a daemon
  ## that should not have started.
  if driver.isNil:
    raise newException(AgentError,
      "an attestation agent needs a backend driver; there is nothing it " &
      "could answer a challenge with")
  if sessionTtlMs <= 0:
    raise newException(AgentError,
      "sessionTtlMs is " & $sessionTtlMs &
      "; a key agreement that never expires is a private key that lives " &
      "as long as the boot")
  if maxSessions <= 0:
    raise newException(AgentError,
      "maxSessions is " & $maxSessions &
      "; no key agreement could ever be established")

  var resolved = identity
  var hasManifest = false
  if manifestText.len > 0:
    # Parsed through the strict parser at start-up, and required to
    # re-render to the same bytes. An agent that would serve a document
    # it cannot itself read is worse than one that will not start, and
    # the byte check is what keeps `/measurement-manifest` able to serve
    # the published bytes rather than a re-spelling of them.
    let parsed = parseAttestedImageManifest(manifestText,
      AttestedImageManifestFileName)
    if renderAttestedImageManifest(parsed) != manifestText:
      raise newException(AgentError,
        "the configured measurement manifest is not in the canonical " &
        "spelling of its own schema; refusing to serve bytes this build " &
        "would not itself have written")
    hasManifest = true
    if resolved.configFingerprint.len > 0 and
       resolved.configFingerprint != parsed.configFingerprint:
      raise newException(AgentError,
        "configFingerprint was configured as " &
        resolved.configFingerprint.escape() &
        " and the measurement manifest says " &
        parsed.configFingerprint.escape() &
        "; a report whose claims contradict the manifest beside it wastes " &
        "the time of whoever reads them, so this is a refusal rather than " &
        "a preference")
    if resolved.verityRootHash.len > 0 and
       resolved.verityRootHash != parsed.imageOutputs.verityRootHash:
      raise newException(AgentError,
        "verityRootHash was configured as " &
        resolved.verityRootHash.escape() & " and the measurement manifest " &
        "says " & parsed.imageOutputs.verityRootHash.escape() &
        "; the manifest is the build's answer and the configuration is " &
        "not entitled to a second one")
    resolved.configFingerprint = parsed.configFingerprint
    resolved.verityRootHash = parsed.imageOutputs.verityRootHash

  # The same predicate the envelope applies, run now rather than on the
  # first request.
  validateUnverifiedClaims(UnverifiedClaims(
    unverifiedGeneration: resolved.generation,
    unverifiedConfigFingerprint: resolved.configFingerprint,
    unverifiedVerityRootHash: resolved.verityRootHash))

  AttestationAgent(driver: driver, keySource: keySource,
    secretStore: secretStore, identity: resolved,
    manifestText: manifestText, hasManifest: hasManifest,
    sessions: initTable[string, KeySession](), sessionTtlMs: sessionTtlMs,
    maxSessions: maxSessions)

proc backend*(a: AttestationAgent): AttestationBackend = a.driver.backend
proc tier*(a: AttestationAgent): AttestationTier = a.driver.tier
proc openSessions*(a: AttestationAgent): int = a.sessions.len
proc canRelease*(a: AttestationAgent): bool =
  ## Whether this build can complete a provision at all: it needs a
  ## mechanism to open the blob with and somewhere the secret is allowed
  ## to land. Reported by ``/health`` so an operator learns this before a
  ## verifier learns it from a 501.
  (not a.keySource.isNil) and (not a.secretStore.isNil)

# ---------------------------------------------------------------------
# Responses
# ---------------------------------------------------------------------

proc jsonOk(body: string): HttpResponse =
  HttpResponse(status: 200, contentType: JsonContentType, body: body)

proc problem(status: int; message: string): HttpResponse =
  ## Refusals are plain text, one line, naming what was wrong. A caller
  ## reading one is fixing a request, and a JSON envelope around a
  ## sentence helps nobody.
  HttpResponse(status: status, contentType: TextContentType,
    body: statusText(status) & ": " & message & "\n")

# ---------------------------------------------------------------------
# Query and body parsing
# ---------------------------------------------------------------------

proc parseQuery(query: string; allowed: openArray[string];
                out1: var Table[string, string]): string =
  ## Strict: an unknown parameter is a refusal and a repeated one is a
  ## refusal. Percent-encoding is refused outright rather than decoded —
  ## every value this surface takes is hex or a fixed word, so a decoder
  ## here would be a decoder that exists only to be wrong.
  out1 = initTable[string, string]()
  if query.len == 0: return ""
  for pair in query.split('&'):
    if pair.len == 0:
      return "the query has an empty parameter"
    let eq = pair.find('=')
    if eq <= 0:
      return "the query parameter " & pair.escape() & " has no value"
    let key = pair[0 ..< eq]
    let value = pair[eq + 1 .. ^1]
    if '%' in pair or '+' in pair:
      return "the query parameter " & key.escape() &
        " is percent-encoded; this surface takes hexadecimal and fixed " &
        "words, and decodes neither"
    if key notin allowed:
      return "the query carries the unknown parameter " & key.escape() &
        "; this build understands " & allowed.join(", ")
    if out1.hasKey(key):
      return "the query repeats the parameter " & key.escape() &
        ", and there is no rule saying which one would win"
    out1[key] = value
  ""

proc parseBodyObject(body: string; required, optional: openArray[string];
                     out1: var Table[string, string]): string =
  ## A flat JSON object of strings, with unknown and missing keys both
  ## refused, for the same reason the report parser refuses them.
  out1 = initTable[string, string]()
  var doc: JsonNode
  try:
    doc = parseJson(body)
  except CatchableError as err:
    return "the request body is not JSON: " & err.msg
  if doc.kind != JObject:
    return "the request body must be a JSON object"
  for key, value in doc:
    if key notin required and key notin optional:
      return "the request body carries the unknown field " & key.escape() &
        "; this build understands " & required.join(", ") &
        (if optional.len > 0: " and the optional " & optional.join(", ")
         else: "")
    if value.kind != JString:
      return "the request body field " & key.escape() & " must be a string"
    out1[key] = value.getStr
  for key in required:
    if not out1.hasKey(key):
      return "the request body is missing the required field " & key.escape()
  ""

# ---------------------------------------------------------------------
# Building a report
# ---------------------------------------------------------------------

proc buildReport(a: AttestationAgent; bindings: ReportBindings;
                 challengeHex: string; nowMs: int64): string =
  ## The one place a report is assembled, for both endpoints that produce
  ## one.
  ##
  ## The 64 bytes are computed here from the challenge and the bindings,
  ## and the driver is handed them. Nothing a driver returns can reach
  ## the envelope's ``reportData``, so a driver that embeds different
  ## bytes in its evidence produces a report whose envelope and evidence
  ## disagree — which is the verifier's to catch, and is not something
  ## this agent can be tricked into papering over.
  let reportDataHex = reportDataHexFor(bindings, challengeHex)
  let quote = acquireQuote(a.driver,
    hexToBytes("reportData", reportDataHex))
  let report = attestationReport(
    a.driver.backend,
    rfc3339At(nowMs),
    challengeHex,
    bindings,
    quote.evidence,
    UnverifiedClaims(
      unverifiedGeneration: a.identity.generation,
      unverifiedConfigFingerprint: a.identity.configFingerprint,
      unverifiedVerityRootHash: a.identity.verityRootHash),
    quote.certificates)
  result = renderAttestationReport(report)

  # Read back through the strict parser before it leaves the machine.
  # Emitting a document this build could not itself accept is the one
  # failure mode an attestation agent must not have, and it is cheap to
  # rule out here rather than discover on a verifier.
  let reparsed = parseAttestationReport(result, "<this agent's report>")
  if renderAttestationReport(reparsed) != result:
    raise newException(AgentError,
      "the report this agent just built does not round-trip through its " &
      "own parser; refusing to emit it")
  if not reparsed.bindsChallenge(challengeHex):
    raise newException(AgentError,
      "the report this agent just built does not bind the challenge it " &
      "was asked for; refusing to emit it")

# ---------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------

proc pruneSessions(a: AttestationAgent; nowMs: int64) =
  var expired: seq[string] = @[]
  for pub, s in a.sessions:
    if nowMs - s.issuedAtMs >= int64(a.sessionTtlMs):
      expired.add pub
  for pub in expired:
    # Overwrite before dropping. The private key of an abandoned session
    # has no further use and no reason to stay legible in memory.
    a.sessions[pub].privateKey = repeat('\0', a.sessions[pub].privateKey.len)
    a.sessions.del(pub)

proc consumeSession(a: AttestationAgent; pub: string) =
  if a.sessions.hasKey(pub):
    a.sessions[pub].privateKey =
      repeat('\0', a.sessions[pub].privateKey.len)
    a.sessions.del(pub)

# ---------------------------------------------------------------------
# The endpoints
# ---------------------------------------------------------------------

proc handleHealth(a: AttestationAgent): HttpResponse =
  let readiness =
    try:
      a.driver.driverProbe()
    except CatchableError as err:
      BackendReadiness(ready: false, detail: err.msg)
  var doc = %*{
    "schema": AgentHealthSchema,
    "status": "ok",
    "tier": $a.driver.tier,
    "backend": $a.driver.backend,
    "driver": a.driver.driverName,
    "backendReady": readiness.ready,
    "backendDetail": readiness.detail,
    "keyAgreement": (if a.keySource.isNil: "unavailable"
                     else: a.keySource.algorithm),
    "provisionedSecretsDir": (if a.secretStore.isNil: ""
                              else: a.secretStore.directory),
    "canRelease": a.canRelease,
    "measurementManifest": (if a.hasManifest: "loaded" else: "absent"),
    "openKeyAgreements": a.sessions.len}
  jsonOk(pretty(doc) & "\n")

proc handleAttestation(a: AttestationAgent; req: HttpRequest;
                       nowMs: int64): HttpResponse =
  var params: Table[string, string]
  let queryError = parseQuery(req.query, ["challenge", "purpose"], params)
  if queryError.len > 0: return problem(400, queryError)
  if not params.hasKey("challenge"):
    return problem(400,
      "no challenge; a report is an answer to one and there is nothing " &
      "for it to bind")
  if params.hasKey("purpose") and params["purpose"] != $bpAttest:
    # A key agreement needs a key minted inside the instance, which a
    # GET cannot do. Answering one here would mean binding a key the
    # caller chose, and a quote over a key the caller holds binds
    # nothing.
    return problem(400,
      "purpose " & params["purpose"].escape() & " is not produced here; " &
      $bpAttest & " is, and " & $bpKeyAgreement & " is minted by POST " &
      PathKeyAgreement)

  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  try:
    jsonOk(buildReport(a, bindings, params["challenge"], nowMs))
  except BindingError as err:
    problem(400, err.msg)
  except ReportError as err:
    problem(400, err.msg)
  except DriverError as err:
    problem(503, err.msg)

proc handleKeyAgreement(a: AttestationAgent; req: HttpRequest;
                        nowMs: int64): HttpResponse =
  if a.keySource.isNil:
    return problem(501,
      "this build carries no ephemeral key source, so it cannot establish " &
      "a key agreement; it will not answer with a public key nobody holds " &
      "the private half of")
  var fields: Table[string, string]
  let bodyError = parseBodyObject(req.body, ["challenge"], [], fields)
  if bodyError.len > 0: return problem(400, bodyError)

  a.pruneSessions(nowMs)
  if a.sessions.len >= a.maxSessions:
    return problem(429,
      "this agent is holding " & $a.sessions.len &
      " key agreements, which is as many as it will; each one is a " &
      "private key in memory, so the table is bounded rather than grown")

  let challengeHex = fields["challenge"]
  var pair: EphemeralKeyPair
  try:
    validateChallengeHex(challengeHex)
    pair = a.keySource.generateEphemeralKeyPair()
  except BindingError as err:
    return problem(400, err.msg)
  except DriverError as err:
    return problem(503, err.msg)

  let pubHex = bytesToHex(pair.publicKey)
  if a.sessions.hasKey(pubHex):
    # A key source that repeats a public key would silently overwrite a
    # live session's private half. Refusing is the only safe answer.
    return problem(500,
      "the ephemeral key source produced a public key that is already " &
      "bound to an open key agreement")

  let bindings = ReportBindings(purpose: bpKeyAgreement, ephemeralPub: pubHex)
  var body = ""
  try:
    body = buildReport(a, bindings, challengeHex, nowMs)
  except BindingError as err:
    return problem(400, err.msg)
  except ReportError as err:
    return problem(400, err.msg)
  except DriverError as err:
    return problem(503, err.msg)

  # Recorded only after the report was built. A session whose report
  # could not be produced is a private key nobody will ever use.
  a.sessions[pubHex] = KeySession(privateKey: pair.privateKey,
    challengeHex: challengeHex, issuedAtMs: nowMs)
  jsonOk(body)

proc handleProvision(a: AttestationAgent; req: HttpRequest;
                     nowMs: int64): HttpResponse =
  var fields: Table[string, string]
  let bodyError = parseBodyObject(req.body,
    ["ephemeralPub", "challenge", "wrappedSecret"], ["name"], fields)
  if bodyError.len > 0: return problem(400, bodyError)

  # Asked before the session table is consulted, so a build that cannot
  # complete a release does not first tell a caller whether a given
  # public key is live. A 501 is about this build; a 404 is about this
  # agent's state, and the two must not be orderable into an oracle.
  if not a.canRelease:
    return problem(501,
      (if a.keySource.isNil:
         "this build carries no key-encapsulation mechanism to unwrap a " &
         "released secret with"
       else:
         "this build has no provisioned-secrets directory to release a " &
         "secret into") &
      ", so it will not consume a key agreement it could not complete")

  a.pruneSessions(nowMs)
  let pub = fields["ephemeralPub"]

  # NOTHING below consumes the session except a release that really
  # happened. The public key and the challenge are both published in the
  # report, so a rule that spent a session on a bad request would let any
  # reader of that report deny the legitimate holder of the secret.
  if not a.sessions.hasKey(pub):
    return problem(404,
      "no open key agreement was issued for that public key; it was never " &
      "issued, it has expired, or it has already been used once")
  let session = a.sessions[pub]
  if session.challengeHex != fields["challenge"]:
    return problem(409,
      "that key agreement was issued under a different challenge; the " &
      "quote binds the key and the challenge together, so a secret " &
      "released against a different one is released against different " &
      "evidence")
  if fields["wrappedSecret"].len == 0:
    return problem(400, "wrappedSecret is empty")
  if fields["wrappedSecret"].len > MaxWrappedSecretBase64:
    return problem(413,
      "wrappedSecret is " & $fields["wrappedSecret"].len &
      " base64 characters; at most " & $MaxWrappedSecretBase64 &
      " are carried")

  let name = (if fields.hasKey("name"): fields["name"] else: DefaultSecretName)
  try:
    validateSecretName(name)
  except ProvisionError as err:
    return problem(400, err.msg)

  var wrapped = ""
  try:
    wrapped = base64.decode(fields["wrappedSecret"])
  except CatchableError:
    return problem(400,
      "wrappedSecret is not base64; the released document is bytes and " &
      "this field is how they are spelled")
  if base64.encode(wrapped) != fields["wrappedSecret"]:
    return problem(400,
      "wrappedSecret is not canonical base64; the field a release rests " &
      "on has to decode to exactly one thing")

  var released = ""
  try:
    released = a.keySource.openReleasedSecret(SecretRelease(
      privateKey: session.privateKey,
      challenge: hexToBytes("challenge", session.challengeHex),
      ephemeralPub: hexToBytes("bindings.ephemeralPub", pub),
      name: name,
      wrapped: wrapped))
  except ProvisionError as err:
    return problem(400, err.msg)
  except CatchableError as err:
    # `openReleasedSecret` raises whatever the mechanism raises, and the
    # mechanism is not this module's to enumerate. What matters here is
    # that a plaintext is never reached on this path: `released` is still
    # the empty string, and the session is still open.
    return problem(400,
      "the released secret was not recovered: " & err.msg)
  if released.len == 0:
    # A mechanism that returned a plaintext of nothing has not released a
    # secret, and writing an empty file would look exactly like success
    # to whatever reads the directory.
    return problem(400,
      "the released secret opened to zero bytes; an empty file in the " &
      "secrets directory is indistinguishable from a secret that arrived")

  var path = ""
  try:
    path = a.secretStore.storeSecret(name, released)
  except CatchableError as err:
    # The filesystem refused, or is no longer the filesystem this daemon
    # started on. The session is deliberately NOT consumed: nothing was
    # released, and the operator's fix is on this machine.
    return problem(500, err.msg)

  # A secret really was released. Now, and only now, this key's single
  # use is spent and the private half goes with it.
  a.consumeSession(pub)
  jsonOk(pretty(%*{
    "schema": AgentReleaseSchema,
    "name": name,
    "path": path,
    "bytes": released.len}) & "\n")

proc handleMeasurementManifest(a: AttestationAgent): HttpResponse =
  if not a.hasManifest:
    return problem(404,
      "this agent was not configured with a measurement manifest")
  # The published bytes, not a re-rendering of them: a verifier may hold
  # a digest of the document the build emitted.
  jsonOk(a.manifestText)

# ---------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------

proc routeCost*(verb, path: string): int {.gcsafe, raises: [].} =
  ## What each route costs the rate limiter. Answerable from the request
  ## line alone, because it is charged before the body is read.
  ##
  ## The split is the point. A quote is a command transaction with a
  ## device that rate-limits itself, measured in hundreds of milliseconds
  ## on a real TPM; a liveness probe is a table lookup. One bucket sized
  ## for probes would wave through as many quotes as probes, which is how
  ## an attacker exhausts the hardware without ever exceeding a
  ## request-count limit.
  ##
  ## ``/provision`` is NOT in the expensive bucket, and that was
  ## reconsidered rather than assumed. It does real work now — a scalar
  ## multiplication, an authenticated decryption and a filesystem write
  ## — but none of it touches the root of trust, and the asymmetry this
  ## split exists for is the DEVICE's: a TPM quote is a command
  ## transaction measured in hundreds of milliseconds that the device
  ## itself rate-limits, while an X25519 exchange and an AEAD open are
  ## microseconds of CPU bounded by ``maxBodyBytes``. Charging a release
  ## as though it were a quote was tried, and it bought nothing the body
  ## bound does not already buy while making two neighbouring gates'
  ## arithmetic depend on it.
  if path == PathAttestation or path == PathKeyAgreement: CostQuote
  else: CostCheap

proc handleRequest*(a: AttestationAgent; req: HttpRequest;
                    nowMs: int64): HttpResponse =
  ## The whole API surface. Pure in the agent's state and the clock.
  case req.path
  of PathHealth:
    if req.verb != "GET": return problem(405, "use GET " & PathHealth)
    handleHealth(a)
  of PathAttestation:
    if req.verb != "GET": return problem(405, "use GET " & PathAttestation)
    handleAttestation(a, req, nowMs)
  of PathKeyAgreement:
    if req.verb != "POST": return problem(405, "use POST " & PathKeyAgreement)
    handleKeyAgreement(a, req, nowMs)
  of PathProvision:
    if req.verb != "POST": return problem(405, "use POST " & PathProvision)
    handleProvision(a, req, nowMs)
  of PathMeasurementManifest:
    if req.verb != "GET":
      return problem(405, "use GET " & PathMeasurementManifest)
    handleMeasurementManifest(a)
  else:
    problem(404,
      "no such endpoint; this agent serves " & PathHealth & ", " &
      PathAttestation & ", " & PathKeyAgreement & ", " & PathProvision &
      " and " & PathMeasurementManifest)

# ---------------------------------------------------------------------
# The socket
# ---------------------------------------------------------------------

proc nowMs(): int64 = int64(epochTime() * 1000.0)

proc newAgentServer*(a: AttestationAgent; host: string; port: Port;
                     l = defaultAgentLimits()): HttpServer =
  ## Bind the agent's endpoints to a socket.
  ##
  ## The clock is read here and nowhere below: ``handleRequest`` takes the
  ## current time as a parameter, so this closure is the only place in the
  ## daemon that asks what time it is.
  let handler = proc (req: HttpRequest): HttpResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      a.handleRequest(req, nowMs())
  newHttpServer(host, port, l, handler, routeCost)
