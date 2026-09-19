## Asking a broker for the key to this machine's own state volumes, and
## the rule that a "no" opens nothing.
##
## ## What this is
##
## The other side of ``secrets``. That module is about a secret a
## verifier *pushes* to a running machine. This one is about a machine
## that cannot finish booting until somebody else agrees that it should:
## the volume key is not on the machine, not in its firmware and not in
## any device it owns, so an early-boot client attests to a broker and
## either receives the key or does not come up.
##
## The protocol is the one ``provision`` already defines, driven from the
## other end:
##
##   1. ``GET /unseal-challenge`` — the broker mints the nonce. Freshness
##      is the *broker's* input and never the machine's; a client that
##      chose its own challenge would be attesting to a question it wrote.
##   2. The client mints an ephemeral key pair inside this boot, binds the
##      public half into evidence through ``buildBoundReport``, and posts
##      the report to ``POST /unseal``.
##   3. The broker verifies, decides, and on acceptance encrypts the key
##      to the public half the evidence bound. On refusal it says so with
##      a status.
##   4. The client opens the blob with the private half — under a context
##      rebuilt from **its own** session, exactly as the receiving end of
##      ``provision`` does — and hands the plaintext to whatever opens the
##      volumes.
##
## ## The one property this module exists for
##
## **A refusal has no key, and that is a fact of the type rather than a
## discipline of the caller.** ``UnsealOutcome`` is a variant: the field
## holding the released key exists only on the ``udUnsealed`` branch, so a
## refusal does not carry one in any spelling — not by field access, not
## through ``fieldPairs``, not in ``repr``. There is nothing on that branch
## to reach. The single way to a key is ``withReleasedKey``, which runs its
## body on one branch and returns ``false`` on the other.
##
## On the OTHER branch the guarantee is narrower, and it is worth saying
## precisely rather than sweepingly, because the sweeping version was
## written here first and it was wrong. ``releasedKey`` is unexported, so
## no module outside this one can NAME it — that is what stops a caller
## from reading the field instead of using the accessor. It is not what
## stops the key from being printed: ``system.repr`` walks the active
## branch of a variant and prints every field on it regardless of whether
## the caller could spell them, and ``fieldPairs`` iterates them the same
## way. The first of those is the one a boot client meets, because it is
## what a debug log reaches for, so ``repr`` and ``$`` are overloaded below
## to withhold the key. ``fieldPairs`` cannot be overloaded and remains a
## way in; it is named here rather than left for a reader to discover.
##
## That shape was chosen over the obvious one — a key field and a
## documented "check the decision first" — because the failure it guards
## against is precisely a caller that reads the refusal, logs it, and
## opens the disk anyway. A machine whose client says "no" and whose
## volumes unlock regardless is worse than one with no client at all: it
## has the appearance of enforcement and none of the substance. A rule
## that lives in a comment is defeated by one forgetful call site; a field
## that does not exist on the branch is not.
##
## ## What this module deliberately does not do
##
## **It does not verify anything, and it reaches no verdict.** The client
## sits inside the attested machine, and linking the code that decides
## whether to trust into the thing being trusted is the one dependency an
## attestation client must not have. Two different statements sit behind
## that sentence and they are worth separating, because only one of them
## is gated:
##
##   * ``UnsealOutcome`` has no verdict, no policy and no failed-check
##     list on either branch. That is a fact of the TYPE and a gate
##     checks it.
##   * This module's import list is three lines at the top of this file
##     and carries no verifier. That is a fact a reader checks by
##     looking; nothing here asserts it, because an assertion about a
##     module's imports written inside a test that has its own imports
##     would be measuring the test.
##
## What the client DOES check is narrower and is about *its own session*:
## that the document it was handed names the key agreement it just
## established, and that the ciphertext opens under the private half it
## holds. Everything else is the broker's.
##
## **It opens no volume.** It produces a key or a refusal; the caller
## runs the unlock. The separation is what lets the refusal path be
## measured — a gate can hand this module a refusing broker and observe
## that the program that opens volumes was never executed.
##
## ## Mocking
##
## None. ``UnsealTransport`` is a seam over a network round trip, not a
## stand-in for one: the shipped implementation is a real HTTP client
## against a real socket, and the gates drive both it and a transport that
## returns recorded answers, because a refusal shape a server will not
## produce on demand is still a refusal this client has to have.

