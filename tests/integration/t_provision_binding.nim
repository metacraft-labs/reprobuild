## A secret is released to ONE key agreement, established inside ONE
## boot session, and to nothing else.
##
## ## What this gate proves
##
## The property has two halves, and they are two refusals: *a quote replayed with a
## different ephemeral key is refused; a key without matching evidence is
## refused.* Both are asserted here, and both are asserted at the point
## the refusal lives rather than by matching a sentence:
##
##   * **A quote replayed with another key.** Two ways, because there are
##     two, and they fail at different places. The *naive* swap — rewrite
##     ``bindings.ephemeralPub`` in the JSON — never reaches a verdict's
##     substance: the envelope carries its own 64 bytes and they no
##     longer agree with what its challenge and bindings produce, so the
##     parser refuses it. The *consistent* swap rebuilds the envelope so
##     it agrees with itself, and then the only thing left that disagrees
##     is the evidence, which still carries the other key's bytes. The
##     gate distinguishes the two by reading ``vcReportSchema`` and
##     ``vcReportDataBinding`` separately, because "a substring satisfied
##     by two different refusals" is the shape that would otherwise let
##     one of these stand in for the other.
##   * **A key without matching evidence**, at the agent: a public key no
##     key agreement was issued for, and a live public key offered under
##     a different challenge.
##
## And the part neither of those covers on its own: a ciphertext composed
## for one session does not open in another, because the context the
## receiver rebuilds is the *session's*, not the request's.
##
## ## What is real
##
## A real socket, the real daemon, the shipped X25519 mechanism drawing
## its seed from the operating system, a real tmpfs and a real
## non-volatile directory beside it. Every refusal below is produced by
## the code a deployment runs.
##
## ## Mocking
##
## The root of trust is ``newMockDriver()`` — a backend for a machine
## that has none — and every release here opts in to that explicitly.
## What is under test is the *binding*, which is the same construction on
## every backend; the tier's own contribution is what the policy gate
## beside this one exercises. The audit sinks collect and refuse on
## purpose; they are inputs, not substitutes.

import std/[base64, json, options, os, strutils, unittest]

import repro_attest
import repro_attest_agent

include ./attestation_agent_harness
include ./provisioning_harness

# ---------------------------------------------------------------------
# An agent that can really complete a provision
# ---------------------------------------------------------------------

proc provisioningAgent(secretsDir: string;
                       withKeySource = true;
                       sessionTtlMs = DefaultSessionTtlMs;
                       maxSessions = DefaultMaxSessions): AttestationAgent =
  newAttestationAgent(
    driver = newMockDriver(),
    identity = sampleIdentity(),
    keySource = (if withKeySource: newX25519KeySource() else: nil),
    secretStore = (if secretsDir.len == 0: nil
                   else: newProvisionedSecretStore(secretsDir)),
    sessionTtlMs = sessionTtlMs,
    maxSessions = maxSessions)

proc patientLimits(): AgentLimits =
  ## The shipped bounds with the two rate buckets widened, and NOTHING
  ## else changed.
  ##
  ## `/provision` is charged as a CHEAP route — see `routeCost`, where
  ## the reasoning is written down — but cheap is not free, and a case
  ## that deliberately makes a dozen refused attempts in a few
  ## milliseconds is abuse-shaped, so the shipped defaults refuse it,
  ## correctly. Every other case here runs against `defaultAgentLimits()`
  ## precisely so they also show that the shipped defaults do not refuse
  ## ordinary use.
  result = defaultAgentLimits()
  result.rateCapacity = 4_000.0
  result.rateRefillPerSecond = 2_000.0
  result.perClientCapacity = 4_000.0
  result.perClientRefillPerSecond = 2_000.0

proc keyAgreementReport(port: Port; challengeHex: string): RawResponse =
  post(port, PathKeyAgreement, $(%*{"challenge": challengeHex}))

proc ephemeralPubOf(reportText: string): string =
  parseAttestationReport(reportText, "<harness>").bindings.ephemeralPub

proc parsedReport(text: string): AttestationReport =
  parseAttestationReport(text, "<gate>")

proc decideFor(reportText, challengeHex: string;
                 allowNoRootOfTrust = true): ReleaseOutcome =
  let sink = newCollectingSink()
  releaseSecret(provisionRelease(reportText, ProvisionDevPolicy, challengeHex,
                                 allowNoRootOfTrust = allowNoRootOfTrust),
                sink, fixedSeed('w'))

