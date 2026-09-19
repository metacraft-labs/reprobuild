## Every way the early-boot client can come back without a key, and the
## fact that none of them comes back with one.
##
## ## What this gate is for
##
## The two boot gates beside it read one honest run and one refused one.
## This one drives the same client through the rest of its refusals, and
## pins each by its own `UnsealRefusal` VALUE rather than by an exception
## type or a substring. That is not pedantry: several of these arise from
## the same round trip, and the failure this kind of check keeps having
## is a rule answered by the rule before it — a test that expected "the
## ciphertext did not open" and was satisfied by "the document was
## malformed" would be green while the check it names had no input at
## all.
##
## ## The malicious relay
##
## Most of the interesting cases need a release document that a correct
## broker will never produce, so they are driven through a transport that
## sits BETWEEN the real client and the real broker, reads the report the
## client posted, and composes its own answer from it. That is the actual
## threat model the framing and the authenticated name exist for — a
## party that can see and rewrite the conversation — and it is the only
## way to reach `release-not-for-this-session`, a ciphertext that does
## not open, and a release that opens to nothing.
##
## ## Mocking
##
## Two seam implementations live here and both are justified.
##
## `ScriptedTransport` returns answers a broker will not give on demand:
## a connection that fails, a status, a body that is not JSON. The
## property under test is the client's behaviour in the face of those,
## and the seam is the interface they arrive through.
##
## `RelayTransport` is a real HTTP client to a real broker with one
## rewriting step in the middle. It is not a stand-in for the broker: the
## broker is real, its release is real, and what the relay does is the
## thing a relay can really do.
##
## The two refusals that need a machine which cannot answer for itself
## are driven with the SHIPPED SEAM'S OWN BASE CLASSES — an
## `AttestationDriver` that has not implemented `driverQuote` and an
## `EphemeralKeySource` that has not implemented
## `generateEphemeralKeyPair`. Those are not doubles; they are what a
## build with half a mechanism is, and the seam raises on them by design.

import std/[base64, httpclient, json, os, strutils, times, unittest]

import repro_attest
import repro_attest/hpke
import repro_attest/x25519_kem
import repro_attest_agent/agent
import repro_attest_agent/cli
import repro_attest_agent/remote_unseal
import repro_attest_agent/unseal_cli

import ./attested_boot/unseal_broker_core
import ./remote_unseal_harness

const
  TestKey = "1a2b" & "3c4d5e6f" & "708192a3" & "b4c5d6e7" & "f8091a2b" &
            "3c4d5e6f" & "70819200" & "aabbccdd"
    ## 64 printable characters, the shape a released volume key has.

  Identity = "remote-unseal-client-gate"

proc gateIdentity(): AgentIdentity =
  AgentIdentity(generation: Identity & "-generation",
                configFingerprint: Identity & "-fingerprint",
                verityRootHash: repeat("0", 64))

# ---------------------------------------------------------------------
# The two seam implementations
# ---------------------------------------------------------------------

type
  ScriptedTransport = ref object of UnsealTransport
    challenge: BrokerAnswer
    release: BrokerAnswer
    failChallenge: bool
    failRelease: bool
    posted: seq[string]

  RelayTransport = ref object of UnsealTransport
    inner: HttpUnsealTransport
    rewrite: proc (report, releaseBody: string): string {.closure.}

proc newScripted(challenge, release: BrokerAnswer; failChallenge = false;
                 failRelease = false): ScriptedTransport =
  result = ScriptedTransport(challenge: challenge, release: release,
                             failChallenge: failChallenge,
                             failRelease: failRelease)
  initUnsealTransport(result, "<scripted>")

method brokerGet(t: ScriptedTransport; path: string): BrokerAnswer =
  if t.failChallenge:
    raise newException(IOError, "the scripted transport refuses to connect")
  t.challenge

method brokerPost(t: ScriptedTransport; path, body: string): BrokerAnswer =
  t.posted.add body
  if t.failRelease:
    raise newException(IOError, "the scripted transport refuses to connect")
  t.release

proc newRelay(inner: HttpUnsealTransport;
              rewrite: proc (report, releaseBody: string): string
                {.closure.}): RelayTransport =
  result = RelayTransport(inner: inner, rewrite: rewrite)
  initUnsealTransport(result, "<relay>")

method brokerGet(t: RelayTransport; path: string): BrokerAnswer =
  t.inner.brokerGet(path)

method brokerPost(t: RelayTransport; path, body: string): BrokerAnswer =
  let answer = t.inner.brokerPost(path, body)
  if answer.status != 200: return answer
  let report = parseJson(body)["report"].getStr
  BrokerAnswer(status: 200, body: t.rewrite(report, answer.body))

proc okChallenge(hex: string): BrokerAnswer =
  BrokerAnswer(status: 200, body: $(%*{
    "schema": UnsealChallengeSchema, "challenge": hex,
    "issuedAt": "2026-09-19T00:00:00Z"}))