import std/[base64, httpclient, json, strutils]

import repro_attest

import ./agent

const
  UnsealChallengePath* = "/unseal-challenge"
    ## Where the broker's nonce comes from.
  UnsealReleasePath* = "/unseal"
    ## Where the report goes and the release comes back.

  UnsealChallengeSchema* = "reproos.remote-unseal-challenge.v1"
  UnsealRequestSchema* = "reproos.remote-unseal-request.v1"
  UnsealReleaseSchema* = "reproos.remote-unseal-release.v1"
    ## Three documents, three versions. Anything two programs parse is a
    ## wire format whether or not anybody called it one.

  MaxBrokerBodyChars* = 1_048_576
    ## What this client will read from a broker at all. The broker is not
    ## trusted — it is the party being asked, not an authority — so its
    ## answer is bounded before it is parsed.

  MaxRefusalReasonBytes* = 512
    ## A broker's refusal text reaches an operator's console and a
    ## machine-written record. It is truncated rather than dropped: the
    ## reason is the most useful thing a refused boot has.
    ##
    ## BYTES, because the slice below is a byte slice, and the name says
    ## so. The bound is reachable and is not decoration: the
    ## release-status refusal embeds the broker's whole answer, and the
    ## body bound is checked on the NEXT branch rather than this one, so
    ## a broker that declines with a megabyte of prose is exactly the
    ## input this truncation exists for.

  TruncationMark* = "…"
    ## What a truncated refusal ends with, named so a gate can pin the
    ## truncation by value rather than by counting bytes it also
    ## computed.

  WithheldKeyMark* = "<withheld>"
    ## What ``repr`` prints where a released key would be. Named so a gate
    ## can pin the withholding by value rather than by asserting the
    ## absence of a string, which is the weaker statement: a ``repr`` that
    ## printed nothing at all would satisfy "the key is not in it".

  DefaultUnsealSecretName* = "state-volume-key"
    ## What the released key is called when a deployment does not say.
    ## Named rather than defaulted to ``DefaultSecretName``, because the
    ## name is authenticated in the HPKE ``aad`` and a machine asking for
    ## its volume key should not be asking under the same label as
    ## everything else a broker holds.

type
  UnsealClientError* = object of CatchableError
    ## A configuration this client will not run with. Every one of these
    ## is raised before a socket is touched, never in answer to something
    ## a broker said — a broker cannot make this client raise, it can
    ## only make it refuse.

  BrokerAnswer* = object
    ## One HTTP answer, reduced to what this client reads.
    status*: int
    body*: string

  UnsealTransport* = ref object of RootObj
    ## How the client reaches the broker. Subclass it and call
    ## ``initUnsealTransport`` once.
    endpointName: string

  UnsealRefusal* = enum
    ## Why no key was recovered.
    ##
    ## These name KINDS, and two of them have more than one producing
    ## site: a challenge document can be malformed by being over-long or
    ## by not parsing, and a release document by either of those or by a
    ## base64 field that is not the canonical spelling of its own bytes.
    ## That is stated rather than glossed, because a gate that pinned a
    ## value and was satisfied by a different site would be green while
    ## the rule it names had no input. Each site carries its own
    ## sentence, and the gate pins the sentence wherever two sites share
    ## a value.
    ##
    ## What the values DO separate is every question a reader of a
    ## refused boot has to be able to answer: was anybody asked, did they
    ## answer, did they decide, and was the answer for this machine.
    urBrokerUnreachable = "broker-unreachable"
    urChallengeStatus = "challenge-status"
    urChallengeMalformed = "challenge-malformed"
    urNoKeyAgreement = "no-key-agreement"
    urNoEvidence = "no-evidence"
    urReleaseStatus = "release-status"
    urReleaseMalformed = "release-malformed"
    urReleaseNotForThisSession = "release-not-for-this-session"
    urCiphertextDidNotOpen = "ciphertext-did-not-open"
    urReleasedKeyEmpty = "released-key-empty"

  UnsealDecision* = enum
    ## ``udRefused`` is the zero value. An outcome nobody finished
    ## carries no key.
    udRefused = "refused"
    udUnsealed = "unsealed"

  UnsealOutcome* = object
    ## What one attempt produced.
    ##
    ## ``brokerStatus`` is 0 when no answer was obtained at all, which is
    ## a different thing from a broker that answered and declined; the
    ## two must not be readable as one, because only the second is a
    ## decision anybody made.
    brokerStatus*: int
    challengeHex*: string
    ephemeralPubHex*: string
    secretName*: string
    case decision*: UnsealDecision
    of udUnsealed:
      releasedKey: string
        ## UNEXPORTED, and on this branch only. See the module header:
        ## this is the whole of the fail-closed property, and it is a
        ## property of the type rather than of anybody's care.
      releasedKeyBytes*: int
        ## How many bytes were recovered. Safe to publish, and a record
        ## that says nothing about the size of what it released is a
        ## record an operator cannot sanity-check.
    of udRefused:
      refusal*: UnsealRefusal
      reason*: string