suite "a released secret is bound to one attested key agreement":

  test "t_provision_binding_roundtrip_lands_in_a_volatile_directory":
    ## The whole protocol, end to end, over a socket: mint a challenge,
    ## take a key agreement, verify it, encrypt to the key the evidence
    ## bound, hand back the ciphertext, and find the plaintext in a
    ## directory with no backing store.
    let dir = volatileScratch("roundtrip")
    defer: removeDir(dir)
    check isVolatileFilesystem(filesystemMagic(dir))

    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let agreed = keyAgreementReport(h.port, ChallengeA)
    check agreed.status == 200
    let report = parsedReport(agreed.body)

    # The key is the instance's, it is 32 bytes, and the 64 bytes the
    # evidence carries are the ones this key and this challenge produce.
    check report.bindings.purpose == bpKeyAgreement
    check report.bindings.ephemeralPub.len == EphemeralPublicKeyBytes * 2
    check report.reportData == reportDataHexFor(report.bindings, ChallengeA)
    check report.bindsChallenge(ChallengeA)

    let sink = newCollectingSink()
    let outcome = releaseSecret(
      provisionRelease(agreed.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      sink, fixedSeed('a'))
    check outcome.decision == rdReleased
    check outcome.wrappedSecretBase64.len > 0
    check outcome.provisionBody.len > 0

    # The relay carries ciphertext. Asserted rather than assumed: the
    # secret is a literal, and a construction that forgot to encrypt
    # would put it here verbatim.
    check SampleSecret notin outcome.wrappedSecretBase64
    check SampleSecret notin base64.decode(outcome.wrappedSecretBase64)

    let released = post(h.port, PathProvision, outcome.provisionBody)
    check released.status == 200
    let landed = dir / DefaultSecretName
    check fileExists(landed)
    check readFile(landed) == SampleSecret
    check getFilePermissions(landed) == {fpUserRead, fpUserWrite}

    # One decision, recorded, and it says what happened.
    check sink.records.len == 1
    check sink.records[0].decision == rdReleased
    check sink.records[0].challengeHex == ChallengeA
    check sink.records[0].ephemeralPubHex == report.bindings.ephemeralPub

  test "t_provision_binding_each_agreement_mints_its_own_key":
    ## Two key agreements are two keys. A source that returned the same
    ## public key twice would make every session below indistinguishable
    ## from every other, and the swap cases would have nothing to swap.
    let dir = volatileScratch("keys")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    var seen: seq[string] = @[]
    for challenge in [ChallengeA, ChallengeA, ChallengeB]:
      let r = keyAgreementReport(h.port, challenge)
      check r.status == 200
      let pub = ephemeralPubOf(r.body)
      check pub.len == EphemeralPublicKeyBytes * 2
      check pub notin seen
      seen.add pub
    check seen.len == 3

  test "t_provision_binding_a_quote_replayed_with_another_key_is_refused":
    ## The first refusal, in both of the two shapes it has.
    let dir = volatileScratch("replay")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    let b = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    check b.status == 200
    let reportA = parsedReport(a.body)
    let pubB = ephemeralPubOf(b.body)
    check reportA.bindings.ephemeralPub != pubB

    # (1) The naive swap: A's document with B's key written into it. The
    # envelope now disagrees with itself about what it bound.
    var doc = parseJson(a.body)
    doc["bindings"]["ephemeralPub"] = %pubB
    let naive = decideFor($doc, ChallengeA)
    check naive.decision == rdWithheld
    check naive.wrappedSecretBase64.len == 0
    check naive.verdict.decision == vdRejected
    check naive.verdict.checks[vcReportSchema].outcome == coFailed

    # (2) The consistent swap: rebuilt so the envelope agrees with
    # itself — same evidence, same challenge, B's key, and the 64 bytes
    # recomputed. The only thing left that disagrees is the evidence, and
    # that is the check that has to catch it.
    let rebuilt = renderAttestationReport(attestationReport(
      reportA.backend, reportA.timestampInformational, ChallengeA,
      ReportBindings(purpose: bpKeyAgreement, ephemeralPub: pubB),
      authoritativeEvidence(reportA), reportA.claims,
      some(certificatesForCrossCheck(reportA))))
    let consistent = decideFor(rebuilt, ChallengeA)
    check consistent.decision == rdWithheld
    check consistent.wrappedSecretBase64.len == 0
    check consistent.verdict.decision == vdRejected

    # The two are NOT the same refusal wearing two names. The first never
    # got past the schema; the second did, and failed on the binding.
    check consistent.verdict.checks[vcReportSchema].outcome == coPassed
    check consistent.verdict.checks[vcReportDataBinding].outcome == coFailed
    check naive.verdict.checks[vcReportDataBinding].outcome == coFailed
    check naive.verdict.checks[vcReportSchema].outcome !=
          consistent.verdict.checks[vcReportSchema].outcome

    # And the control: A's own unmodified report releases. Without it,
    # every assertion above would also hold for a helper that refused
    # everything.
    let honest = decideFor(a.body, ChallengeA)
    check honest.decision == rdReleased
    check honest.verdict.checks[vcReportDataBinding].outcome == coPassed

  test "t_provision_binding_a_key_with_no_matching_session_is_refused":
    ## The second refusal, at the agent. Neither shape
    ## consumes anything, which the release at the end measures.
    let dir = volatileScratch("nosession")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    let outcome = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check outcome.decision == rdReleased

    # A public key nobody issued. Well formed in every other way — the
    # wrapped secret is the real one — so the only thing wrong is the key.
    var body = parseJson(outcome.provisionBody)
    body["ephemeralPub"] = %repeat("ab", EphemeralPublicKeyBytes)
    let unknown = post(h.port, PathProvision, $body)
    check unknown.status == 404

    # A live key, offered under a challenge it was not issued under.
    body = parseJson(outcome.provisionBody)
    body["challenge"] = %ChallengeB
    let wrongChallenge = post(h.port, PathProvision, $body)
    check wrongChallenge.status == 409

    check not fileExists(dir / DefaultSecretName)

    # The session survived both, so neither refusal spent it.
    let honest = post(h.port, PathProvision, outcome.provisionBody)
    check honest.status == 200
    check readFile(dir / DefaultSecretName) == SampleSecret

  test "t_provision_binding_a_ciphertext_for_another_session_does_not_open":
    ## The context the receiver rebuilds is the SESSION's. A ciphertext
    ## composed for A, offered under B's key and challenge, is refused —
    ## and B's session is still open afterwards, so the refusal cost the
    ## legitimate holder of the secret nothing.
    let dir = volatileScratch("crosssession")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    let b = keyAgreementReport(h.port, ChallengeB)
    check a.status == 200
    check b.status == 200

    let forA = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check forA.decision == rdReleased

    # A's ciphertext, B's session. Both fields the agent checks are B's,
    # so the binding checks pass and the AEAD is what refuses.
    var body = parseJson(forA.provisionBody)
    body["ephemeralPub"] = %ephemeralPubOf(b.body)
    body["challenge"] = %ChallengeB
    let crossed = post(h.port, PathProvision, $body)
    check crossed.status == 400
    check not fileExists(dir / DefaultSecretName)

    # B's own release still works: the refusal did not spend B's session.
    let forB = releaseSecret(
      provisionRelease(b.body, ProvisionDevPolicy, ChallengeB,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('b'))
    check forB.decision == rdReleased
    check post(h.port, PathProvision, forB.provisionBody).status == 200
    check readFile(dir / DefaultSecretName) == SampleSecret

  test "t_provision_binding_the_name_a_secret_lands_under_is_authenticated":
    ## The name rides in the AEAD's additional data, so a relay cannot
    ## relabel a released secret — handing a machine one credential under
    ## the name of another is a privilege change performed entirely with
    ## ciphertext nobody could read.
    let dir = volatileScratch("name")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    let forAlpha = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       secretName = "alpha", allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check forAlpha.decision == rdReleased
    check parseJson(forAlpha.provisionBody)["name"].getStr == "alpha"

    var body = parseJson(forAlpha.provisionBody)
    body["name"] = %"beta"
    check post(h.port, PathProvision, $body).status == 400
    check not fileExists(dir / "alpha")
    check not fileExists(dir / "beta")

    # And the control: the same session, released under "beta" properly,
    # does land. So the refusal above was about the relabelling and not
    # about the name "beta".
    let forBeta = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       secretName = "beta", allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check post(h.port, PathProvision, forBeta.provisionBody).status == 200
    check readFile(dir / "beta") == SampleSecret

  test "t_provision_binding_a_session_is_spent_by_a_release_and_by_nothing_else":
    let dir = volatileScratch("single")
    defer: removeDir(dir)
    let agent = provisioningAgent(dir)
    var h = startHarness(agent, patientLimits())
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    check agent.openSessions == 1

    # Four refusals, none of them a release.
    var body = parseJson("{}")
    check post(h.port, PathProvision, "{}").status == 400
    body = %*{"ephemeralPub": ephemeralPubOf(a.body), "challenge": ChallengeA,
              "wrappedSecret": ""}
    check post(h.port, PathProvision, $body).status == 400
    body["wrappedSecret"] = %"not base64 at all !!"
    check post(h.port, PathProvision, $body).status == 400
    body["wrappedSecret"] = %base64.encode("not a wrapped secret")
    check post(h.port, PathProvision, $body).status == 400
    check agent.openSessions == 1

    let outcome = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check post(h.port, PathProvision, outcome.provisionBody).status == 200
    check agent.openSessions == 0
    # The same body again: the key's single use is spent.
    check post(h.port, PathProvision, outcome.provisionBody).status == 404

  test "t_provision_binding_a_release_spelled_two_ways_is_two_documents":
    ## The canonical-base64 rule, with the input it needs.
    ##
    ## It had none: the case that was here sent a non-canonical spelling
    ## of something that was not a wrapped secret anyway, so deleting the
    ## rule left the document reader answering with the same status and
    ## nothing went red. The release below is REAL — remove the rule and
    ## it succeeds.
    let dir = volatileScratch("canon")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir), patientLimits())
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    let outcome = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check outcome.decision == rdReleased

    # A second spelling of the SAME bytes. Nim's decoder skips a
    # character outside the alphabet, so a trailing newline decodes to
    # the identical blob and re-encodes to a different string — which is
    # exactly the "one value, two documents" the rule refuses.
    let respelled = outcome.wrappedSecretBase64 & "\n"
    check base64.decode(respelled) ==
          base64.decode(outcome.wrappedSecretBase64)
    check base64.encode(base64.decode(respelled)) != respelled
    var body = parseJson(outcome.provisionBody)
    body["wrappedSecret"] = %respelled
    check post(h.port, PathProvision, $body).status == 400
    check not fileExists(dir / DefaultSecretName)

    # The control: the canonical spelling of the same release lands.
    check post(h.port, PathProvision, outcome.provisionBody).status == 200
    check readFile(dir / DefaultSecretName) == SampleSecret

  test "t_provision_binding_a_build_that_cannot_release_says_so_and_spends_nothing":
    let dir = volatileScratch("cannot")
    defer: removeDir(dir)

    # No mechanism: a key agreement cannot even be minted.
    block:
      var h = startHarness(provisioningAgent(dir, withKeySource = false))
      defer: stopHarness(h)
      check keyAgreementReport(h.port, ChallengeA).status == 501

    # A mechanism, but nowhere a secret is allowed to land. The refusal
    # comes BEFORE the session table is consulted, so it is not an oracle
    # for which public keys are live.
    block:
      let agent = provisioningAgent("")
      var h = startHarness(agent)
      defer: stopHarness(h)
      let a = keyAgreementReport(h.port, ChallengeA)
      check a.status == 200
      check agent.openSessions == 1
      let outcome = releaseSecret(
        provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                         allowNoRootOfTrust = true),
        newCollectingSink(), fixedSeed('a'))
      check post(h.port, PathProvision, outcome.provisionBody).status == 501
      # A public key that was never issued gets the SAME answer, which is
      # what "not an oracle" means.
      var body = parseJson(outcome.provisionBody)
      body["ephemeralPub"] = %repeat("cd", EphemeralPublicKeyBytes)
      check post(h.port, PathProvision, $body).status == 501
      check agent.openSessions == 1

  test "t_provision_binding_every_concatenation_is_framed":
    ## The defect §5.2 was amended for, one layer down. Without the
    ## length prefixes, moving the boundary between two variable-length
    ## parts produces the same bytes — so the three constructions this
    ## release path adds are each shown to separate a split the other way.
    # The property, in BOTH directions, over the same parts. The
    # unframed join is computed here rather than exported from the
    # library, because nothing in the library may have one.
    proc unframedJoin(parts: openArray[string]): string =
      for p in parts: result.add p
    check unframedJoin(["AB", "C"]) == unframedJoin(["A", "BC"])
    check framedJoin(["AB", "C"]) != framedJoin(["A", "BC"])
    check framedJoin(["A"]) == framedJoin(["A"])
    check framedJoin(["A", "B"]) != framedJoin(["A", "B", ""])
    check framedJoin(newSeq[string]()) == ""

    # And the frame is really a frame: the four bytes say how many
    # follow. Read back BY VALUE, so deleting the prefix from any one
    # construction is caught here rather than inferred from a collision
    # that `bindingPreimage` would have prevented anyway.
    proc framedFieldLen(s: string; at: int): int =
      (int(uint8(s[at])) shl 24) or (int(uint8(s[at + 1])) shl 16) or
      (int(uint8(s[at + 2])) shl 8) or int(uint8(s[at + 3]))

    let preimage = bindingPreimage(bpKeyAgreement, "chal", "pub")
    let info = provisionInfo("chal", "pub")
    check info.len == ProvisionInfoTag.len + 4 + preimage.len
    check framedFieldLen(info, ProvisionInfoTag.len) == preimage.len
    check info[ProvisionInfoTag.len + 4 .. ^1] == preimage
    check info != ProvisionInfoTag & preimage   # the unframed spelling

    let aad = provisionAad("alpha")
    check framedFieldLen(aad, ProvisionAadTag.len) == 5
    check aad[ProvisionAadTag.len + 4 .. ^1] == "alpha"
    check aad != ProvisionAadTag & "alpha"

    let id = uint16(ProvisionAead)
    check renderWrappedSecret(id, "AB", "C") !=
          renderWrappedSecret(id, "A", "BC")
    check provisionInfo("AB", "C") != provisionInfo("A", "BC")
    check provisionAad("ab") != provisionAad("a") & "b"

    # The info really is the bytes the hardware hashed, framed once.
    check provisionInfo("chal", "pub") != provisionInfo("cha", "lpub")

    # And it round-trips exactly, remainder included.
    let blob = renderWrappedSecret(id, repeat('e', EncapsulatedKeyBytes), "ciphertext")
    let parsed = parseWrappedSecret(blob)
    check parsed.aeadId == id
    check parsed.enc == repeat('e', EncapsulatedKeyBytes)
    check parsed.ciphertext == "ciphertext"
    proc refusalFor(body: string): string =
      try:
        discard parseWrappedSecret(body)
        ""
      except ProvisionError as err:
        err.msg
    check refusalFor(blob & "\x00").contains("bytes after its ciphertext")
    check refusalFor(blob[0 ..< blob.len - 1]).contains(
      "bytes of ciphertext and carries")
    check refusalFor("x" & blob[1 .. ^1]).contains("begins with")

  test "t_provision_binding_a_secret_is_never_written_to_backed_storage":
    ## The rule the roundtrip gate's block-device search exists to
    ## corroborate, asserted here where its refusal has a reachable input
    ## on any machine that runs this suite.
    let persistent = persistentScratch("persistent")
    defer: removeDir(persistent)
    let volatileDir = volatileScratch("volatile")
    defer: removeDir(volatileDir)

    # Both fixtures are constrained by the gate that uses them: a machine
    # where "/tmp" is a tmpfs fails here rather than passing vacuously.
    check not isVolatileFilesystem(filesystemMagic(persistent))
    check isVolatileFilesystem(filesystemMagic(volatileDir))

    expect SecretStoreError:
      discard newProvisionedSecretStore(persistent)
    let store = newProvisionedSecretStore(volatileDir)
    check store.directory == volatileDir
    check store.storeSecret("kept", SampleSecret) == volatileDir / "kept"
    check readFile(volatileDir / "kept") == SampleSecret

    # A symbolic link out of the checked directory is the one path the
    # filesystem check does not cover, and it is refused.
    let target = persistent / "planted"
    createSymlink(target, volatileDir / "escape")
    expect SecretStoreError:
      discard store.storeSecret("escape", SampleSecret)
    check not fileExists(target)

    # The re-check before every write, which is a DIFFERENT rule from
    # the one at construction and had no input until this case: a
    # directory that was a volatile filesystem when the daemon started
    # and is not one when a secret arrives. Reached here by taking the
    # directory away under the store's feet, which is the cheapest input
    # that separates the two checks; the message names WHEN it ran, and
    # the two messages are different sentences.
    let vanishing = volatileScratch("vanishing")
    let vanishingStore = newProvisionedSecretStore(vanishing)
    check vanishingStore.storeSecret("first", SampleSecret) ==
          vanishing / "first"
    removeDir(vanishing)
    var reWhen = ""
    try:
      discard vanishingStore.storeSecret("second", SampleSecret)
    except SecretStoreError as err:
      reWhen = err.msg
    check reWhen.contains("re-checked before writing a secret")

    # And the same rule with the STRONGER input, because the one above
    # reaches `requireVolatileDirectory` through its does-not-exist arm
    # and says nothing about the `statfs`. Here the path still resolves
    # to a directory — it is a symbolic link to the persistent fixture —
    # so only the magic number separates the two, and the refusal names
    # it. Without this, deleting the filesystem test from the write path
    # would leave the existence test answering, which is the "a refusal
    # answered by a DIFFERENT refusal" shape.
    let swapped = volatileScratch("swapped")
    let swappedStore = newProvisionedSecretStore(swapped)
    check swappedStore.storeSecret("before", SampleSecret) ==
          swapped / "before"
    removeDir(swapped)
    createSymlink(persistent, swapped)
    defer: removeFile(swapped)
    check dirExists(swapped)
    var swapWhen = ""
    try:
      discard swappedStore.storeSecret("after", SampleSecret)
    except SecretStoreError as err:
      swapWhen = err.msg
    check swapWhen.contains("is on a filesystem with magic")
    check swapWhen.contains("re-checked before writing a secret")
    check not fileExists(persistent / "after")

    var startWhen = ""
    try:
      discard newProvisionedSecretStore(persistent)
    except SecretStoreError as err:
      startWhen = err.msg
    check startWhen.contains("checked when the agent started")
    check reWhen != startWhen

    # A directory another local account can write is refused.
    let loose = volatileScratch("loose")
    defer: removeDir(loose)
    setFilePermissions(loose, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupWrite, fpGroupExec})
    expect SecretStoreError:
      discard newProvisionedSecretStore(loose)

    # The accept list, by value, on both sides.
    check isVolatileFilesystem(TmpfsMagic)
    check isVolatileFilesystem(RamfsMagic)
    check not isVolatileFilesystem(TmpfsMagic + 1)
    check not isVolatileFilesystem(0)
    check not isVolatileFilesystem(0x2FC12FC1'i64)   # zfs
    check not isVolatileFilesystem(0xEF53'i64)       # ext4

  test "t_provision_binding_a_name_off_the_wire_cannot_leave_the_directory":
    let dir = volatileScratch("names")
    defer: removeDir(dir)
    let store = newProvisionedSecretStore(dir)
    var reasons: seq[string] = @[]
    for bad in ["../escape", "/etc/passwd", "a/b", "", ".", "..",
                ".hidden", "UPPER", "with space", repeat("x", 65)]:
      var msg = ""
      try:
        discard store.secretPath(bad)
      except ProvisionError as err:
        msg = err.msg
      check msg.len > 0
      reasons.add msg

    # `.` and `..` ALSO begin with a dot, so without this the rule about
    # them could be deleted and the leading-dot rule would answer in its
    # place — a refusal answered by a different refusal, which is how a
    # rule stops being a rule without anything going red. Measured: it
    # was GREEN under exactly that mutation before these three lines.
    check reasons[4].contains("names a directory")
    check reasons[5].contains("names a directory")
    check reasons[6].contains("begins with a dot")
    check not reasons[6].contains("names a directory")
    check not reasons[4].contains("begins with a dot")
    for good in ["secret", "db.password", "tls-key", "a_b", "x"]:
      check store.secretPath(good) == dir / good

  test "t_provision_binding_a_literal_secret_seals_without_writing_read_only_memory":
    ## A defect found by being HPKE's first non-test consumer, and fixed
    ## in `aeadSeal`. Both AEADs encrypt in place through `addr buf[0]`,
    ## and `var buf = pt` is a MOVE rather than a copy whenever the
    ## compiler can see `pt` is dead afterwards. The move carries the
    ## caller's string all the way down — and when the caller's string is
    ## a literal or a `const`, its bytes are in the binary's read-only
    ## data. Writing through them is a segmentation fault, not a
    ## ciphertext.
    ##
    ## Every caller HPKE had was a test, and the published vectors arrive
    ## as `hexToBytes(...)`, which is heap-allocated — so the whole
    ## corpus ran through the move without ever touching read-only
    ## memory. A released secret, by contrast, is very often a constant
    ## in whoever's program is releasing it.
    ##
    ## The case is deliberately spelled with literals and `const`s at
    ## every position, because a runtime-built string would not reach the
    ## defect at all.
    const ConstSecret = "a const, which is a literal, which is read-only"
    let recipient = deriveKeyPair(repeat('r', SeedBytes))

    let (enc, ct) = sealBase(ProvisionAead, recipient.pk,
                             deriveKeyPair(repeat('e', SeedBytes)),
                             "literal info", "literal aad", ConstSecret)
    check openBase(ProvisionAead, enc, recipient.sk,
                   "literal info", "literal aad", ct) == ConstSecret

    # And through the mechanism, which is how the release helper reaches
    # it: the secret, the name and the seed are all constants here.
    let wrapped = wrapSecretForEphemeral(
      recipient.pk, hexToBytes("challenge", ChallengeA), "literal-name",
      ConstSecret, repeat('z', SeedBytes))
    check parseWrappedSecret(wrapped).ciphertext.len ==
          ConstSecret.len + ProvisionAead.nt

    # THE SAME DEFECT AT THE OTHER IN-PLACE SITE, which the case above
    # could not reach. BearSSL's curve25519 `mul` also writes its result
    # back over the buffer it is handed, so `x25519` had the identical
    # `var buf = point`. Every public key that had ever reached it came
    # out of `hexToBytes` or `publicKey`, both of which allocate, so it
    # was latent for the same reason and in the same way. A `const`
    # recipient key is an ordinary thing for a releasing program to
    # hold.
    #
    # Pinned by VALUE rather than by "it did not crash": the literal
    # must produce the same shared secret as the identical heap bytes,
    # so a copy that silently corrupted the input would be red here too.
    const ConstRecipientPub =
      "\x37\xFA\xC7\x0F\x3C\x86\xF2\xFA\x01\xF8\x0F\x8C\x81\x91\x77\x91" &
      "\x24\xD9\x97\xEC\x7F\x10\x67\xE7\xDA\x0E\x7F\xA6\x98\x92\xA9\x01"
    check ConstRecipientPub == recipient.pk
    let sender = deriveKeyPair(repeat('s', SeedBytes))
    check dh(sender.sk, ConstRecipientPub) == dh(sender.sk, recipient.pk)
    let (encL, ctL) = sealBase(ProvisionAead, ConstRecipientPub, sender,
                               "literal info", "literal aad", ConstSecret)
    check openBase(ProvisionAead, encL, recipient.sk,
                   "literal info", "literal aad", ctL) == ConstSecret

  test "t_provision_binding_a_release_that_opens_to_nothing_is_not_a_release":
    ## A ciphertext that authenticates and yields ZERO bytes. It is a
    ## reachable document — a tag with no body is a well-formed AEAD
    ## output and the framing carries it happily — and writing the empty
    ## file it would produce is indistinguishable, to whatever reads the
    ## secrets directory, from a secret that arrived.
    ##
    ## The case has to be built by hand because the shipped sender
    ## refuses to compose one, which is the other half of the rule and is
    ## asserted here too.
    let dir = volatileScratch("empty")
    defer: removeDir(dir)
    var h = startHarness(provisioningAgent(dir))
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    let pub = ephemeralPubOf(a.body)

    # The sender will not make one.
    expect KemError:
      discard wrapSecretForEphemeral(
        hexToBytes("pub", pub), hexToBytes("challenge", ChallengeA),
        DefaultSecretName, "", repeat('s', SeedBytes))

    # So it is composed directly, through the same primitives, with an
    # empty plaintext.
    let (enc, ct) = sealBase(ProvisionAead, hexToBytes("pub", pub),
      deriveKeyPair(repeat('s', SeedBytes)),
      provisionInfo(hexToBytes("challenge", ChallengeA),
                    hexToBytes("pub", pub)),
      provisionAad(DefaultSecretName), "")
    check ct.len == ProvisionAead.nt
    let body = %*{"ephemeralPub": pub, "challenge": ChallengeA,
                  "wrappedSecret": base64.encode(
                    renderWrappedSecret(uint16(ProvisionAead), enc, ct)),
                  "name": DefaultSecretName}
    check post(h.port, PathProvision, $body).status == 400
    check not fileExists(dir / DefaultSecretName)

  test "t_provision_binding_the_document_reader_refuses_every_malformed_shape":
    ## Every refusal `provision` states, given the input that reaches it.
    ##
    ## This case exists because the first measurement of this gate found
    ## eleven of them with NO reachable input — a rule nothing can reach
    ## is a sentence, not a rule, and that is where holes live. The
    ## composer and the parser are checked
    ## together and each refusal is matched by a phrase only it produces.
    let id = uint16(ProvisionAead)
    let enc = repeat('e', EncapsulatedKeyBytes)

    template refused(body: untyped): string =
      block:
        var msg = ""
        try:
          discard body
        except ProvisionError as err:
          msg = err.msg
        check msg.len > 0
        msg

    var seen: seq[string] = @[]
    proc distinctRefusal(msgs: var seq[string]; m: string) =
      for prior in msgs:
        check not (m in prior)
        check not (prior in m)
      msgs.add m

    proc refusedBy(msgs: var seq[string]; m, phrase: string) =
      ## The phrase FIRST: it says which rule answered. A row that only
      ## asserted "some refusal, and not one we have seen" is satisfied
      ## by a neighbouring rule picking up the input, which is how a
      ## bound gets deleted without anything going red.
      check phrase in m
      for prior in msgs:
        check not (m in prior)
        check not (prior in m)
      msgs.add m

    # The composer will not build a document its own reader refuses.
    refusedBy(seen, refused renderWrappedSecret(id, "", "ct"),
      "the encapsulated key is empty")
    refusedBy(seen, refused renderWrappedSecret(
      id, repeat('e', MaxEncapsulatedKeyBytes + 1), "ct"),
      "the encapsulated key is " & $(MaxEncapsulatedKeyBytes + 1) &
      " bytes; at most")
    refusedBy(seen, refused renderWrappedSecret(id, enc, ""),
      "the ciphertext is empty")
    refusedBy(seen, refused renderWrappedSecret(
      id, enc, repeat('c', MaxWrappedCiphertextBytes + 1)),
      "the ciphertext is " & $(MaxWrappedCiphertextBytes + 1) &
      " bytes; at most")

    # And the parser refuses every shape the framing admits and the
    # document does not. Each blob is built by hand, because a composer
    # that produced one would be the defect.
    proc be32(n: int): string =
      result = newString(4)
      result[0] = char((n shr 24) and 0xFF)
      result[1] = char((n shr 16) and 0xFF)
      result[2] = char((n shr 8) and 0xFF)
      result[3] = char(n and 0xFF)
    let hdr = WrappedSecretTag & "\x00\x01"

    refusedBy(seen, refused parseWrappedSecret(hdr & "\x00\x00"),
      "ends before the length of its encapsulated key")
    refusedBy(seen, refused parseWrappedSecret(hdr & be32(0)),
      "frames an encapsulated key of zero bytes")
    refusedBy(seen, refused parseWrappedSecret(
      hdr & be32(MaxEncapsulatedKeyBytes + 1)),
      "frames an encapsulated key of " & $(MaxEncapsulatedKeyBytes + 1) &
      " bytes; at most")
    refusedBy(seen, refused parseWrappedSecret(hdr & be32(64) & "short"),
      "frames 64 bytes of encapsulated key and carries")
    refusedBy(seen, refused parseWrappedSecret(hdr & be32(enc.len) & enc),
      "ends before the length of its ciphertext")
    refusedBy(seen, refused parseWrappedSecret(
      hdr & be32(enc.len) & enc & be32(0)),
      "frames a ciphertext of zero bytes")
    refusedBy(seen, refused parseWrappedSecret(
      hdr & be32(enc.len) & enc & be32(MaxWrappedCiphertextBytes + 1)),
      "frames a ciphertext of " & $(MaxWrappedCiphertextBytes + 1) &
      " bytes; at most")
    refusedBy(seen, refused parseWrappedSecret(
      hdr & be32(enc.len) & enc & be32(99) & "short"),
      "frames 99 bytes of ciphertext and carries")
    check seen.len == 12

    # The positive control: the shape between all of those is accepted.
    let good = parseWrappedSecret(renderWrappedSecret(id, enc, "ciphertext"))
    check good.enc == enc

  test "t_provision_binding_the_mechanism_refuses_what_it_cannot_open":
    ## Every refusal `x25519_kem` states that a caller can reach. Two
    ## cannot be: a short draw from the operating system's random source,
    ## and a derivation that produced a key of the wrong length. Both are
    ## recorded in the ledger as unreachable rather than given a fake
    ## input, because faking either would mean replacing the mechanism
    ## with something that is not it.
    let recipient = deriveKeyPair(repeat('r', SeedBytes))
    let session = SecretRelease(
      privateKey: recipient.sk,
      challenge: hexToBytes("challenge", ChallengeA),
      ephemeralPub: recipient.pk,
      name: DefaultSecretName,
      wrapped: wrapSecretForEphemeral(
        recipient.pk, hexToBytes("challenge", ChallengeA),
        DefaultSecretName, SampleSecret, repeat('s', SeedBytes)))
    let source = newX25519KeySource()
    # The positive control FIRST: this session opens.
    check source.openReleasedSecret(session) == SampleSecret

    template kemRefused(body: untyped): string =
      block:
        var msg = ""
        try:
          discard body
        except KemError as err:
          msg = err.msg
        check msg.len > 0
        msg

    var messages: seq[string] = @[]
    proc distinctKemRefusal(msgs: var seq[string]; m: string) =
      for prior in msgs:
        check not (m in prior)
        check not (prior in m)
      msgs.add(m)

    var shortKey = session
    shortKey.privateKey = repeat('k', 16)
    distinctKemRefusal(messages, kemRefused source.openReleasedSecret(shortKey))
    check messages[^1].contains("this key agreement holds a 16-byte")

    # A suite this build does not compose. The document is otherwise
    # perfect, so what is refused is the suite and not the bytes.
    var wrongSuite = session
    let parsed = parseWrappedSecret(session.wrapped)
    wrongSuite.wrapped = renderWrappedSecret(
      uint16(haChaCha20Poly1305), parsed.enc, parsed.ciphertext)
    distinctKemRefusal(messages, kemRefused source.openReleasedSecret(wrongSuite))
    # By PHRASE, because the bytes are a perfectly good AES ciphertext:
    # remove the suite check and this document opens rather than being
    # refused for some other reason.
    check messages[^1].contains("authenticated-encryption suite")

    var shortEnc = session
    shortEnc.wrapped = renderWrappedSecret(
      uint16(ProvisionAead), repeat('e', 16), parsed.ciphertext)
    distinctKemRefusal(messages, kemRefused source.openReleasedSecret(shortEnc))
    # Likewise by phrase: HPKE's own `decap` refuses a short
    # encapsulation too, so without this the mechanism's width rule
    # could be deleted and a DIFFERENT refusal would answer in its
    # place.
    check messages[^1].contains("-byte encapsulated key and this " &
                                "mechanism encapsulates")

    # A plaintext over the ceiling: the blob is inside the document
    # bound and what it opens to is not. Tested AT the bound and one
    # byte over it, because a bound tested only under itself is not
    # tested.
    proc sealedOf(size: int): SecretRelease =
      result = session
      let (e, c) = sealBase(ProvisionAead, recipient.pk,
        deriveKeyPair(repeat('z', SeedBytes)),
        provisionInfo(session.challenge, session.ephemeralPub),
        provisionAad(DefaultSecretName), repeat('P', size))
      result.wrapped = renderWrappedSecret(uint16(ProvisionAead), e, c)
    check source.openReleasedSecret(sealedOf(MaxSecretBytes)).len ==
          MaxSecretBytes
    distinctKemRefusal(messages, kemRefused source.openReleasedSecret(
      sealedOf(MaxSecretBytes + 1)))

    # The sending half.
    distinctKemRefusal(messages, kemRefused wrapSecretForEphemeral(
      repeat('p', 16), session.challenge, DefaultSecretName, SampleSecret,
      repeat('s', SeedBytes)))
    distinctKemRefusal(messages, kemRefused wrapSecretForEphemeral(
      recipient.pk, session.challenge, DefaultSecretName, "",
      repeat('s', SeedBytes)))
    distinctKemRefusal(messages, kemRefused wrapSecretForEphemeral(
      recipient.pk, session.challenge, DefaultSecretName,
      repeat('S', MaxSecretBytes + 1), repeat('s', SeedBytes)))
    check messages.len == 7

    # The sender validates the name it is about to bind into the `aad`.
    # Reached DIRECTLY, because every other path to this call goes
    # through `releaseSecret`, which validates the same name one layer
    # up — so without this the rule here could be deleted and the
    # earlier refusal would answer in its place.
    expect ProvisionError:
      discard wrapSecretForEphemeral(
        recipient.pk, session.challenge, "../escape", SampleSecret,
        repeat('s', SeedBytes))

  test "t_provision_binding_the_store_refuses_a_directory_it_was_never_given":
    let dir = volatileScratch("cfg")
    defer: removeDir(dir)
    proc storeRefusal(path: string): string =
      try:
        discard newProvisionedSecretStore(path)
        ""
      except SecretStoreError as err:
        err.msg
    # By PHRASE. An empty path is also not absolute, and a relative path
    # also does not exist, so each of these rules is answered by the
    # NEXT one if it is deleted — and `expect SecretStoreError` cannot
    # tell the difference. Measured: the relative-path row was GREEN
    # under exactly that mutation.
    check storeRefusal("").contains("was not configured")
    check storeRefusal("relative/dir").contains("is relative")
    check storeRefusal("/nonexistent-provisioned-secrets").contains(
      "does not exist")
    check newProvisionedSecretStore(dir).directory == dir

  test "t_provision_binding_the_agent_refuses_a_release_it_cannot_land":
    ## Two refusals the endpoint states that nothing else reaches: an
    ## over-long wrapped secret, and a directory that stopped being
    ## usable while the daemon was running. Neither consumes the session,
    ## which is what the release at the end measures.
    let dir = volatileScratch("agentrefuse")
    defer: removeDir(dir)
    let agent = provisioningAgent(dir)
    var h = startHarness(agent, patientLimits())
    defer: stopHarness(h)

    let a = keyAgreementReport(h.port, ChallengeA)
    check a.status == 200
    let pub = ephemeralPubOf(a.body)
    let outcome = releaseSecret(
      provisionRelease(a.body, ProvisionDevPolicy, ChallengeA,
                       allowNoRootOfTrust = true),
      newCollectingSink(), fixedSeed('a'))
    check outcome.decision == rdReleased

    # Over the field's bound, and under the transport's, so what refuses
    # it is the document bound rather than the socket.
    var body = parseJson(outcome.provisionBody)
    body["wrappedSecret"] = %repeat('A', MaxWrappedSecretBase64 + 4)
    check ($body).len < defaultAgentLimits().maxBodyBytes
    check post(h.port, PathProvision, $body).status == 413

    # A name off the wire that could not become a file, at the endpoint
    # rather than at the library call.
    body = parseJson(outcome.provisionBody)
    body["name"] = %"../escape"
    check post(h.port, PathProvision, $body).status == 400

    # The directory stops being one. The daemon checked it at start-up
    # and checks it again here, and the second check is the only thing
    # standing between a released secret and a write that would not go
    # where the first check said it would.
    removeDir(dir)
    check post(h.port, PathProvision, outcome.provisionBody).status == 500
    check agent.openSessions == 1

    # Put it back, and the same body — unchanged — completes. So the 500
    # was about the directory and the session really did survive it.
    createDir(dir)
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    check post(h.port, PathProvision, outcome.provisionBody).status == 200
    check readFile(dir / DefaultSecretName) == SampleSecret
    check agent.openSessions == 0

  test "t_provision_binding_the_two_rules_about_key_material_have_inputs":
    ## Two refusals the mechanism states that no caller can reach through
    ## it: a short draw from the operating system's random source, and a
    ## derivation that produced a key of the wrong width. Neither is
    ## reachable by a test that is not a replacement for the thing under
    ## test, so each is its own procedure and is checked by value.
    ##
    ## They are here rather than deleted because they are what the build
    ## would need to notice if either ever became possible, and they are
    ## split out rather than left inline because the first measurement of
    ## this gate found both with no reachable input at all.
    expect DriverError: requireFullDraw(0)
    expect DriverError: requireFullDraw(SeedBytes - 1)
    expect DriverError: requireFullDraw(SeedBytes + 1)
    requireFullDraw(SeedBytes)          # and the one draw that passes

    expect DriverError: requireDerivedWidths(EphemeralPublicKeyBytes - 1,
                                             SeedBytes)
    expect DriverError: requireDerivedWidths(EphemeralPublicKeyBytes,
                                             SeedBytes - 1)
    expect DriverError: requireDerivedWidths(0, 0)
    requireDerivedWidths(EphemeralPublicKeyBytes, SeedBytes)

    # And the seam's OWN refusal, which had no input either: a key source
    # that implements one half of the pair. `openReleasedSecret` and
    # `generateEphemeralKeyPair` are declared together precisely so a
    # build cannot acquire half a mechanism — and the half-built source
    # must say which half it is missing rather than return something.
    # Measured by instrumenting every refusal site: before this case, the
    # base method was never entered by any gate.
    let halfSource = EphemeralKeySource()
    initEphemeralKeySource(halfSource, "half-a-mechanism")
    var seamMsg = ""
    try:
      discard halfSource.openReleasedSecret(SecretRelease(
        privateKey: repeat('k', SeedBytes), challenge: "c",
        ephemeralPub: "p", name: DefaultSecretName, wrapped: "w"))
    except DriverError as err:
      seamMsg = err.msg
    check seamMsg.contains("does not implement openReleasedSecret")
    check seamMsg.contains("half-a-mechanism")
    # By PHRASE, because the OTHER half of the seam raises from the same
    # type with a message of the same shape, and "expect DriverError"
    # cannot tell the two apart.
    var mintMsg = ""
    try:
      discard halfSource.generateEphemeralKeyPair()
    except DriverError as err:
      mintMsg = err.msg
    check mintMsg.contains("does not implement generateEphemeralKeyPair")
    check seamMsg != mintMsg
