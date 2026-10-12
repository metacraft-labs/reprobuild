## A rebuilder's key stops counting, and this is where that becomes
## true.
##
## ## What this closes
##
## The quorum verifier beside this gate was built with a roster that had
## no time in it. `QuorumSigner` was one field — a key — so there was no
## `notAfter`, no revocation, and the quorum path parses no certificate,
## which means `x509`'s validity and revocation machinery was never
## reached from it. "One signer's admission expired" had no meaning that
## could be written down, let alone tested, and the change that
## delivered the quorum recorded exactly that rather than skipping it.
##
## So the admission window is NEW and it is REQUIRED: `validateRoster`
## refuses an entry that states no end. That is the load-bearing half.
## An optional window with a zero default would be a key admitted
## forever by anybody who did not think about it, which is precisely how
## key lifetime is skipped in practice — not by a decision, by a
## default.
##
## ## The three ways a key stops counting, and the one way it does not
##
## `saNotYetAdmitted`, `saAdmissionEnded` and `saRevoked` each produce
## their own entry outcome, because a reader acts differently on each: a
## key from the future is a clock fault, a key past its window is a
## rotation somebody did not finish, and a revoked key is an incident.
##
## None of the three is a DEFECT — none rejects a bundle that reaches
## the threshold on other signers. This is the same complement the
## unadmitted-signer rule already had, for the same reason: if a lapsed
## signature denied a bundle, appending one to a published bundle would
## be a denial of service anybody could perform.
##
## ## What revocation here cannot do, asserted rather than hoped
##
## A quorum signature carries no signing time. So nothing distinguishes
## a signature made the day before a key was revoked from one made the
## day after, and revoking a key therefore withdraws every bundle it
## ever contributed to, honest ones included. That is the fail-closed
## reading and it is the only one the evidence supports — and it is
## carried out of the evaluation as a caveat rather than left for a
## reader to work out, with a case in BOTH directions so the caveat
## cannot become one that always rides.
##
## ## Rotation is overlap
##
## The successor's window opens before the predecessor's closes, so a
## bundle signed during the handover reaches the threshold under both.
## The gate walks a rotation instant by instant and requires the
## threshold to be reachable at every one of them — and then walks a
## handover that leaves a GAP and requires it to be unreachable at the
## seam, so "rotation works" is not a sentence that would hold however
## the windows were arranged.
##
## The boundary is measured rather than assumed, and it moved a claim
## this gate first made wrongly: the admission window is half-open —
## closed at its start, open at its end — so a successor opening at the
## exact instant the predecessor closes leaves NO gap. That is a real
## property and it is not one to plan a rotation inside, because it puts
## one second between the handover that works and the handover that does
## not. Both sides of that second have a case.
##
## ## Mocking
##
## None. Real ECDSA signatures over real statements, minted fresh.