proc initUnsealTransport*(t: UnsealTransport; endpointName: string) =
  if endpointName.len == 0:
    raise newException(UnsealClientError,
      "an unseal transport must name the endpoint it reaches; the name " &
      "is what an operator reads when a machine will not come up")
  t.endpointName = endpointName

proc endpoint*(t: UnsealTransport): string = t.endpointName

method brokerGet*(t: UnsealTransport; path: string): BrokerAnswer {.base.} =
  raise newException(UnsealClientError,
    "unseal transport " & t.endpoint & " does not implement brokerGet")

method brokerPost*(t: UnsealTransport; path, body: string): BrokerAnswer
    {.base.} =
  raise newException(UnsealClientError,
    "unseal transport " & t.endpoint & " does not implement brokerPost")

# ---------------------------------------------------------------------
# The only way to a released key
# ---------------------------------------------------------------------

proc withReleasedKey*(o: UnsealOutcome;
                      body: proc (key: string) {.closure.}): bool =
  ## Run ``body`` with the released key, and report whether it ran.
  ##
  ## This is the sole accessor. On ``udRefused`` there is no key to pass
  ## — the field does not exist on that branch — so the body is not run
  ## and the answer is ``false``. A caller that ignores the answer still
  ## cannot open a volume, because it was never handed anything to open
  ## one with.
  case o.decision
  of udUnsealed:
    body(o.releasedKey)
    true
  of udRefused:
    false

proc repr*(o: UnsealOutcome): string =
  ## What this outcome looks like in a log, with any released key
  ## WITHHELD.
  ##
  ## Picked ahead of ``system.repr`` for this type by ordinary overload
  ## resolution, and the reason it has to exist is in the module header:
  ## the unexported field stops a caller NAMING the key, and stops
  ## nothing from printing it. ``releasedKeyBytes`` is what is published
  ## instead, which is the part an operator can sanity-check without
  ## being handed the credential.
  result = "UnsealOutcome(brokerStatus: " & $o.brokerStatus &
    ", challengeHex: " & o.challengeHex.escape() &
    ", ephemeralPubHex: " & o.ephemeralPubHex.escape() &
    ", secretName: " & o.secretName.escape() &
    ", decision: " & $o.decision
  case o.decision
  of udUnsealed:
    result.add ", releasedKeyBytes: " & $o.releasedKeyBytes &
      ", releasedKey: " & WithheldKeyMark
  of udRefused:
    result.add ", refusal: " & $o.refusal & ", reason: " & o.reason.escape()
  result.add ")"

proc `$`*(o: UnsealOutcome): string = repr(o)
  ## The same text. A type with one of these and not the other has a
  ## spelling that leaks and a spelling that does not, and which one a
  ## call site reached would be an accident of how it was written.

proc refused(status: int; why: UnsealRefusal; reason, challengeHex,
             pubHex, name: string): UnsealOutcome =
  var text = reason
  if text.len > MaxRefusalReasonBytes:
    text = text[0 ..< MaxRefusalReasonBytes] & TruncationMark
  UnsealOutcome(brokerStatus: status, challengeHex: challengeHex,
                ephemeralPubHex: pubHex, secretName: name,
                decision: udRefused, refusal: why, reason: text)

# ---------------------------------------------------------------------
# The documents
# ---------------------------------------------------------------------

proc renderUnsealRequest*(reportText, name: string): string =
  ## What ``POST /unseal`` carries. The report travels as a JSON *string*
  ## rather than as an embedded object, deliberately: a verifier checks
  ## the bytes a machine signed over, and re-serialising a parsed
  ## document is how those bytes stop being those bytes.
  $(%*{"schema": UnsealRequestSchema, "name": name, "report": reportText})

