## The verifier half of one secret release, driven against a machine
## over a socket.
##
## This is the program the *host* runs while a guest is up: it mints a
## nonce, asks the guest for a key agreement, verifies what comes back
## against a policy, encrypts the secret to the key that evidence bound,
## and hands the ciphertext to ``POST /provision``. It is the shipped
## library at every step — ``mintChallenge``, ``releaseSecret``,
## ``FileAuditSink`` — with nothing here but the command line and the
## HTTP.
##
## It writes a flat ``key=value`` record of what happened, because the
## gate that reads this experiment runs offline from those bytes.
##
## **The secret never appears in anything this program writes.** The
## record carries its SHA-256; the guest, which is the only other party
## that ever holds the plaintext, writes the same digest from inside
## itself, and the gate compares the two. That is how "the machine
## really decrypted it" is established without exporting it.
##
## Named without a ``t_`` prefix: it is a program the harness runs, not
## a registered test.
##
## ## Mocking
##
## None. The guest's root of trust is a software one — see the harness's
## README — which is why the release below declares
## ``allowNoRootOfTrust``. Every other rule is the shipped one.

import std/[httpclient, json, options, os, parseopt, strutils, times]

import nimcrypto/[hash, sha2]

import repro_attest
import repro_attest/x25519_kem
import repro_attest_verify

type
  Options = object
    agent: string
    outDir: string
    secretFile: string
    name: string
    policyFile: string
    timeoutSeconds: int

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("provision-releaser: " & msg)
  quit(2)

proc parseArgs(): Options =
  result.name = "released-credential"
  result.timeoutSeconds = 120
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case p.key
      of "agent": result.agent = p.val
      of "out": result.outDir = p.val
      of "secret-file": result.secretFile = p.val
      of "name": result.name = p.val
      of "policy": result.policyFile = p.val
      of "timeout-seconds": result.timeoutSeconds = parseInt(p.val)
      else: fail("unknown option --" & p.key)
    of cmdArgument: fail("unexpected argument " & p.key.escape())
  for (flag, value) in {"--agent": result.agent, "--out": result.outDir,
                        "--secret-file": result.secretFile,
                        "--policy": result.policyFile}:
    if value.len == 0: fail(flag & " is required")

proc waitForAgent(base: string; seconds: int): string =
  ## The guest boots on its own schedule. Poll ``/health`` until it
  ## answers, and return the body, so the record can say what the
  ## machine reported about itself.
  let deadline = epochTime() + float(seconds)
  var lastError = "never attempted"
  while epochTime() < deadline:
    var client = newHttpClient(timeout = 2_000)
    try:
      let body = client.getContent(base & "/health")
      client.close()
      return body
    except CatchableError as err:
      lastError = err.msg
      try: client.close()
      except CatchableError: discard
    sleep(500)
  fail("the agent at " & base & " never answered /health within " &
    $seconds & "s; last error: " & lastError)

proc postJson(base, path, body: string): tuple[status: int, body: string] =
  var client = newHttpClient(timeout = 20_000)
  try:
    let resp = client.request(base & path, httpMethod = HttpPost, body = body,
      headers = newHttpHeaders({"Content-Type": "application/json"}))
    result = (resp.status.split(' ')[0].parseInt, resp.body)
  finally:
    try: client.close()
    except CatchableError: discard

proc sha256Of(data: string): string = toLowerAscii($sha256.digest(data))