import std/[options, sequtils, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_cli_support/attest as cli_attest

import ./software_root_test_pki
import ./edge_attestation_harness

include ./attestation_verifier_harness

const
  EvidencePolicyTemplate = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[measurements.evidence]
min_signatures = @K@
known_keys = [@KEYS@]
require_transparency_log = false

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

  Epoch = 1_000_000_000'i64     ## a round instant to build windows from
  Hour = 3_600'i64
  Day = 86_400'i64

proc evidencePolicy(k: int; names: openArray[string]): AttestationPolicy =
  var quoted: seq[string] = @[]
  for n in names: quoted.add "\"" & n & "\""
  parseAttestationPolicy(
    EvidencePolicyTemplate.replace("@K@", $k)
                          .replace("@KEYS@", quoted.join(", ")),
    "<evidence-policy>")

proc verdictAt(policy: AttestationPolicy; manifestText, bundleText: string;
               roster: seq[QuorumSigner]; nowSeconds: int64): Verdict =
  ## A full verdict through the production driver at a stated instant.
  ##
  ## The instant is the point of this gate, so it is a parameter here
  ## rather than the harness default. It reaches the quorum evaluation
  ## through `VerificationRequest.nowMs`, which is the same field the
  ## command line fills from its own clock — so what is exercised is the
  ## path an operator runs, not a second one built for the test.
  let text = tpm2ReportText()
  let report = parseAttestationReport(text, "<tpm report>")
  var req = verificationRequest(text, policy, some(manifestText))
  req.attestationsText = some(bundleText)
  req.attestationsSource = "<rotation attestations>"
  req.signerRoster = roster
  req.nowMs = nowSeconds * 1000
  req.challengeIssuedAtMs = some(nowSeconds * 1000)
  verifyWithReading(req, report,
    tpmReading(sampleExpectedPcr11(), report.reportData))

proc admit(key: TestKey; notBefore, notAfter: int64): QuorumSigner =
  admittedSigner(signerFor(key).key, notBefore, notAfter)

suite "a roster entry states how long it counts, and cannot decline to":

  let keyA = newTestKey()
  let keyB = newTestKey()

  test "an entry with no stated end is REFUSED, not admitted forever":
    # The whole reason the field is not optional. A roster that could
    # omit it would be a roster that omits it.
    var open = QuorumSigner(key: signerFor(keyA).key)
    check not open.admission.hasNotAfter
    expect RosterError: validateRoster([open])
    try:
      validateRoster([open])
    except RosterError as err:
      check "states no end to its admission" in err.msg
      check "admitted forever" in err.msg
    # The same key WITH a window is accepted, so the refusal is about
    # the missing end and not about the entry.
    validateRoster([admit(keyA, Epoch, Epoch + Day)])

  test "a window that is not a window is refused, in both degenerate forms":
    for (nb, na) in [(Epoch, Epoch), (Epoch + Day, Epoch)]:
      var s = admit(keyA, nb, na)
      checkpoint("from " & $nb & " until " & $na)
      expect RosterError: validateRoster([s])
    validateRoster([admit(keyA, Epoch, Epoch + 1)])

  test "a revocation with no reason, or before the admission began, is refused":
    let base = admit(keyA, Epoch, Epoch + Day)
    var silent = revoked(base, Epoch + Hour, "")
    expect RosterError: validateRoster([silent])
    try:
      validateRoster([silent])
    except RosterError as err:
      check "revoked with no reason" in err.msg
    var backdated = revoked(base, Epoch - Day, "lost the key")
    expect RosterError: validateRoster([backdated])
    try:
      validateRoster([backdated])
    except RosterError as err:
      check "before its admission began" in err.msg
    # And a well-formed revocation is accepted, so neither refusal is
    # refusing every revocation.
    validateRoster([revoked(base, Epoch + Hour, "lost the key")])

  test "the constructor is the only way to reach a valid entry by default":
    # `admittedSigner` states the end; a raw object literal does not.
    # Asserted so that a future caller reaching for the literal finds a
    # case saying why not.
    let made = admittedSigner(signerFor(keyB).key, Epoch, Epoch + Day)
    check made.admission.hasNotAfter
    check made.admission.notAfter == Epoch + Day
    check not made.admission.revoked
    check default(SignerAdmission).hasNotAfter == false

suite "classifyAdmission, at every edge":

  let window = SignerAdmission(notBefore: Epoch, hasNotAfter: true,
                               notAfter: Epoch + Day)

  test "the window is closed at the start and open at the end":
    check classifyAdmission(window, Epoch - 1) == saNotYetAdmitted
    check classifyAdmission(window, Epoch) == saAdmitted
    check classifyAdmission(window, Epoch + Day - 1) == saAdmitted
    check classifyAdmission(window, Epoch + Day) == saAdmissionEnded
    check classifyAdmission(window, Epoch + Day + 1) == saAdmissionEnded

  test "revocation takes effect at its instant and not before":
    var r = window
    r.revoked = true
    r.revokedAt = Epoch + Hour
    r.revocationReason = "the holder lost control of it"
    check classifyAdmission(r, Epoch + Hour - 1) == saAdmitted
    check classifyAdmission(r, Epoch + Hour) == saRevoked
    check classifyAdmission(r, Epoch + Day + 1) == saRevoked

  test "a revoked key inside its window reads as revoked, not as admitted":
    # The order of the tests, asserted. Testing the window first would
    # report a key whose holder lost control of it as merely admitted,
    # which is the fact a reader most needs and the one they would not
    # get.
    var r = window
    r.revoked = true
    r.revokedAt = Epoch + Hour
    r.revocationReason = "compromised"
    check classifyAdmission(r, Epoch + 2 * Hour) == saRevoked
    # And the complement: identical entry, no revocation, same instant.
    check classifyAdmission(window, Epoch + 2 * Hour) == saAdmitted

  test "every state maps to its own outcome, and the map is a bijection":
    var outcomes: seq[QuorumEntryOutcome] = @[]
    for state in AdmissionState: outcomes.add outcomeFor(state)
    check outcomes.len == 4
    check outcomes.deduplicate.len == 4
    check outcomeFor(saAdmitted) == qeoCounted
    check outcomeFor(saNotYetAdmitted) == qeoSignerNotYetAdmitted
    check outcomeFor(saAdmissionEnded) == qeoSignerAdmissionEnded
    check outcomeFor(saRevoked) == qeoSignerRevoked

suite "a lapsed or revoked signer contributes nothing, and denies nothing":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<rotation manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let keyC = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB), signerName(keyC)]

  proc evaluate(roster: seq[QuorumSigner]; entries: seq[EdgeAttestation];
                at: int64): QuorumEvaluation =
    let bundleText = bundleOf(claim, entries)
    evaluateQuorum(parseEdgeAttestationBundle(bundleText, "<bundle>"),
                   claim, roster, at)

  test "a signature by a key whose admission has ENDED is not counted":
    let roster = @[admit(keyA, Epoch, Epoch + Day),
                   admit(keyB, Epoch, Epoch + Day),
                   admit(keyC, Epoch, Epoch + 10 * Day)]
    let entries = @[quorumEntry(keyA, statement),
                    quorumEntry(keyC, statement)]
    # Inside every window: two counted.
    let early = evaluate(roster, entries, Epoch + Hour)
    check early.countedSigners.len == 2
    check early.defects.len == 0
    # After A's window closes: one counted, and NOT a defect.
    let late = evaluate(roster, entries, Epoch + 2 * Day)
    check late.countedSigners == @[signerName(keyC)]
    check late.entries[0].outcome == qeoSignerAdmissionEnded
    check late.defects.len == 0
    check "stopped being admitted at" in late.entries[0].detail
    check signerName(keyA) in late.entries[0].detail

  test "a signature by a key not yet admitted is not counted either":
    let roster = @[admit(keyA, Epoch + 5 * Day, Epoch + 10 * Day),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let ev = evaluate(roster, @[quorumEntry(keyA, statement),
                                quorumEntry(keyB, statement)], Epoch + Hour)
    check ev.countedSigners == @[signerName(keyB)]
    check ev.entries[0].outcome == qeoSignerNotYetAdmitted
    check ev.defects.len == 0
    check "is admitted from" in ev.entries[0].detail

  test "a REVOKED signer is not counted, and the reason travels":
    let roster = @[revoked(admit(keyA, Epoch, Epoch + 10 * Day),
                           Epoch + Day, "the holder reported it stolen"),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let before = evaluate(roster, @[quorumEntry(keyA, statement),
                                    quorumEntry(keyB, statement)],
                          Epoch + Hour)
    check before.countedSigners.len == 2
    let after = evaluate(roster, @[quorumEntry(keyA, statement),
                                   quorumEntry(keyB, statement)],
                         Epoch + 2 * Day)
    check after.countedSigners == @[signerName(keyB)]
    check after.entries[0].outcome == qeoSignerRevoked
    check after.defects.len == 0
    check "the holder reported it stolen" in after.entries[0].detail

  test "none of the three is a defect: a bundle that reaches K still passes":
    # The complement, and it is load-bearing. If a lapsed signature
    # denied a bundle, anyone could deny a published bundle by appending
    # one.
    let policy = evidencePolicy(2, admitted)
    let roster = @[admit(keyA, Epoch, Epoch + Day),
                   admit(keyB, Epoch, Epoch + 10 * Day),
                   admit(keyC, Epoch, Epoch + 10 * Day)]
    let bundleText = bundleOf(claim, @[quorumEntry(keyA, statement),
                                       quorumEntry(keyB, statement),
                                       quorumEntry(keyC, statement)])
    let v = verdictAt(policy, manifestText, bundleText, roster,
                      Epoch + 2 * Day)
    check v.checks[vcEvidenceQuorum].outcome == coPassed
    check v.decision == vdAcceptedEvidenceBackedManifest
    check ord(cli_attest.attestExitCodeFor(v.decision)) == 5

  test "and a bundle that reaches K only through a lapsed signer does NOT":
    # The same fixture one signer short. Without this the case above
    # would hold whether or not the lapsed signature was counted.
    let policy = evidencePolicy(2, admitted)
    let roster = @[admit(keyA, Epoch, Epoch + Day),
                   admit(keyB, Epoch, Epoch + 10 * Day),
                   admit(keyC, Epoch, Epoch + 10 * Day)]
    let bundleText = bundleOf(claim, @[quorumEntry(keyA, statement),
                                       quorumEntry(keyB, statement)])
    let inside = verdictAt(policy, manifestText, bundleText, roster,
                           Epoch + Hour)
    check inside.checks[vcEvidenceQuorum].outcome == coPassed
    let outside = verdictAt(policy, manifestText, bundleText, roster,
                            Epoch + 2 * Day)
    check outside.checks[vcEvidenceQuorum].outcome == coFailed
    check outside.decision == vdRejected
    check "1 valid signature(s)" in outside.checks[vcEvidenceQuorum].detail

  test "the only thing that changed between those two verdicts is the clock":
    # Asserted so the pair above cannot be passing for some other
    # difference: same policy, same roster, same bundle bytes.
    let policy = evidencePolicy(2, admitted)
    let roster = @[admit(keyA, Epoch, Epoch + Day),
                   admit(keyB, Epoch, Epoch + 10 * Day),
                   admit(keyC, Epoch, Epoch + 10 * Day)]
    let bundleText = bundleOf(claim, @[quorumEntry(keyA, statement),
                                       quorumEntry(keyB, statement)])
    let a = verdictAt(policy, manifestText, bundleText, roster, Epoch + Hour)
    let b = verdictAt(policy, manifestText, bundleText, roster,
                      Epoch + 2 * Day)
    check a.decision != b.decision
    check bundleText == bundleOf(claim, @[quorumEntry(keyA, statement),
                                          quorumEntry(keyB, statement)])

suite "the caveat a revocation carries, in both directions":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<rotation manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()
  let keyB = newTestKey()
  let admitted = [signerName(keyA), signerName(keyB)]
  let policy = evidencePolicy(2, admitted)
  let bundleText = bundleOf(claim, @[quorumEntry(keyA, statement),
                                     quorumEntry(keyB, statement)])

  test "a verdict reached with a revocation in force says what that means":
    let roster = @[revoked(admit(keyA, Epoch, Epoch + 10 * Day),
                           Epoch + Day, "compromised"),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let v = verdictAt(policy, manifestText, bundleText, roster,
                      Epoch + 2 * Day)
    check RevocationHasNoSigningTimeCaveat in v.caveats
    check "carries no signing time" in RevocationHasNoSigningTimeCaveat

  test "a verdict with NO revocation in force does not carry it":
    # Without this the caveat would be one that always rides, which
    # tells a reader nothing at all.
    let roster = @[admit(keyA, Epoch, Epoch + 10 * Day),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let v = verdictAt(policy, manifestText, bundleText, roster,
                      Epoch + 2 * Day)
    check RevocationHasNoSigningTimeCaveat notin v.caveats
    check v.checks[vcEvidenceQuorum].outcome == coPassed

  test "a revocation whose instant has not arrived carries no caveat yet":
    # The caveat tracks a revocation IN FORCE, not a field being set.
    let roster = @[revoked(admit(keyA, Epoch, Epoch + 10 * Day),
                           Epoch + 5 * Day, "will be retired"),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let v = verdictAt(policy, manifestText, bundleText, roster, Epoch + Day)
    check RevocationHasNoSigningTimeCaveat notin v.caveats
    check v.checks[vcEvidenceQuorum].outcome == coPassed

  test "it is carried on a REJECTION too, not only on an acceptance":
    # A reader of a rejection needs it more, not less: they are about to
    # ask why the bundle came up short.
    let roster = @[revoked(admit(keyA, Epoch, Epoch + 10 * Day),
                           Epoch + Day, "compromised"),
                   admit(keyB, Epoch, Epoch + 10 * Day)]
    let short = bundleOf(claim, @[quorumEntry(keyA, statement)])
    let v = verdictAt(policy, manifestText, short, roster, Epoch + 2 * Day)
    check v.decision == vdRejected
    check RevocationHasNoSigningTimeCaveat in v.caveats

suite "rotation is overlap, and a handover without it has a gap":

  let manifestText = sampleManifestText()
  let claim = claimForManifest(manifestText, "<rotation manifest>")
  let statement = edgeStatementBytes(claim)
  let keyA = newTestKey()          ## the key being rotated OUT
  let keyB = newTestKey()          ## the steady second signer
  let keyC = newTestKey()          ## the successor
  let admitted = [signerName(keyA), signerName(keyB), signerName(keyC)]

  # A signs until the handover; C signs from a little before it. Both
  # signatures exist in the published bundle, which is the realistic
  # shape: a rebuilder does not know which verifier will read it when.
  let bundleText = bundleOf(claim, @[quorumEntry(keyA, statement),
                                     quorumEntry(keyB, statement),
                                     quorumEntry(keyC, statement)])
  let handover = Epoch + 10 * Day

  proc rosterWithOverlap(overlap: int64): seq[QuorumSigner] =
    @[admit(keyA, Epoch, handover),
      admit(keyB, Epoch, Epoch + 100 * Day),
      admit(keyC, handover - overlap, Epoch + 100 * Day)]

  test "with overlap the threshold is reachable at EVERY instant across it":
    let roster = rosterWithOverlap(2 * Day)
    let policy = evidencePolicy(2, admitted)
    var instants = 0
    for at in [Epoch + Day, handover - 3 * Day, handover - 2 * Day,
               handover - Day, handover - 1, handover, handover + Day,
               handover + 10 * Day]:
      checkpoint("at " & $at)
      let v = verdictAt(policy, manifestText, bundleText, roster, at)
      check v.checks[vcEvidenceQuorum].outcome == coPassed
      check v.decision == vdAcceptedEvidenceBackedManifest
      inc instants
    check instants == 8

  test "the rotation really happens: who is counted changes across it":
    # Otherwise the case above would hold for a roster in which nothing
    # rotated at all.
    let roster = rosterWithOverlap(2 * Day)
    let bundle = parseEdgeAttestationBundle(bundleText, "<bundle>")
    let before = evaluateQuorum(bundle, claim, roster, Epoch + Day)
    let after = evaluateQuorum(bundle, claim, roster, handover + Day)
    check signerName(keyA) in before.countedSigners
    check signerName(keyC) notin before.countedSigners
    check signerName(keyA) notin after.countedSigners
    check signerName(keyC) in after.countedSigners
    check before.countedSigners.len == 2
    check after.countedSigners.len == 2

  test "with a GAP there is an instant where the threshold is not reachable":
    # The negative that makes "rotation works" mean something. The
    # successor opens a day after the predecessor closes, so across that
    # day only the steady signer counts.
    let roster = @[admit(keyA, Epoch, handover),
                   admit(keyB, Epoch, Epoch + 100 * Day),
                   admit(keyC, handover + Day, Epoch + 100 * Day)]
    let policy = evidencePolicy(2, admitted)
    let atSeam = verdictAt(policy, manifestText, bundleText, roster,
                           handover + Hour)
    check atSeam.checks[vcEvidenceQuorum].outcome == coFailed
    check atSeam.decision == vdRejected
    check "1 valid signature(s)" in atSeam.checks[vcEvidenceQuorum].detail
    # And either side of the gap is fine, so the failure is the gap.
    check verdictAt(policy, manifestText, bundleText, roster,
                    handover - Hour).checks[vcEvidenceQuorum].outcome ==
      coPassed
    check verdictAt(policy, manifestText, bundleText, roster,
                    handover + 2 * Day).checks[vcEvidenceQuorum].outcome ==
      coPassed

  test "the windows tile at zero overlap, and one second of GAP breaks it":
    # The boundary, from both sides. Zero overlap is SAFE, because the
    # window is closed at its start and open at its end, so the
    # successor picks up in the same second the predecessor lets go.
    # That is worth knowing and worth not relying on: it leaves exactly
    # one second between a handover that works and one that does not,
    # and an operator who plans a rotation to the second has already
    # made the mistake this overlap exists to prevent.
    let policy = evidencePolicy(2, admitted)
    check verdictAt(policy, manifestText, bundleText,
                    rosterWithOverlap(0), handover
                   ).checks[vcEvidenceQuorum].outcome == coPassed
    check verdictAt(policy, manifestText, bundleText,
                    rosterWithOverlap(-1), handover
                   ).checks[vcEvidenceQuorum].outcome == coFailed
    # And the gap is exactly one second wide: the predecessor covers the
    # instant before it and the successor covers the instant after, so
    # the failure is the seam and not the whole handover. Both sides are
    # asserted, because a "gap" that swallowed the neighbouring seconds
    # would be a different defect passing the same case.
    check verdictAt(policy, manifestText, bundleText,
                    rosterWithOverlap(-1), handover - 1
                   ).checks[vcEvidenceQuorum].outcome == coPassed
    check verdictAt(policy, manifestText, bundleText,
                    rosterWithOverlap(-1), handover + 1
                   ).checks[vcEvidenceQuorum].outcome == coPassed