proc base64Decoded(s: string): string =
  ## Decode, and require the spelling to be the only one that produces
  ## these bytes. A field a release rests on has to decode to exactly one
  ## thing, and ``std/base64`` accepts several spellings of the same
  ## value.
  result = base64.decode(s)
  if base64.encode(result) != s:
    raise newException(UnsealClientError,
      "this is not the canonical spelling of its own bytes")

proc readStringField(doc: JsonNode; key, source: string): string =
  if not doc.hasKey(key):
    raise newException(UnsealClientError,
      source & " is missing the required field " & key.escape())
  if doc[key].kind != JString:
    raise newException(UnsealClientError,
      source & "." & key & " must be a string")
  doc[key].getStr

proc parseChallengeAnswer*(body: string): string =
  ## The nonce out of the broker's challenge document, validated against
  ## the binding discipline's own floor before it is used for anything.
  var doc: JsonNode
  try:
    doc = parseJson(body)
  except CatchableError as err:
    raise newException(UnsealClientError,
      "the broker's challenge document is not JSON: " & err.msg)
  if doc.kind != JObject:
    raise newException(UnsealClientError,
      "the broker's challenge document is not a JSON object")
  let schema = readStringField(doc, "schema", "the broker's challenge document")
  if schema != UnsealChallengeSchema:
    raise newException(UnsealClientError,
      "the broker's challenge document names schema " & schema.escape() &
      " and this build understands " & UnsealChallengeSchema.escape())
  result = readStringField(doc, "challenge",
                           "the broker's challenge document")
  try:
    validateChallengeHex(result)
  except BindingError as err:
    raise newException(UnsealClientError,
      "the broker's challenge is not one this build will attest to: " &
      err.msg)

type
  UnsealRelease* = object
    ## The broker's release document, as this client reads it.
    name*: string
    challengeHex*: string
    ephemeralPubHex*: string
    wrappedSecretBase64*: string

proc parseUnsealRelease*(body: string): UnsealRelease =
  var doc: JsonNode
  try:
    doc = parseJson(body)
  except CatchableError as err:
    raise newException(UnsealClientError,
      "the broker's release document is not JSON: " & err.msg)
  if doc.kind != JObject:
    raise newException(UnsealClientError,
      "the broker's release document is not a JSON object")
  let schema = readStringField(doc, "schema", "the broker's release document")
  if schema != UnsealReleaseSchema:
    raise newException(UnsealClientError,
      "the broker's release document names schema " & schema.escape() &
      " and this build understands " & UnsealReleaseSchema.escape())
  result.name = readStringField(doc, "name", "the broker's release document")
  result.challengeHex =
    readStringField(doc, "challenge", "the broker's release document")
  result.ephemeralPubHex =
    readStringField(doc, "ephemeralPub", "the broker's release document")
  result.wrappedSecretBase64 =
    readStringField(doc, "wrappedSecret", "the broker's release document")

# ---------------------------------------------------------------------
# The attempt
# ---------------------------------------------------------------------