proc attempt(t: UnsealTransport; keySource: EphemeralKeySource = nil;
             driver: AttestationDriver = nil;
             name = "state-volume-key"): UnsealOutcome =
  performRemoteUnseal(t,
    (if driver.isNil: AttestationDriver(newMockDriver()) else: driver),
    (if keySource.isNil: EphemeralKeySource(newX25519KeySource())
     else: keySource),
    gateIdentity(), name, int64(epochTime() * 1000.0))

proc brokerReleasedIn(record: string): bool =
  ## The client's own record, read here rather than through the evidence
  ## module: this gate is about the client, and importing the boot gates'
  ## reader would make a change to that reader able to redden this.
  var decision = ""
  var opener = ""
  for line in record.splitLines:
    if line.startsWith("unseal_decision="): decision = line.split('=')[1]
    if line.startsWith("opener_ran="): opener = line.split('=')[1]
  decision == "unsealed" and opener == "1"

proc reportSession(report: string): tuple[challenge, pub: string] =
  let parsed = parseAttestationReport(report, "<relay>")
  (parsed.challenge, parsed.bindings.ephemeralPub)

runAsRecorderIfAsked()

suite "the remote-unseal client comes back with a key or with nothing":

  test "t_remote_unseal_client_refusals_are_each_their_own":
    ## Every refusal value, each reached by the input that produces it
    ## and no other, and each carrying no key.
    let hex = repeat("a1", 32)

    proc noKey(o: UnsealOutcome; why: UnsealRefusal) =
      check o.decision == udRefused
      check o.refusal == why
      var ran = 0
      check o.withReleasedKey(proc (key: string) = inc ran) == false
      check ran == 0

    # The broker could not be reached at all — for the challenge, and
    # then for the release. TWO SITES, ONE VALUE, so the value alone is
    # not enough: a case that pinned only `broker-unreachable` would be
    # satisfied by whichever site it did not mean, and the two are
    # different situations for whoever is looking at a machine that did
    # not come up. Each sentence is pinned, and each is checked ABSENT
    # from the other outcome so the pin cannot be a substring both carry.
    let unreachableChallenge = attempt(newScripted(okChallenge(hex),
                              BrokerAnswer(status: 200, body: ""),
                              failChallenge = true))
    noKey(unreachableChallenge, urBrokerUnreachable)
    check "could not be reached for a challenge" in
      unreachableChallenge.reason
    check "could not be reached for a release" notin
      unreachableChallenge.reason
    let unreachableRelease = attempt(newScripted(okChallenge(hex),
                              BrokerAnswer(status: 200, body: ""),
                              failRelease = true))
    noKey(unreachableRelease, urBrokerUnreachable)
    check "could not be reached for a release" in unreachableRelease.reason
    check "could not be reached for a challenge" notin
      unreachableRelease.reason
    # And only the second of them got as far as establishing a session.
    check unreachableChallenge.challengeHex == ""
    check unreachableRelease.challengeHex == hex

    # The broker answered the challenge with a status.
    let statusOutcome = attempt(newScripted(
      BrokerAnswer(status: 503, body: "not today"),
      BrokerAnswer(status: 200, body: "")))
    noKey(statusOutcome, urChallengeStatus)
    check statusOutcome.brokerStatus == 503
    check statusOutcome.challengeHex == ""

    # And with documents it will not read. Several distinct sites, all
    # reported as `challenge-malformed`, each with its own sentence — and
    # the over-long one is pinned by its sentence below, because a value
    # two sites share is a value a gate must not rest a claim on alone.
    for body in [
        "{",
        "[]",
        $(%*{"schema": "something.else", "challenge": hex}),
        $(%*{"schema": UnsealChallengeSchema, "challenge": "00"}),
        $(%*{"schema": UnsealChallengeSchema}),
        $(%*{"schema": UnsealChallengeSchema, "challenge": 7})]:
      noKey(attempt(newScripted(BrokerAnswer(status: 200, body: body),
                                BrokerAnswer(status: 200, body: ""))),
            urChallengeMalformed)
    # TWO OF THOSE SIX RULES WERE BEING ANSWERED BY A DIFFERENT ONE, and
    # the value they all carry could not tell. A document with no
    # `schema` reaches `doc[key]`, which raises on its own if the
    # required-field rule is deleted; a `schema` that is a number reaches
    # `getStr`, which answers "" and lets the next validator refuse. Both
    # mutations leave `challenge-malformed` in place, so the SENTENCE is
    # what the rule is pinned by.
    proc challengeRefusalFor(body: string): string =
      attempt(newScripted(BrokerAnswer(status: 200, body: body),
                          BrokerAnswer(status: 200, body: ""))).reason
    check "is missing the required field \"schema\"" in
      challengeRefusalFor($(%*{"challenge": hex}))
    check ".schema must be a string" in
      challengeRefusalFor($(%*{"schema": 7, "challenge": hex}))
    check "is missing the required field \"challenge\"" in
      challengeRefusalFor($(%*{"schema": UnsealChallengeSchema}))
    # A challenge document larger than this client will read at all. The
    # bound is tested ABOVE it, by one character, and the refusal names
    # the bound rather than complaining that the body is not JSON — which
    # it also is not, and which is the refusal this case would otherwise
    # have been satisfied by.
    let overLongChallenge = attempt(newScripted(
      BrokerAnswer(status: 200, body: repeat("x", MaxBrokerBodyChars + 1)),
      BrokerAnswer(status: 200, body: "")))
    noKey(overLongChallenge, urChallengeMalformed)
    check ("at most " & $MaxBrokerBodyChars & " are read") in
      overLongChallenge.reason
    check $(MaxBrokerBodyChars + 1) in overLongChallenge.reason
    # AND AT THE BOUND, which is the half this case did not have. A
    # document of exactly `MaxBrokerBodyChars` is READ — and then refused
    # for a different reason, because it is still not JSON. Without this
    # the comparison could be relaxed to `>=` and nothing would notice,
    # which is the bound-tested-under-itself shape the release branch
    # below already guards against and this one did not.
    let atBoundChallenge = attempt(newScripted(
      BrokerAnswer(status: 200, body: repeat("x", MaxBrokerBodyChars)),
      BrokerAnswer(status: 200, body: "")))
    noKey(atBoundChallenge, urChallengeMalformed)
    check "is not JSON" in atBoundChallenge.reason
    check ("at most " & $MaxBrokerBodyChars & " are read") notin
      atBoundChallenge.reason

    # This machine could not mint a key agreement, and could not produce
    # evidence. Both are the SHIPPED SEAM's own base classes: a build
    # that acquired half a mechanism.
    var halfKeySource = EphemeralKeySource()
    initEphemeralKeySource(halfKeySource, "half-a-mechanism")
    noKey(attempt(newScripted(okChallenge(hex),
                              BrokerAnswer(status: 200, body: "")),
                  keySource = halfKeySource), urNoKeyAgreement)
    var halfDriver = AttestationDriver()
    initAttestationDriver(halfDriver, abMock, "half-a-driver")
    noKey(attempt(newScripted(okChallenge(hex),
                              BrokerAnswer(status: 200, body: "")),
                  driver = halfDriver), urNoEvidence)

    # A BROKER THAT DECLINES WITH A NOVEL. The refusal text reaches an
    # operator's console and a machine-written record, so it is bounded
    # — and the bound is on THIS branch while the body bound is on the
    # next, which is what makes a megabyte of prose reach it. Tested at
    # the bound and one byte over, because a bound tested only under
    # itself is not tested.
    let prefix = "the broker refused to release " &
      "state-volume-key".escape() & ": "
    let atBound = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 403,
                   body: repeat("z", MaxRefusalReasonBytes - prefix.len))))
    check atBound.refusal == urReleaseStatus
    check atBound.reason.len == MaxRefusalReasonBytes
    check not atBound.reason.endsWith(TruncationMark)
    let overBound = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 403,
                   body: repeat("z", MaxRefusalReasonBytes - prefix.len + 1))))
    check overBound.refusal == urReleaseStatus
    check overBound.reason.len == MaxRefusalReasonBytes + TruncationMark.len
    check overBound.reason.endsWith(TruncationMark)
    check overBound.reason.startsWith(prefix)
    # The mark itself, by VALUE. Both assertions above name the constant
    # on each side, so changing what the constant IS moves them together
    # and they stay green — which is exactly what the constant's own
    # rationale says it exists to prevent.
    check TruncationMark == "\u2026"
    check overBound.reason.endsWith("\u2026")

    # A BROKER THAT DECLINES WITH A MEGABYTE, which is the input the
    # truncation was written for and did not have. The body bound is
    # checked on the NEXT branch, so a refusal status carries the whole
    # answer into the reason and the truncation is the only thing
    # standing between an operator's console and a megabyte of prose. If
    # the body bound were moved ahead of the status check this would come
    # back `release-malformed` instead, and nothing would have noticed.
    let hugeRefusal = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 403,
                   body: repeat("q", MaxBrokerBodyChars + 1))))
    noKey(hugeRefusal, urReleaseStatus)
    check hugeRefusal.brokerStatus == 403
    check hugeRefusal.reason.len == MaxRefusalReasonBytes + TruncationMark.len
    check hugeRefusal.reason.startsWith(prefix)

    # The broker answered the ask with a status. This is the one the
    # refusal gate is about, reached here without a boot.
    let refused = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 403, body: "no")))
    noKey(refused, urReleaseStatus)
    check refused.brokerStatus == 403
    check refused.challengeHex == hex
    check refused.ephemeralPubHex.len == 64

    # And with release documents it will not read.
    for body in ["{", "[]",
                 $(%*{"schema": "something.else"}),
                 $(%*{"schema": UnsealReleaseSchema, "name": "x"})]:
      noKey(attempt(newScripted(okChallenge(hex),
                                BrokerAnswer(status: 200, body: body))),
            urReleaseMalformed)
    let overLongRelease = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 200,
                   body: repeat("x", MaxBrokerBodyChars + 1))))
    noKey(overLongRelease, urReleaseMalformed)
    check ("release document is " & $(MaxBrokerBodyChars + 1)) in
      overLongRelease.reason
    # And the same document one character shorter is refused for a
    # DIFFERENT reason, which is what makes the bound a bound rather than
    # a sentence.
    let underLongRelease = attempt(newScripted(okChallenge(hex),
      BrokerAnswer(status: 200, body: repeat("x", MaxBrokerBodyChars))))
    check underLongRelease.refusal == urReleaseMalformed
    check "is not JSON" in underLongRelease.reason
    check underLongRelease.reason != overLongRelease.reason

  test "t_remote_unseal_client_refuses_a_relay_that_rewrites_the_release":
    ## A REAL broker releasing a REAL key, with a party in the middle.
    ## Each rewrite is something a relay can really do, and each is
    ## refused by its own rule.
    let dir = getTempDir() / "remote-unseal-relay-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var h = startBroker(harnessConfig(dir / "broker", TestKey))
    defer: stopBroker(h)

    proc through(rewrite: proc (report, body: string): string {.closure.}):
        UnsealOutcome =
      attempt(newRelay(newHttpUnsealTransport(h.brokerUrl), rewrite))

    # The honest path first, through the SAME relay with an identity
    # rewrite, so the rewrites below are the only difference between a
    # released key and a refusal.
    let honest = through(proc (report, body: string): string = body)
    check honest.decision == udUnsealed
    var opened = ""
    check honest.withReleasedKey(proc (key: string) = opened = key)
    check opened == TestKey

    # AND THE OUTCOME DOES NOT PRINT THE KEY. The unexported field stops
    # a caller naming it and stops nothing from printing it: `repr` walks
    # the active branch of a variant and does not care what the caller
    # could spell. An early-boot client whose outcome reached a debug
    # line would have published the volume key, so the two spellings a
    # log reaches for are overloaded to withhold it.
    check TestKey notin repr(honest)
    check TestKey notin $honest
    # By VALUE, not by absence: a `repr` that printed nothing at all
    # would satisfy "the key is not in it".
    check WithheldKeyMark in repr(honest)
    check ("releasedKeyBytes: " & $TestKey.len) in repr(honest)
    check ("ephemeralPubHex: \"" & honest.ephemeralPubHex) in repr(honest)

    # The relay relabels the release. The name is authenticated in the
    # HPKE `aad`, so this cannot succeed — but the client says WHICH
    # thing went wrong rather than reporting a tag failure.
    let relabelled = through(proc (report, body: string): string =
      let doc = parseJson(body)
      doc["name"] = %"some-other-secret"
      $doc)
    check relabelled.decision == udRefused
    check relabelled.refusal == urReleaseNotForThisSession

    # The relay claims the release was for a different key agreement.
    let otherKey = through(proc (report, body: string): string =
      let doc = parseJson(body)
      doc["ephemeralPub"] = %repeat("bb", 32)
      $doc)
    check otherKey.decision == udRefused
    check otherKey.refusal == urReleaseNotForThisSession

    let otherChallenge = through(proc (report, body: string): string =
      let doc = parseJson(body)
      doc["challenge"] = %repeat("cc", 32)
      $doc)
    check otherChallenge.decision == udRefused
    check otherChallenge.refusal == urReleaseNotForThisSession

    # The relay leaves every field that names the session alone and
    # corrupts the ciphertext. Now the AEAD is what refuses, and the
    # client says so with a DIFFERENT value — which is the whole point of
    # the check above buying a diagnosis rather than a protection.
    let corrupted = through(proc (report, body: string): string =
      let doc = parseJson(body)
      var wrapped = doc["wrappedSecret"].getStr
      wrapped[8] = (if wrapped[8] == 'A': 'B' else: 'A')
      doc["wrappedSecret"] = %wrapped
      $doc)
    check corrupted.decision == udRefused
    check corrupted.refusal == urCiphertextDidNotOpen

    # A base64 spelling that is not the canonical one for its own bytes.
    let sloppy = through(proc (report, body: string): string =
      let doc = parseJson(body)
      doc["wrappedSecret"] = %(doc["wrappedSecret"].getStr & "=")
      $doc)
    check sloppy.decision == udRefused
    check sloppy.refusal == urReleaseMalformed
    # Pinned by SENTENCE as well as by value: three sites report
    # `release-malformed`, and a gate that named only the value here
    # would be satisfied by the document simply failing to parse.
    check "not canonical base64" in sloppy.reason

    # AND A RELEASE THAT OPENS TO NOTHING. The relay composes its own
    # blob, correctly, to the very key the evidence bound and under the
    # very context this client will rebuild — and encrypts zero bytes.
    # Everything the client checks passes; the plaintext is empty. An
    # empty passphrase is a passphrase, and this build will not offer one
    # to a volume opener.
    let empty = through(proc (report, body: string): string =
      let (challengeHex, pubHex) = reportSession(report)
      let recipient = hexToBytes("pub", pubHex)
      let seed = repeat("\x5a", 32)
      let (enc, ct) = sealBase(haAes128Gcm, recipient, deriveKeyPair(seed),
        provisionInfo(hexToBytes("challenge", challengeHex), recipient),
        provisionAad("state-volume-key"), "")
      let doc = parseJson(body)
      doc["wrappedSecret"] = %base64.encode(
        renderWrappedSecret(uint16(haAes128Gcm), enc, ct))
      $doc)
    check empty.decision == udRefused
    check empty.refusal == urReleasedKeyEmpty
    var emptyRan = 0
    check empty.withReleasedKey(proc (key: string) = inc emptyRan) == false
    check emptyRan == 0

  test "t_remote_unseal_client_refuses_a_configuration_it_cannot_run":
    ## Everything that raises rather than refusing, and the line between
    ## the two: a broker cannot make this client raise, and a
    ## misconfiguration never becomes a refusal an operator might retry.
    proc refusalFor(body: proc()): string =
      try:
        body()
        ""
      except CatchableError as e:
        e.msg

    check "needs a transport" in refusalFor(proc () =
      discard performRemoteUnseal(nil, newMockDriver(), newX25519KeySource(),
        gateIdentity(), "state-volume-key", 0))
    check "no evidence this machine could offer" in refusalFor(proc () =
      discard performRemoteUnseal(newScripted(okChallenge(repeat("a1", 32)),
        BrokerAnswer(status: 200, body: "")), nil, newX25519KeySource(),
        gateIdentity(), "state-volume-key", 0))
    check "a key arriving in the clear" in refusalFor(proc () =
      discard performRemoteUnseal(newScripted(okChallenge(repeat("a1", 32)),
        BrokerAnswer(status: 200, body: "")), newMockDriver(), nil,
        gateIdentity(), "state-volume-key", 0))
    # The secret name is validated before a packet leaves, by the shipped
    # rule, so a name that would become a path never reaches a broker.
    check "restricted to lower-case" in refusalFor(proc () =
      discard attempt(newScripted(okChallenge(repeat("a1", 32)),
        BrokerAnswer(status: 200, body: "")), name = "../../etc/shadow"))

    # The transport's own construction.
    check "must name the endpoint" in refusalFor(proc () =
      var t = UnsealTransport()
      initUnsealTransport(t, ""))
    check "needs a broker address" in refusalFor(proc () =
      discard newHttpUnsealTransport(""))
    check "not an http:// or https:// URL" in refusalFor(proc () =
      discard newHttpUnsealTransport("ftp://broker.example"))
    check "a boot that hangs rather than one that fails" in refusalFor(
      proc () = discard newHttpUnsealTransport("http://x", timeoutMs = 0))
    # A trailing slash is trimmed rather than refused, so a deployment
    # that writes one does not get a 404 for every path.
    check newHttpUnsealTransport("http://broker.example/").endpoint ==
      "http://broker.example"

    # The seam's own base methods: a transport that implements neither
    # half. Pinned by PHRASE, because both halves raise the same
    # exception type with a message of the same shape.
    var bare = UnsealTransport()
    initUnsealTransport(bare, "<bare>")
    check "does not implement brokerGet" in refusalFor(proc () =
      discard bare.brokerGet("/x"))
    check "does not implement brokerPost" in refusalFor(proc () =
      discard bare.brokerPost("/x", "{}"))

  test "t_remote_unseal_client_command_line_refuses_what_it_cannot_do":
    proc refusalFor(args: seq[string]): string =
      try:
        discard parseUnsealArgs(args)
        ""
      except ValueError as e:
        e.msg

    check "must be DEVICE:MAPPING" in refusalFor(@["--broker=http://x",
      "--volume=justadevice"])
    check "names no mapping" in refusalFor(@["--broker=http://x",
      "--volume=/dev/sda:"])
    check "a device-mapper name is a name rather than a path" in refusalFor(
      @["--broker=http://x", "--volume=/dev/sda:/dev/mapper/x"])
    check "requires a value" in refusalFor(@["--broker"])
    check "unknown attestation-agent remote-unseal flag" in refusalFor(
      @["--broker=http://x", "--listen=0.0.0.0:1"])
    check "--action \"sideways\" is not one of open, format" in refusalFor(
      @["--broker=http://x", "--action=sideways"])
    check "--broker is required" in refusalFor(@["--name=x"])

    # The parsed shape, by value.
    let parsed = parseUnsealArgs(@["--broker=http://b", "--action=format",
      "--volume=/dev/vda:root", "--volume=/dev/vdb:home"])
    check parsed.action == vaFormat
    check parsed.volumes.len == 2
    check parsed.volumes[0].device == "/dev/vda"
    check parsed.volumes[1].mapping == "home"
    check parsed.name == DefaultUnsealSecretName
    check parseUnsealArgs(@["--broker=http://b"]).action == vaOpen

    # The two actions produce two different argument vectors, and BOTH
    # take the key on standard input. A `format` that took a key file
    # would write the key to a filesystem, which is the arrangement this
    # command exists to remove.
    let v = VolumeSpec(device: "/dev/vda", mapping: "reproos-state-root")
    let openArgv = unlockArguments(vaOpen, v)
    let formatArgv = unlockArguments(vaFormat, v)
    check openArgv != formatArgv
    check openArgv[0] == "open"
    check formatArgv[0] == "luksFormat"
    for argv in [openArgv, formatArgv]:
      check "--key-file=-" in argv
      check "/dev/vda" in argv
    check "reproos-state-root" in openArgv
    check "reproos-state-root" notin formatArgv

    # THE OTHER RULE ABOUT WHICH PROGRAM RUNS, with its own inputs. A
    # bare name resolved through PATH lets the environment choose what is
    # handed a volume key; an early-boot client names the program.
    var openerRefusal = ""
    try:
      requireAbsoluteOpener("cryptsetup")
    except ValueError as e:
      openerRefusal = e.msg
    check "is not an absolute path" in openerRefusal
    var emptyOpenerRefusal = ""
    try:
      requireAbsoluteOpener("")
    except ValueError as e:
      emptyOpenerRefusal = e.msg
    check "will not guess one" in emptyOpenerRefusal
    check emptyOpenerRefusal != openerRefusal
    # And an absolute one is accepted.
    requireAbsoluteOpener(getAppFilename())

    # THE RULE ABOUT /proc, with an input. Every process's arguments are
    # world-readable, so an argument vector carrying the key is refused
    # before the process is created.
    var argvRefusal = ""
    try:
      requireKeyNotOnCommandLine(@["open", "--key-file=" & TestKey], TestKey)
    except ValueError as e:
      argvRefusal = e.msg
    check "world-readable through" in argvRefusal
    check "argument 1" in argvRefusal
    # And it says nothing about a vector that does not carry it, nor
    # about an empty key.
    requireKeyNotOnCommandLine(openArgv, TestKey)
    requireKeyNotOnCommandLine(@["open", "--key-file=" & TestKey], "")

  test "t_remote_unseal_client_reaches_a_broker_that_rejects_outright":
    ## The OTHER refusal a broker can arrive at, and it is a different
    ## one: a policy that admits no tier this machine has produces
    ## `rejected` rather than a withheld acceptance. The client cannot
    ## tell them apart — both are a status — and that is correct: what it
    ## must do in either case is come back with nothing.
    let dir = getTempDir() / "remote-unseal-reject-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var h = startBroker(harnessConfig(dir / "broker", TestKey,
                                      policy = HarnessRejectingPolicy))
    defer: stopBroker(h)
    let outcome = attempt(newHttpUnsealTransport(h.brokerUrl))
    check outcome.decision == udRefused
    check outcome.refusal == urReleaseStatus

    let record = readFile(dir / "broker" / "broker-1.txt")
    check "verdict=rejected" in record
    check "release_decision=withheld" in record
    # A DIFFERENT reason from the opt-in refusal the boot gate captured.
    check "the checks that failed are" in record
    check "deliberate opt-in" notin record

  test "t_remote_unseal_client_asks_for_one_named_secret":
    ## A broker holding one key, asked for another. The refusal is the
    ## broker's and the client reports it as a status refusal — but the
    ## interesting half is that the client sent the name it was given and
    ## not a name of its own.
    let dir = getTempDir() / "remote-unseal-name-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var h = startBroker(harnessConfig(dir / "broker", TestKey))
    defer: stopBroker(h)
    let t = ScriptedTransport(challenge: okChallenge(repeat("a1", 32)),
                              release: BrokerAnswer(status: 200, body: ""))
    initUnsealTransport(t, "<scripted>")
    discard attempt(t, name = "some-other-key")
    check t.posted.len == 1
    let posted = parseJson(t.posted[0])
    check posted["schema"].getStr == UnsealRequestSchema
    check posted["name"].getStr == "some-other-key"
    # The report travels as a STRING, byte for byte as the machine built
    # it. A verifier checks the bytes a machine signed over, and
    # re-serialising a parsed document is how those stop being those
    # bytes.
    check posted["report"].kind == JString
    let report = posted["report"].getStr
    check parseAttestationReport(report, "<gate>").bindings.purpose ==
      bpKeyAgreement
    # BYTE FOR BYTE, with an input. `kind == JString` is satisfied by a
    # report that was parsed and written out again, which is the one
    # thing the sentence above forbids — so the bytes are pinned against
    # the canonical renderer that produced them, and against the
    # re-serialisation that would replace them.
    check report ==
      renderAttestationReport(parseAttestationReport(report, "<gate>"))
    check report != $parseJson(report)

    # And the real broker answers a name it does not hold with a 404
    # rather than by releasing what it does hold under the asked-for
    # label.
    let outcome = attempt(newHttpUnsealTransport(h.brokerUrl),
                          name = "some-other-key")
    check outcome.decision == udRefused
    check outcome.refusal == urReleaseStatus
    check outcome.brokerStatus == 404
    check "unknown-secret" in readFile(dir / "broker" / "broker-1.txt")

  test "t_remote_unseal_client_command_line_exits_rather_than_running":
    ## The three ways the command refuses to run at all, each by its exit
    ## code. They are separated from the parser's own refusals above
    ## because the parser can be asked directly and this cannot: the
    ## question here is what the PROGRAM does, and the answer has to be
    ## "it exits without touching a broker or a disk".
    check runRemoteUnseal(@["--no-such-flag"]) == ExitUsage
    # A tier this build does not implement is a refusal and not a
    # fallback: a machine that attested with mock evidence because a
    # device node was missing would be handed its disk key on the
    # strength of nothing.
    check runRemoteUnseal(@["--broker=http://127.0.0.1:1", "--tier=tpm"]) ==
      ExitUsage
    # A broker address this build will not use. The transport refuses at
    # construction, before a packet leaves.
    check runRemoteUnseal(@["--broker=ftp://broker.example"]) == ExitUsage

  test "t_remote_unseal_broker_refuses_what_it_cannot_decide":
    ## The broker's own refusals, driven over its real socket with a
    ## plain HTTP client rather than through the client under test —
    ## because several of these are things the client will never send,
    ## and a rule only a well-behaved caller can reach is a rule with no
    ## input.
    let dir = getTempDir() / "remote-unseal-broker-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    proc call(h: BrokerHarness; verb, path, body: string):
        tuple[status: int, body: string] =
      var c = newHttpClient(timeout = 10_000)
      try:
        let resp = c.request(h.brokerUrl & path,
          httpMethod = (if verb == "GET": HttpGet else: HttpPost),
          body = body,
          headers = newHttpHeaders({"Content-Type": "application/json"}))
        (resp.status.split(' ')[0].parseInt, resp.body)
      finally:
        try: c.close()
        except CatchableError: discard

    var h = startBroker(harnessConfig(dir / "broker", TestKey))
    defer: stopBroker(h)

    # Neither route answers the other's verb.
    check call(h, "POST", UnsealChallengePath, "{}").status == 405
    check call(h, "GET", UnsealReleasePath, "").status == 405
    # Nor does it serve anything else.
    let unknown = call(h, "GET", "/keys", "")
    check unknown.status == 404
    check "this broker serves" in unknown.body

    # A release asked for before any nonce was minted. Freshness is the
    # broker's input, so there is nothing for a report to answer.
    let early = call(h, "POST", UnsealReleasePath,
      $(%*{"schema": UnsealRequestSchema, "name": "state-volume-key",
           "report": "{}"}))
    check early.status == 409
    check "no challenge has been minted" in early.body

    # Now mint one, and send bodies the broker will not read.
    check call(h, "GET", UnsealChallengePath, "").status == 200
    check call(h, "POST", UnsealReleasePath, "not json").status == 400
    let missingReport = call(h, "POST", UnsealReleasePath,
      $(%*{"schema": UnsealRequestSchema, "name": "state-volume-key"}))
    check missingReport.status == 400
    check "`report` and `name`" in missingReport.body
    # A report that is a string but not a report: the verifier reaches a
    # verdict about it rather than falling over, so the answer is the
    # decision 403 and not the malformed-request 400. The two are
    # different situations and the broker must not conflate them.
    let unparseable = call(h, "POST", UnsealReleasePath,
      $(%*{"schema": UnsealRequestSchema, "name": "state-volume-key",
           "report": "this is not a report"}))
    check unparseable.status == 403
    # The broker numbers its records by release request, and only the
    # requests that reached the decision are counted — the two 405s and
    # the 404 above are not release requests at all.
    check h.broker.releaseRequests == 4
    let lastRecord = readFile(dir / "broker" /
      ("broker-" & $h.broker.releaseRequests & ".txt"))
    check "verdict=rejected" in lastRecord
    check "release_decision=withheld" in lastRecord

  test "t_remote_unseal_broker_refuses_a_configuration_it_cannot_serve":
    ## Everything wrong with a broker's configuration is wrong before it
    ## binds a socket — except one, which is deliberately left to the
    ## release rule that owns it.
    proc refusalFor(body: proc()): string =
      try:
        body()
        ""
      except CatchableError as e:
        e.msg

    let dir = getTempDir() / "remote-unseal-cfg-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    check "needs an output directory" in refusalFor(proc () =
      discard newUnsealBroker(BrokerConfig(secret: TestKey,
        policyText: HarnessPolicy)))
    check "nothing to decide about" in refusalFor(proc () =
      discard newUnsealBroker(BrokerConfig(outDir: dir,
        policyText: HarnessPolicy)))
    check "needs a policy document" in refusalFor(proc () =
      discard newUnsealBroker(BrokerConfig(outDir: dir, secret: TestKey)))

    # THE ONE THAT IS NOT CHECKED HERE. A secret name that could not
    # become a file is refused by `releaseSecret`, which owns that rule,
    # and the broker reports it as a request it could not decide rather
    # than as a decision. Validating the name at construction would make
    # the release rule's own refusal unreachable from here, which is why
    # it is not done.
    var h = startBroker(harnessConfig(dir / "broker", TestKey,
                                      secretName = "NOT A FILE NAME"))
    defer: stopBroker(h)
    var c = newHttpClient(timeout = 10_000)
    defer:
      try: c.close()
      except CatchableError: discard
    discard c.getContent(h.brokerUrl & UnsealChallengePath)
    let resp = c.request(h.brokerUrl & UnsealReleasePath,
      httpMethod = HttpPost,
      body = $(%*{"schema": UnsealRequestSchema, "name": "NOT A FILE NAME",
                  "report": "{}"}),
      headers = newHttpHeaders({"Content-Type": "application/json"}))
    check resp.status.split(' ')[0].parseInt == 400
    check "this request could not be decided" in resp.body
    check "release-error" in readFile(dir / "broker" / "broker-1.txt")

  test "t_remote_unseal_client_does_not_retry_a_decision":
    ## `--wait-seconds` exists so a client that comes up before its
    ## broker does not fail on a socket that is not listening yet. It
    ## must NOT make the client ask again after a broker has DECIDED —
    ## asking a broker to change its mind until it does is the fallback
    ## this whole arrangement exists not to have.
    ##
    ## Measured two ways, because either alone is weak: the broker is
    ## asked exactly once, and the client comes back well inside the
    ## window it was given.
    let dir = getTempDir() / "remote-unseal-retry-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var h = startBroker(harnessConfig(dir / "broker", TestKey,
                                      requireRootOfTrust = true))
    defer: stopBroker(h)
    let waitSeconds = 6
    let began = epochTime()
    let status = runRemoteUnseal(@[
      "--broker=" & h.brokerUrl,
      "--generation=retry-gate-generation",
      "--config-fingerprint=retry-gate-fingerprint",
      "--verity-root-hash=" & repeat("0", 64),
      "--report=" & (dir / "client.txt"),
      "--timeout-seconds=20",
      "--wait-seconds=" & $waitSeconds])
    let elapsed = epochTime() - began
    check status == ExitBrokerRefused
    check h.broker.releaseRequests == 1
    check elapsed < float(waitSeconds)

    # And the window really is a window: an address nothing is listening
    # on is retried until it runs out, which is the case the flag is
    # for and the ONLY refusal it applies to.
    let shortWait = 2
    let beganUnreachable = epochTime()
    let unreachable = runRemoteUnseal(@[
      "--broker=http://127.0.0.1:1",
      "--generation=retry-gate-generation",
      "--config-fingerprint=retry-gate-fingerprint",
      "--verity-root-hash=" & repeat("0", 64),
      "--report=" & (dir / "unreachable.txt"),
      "--timeout-seconds=1",
      "--wait-seconds=" & $shortWait])
    check unreachable == ExitBrokerRefused
    check epochTime() - beganUnreachable >= float(shortWait)
    check ("unseal_refusal=" & $urBrokerUnreachable) in
      readFile(dir / "unreachable.txt")

  test "t_remote_unseal_client_is_reachable_from_the_command_line":
    ## The subcommand really is wired into the binary an initramfs runs.
    ## Without this the dispatch is a line nothing consumes: every other
    ## case here calls `runRemoteUnseal` directly, so deleting the arm
    ## that reaches it would change no answer anywhere.
    let dir = getTempDir() / "remote-unseal-argv-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let recorder = dir / "opener.log"
    var h = startBroker(harnessConfig(dir / "broker", TestKey))
    defer: stopBroker(h)
    putEnv(RecorderLogEnv, recorder)
    defer: delEnv(RecorderLogEnv)

    check runAttestationAgent(@["remote-unseal",
      "--broker=" & h.brokerUrl,
      "--generation=argv-gate-generation",
      "--config-fingerprint=argv-gate-fingerprint",
      "--verity-root-hash=" & repeat("0", 64),
      "--volume=/dev/does-not-exist:argv-gate-root",
      "--cryptsetup=" & getAppFilename(),
      "--report=" & (dir / "client.txt"),
      "--timeout-seconds=20"]) == ExitUnsealed
    check brokerReleasedIn(readFile(dir / "client.txt"))
    check recorderInvocations(recorder).len == 4

    # And the daemon's own parser never sees the boot client's flags: a
    # flag accepted where it means nothing is a flag an operator will one
    # day believe did something.
    check runAttestationAgent(@["serve", "--broker=http://x"]) == ExitUsage
