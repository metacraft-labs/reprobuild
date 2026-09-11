## An acceptance that read its identity out of a manifest nobody pinned
## is not the unqualified `accepted`, and the difference reaches `$?`.
##
## ## The gap this gate closes
##
## `repro attest verify` has always said this in words. Under a policy
## whose `measurements.manifests` is empty, the `manifest-pinned` row
## reads *skipped* and the verdict carries a caveat spelling out that the
## manifest it compared against "was authenticated by nothing but the
## fact that it was supplied to the verifier". It then printed an
## `establishes:` block — a configuration fingerprint and a verity root
## hash read straight out of that document — and exited **0**, which is
## the same exit code as a verdict backed by a manifest the operators
## pinned by digest in advance.
##
## Prose is not a channel `$?` can read. The verdict object already
## distinguishes acceptances that establish less than they look like they
## do — a mock-tier report reaches `accepted-without-a-root-of-trust` and
## exits 3, never 0 — and this is the same property one step along: the
## evidence came from a root of trust, and the *expectation* it was
## compared against came from whoever ran the command.
##
## ## How the two sides are held equal
##
## The trap in a two-policy comparison is that the two policies differ in
## more than the key under test, in which case the gate proves that
## *something* moved rather than that the pin moved it. So the second
## policy is produced from the first by one string replacement, and the
## two documents are then compared LINE BY LINE: exactly one line may
## differ and it must be the `manifests` line. Everything else — the
## report, the reading, the manifest bytes, the challenge, the clock — is
## the same object passed to both.
##
## Symmetrically, the new code must not be reachable by an unrelated
## path. `manifests = []` on its own does not produce it: the mock-tier
## development policy has an empty list too, and a mock report under it
## still reaches `accepted-without-a-root-of-trust` and exit 3, because a
## mock report establishes no identity for an unpinned manifest to have
## supplied. Nor does a rejection under the unpinned policy: a
## measurement the manifest does not contain, and a verification with no
## manifest at all, both exit 1.
##
## ## What this gate does NOT prove
##
## It does not observe exit code 4 coming out of a *process*. Reaching an
## acceptance on a tier that has a root of trust needs a reader for that
## backend's evidence, and this build carries one for the mock backend
## only; the tpm-tier verdicts below are driven through the documented
## embedding seam, with a reading a caller supplied, exactly as the
## enumeration gate drives the same branch. What is checked instead is
## that the command line has no exit-code opinion of its own: the
## decision-to-code mapping is a single total function, and the CLI's
## source mentions no decision value outside it.
##
## ## Mocking
##
## None. The reading handed to the embedding seam is the caller's own,
## which is what that seam is for; the verdict records whose reading it
## was and caveats itself accordingly.