proc performRemoteUnseal*(t: UnsealTransport; driver: AttestationDriver;
                          keySource: EphemeralKeySource;
                          identity: AgentIdentity; secretName: string;
                          nowMs: int64): UnsealOutcome =
  ## One attempt at the whole protocol.
  ##
  ## Every way this can end without a key is a *refusal* carrying its own
  ## ``UnsealRefusal`` value, because an early-boot caller has one
  ## question — may I open the disk — and an exception that escaped would
  ## have to be answered by somebody, somewhere, writing the fallback
  ## this module exists to make unspellable. The only things that raise
  ## are configuration faults, and they are all checked here before a
  ## packet leaves.
  if t.isNil:
    raise newException(UnsealClientError,
      "a remote unseal needs a transport; there is nothing to ask")
  if driver.isNil:
    raise newException(UnsealClientError,
      "a remote unseal needs a backend driver; there is no evidence this " &
      "machine could offer for the key it is asking for")
  if keySource.isNil:
    raise newException(UnsealClientError,
      "a remote unseal needs an ephemeral key source; without one the " &
      "broker would have nothing to encrypt to, and a key arriving in " &
      "the clear is a key every relay on the path now holds")
  let name = (if secretName.len == 0: DefaultUnsealSecretName
              else: secretName)
  validateSecretName(name)

  # ---- the broker's nonce ------------------------------------------
  var challengeAnswer: BrokerAnswer
  try:
    challengeAnswer = t.brokerGet(UnsealChallengePath)
  except CatchableError as err:
    return refused(0, urBrokerUnreachable,
      "the broker at " & t.endpoint & " could not be reached for a " &
      "challenge: " & err.msg, "", "", name)
  if challengeAnswer.status != 200:
    return refused(challengeAnswer.status, urChallengeStatus,
      "the broker answered " & $challengeAnswer.status & " to " &
      UnsealChallengePath & ": " & challengeAnswer.body, "", "", name)
  if challengeAnswer.body.len > MaxBrokerBodyChars:
    return refused(challengeAnswer.status, urChallengeMalformed,
      "the broker's challenge document is " & $challengeAnswer.body.len &
      " characters; at most " & $MaxBrokerBodyChars & " are read", "", "",
      name)
  var challengeHex = ""
  try:
    challengeHex = parseChallengeAnswer(challengeAnswer.body)
  except CatchableError as err:
    return refused(challengeAnswer.status, urChallengeMalformed,
      err.msg, "", "", name)

  # ---- this boot's own key agreement -------------------------------
  # Minted here and held nowhere else. The private half is overwritten
  # before this procedure returns on EVERY path, including the refusals
  # below, because a boot that was told no has no further use for it and
  # no reason to leave it legible.
  var pair: EphemeralKeyPair
  try:
    pair = keySource.generateEphemeralKeyPair()
  except CatchableError as err:
    return refused(0, urNoKeyAgreement,
      "this machine could not mint a key agreement to be answered " &
      "under: " & err.msg, challengeHex, "", name)
  let pubHex = bytesToHex(pair.publicKey)
  defer:
    for i in 0 ..< pair.privateKey.len: pair.privateKey[i] = '\0'

  var reportText = ""
  try:
    reportText = buildBoundReport(driver, identity,
      ReportBindings(purpose: bpKeyAgreement, ephemeralPub: pubHex),
      challengeHex, nowMs)
  except CatchableError as err:
    # The machine could not produce evidence about itself — no device, a
    # device that refused, a driver this build does not carry. Nobody was
    # asked, which is why the status stays 0.
    return refused(0, urNoEvidence,
      "this machine could not produce evidence to ask with: " & err.msg,
      challengeHex, pubHex, name)

  # ---- the ask -----------------------------------------------------
  var releaseAnswer: BrokerAnswer
  try:
    releaseAnswer = t.brokerPost(UnsealReleasePath,
                                 renderUnsealRequest(reportText, name))
  except CatchableError as err:
    return refused(0, urBrokerUnreachable,
      "the broker at " & t.endpoint & " could not be reached for a " &
      "release: " & err.msg, challengeHex, pubHex, name)

  # THE REFUSAL THIS WHOLE MODULE IS SHAPED BY. A broker that declines
  # answers with a status and a sentence, and what this client does with
  # that is produce an outcome that has no key in it.
  if releaseAnswer.status != 200:
    return refused(releaseAnswer.status, urReleaseStatus,
      "the broker refused to release " & name.escape() & ": " &
      releaseAnswer.body, challengeHex, pubHex, name)
  if releaseAnswer.body.len > MaxBrokerBodyChars:
    return refused(releaseAnswer.status, urReleaseMalformed,
      "the broker's release document is " & $releaseAnswer.body.len &
      " characters; at most " & $MaxBrokerBodyChars & " are read",
      challengeHex, pubHex, name)

  var release: UnsealRelease
  try:
    release = parseUnsealRelease(releaseAnswer.body)
  except CatchableError as err:
    return refused(releaseAnswer.status, urReleaseMalformed, err.msg,
                   challengeHex, pubHex, name)

  # The document must name the session this client just established. The
  # AEAD would refuse a document composed for another one anyway — the
  # context is rebuilt below from the session's own values and never from
  # these fields — so this check buys a DIAGNOSIS rather than a
  # protection, and it is worth having for exactly that: "the broker
  # answered about a different key agreement" and "the ciphertext did not
  # open" are different operational situations and a machine that will
  # not boot should say which.
  if release.challengeHex != challengeHex or
     release.ephemeralPubHex != pubHex or release.name != name:
    return refused(releaseAnswer.status, urReleaseNotForThisSession,
      "the broker released " & release.name.escape() & " for key " &
      release.ephemeralPubHex.escape() & " under challenge " &
      release.challengeHex.escape() & "; this boot asked for " &
      name.escape() & " for key " & pubHex.escape() & " under " &
      challengeHex.escape(), challengeHex, pubHex, name)

  var wrapped = ""
  try:
    wrapped = base64Decoded(release.wrappedSecretBase64)
  except CatchableError as err:
    return refused(releaseAnswer.status, urReleaseMalformed,
      "the broker's wrappedSecret is not canonical base64: " & err.msg,
      challengeHex, pubHex, name)

  var key = ""
  try:
    key = keySource.openReleasedSecret(SecretRelease(
      privateKey: pair.privateKey,
      challenge: hexToBytes("challenge", challengeHex),
      ephemeralPub: hexToBytes("bindings.ephemeralPub", pubHex),
      name: name,
      wrapped: wrapped))
  except CatchableError as err:
    return refused(releaseAnswer.status, urCiphertextDidNotOpen,
      "the released key did not open under this boot's key agreement: " &
      err.msg, challengeHex, pubHex, name)
  if key.len == 0:
    # A mechanism that authenticated a plaintext of nothing has released
    # no key, and an empty passphrase handed to a volume opener is a
    # passphrase.
    return refused(releaseAnswer.status, urReleasedKeyEmpty,
      "the released key opened to zero bytes; an empty passphrase is a " &
      "passphrase, and this build will not offer one to a volume opener",
      challengeHex, pubHex, name)

  UnsealOutcome(brokerStatus: releaseAnswer.status, challengeHex: challengeHex,
                ephemeralPubHex: pubHex, secretName: name,
                decision: udUnsealed, releasedKey: key,
                releasedKeyBytes: key.len)

