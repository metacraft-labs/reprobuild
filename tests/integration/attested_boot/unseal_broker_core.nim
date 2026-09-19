## The broker half of a remote unseal: the party that holds a machine's
## state-volume key and decides, per boot, whether that machine gets it.
##
## This is the counterpart of ``provision_releaser`` and it runs the
## protocol from the other end. The releaser *pushes* a secret at a
## machine that is already up; this one *waits* to be asked by a machine
## that cannot finish booting until it answers.
##
##   GET  /unseal-challenge  — mint a nonce, remember when
##   POST /unseal            — verify the report, decide, and either
##                             release the key encrypted to the ephemeral
##                             key that evidence bound, or answer with a
##                             status and a sentence
##
## Every rule is the shipped one. The server is the agent's own bounded
## ``httpd``; the nonce is ``mintChallenge``; the decision is
## ``releaseSecret`` with a real ``FileAuditSink``; the ciphertext is
## ``wrapSecretForEphemeral`` through ``release.nim``. What is here is the
## two routes and the record they write.
##
## ## The refusal is a refusal of the shipped rules, not a test branch
##
## ``requireRootOfTrust`` does not add a rejection. It *withholds* the
## opt-in that ``release.nim`` requires before it will release against
## ``accepted-without-a-root-of-trust`` — a rule that exists for
## production and is exercised here by not opting in. A broker that
## refused by returning a hard-coded 403 would be testing the harness;
## this one refuses because the library declined, and the audit record it
## writes says which rule declined and why.
##
## The policy document is the other axis, and it is a genuinely different
## refusal: a policy that admits no tier this machine has produces
## ``rejected`` rather than a withheld acceptance, and the two carry
## different reasons in the audit log and the same status on the wire.
##
## **The secret never appears in anything this module writes.** The
## records carry its SHA-256; the machine that decrypts it writes the
## same digest from inside itself, and the two are compared by a gate.
##
## ## No globals
##
## Everything is on one state object, so a gate can stand a broker up in
## a thread beside the code under test without the two sharing anything.
## Named without a ``t_`` prefix: it is a library the harness and the
## gates both use, not a registered test.
##
## ## Mocking
##
## None. Real socket, real verifier, real RFC 9180 composition. The
## machine on the other side has a software root of trust — see the
## harness README — which is why the accepting mode declares
## ``allowNoRootOfTrust`` out loud and the record says so.

import std/[json, options, os, strutils]

import nimcrypto/[hash, sha2]

import repro_attest/x25519_kem
import repro_attest_agent/httpd
import repro_attest_agent/limits
import repro_attest_agent/remote_unseal
import repro_attest_verify

type
  BrokerConfig* = object
    outDir*: string
      ## Where the per-decision records and the audit log are written.
    secret*: string
      ## The volume key this broker holds. In memory only.
    secretName*: string
    policyText*: string
    policySource*: string
    requireRootOfTrust*: bool
      ## Withhold ``allowNoRootOfTrust``. See the module header.

  UnsealBroker* = ref object
    config: BrokerConfig
    policy: AttestationPolicy
    challenge: MintedChallenge
    challengeMinted: bool
    releaseRequests: int

proc newUnsealBroker*(config: BrokerConfig): UnsealBroker =
  if config.outDir.len == 0:
    raise newException(ValueError, "a broker needs an output directory")
  if config.secret.len == 0:
    raise newException(ValueError,
      "a broker with no key to hold has nothing to decide about")
  if config.policyText.len == 0:
    raise newException(ValueError, "a broker needs a policy document")
  createDir(config.outDir)
  result = UnsealBroker(config: config,
    policy: parseAttestationPolicy(config.policyText, config.policySource))

proc releaseRequests*(b: UnsealBroker): int = b.releaseRequests

proc sha256Hex(s: string): string = toLowerAscii($sha256.digest(s))

proc textProblem(status: int; message: string): HttpResponse =
  HttpResponse(status: status, contentType: "text/plain",
    body: statusText(status) & ": " & message & "\n")

proc handleChallenge(b: UnsealBroker; nowMs: int64): HttpResponse =
  ## One live nonce at a time. A broker holding a table of them would be
  ## a broker with state this experiment does not need, and a machine
  ## that asks twice in one boot has restarted its client — which is a
  ## thing to see in the record rather than to accommodate.
  b.challenge = mintChallenge(nowMs)
  b.challengeMinted = true
  HttpResponse(status: 200, contentType: "application/json",
    body: $(%*{"schema": UnsealChallengeSchema,
               "challenge": b.challenge.challengeHex,
               "issuedAt": b.challenge.issuedAt}) & "\n")

proc writeDecisionRecord(b: UnsealBroker; index: int; lines: seq[string]) =
  writeFile(b.config.outDir / ("broker-" & $index & ".txt"),
            lines.join("\n") & "\n")