import std/[options, os, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_cli_support/attest

include ./attestation_verifier_harness

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  CliSource = RepoRoot / "libs" / "repro_cli_support" / "src" /
    "repro_cli_support" / "attest.nim"

  PinnedManifestsLine = "manifests = [\"@DIGEST@\"]"
  UnpinnedManifestsLine = "manifests = []"

proc unpinnedTpmPolicyText(): string =
  ## The tpm policy with its pin list emptied, and nothing else touched.
  doAssert TpmPolicyTemplate.count(PinnedManifestsLine) == 1,
    "the tpm policy template no longer carries exactly one manifest pin " &
      "line; the one-key comparison below would be comparing something else"
  tpmPolicyText().replace(
    PinnedManifestsLine.replace("@DIGEST@", sampleManifestDigest()),
    UnpinnedManifestsLine)

proc unpinnedTpmPolicy(): AttestationPolicy =
  parseAttestationPolicy(unpinnedTpmPolicyText(), "<tpm-policy-unpinned>")

proc differingLines(a, b: string): seq[string] =
  ## Every line index at which the two documents disagree, rendered as
  ## "<index>: <a> | <b>". A length difference is a disagreement too.
  let la = a.splitLines
  let lb = b.splitLines
  for i in 0 ..< max(la.len, lb.len):
    let x = (if i < la.len: la[i] else: "<absent>")
    let y = (if i < lb.len: lb[i] else: "<absent>")
    if x != y: result.add $i & ": " & x & " | " & y

proc exitCodeOf(v: Verdict): int = ord(attestExitCodeFor(v.decision))

proc strippedCliSource(): seq[string] =
  ## The CLI module's lines with Nim comments removed, so a decision
  ## value named in a comment is not read as a second mapping.
  for rawLine in readFile(CliSource).splitLines:
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    result.add line

suite "an unpinned manifest is not a plain acceptance":

  # -- the two policies are one key apart -----------------------------

  test "the two policies differ in exactly one line, and it is the pin":
    let pinned = tpmPolicyText()
    let unpinned = unpinnedTpmPolicyText()
    check pinned != unpinned
    let diff = differingLines(pinned, unpinned)
    check diff.len == 1
    if diff.len == 1:
      check "manifests" in diff[0]
      check sampleManifestDigest() in diff[0]
      check UnpinnedManifestsLine in diff[0]
    # Both are documents the real parser accepts. Without this the
    # "unpinned" half could be a policy that never parsed at all.
    check tpmPolicy().pinsManifests
    check not unpinnedTpmPolicy().pinsManifests

  # -- the deliverable ------------------------------------------------

  test "pinning the manifest exits 0; emptying the pin list does not":
    # One report, one reading, one manifest, two policies.
    let measurement = sampleExpectedPcr11()
    let manifestText = sampleManifestText()

    let vPinned = tpmVerdict(measurement, manifestText, tpmPolicy())
    let vUnpinned = tpmVerdict(measurement, manifestText, unpinnedTpmPolicy())

    # The codes are pinned as LITERALS as well as by name. A check
    # written only against the constant that produced the value passes
    # whatever that constant is later changed to.
    check AttestExitAccepted == 0
    check AttestExitAcceptedUnauthenticatedManifest == 4

    check vPinned.decision == vdAccepted
    check exitCodeOf(vPinned) == 0

    check vUnpinned.decision == vdAcceptedUnpinnedManifest
    check exitCodeOf(vUnpinned) == 4

    # The whole point, stated as the inequality a script would see.
    check exitCodeOf(vPinned) != exitCodeOf(vUnpinned)

    # And the negative half: pinning RESTORES 0, so the new code is not
    # something the tpm path reaches regardless of the policy.
    check exitCodeOf(vPinned) == AttestExitAccepted

  test "the same identity is established either way — only its standing moves":
    let measurement = sampleExpectedPcr11()
    let manifestText = sampleManifestText()
    let vPinned = tpmVerdict(measurement, manifestText, tpmPolicy())
    let vUnpinned = tpmVerdict(measurement, manifestText, unpinnedTpmPolicy())

    # Both establish an identity, and it is the same identity: this is
    # not a gate about one verdict having less to say than the other.
    check vPinned.hasIdentity
    check vUnpinned.hasIdentity
    check vPinned.identity == vUnpinned.identity
    check vUnpinned.identity.configFingerprint ==
      sampleManifest().configFingerprint

    # Exactly one row moves, and it is `manifest-pinned`.
    var moved: seq[VerifierCheck] = @[]
    for chk in VerifierCheck:
      if vPinned.checks[chk].outcome != vUnpinned.checks[chk].outcome:
        moved.add chk
    check moved == @[vcManifestPinned]
    check vPinned.checks[vcManifestPinned].outcome == coPassed
    check vUnpinned.checks[vcManifestPinned].outcome == coSkipped
    check vUnpinned.checks[vcMeasurementMatch].outcome == coPassed

    # The prose channel still says it, so the exit code is an addition
    # rather than a replacement.
    check UnpinnedManifestCaveat in vUnpinned.caveats
    check UnpinnedManifestCaveat notin vPinned.caveats
    check "accepted-against-an-unauthenticated-manifest" in
      renderVerdictText(vUnpinned)
    check "\"decision\": \"accepted-against-an-unauthenticated-manifest\"" in
      renderVerdictJson(vUnpinned)
    # `establishes:` is still printed — the block a reader wants — and
    # the decision above it is what qualifies it.
    check "establishes:" in renderVerdictText(vUnpinned)

  # -- the new code is not reachable by an unrelated path -------------

  test "an empty pin list alone does not produce the new code":
    # The mock development policy pins nothing either. A mock report
    # under it is still `accepted-without-a-root-of-trust` and still
    # exits 3, because it establishes no identity for an unpinned
    # manifest to have supplied — the missing root of trust is the
    # larger caveat and keeps its own code.
    check MockDevPolicy.count(UnpinnedManifestsLine) == 1
    let policy = mockPolicy()
    check not policy.pinsManifests
    let text = mockReportText()
    var req = verificationRequest(text, policy, some(sampleManifestText()))
    let v = verifyAttestationReport(req)
    check v.checks[vcManifestPinned].outcome == coSkipped
    check not v.hasIdentity
    check v.decision == vdAcceptedNoRootOfTrust
    check AttestExitAcceptedNoRootOfTrust == 3
    check exitCodeOf(v) == 3
    check exitCodeOf(v) != AttestExitAcceptedUnauthenticatedManifest

    # …and it is not merely that this build's mock reader publishes no
    # launch measurement, which a caller bringing its own reader could
    # defeat. The measurement manifest defines no launch shape for the
    # mock backend at all, so the comparison FAILS rather than passing,
    # and a mock verdict that establishes an identity is unreachable
    # through the embedding seam too. That is what makes "hollow in both
    # directions at once" impossible rather than merely unobserved.
    let supplied = verifyWithReading(
      verificationRequest(text, policy, some(sampleManifestText())),
      parseAttestationReport(text, "<mock report>"),
      tpmReading(sampleExpectedPcr11(),
        parseAttestationReport(text, "<mock report>").reportData))
    check supplied.checks[vcMeasurementMatch].outcome == coFailed
    check not supplied.hasIdentity
    check supplied.decision == vdRejected
    check exitCodeOf(supplied) == 1

  test "a rejection under the unpinned policy is still a rejection":
    let policy = unpinnedTpmPolicy()
    check AttestExitRejected == 1

    # (a) a measurement the manifest does not contain.
    let wrong =
      "0000000000000000000000000000000000000000000000000000000000000000"
    let vWrong = tpmVerdict(wrong, sampleManifestText(), policy)
    check vWrong.checks[vcManifestPinned].outcome == coSkipped
    check vWrong.checks[vcMeasurementMatch].outcome == coFailed
    check vWrong.decision == vdRejected
    check exitCodeOf(vWrong) == 1

    # (b) no manifest at all. On a tier with a root of trust the
    # comparison is required, so "nothing to compare against" is a
    # failure and not a second flavour of unpinned acceptance.
    let text = tpm2ReportText()
    let report = parseAttestationReport(text, "<tpm report>")
    var req = verificationRequest(text, policy, none(string))
    let vNone = verifyWithReading(req, report,
      tpmReading(sampleExpectedPcr11(), report.reportData))
    check vNone.checks[vcManifestPinned].outcome == coSkipped
    check vNone.checks[vcMeasurementMatch].outcome == coFailed
    check not vNone.hasIdentity
    check vNone.decision == vdRejected
    check exitCodeOf(vNone) == 1

  # -- the rule itself, driven directly -------------------------------

  test "the decision rule: which rows make an acceptance unauthenticated":
    # `decisionFor` is a pure function of the check array and the tier,
    # so the rule can be exercised without a report at all — which is
    # how the combinations the shipped build cannot reach get covered.
    proc checkArray(skipped: set[VerifierCheck]):
        array[VerifierCheck, CheckRecord] =
      var v: Verdict
      for chk in VerifierCheck:
        if chk in skipped:
          v.record(chk, false, inapplicable("fixture: not performed"))
        else:
          v.record(chk, true, satisfied("fixture: performed and satisfied"))
      v.checks

    let everything = checkArray({})
    let noPin = checkArray({vcManifestPinned})
    let noPinNoMeasurement = checkArray({vcManifestPinned, vcMeasurementMatch})
    let noMeasurement = checkArray({vcMeasurementMatch})

    # The predicate the decision and the identity block share.
    check identityRestsOnUnauthenticatedManifest(noPin)
    check not identityRestsOnUnauthenticatedManifest(everything)
    check not identityRestsOnUnauthenticatedManifest(noPinNoMeasurement)
    check not identityRestsOnUnauthenticatedManifest(noMeasurement)

    # An unpinned manifest qualifies an acceptance only when an identity
    # was actually read out of one. Nothing pinned and nothing compared
    # is an acceptance that established no identity to qualify.
    check decisionFor(noPin, atTpm) == vdAcceptedUnpinnedManifest
    check decisionFor(noPinNoMeasurement, atTpm) == vdAccepted
    check decisionFor(noMeasurement, atTpm) == vdAccepted
    check decisionFor(everything, atTpm) == vdAccepted
    check decisionFor(everything, atCvm) == vdAccepted

    # Precedence, stated as an assertion rather than as a comment: on the
    # tier with no root of trust the missing root of trust is what the
    # decision says, whatever the policy pinned. Reordering the two
    # clauses would silently move a mock verdict from exit 3 to exit 4.
    check decisionFor(noPin, atMock) == vdAcceptedNoRootOfTrust
    check decisionFor(everything, atMock) == vdAcceptedNoRootOfTrust
    check ord(attestExitCodeFor(decisionFor(noPin, atMock))) == 3

    # A rejection is still a rejection whatever else is true of it.
    var rejecting: Verdict
    for chk in VerifierCheck:
      if chk == vcNativeEvidence:
        rejecting.record(chk, true, violated("fixture: refused"))
      elif chk == vcManifestPinned:
        rejecting.record(chk, false, inapplicable("fixture: not performed"))
      else:
        rejecting.record(chk, true, satisfied("fixture: satisfied"))
    check decisionFor(rejecting.checks, atTpm) == vdRejected
    check ord(attestExitCodeFor(decisionFor(rejecting.checks, atTpm))) == 1

  test "every decision has its own exit code, and no two share one":
    # Pinned as literals, and asserted to be the same values the named
    # constants carry — the constants alone would move with the code.
    check ord(attestExitCodeFor(vdAccepted)) == 0
    check ord(attestExitCodeFor(vdRejected)) == 1
    check ord(attestExitCodeFor(vdAcceptedNoRootOfTrust)) == 3
    check ord(attestExitCodeFor(vdAcceptedUnpinnedManifest)) == 4
    check ord(attestExitCodeFor(vdAccepted)) == AttestExitAccepted
    check ord(attestExitCodeFor(vdRejected)) == AttestExitRejected
    check ord(attestExitCodeFor(vdAcceptedNoRootOfTrust)) ==
      AttestExitAcceptedNoRootOfTrust
    check ord(attestExitCodeFor(vdAcceptedUnpinnedManifest)) ==
      AttestExitAcceptedUnauthenticatedManifest

    # Injective: a mapping that collapsed two decisions onto one code
    # would satisfy every "derived from the verdict" claim above and
    # still be unreadable by a script.
    var seen: seq[int] = @[]
    var decisions = 0
    for d in VerdictDecision:
      inc decisions
      let code = ord(attestExitCodeFor(d))
      check code notin seen
      seen.add code
    check decisions == seen.len
    check decisions >= 4

  # -- the command line adds no opinion of its own --------------------

  test "the CLI names no decision outside the one mapping function":
    # The two channels came apart once because the exit code was decided
    # at the point of exit rather than derived from the decision. A
    # second `case verdict.decision` anywhere in this module would let
    # them come apart again, so there may not be one: every mention of a
    # decision value in the CLI's source lives inside
    # `attestExitCodeFor`.
    let lines = strippedCliSource()
    var start = -1
    for i, line in lines:
      if line.startsWith("proc attestExitCodeFor*"):
        check start == -1        # …and there is only one of it
        start = i
    check start >= 0
    var stop = lines.len
    if start >= 0:
      for i in start + 1 ..< lines.len:
        let line = lines[i]
        if line.strip().len > 0 and not line.startsWith(" "):
          stop = i
          break

    var names: seq[string] = @[]
    for d in VerdictDecision: names.add $d
    # The identifiers, not the rendered strings. Their number is checked
    # against the enum's, so a decision value added without being listed
    # here reddens rather than being quietly unsearched for.
    let identifiers = ["vdAccepted", "vdRejected", "vdAcceptedNoRootOfTrust",
                       "vdAcceptedUnpinnedManifest"]
    check identifiers.len == names.len
    var outside: seq[string] = @[]
    if start >= 0:
      for i, line in lines:
        if i >= start and i < stop: continue
        for ident in identifiers:
          if ident in line: outside.add $i & ": " & line.strip()
    check outside.len == 0
    if outside.len > 0: echo "decision values outside the mapping: ", outside

    # A control: EVERY identifier really does occur inside the window,
    # so the emptiness above is not the emptiness of a search that
    # matches nothing — and a decision dropped from the mapping is
    # caught here rather than passing as "mentioned nowhere outside it".
    for ident in identifiers:
      var found = false
      if start >= 0:
        for i in start ..< stop:
          if ident in lines[i]: found = true
      check found
      if not found: echo "not mapped to an exit code: ", ident

  test "the command line really routes its exit code through that function":
    # Exit code 4 cannot be observed from a process in this build: an
    # acceptance on a tier that has a root of trust needs a reader for
    # that backend's evidence and there is none. What can be observed is
    # that a real invocation returns exactly what the mapping says for
    # the decision it printed — checked here on the mock path, where
    # both halves are reachable.
    let scratch = getTempDir() / "repro-attest-exit-codes-" &
      $getCurrentProcessId()
    createDir(scratch)
    defer: removeDir(scratch)
    let challengePath = scratch / "challenge.json"
    check runAttestCommand(@["challenge", "--out", challengePath]) == 0
    let minted = parseChallengeRecord(readFile(challengePath), challengePath)

    let policyPath = scratch / "policy.toml"
    writeFile(policyPath, MockDevPolicy)
    let manifestPath = scratch / "manifest.json"
    writeFile(manifestPath, sampleManifestText())
    let reportPath = scratch / "report.json"
    writeFile(reportPath, mockReportText(minted.challengeHex))
    let verdictPath = scratch / "verdict.txt"

    let code = runAttestCommand(@["verify",
      "--report-file", reportPath,
      "--policy", policyPath,
      "--manifest", manifestPath,
      "--challenge-file", challengePath,
      "--out", verdictPath])
    let printed = readFile(verdictPath)
    check "verdict: accepted-without-a-root-of-trust" in printed
    check code == ord(attestExitCodeFor(vdAcceptedNoRootOfTrust))
    check code == 3

    # And the refusals keep their code, which is what "an addition, not a
    # renumbering" has to mean for a caller already scripting on them.
    check runAttestCommand(@["verify", "--report-file", reportPath]) == 2
    check runAttestCommand(@["challenge", "--hex", "--out",
      scratch / "nonce.txt"]) == 0