# ---------------------------------------------------------------------
# The shipped transport
# ---------------------------------------------------------------------

type
  HttpUnsealTransport* = ref object of UnsealTransport
    ## The transport an initrd uses: one HTTP round trip per step, over
    ## ``std/httpclient``.
    ##
    ## Plaintext HTTP is the design's position and not an omission — what
    ## protects the key is that it is encrypted to a key the *evidence*
    ## bound, so a relay that reads the whole conversation learns a
    ## public key and a ciphertext. A transport that added TLS would add
    ## a certificate store to an initrd for hygiene, and the hygiene is
    ## worth having where a deployment can afford it; it is not what the
    ## property rests on.
    base: string
    timeoutMs: int

proc newHttpUnsealTransport*(base: string; timeoutMs = 20_000):
    HttpUnsealTransport =
  if base.len == 0:
    raise newException(UnsealClientError,
      "a remote unseal needs a broker address")
  if not (base.startsWith("http://") or base.startsWith("https://")):
    raise newException(UnsealClientError,
      "the broker address " & base.escape() & " is not an http:// or " &
      "https:// URL")
  if timeoutMs <= 0:
    raise newException(UnsealClientError,
      "the broker timeout is " & $timeoutMs &
      " milliseconds; a boot that waits forever for a key is a boot that " &
      "hangs rather than one that fails")
  var trimmed = base
  while trimmed.len > 0 and trimmed[^1] == '/':
    trimmed = trimmed[0 ..< ^1]
  result = HttpUnsealTransport(base: trimmed, timeoutMs: timeoutMs)
  initUnsealTransport(result, trimmed)

proc answerOf(resp: Response): BrokerAnswer =
  BrokerAnswer(status: resp.status.split(' ')[0].parseInt, body: resp.body)

method brokerGet*(t: HttpUnsealTransport; path: string): BrokerAnswer =
  var client = newHttpClient(timeout = t.timeoutMs)
  try:
    answerOf(client.request(t.base & path, httpMethod = HttpGet))
  finally:
    try: client.close()
    except CatchableError: discard

method brokerPost*(t: HttpUnsealTransport; path, body: string): BrokerAnswer =
  var client = newHttpClient(timeout = t.timeoutMs)
  try:
    answerOf(client.request(t.base & path, httpMethod = HttpPost, body = body,
      headers = newHttpHeaders({"Content-Type": "application/json"})))
  finally:
    try: client.close()
    except CatchableError: discard