proc handleUnseal(b: UnsealBroker; body: string; nowMs: int64): HttpResponse =
  inc b.releaseRequests
  let index = b.releaseRequests
  var lines: seq[string] = @[]
  proc say(k, v: string) = lines.add(k & "=" & v)
  say("request", $index)
  say("secret_sha256", sha256Hex(b.config.secret))
  say("secret_bytes", $b.config.secret.len)
  say("policy_digest", policyDigestOf(b.config.policyText))
  say("require_root_of_trust",
      (if b.config.requireRootOfTrust: "1" else: "0"))

  if not b.challengeMinted:
    say("outcome", "no-challenge")
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    return textProblem(409,
      "no challenge has been minted; ask " & UnsealChallengePath & " first")

  var doc: JsonNode
  try:
    doc = parseJson(body)
  except CatchableError as err:
    say("outcome", "malformed-request")
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    return textProblem(400, "the request body is not JSON: " & err.msg)
  if doc.kind != JObject or not doc.hasKey("report") or
     doc["report"].kind != JString or not doc.hasKey("name") or
     doc["name"].kind != JString:
    say("outcome", "malformed-request")
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    return textProblem(400,
      "the request must be a JSON object carrying the string fields " &
      "`report` and `name`")
  let reportText = doc["report"].getStr
  let askedName = doc["name"].getStr
  say("asked_name", askedName)
  say("challenge", b.challenge.challengeHex)

  if askedName != b.config.secretName:
    # A broker holds one key here. Releasing it under a name the machine
    # chose would put a label the machine picked into the authenticated
    # `aad`, and that label is exactly what stops a relay relabelling a
    # release.
    say("outcome", "unknown-secret")
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    return textProblem(404,
      "this broker holds " & b.config.secretName.escape() &
      " and was asked for " & askedName.escape())

  let sink = newFileAuditSink(b.config.outDir / "broker-audit.jsonl")
  var outcome: ReleaseOutcome
  try:
    outcome = releaseSecret(ReleaseRequest(
      verification: VerificationRequest(
        reportText: reportText,
        reportSource: "<the machine's report>",
        policy: b.policy,
        policySource: b.config.policySource,
        manifestText: none(string),
        manifestSource: "",
        expectedChallengeHex: b.challenge.challengeHex,
        challengeIssuedAtMs: some(parseIssuedAtMs(b.challenge.issuedAt)),
        nowMs: nowMs),
      policyText: b.config.policyText,
      secretName: b.config.secretName,
      secret: b.config.secret,
      # The opt-in, or deliberately not. See the module header: the
      # refusal this produces is the shipped rule declining, not a branch
      # written to decline.
      allowNoRootOfTrust: not b.config.requireRootOfTrust),
      sink, drawSenderSeed())
  except CatchableError as err:
    say("outcome", "release-error")
    say("release_error", err.msg.replace("\n", " "))
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    return textProblem(400, "this request could not be decided: " & err.msg)

  say("verdict", $outcome.verdict.decision)
  say("release_decision", $outcome.decision)
  say("release_reason", outcome.audit.reason.replace("\n", " "))
  say("audit_challenge", outcome.audit.challengeHex)
  say("audit_ephemeral_pub", outcome.audit.ephemeralPubHex)
  say("audit_policy_digest", outcome.audit.policyDigest)

  if outcome.decision != rdReleased:
    say("outcome", "withheld")
    say("wrapped_bytes", "0")
    say("end", "1")
    b.writeDecisionRecord(index, lines)
    # 403 and not 500: the machine asked a well-formed question and the
    # answer is no. A status that read as an error would invite a client
    # to retry, and retrying a decision is the fallback this arrangement
    # exists not to have.
    return textProblem(403, outcome.audit.reason)

  say("outcome", "released")
  say("wrapped_bytes", $outcome.wrappedSecretBase64.len)
  say("wrapped_carries_plaintext",
      $(b.config.secret in outcome.wrappedSecretBase64))
  say("end", "1")
  b.writeDecisionRecord(index, lines)

  let provision = parseJson(outcome.provisionBody)
  HttpResponse(status: 200, contentType: "application/json",
    body: $(%*{"schema": UnsealReleaseSchema,
               "name": provision["name"].getStr,
               "challenge": provision["challenge"].getStr,
               "ephemeralPub": provision["ephemeralPub"].getStr,
               "wrappedSecret": provision["wrappedSecret"].getStr}) & "\n")

proc brokerRespond*(b: UnsealBroker; req: HttpRequest;
                    nowMs: int64): HttpResponse =
  ## The whole surface, pure in the broker's state and the clock.
  case req.path
  of UnsealChallengePath:
    if req.verb != "GET":
      return textProblem(405, "use GET " & UnsealChallengePath)
    handleChallenge(b, nowMs)
  of UnsealReleasePath:
    if req.verb != "POST":
      return textProblem(405, "use POST " & UnsealReleasePath)
    handleUnseal(b, req.body, nowMs)
  else:
    return textProblem(404,
      "this broker serves " & UnsealChallengePath & " and " &
      UnsealReleasePath)

proc brokerRouteCost*(verb, path: string): int {.gcsafe, raises: [].} =
  ## Both routes are cheap in the sense the limiter cares about: neither
  ## touches a root of trust. The verification is arithmetic.
  CostCheap