when isMainModule:
  let o = parseArgs()
  createDir(o.outDir)
  let record = o.outDir / "releaser-report.txt"
  var lines: seq[string] = @[]
  proc say(k, v: string) = lines.add(k & "=" & v)

  let secret = readFile(o.secretFile)
  if secret.len == 0: fail("the secret file is empty")
  let policyText = readFile(o.policyFile)

  say("agent", o.agent)
  say("secret_bytes", $secret.len)
  say("secret_sha256", sha256Of(secret))
  say("secret_name", o.name)
  say("policy_digest", policyDigestOf(policyText))

  let health = waitForAgent(o.agent, o.timeoutSeconds)
  writeFile(o.outDir / "health.json", health)
  let healthDoc = parseJson(health)
  say("health_backend", healthDoc["backend"].getStr)
  say("health_tier", healthDoc["tier"].getStr)
  say("health_key_agreement", healthDoc["keyAgreement"].getStr)
  say("health_can_release", $healthDoc["canRelease"].getBool)
  say("health_secrets_dir", healthDoc["provisionedSecretsDir"].getStr)

  # The nonce is minted here, by the verifier, and is the only source of
  # freshness this protocol has.
  let nowMs = int64(epochTime() * 1000.0)
  let challenge = mintChallenge(nowMs)
  say("challenge", challenge.challengeHex)
  say("challenge_issued_at", challenge.issuedAt)

  let agreed = postJson(o.agent, "/key-agreement",
    $(%*{"challenge": challenge.challengeHex}))
  say("key_agreement_status", $agreed.status)
  if agreed.status != 200:
    writeFile(record, lines.join("\n") & "\n")
    fail("/key-agreement answered " & $agreed.status & ": " & agreed.body)
  writeFile(o.outDir / "key-agreement-report.json", agreed.body)

  let report = parseAttestationReport(agreed.body, "<the machine's report>")
  say("report_purpose", $report.bindings.purpose)
  say("report_ephemeral_pub", report.bindings.ephemeralPub)
  say("report_binds_challenge", $report.bindsChallenge(challenge.challengeHex))

  let sink = newFileAuditSink(o.outDir / "release-audit.jsonl")
  let outcome = releaseSecret(ReleaseRequest(
    verification: VerificationRequest(
      reportText: agreed.body,
      reportSource: "<the machine's report>",
      policy: parseAttestationPolicy(policyText, o.policyFile),
      policySource: o.policyFile,
      manifestText: none(string),
      manifestSource: "",
      expectedChallengeHex: challenge.challengeHex,
      challengeIssuedAtMs: some(parseIssuedAtMs(challenge.issuedAt)),
      nowMs: nowMs),
    policyText: policyText,
    secretName: o.name,
    secret: secret,
    # The guest's root of trust is a software one. Declared here rather
    # than hidden, so the record says what this release rests on.
    allowNoRootOfTrust: true), sink, drawSenderSeed())

  say("verdict", $outcome.verdict.decision)
  say("release_decision", $outcome.decision)
  if outcome.decision != rdReleased:
    say("release_reason", outcome.audit.reason)
    writeFile(record, lines.join("\n") & "\n")
    fail("the release was withheld: " & outcome.audit.reason)

  say("wrapped_secret_sha256", sha256Of(outcome.wrappedSecretBase64))
  say("wrapped_secret_base64_len", $outcome.wrappedSecretBase64.len)
  # The relay carries ciphertext, and this record says so by measurement
  # rather than by claim.
  say("wrapped_carries_plaintext",
    $(secret in outcome.wrappedSecretBase64))

  let provisioned = postJson(o.agent, "/provision", outcome.provisionBody)
  say("provision_status", $provisioned.status)
  writeFile(o.outDir / "provision-response.txt", provisioned.body)
  if provisioned.status == 200:
    let doc = parseJson(provisioned.body)
    say("provision_path", doc["path"].getStr)
    say("provision_bytes", $doc["bytes"].getInt)

  # A second attempt with the same body: the key's single use is spent.
  let replayed = postJson(o.agent, "/provision", outcome.provisionBody)
  say("replay_status", $replayed.status)

  writeFile(record, lines.join("\n") & "\n")
  if provisioned.status != 200:
    fail("/provision answered " & $provisioned.status & ": " &
      provisioned.body)
  echo "provision-releaser: released " & $secret.len & " bytes to " &
    o.agent
