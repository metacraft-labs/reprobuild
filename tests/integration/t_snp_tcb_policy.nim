## A platform version below the verifier's floor is refused, a grace
## window accepts one inside it, and the window ends.
##
## ## The inputs are real, including the below-floor ones
##
## The two attestation reports this gate reads were produced by two
## different AMD EPYC parts, and both of them are genuinely below the
## floor the production policy document states. Nothing had to be
## fabricated to reach the refusal: the shipped policy requires
## bootloader 4, snp 22 and microcode 213, and the two machines report
## (3, 8, 115) and (2, 5, 68). Those are the versions those parts were
## running.
##
## The floor itself is not written here either. It is read out of the
## production policy DOCUMENT that every verdict gate in this tree
## shares — `attestation_verifier_harness`'s `ProductionPolicyTemplate`
## — through the real policy reader, so a case here is testing what that
## document says and not a number this file chose.
##
## Said precisely, because the stronger claim would be false: that
## document is a shared TEST FIXTURE and not configuration this
## repository installs. No attestation-policy document is shipped
## anywhere in the tree, so "what the shipped configuration does" is not
## something any gate can measure yet, and a case below pins the four
## numbers so that changing the shared fixture is a visible diff rather
## than a silent change to what every case here measures.
##
## ## How the window is measured
##
## The obvious way to check a window is to compute its end and compare
## the verdict's idea of the end with it — and that is a constant used on
## both sides of the check, which is worth nothing. So the window is
## measured by **observation**: the gate sweeps the clock day by day,
## records which days are accepted, and requires the accepted set to be
## exactly the first N+1 of them. Then it compares N with the number in
## the policy document, which is a different source.
##
## And it is measured twice more: the same sweep is run against two
## policy documents that differ only in that number, and the observed
## boundary moves with the document. A verifier that ignored the policy
## and used a built-in window would pass the first sweep and fail these.
##
## The edge is pinned at four adjacent instants — one second before the
## last accepted one, the last accepted one, one second after, and one
## second after that — rather than at the boundary alone. A single test
## at a boundary passes under both `<=` and `<`.
##
## ## The thing the window must NOT be anchored on
##
## A grace window's start is a fact about the verifier's own
## configuration. The evidence cannot be allowed to supply it, because a
## machine that could choose when its own excuse began would never run
## out of it. The tempting field is the endorsement certificate's
## not-before — it looks like the instant the vendor endorsed this part
## at this version, and the vendor issues those on demand for any version
## asked for. A case below pins that this rule ignores that field: the
## two parts' certificates are dated eighteen months apart and both are
## treated identically.
##
## ## Mocking
##
## None. Real reports, real policy documents through the real reader.

import std/[exitprocs, os, strutils, unittest]

import repro_attest_verify/snp_chain
import repro_attest_verify/snp_report
import repro_attest_verify/snp_tcb

include ./attestation_verifier_harness
include ./snp_vectors

var reachedTcbOutcomes: set[SnpTcbOutcome] = {}
var reachedBindingOutcomes: set[SnpBindingOutcome] = {}

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var f: File
  if open(f, path, fmAppend):
    for k in SnpTcbOutcome:
      if k in reachedTcbOutcomes: f.writeLine("snp_tcb:" & $k)
    for k in SnpBindingOutcome:
      if k in reachedBindingOutcomes: f.writeLine("snp_binding:" & $k)
    f.close()

addExitProc(writeCensus)

proc bytesOfHex(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc base64Decode(text: string): seq[byte] =
  const Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var acc = 0
  var bits = 0
  for c in text:
    if c == '=': break
    let idx = Alphabet.find(c)
    if idx < 0: continue
    acc = (acc shl 6) or idx
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xff)

proc pemCertificates(text: string): seq[seq[byte]] =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    result.add base64Decode(text[b + Begin.len ..< e])
    pos = e + End.len

const
  Now = 1_788_220_800'i64        ## 2026-09-01T00:00:00Z; see `snp_vectors`.
  FloorTookEffect = 1_780_000_000'i64
    ## The verifier's own instant, 2026-05-28T12:26:40Z. Chosen so the
    ## whole sweep below stays inside every certificate's validity
    ## window; nothing about it is read from any report.

let milanChain = pemCertificates(KdsMilanChainPem)
let milanAsk = milanChain[0]
let milanArk = milanChain[1]
let milanCrl = @[bytesOfHex(KdsMilanCrlDerHex)]

let production = parseAttestationPolicy(productionPolicyText(), "<prod>")

proc lowerFloorPolicyText(): string =
  ## The same shipped document with only the four numbers changed, so a
  ## report can also be shown to be ABOVE a floor. Still parsed by the
  ## real reader: a hand-built `SevSnpTcbMinimum` would be a value this
  ## gate invented rather than one a document can express.
  productionPolicyText().replace(
    "sev-snp.min_tcb = { bootloader = 4, tee = 0, snp = 22, microcode = 213 }",
    "sev-snp.min_tcb = { bootloader = 1, tee = 0, snp = 4, microcode = 60 }")

proc graceDaysPolicyText(days: int): string =
  productionPolicyText().replace(
    "allow_grace_days = 14", "allow_grace_days = " & $days)

let reports = @[
  ("virtee/sev Milan", parseSnpReport(bytesOfHex(VirteeMilanReportHex)),
   bytesOfHex(VirteeMilanVcekDerHex)),
  ("google/go-sev-guest Milan", parseSnpReport(bytesOfHex(GsgMilanReportHex)),
   bytesOfHex(GsgMilanVcekDerHex))]

proc note(v: SnpTcbVerdict) = reachedTcbOutcomes.incl v.outcome
proc note(v: SnpBindingVerdict) = reachedBindingOutcomes.incl v.outcome

proc acceptedOnDay(report: SnpReport; floor: SevSnpTcbMinimum;
                   days, day: int): bool =
  let v = evaluateSnpTcb(report.reportedTcb, floor, days, FloorTookEffect,
                         FloorTookEffect + int64(day) * int64(SecondsPerDay))
  note(v)
  v.isAcceptance

# ---------------------------------------------------------------------

proc driveSnpTwoRealPartsAreBelowTheShippedFloor() =
  ## The body of test
  ##   "t_snp_two_real_parts_are_below_the_shipped_floor"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Genuinely below, on three of the four components each. If the
  # fleet these came from is ever patched past the floor this case
  # goes red — which is the correct outcome, because the rest of the
  # gate would then be measuring nothing.
  check reports.len == 2
  for (label, report, _) in reports:
    checkpoint label
    let v = evaluateSnpTcb(report.reportedTcb,
                           production.tcb.sevSnpMinTcb,
                           0, 0'i64, Now)
    note(v)
    checkpoint v.detail
    check not v.isAcceptance
    check v.outcome == stoBelowFloorWithNoWindow
    check v.flagged
    check v.below.len == 3
    check "bootloader" in v.below.join(", ")
    check "snp" in v.below.join(", ")
    check "microcode" in v.below.join(", ")
    # tee is EQUAL to the floor, so it is not named. An
    # at-the-floor component must not read as below it.
    check report.reportedTcb.tee == production.tcb.sevSnpMinTcb.tee
    check "tee" notin v.below.join(", ")

proc driveSnpTheSameReportsAreAcceptedAgainstAFloorTheyMeet() =
  ## The body of test
  ##   "t_snp_the_same_reports_are_accepted_against_a_floor_they_meet"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The positive control for the comparison itself. Without it,
  # "below the floor" is consistent with a rule that refuses
  # everything.
  let lower = parseAttestationPolicy(lowerFloorPolicyText(), "<lower>")
  check lower.tcb.sevSnpMinTcb.bootloader == 1
  check lower.tcb.sevSnpMinTcb.snp == 4
  check lower.tcb.sevSnpMinTcb.microcode == 60
  for (label, report, _) in reports:
    checkpoint label
    let v = evaluateSnpTcb(report.reportedTcb, lower.tcb.sevSnpMinTcb,
                           0, 0'i64, Now)
    note(v)
    check v.isAcceptance
    check v.outcome == stoAtOrAboveFloor
    check not v.flagged
    check v.below.len == 0
    check v.graceEndsAt == 0

proc driveSnpEachComponentIsComparedOnItsOwn() =
  ## The body of test
  ##   "t_snp_each_component_is_compared_on_its_own"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # One component below at a time, so the comparison is shown to be
  # four comparisons and not one.
  let base = SevSnpTcbMinimum(bootloader: 1, tee: 0, snp: 4, microcode: 60)
  let (_, report, _) = reports[0]
  check report.reportedTcb.bootloader == 3
  check report.reportedTcb.tee == 0
  check report.reportedTcb.snp == 8
  check report.reportedTcb.microcode == 115
  var raised = 0
  for component in 0 .. 3:
    var floor = base
    case component
    of 0: floor.bootloader = 4
    of 1: floor.tee = 1
    of 2: floor.snp = 9
    else: floor.microcode = 116
    let v = evaluateSnpTcb(report.reportedTcb, floor, 0, 0'i64, Now)
    note(v)
    check not v.isAcceptance
    check v.below.len == 1
    inc raised
  check raised == 4

suite "the floor":

  test "t_snp_the_production_policy_document_states_the_floor_this_gate_uses":
    # Read out of the document, not written here — and pinned, so a
    # change to the shared production-policy fixture that would silently
    # change what every case below measures is red instead.
    check production.tcb.present
    check production.tcb.hasSevSnpMinTcb
    check production.tcb.sevSnpMinTcb.bootloader == 4
    check production.tcb.sevSnpMinTcb.tee == 0
    check production.tcb.sevSnpMinTcb.snp == 22
    check production.tcb.sevSnpMinTcb.microcode == 213
    check production.tcb.allowGraceDays == 14

  test "t_snp_two_real_parts_are_below_the_shipped_floor":
    driveSnpTwoRealPartsAreBelowTheShippedFloor()

  test "t_snp_the_same_reports_are_accepted_against_a_floor_they_meet":
    driveSnpTheSameReportsAreAcceptedAgainstAFloorTheyMeet()

  test "t_snp_each_component_is_compared_on_its_own":
    driveSnpEachComponentIsComparedOnItsOwn()

proc driveSnpAFlaggedReportIsAcceptedInsideTheWindow() =
  ## The body of test
  ##   "t_snp_a_flagged_report_is_accepted_inside_the_window"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let days = production.tcb.allowGraceDays
  for (label, report, _) in reports:
    checkpoint label
    let v = evaluateSnpTcb(report.reportedTcb,
                           production.tcb.sevSnpMinTcb, days,
                           FloorTookEffect,
                           FloorTookEffect + int64(SecondsPerDay))
    note(v)
    checkpoint v.detail
    check v.isAcceptance
    check v.outcome == stoBelowFloorWithinGrace
    # An acceptance, and still flagged. This is the one place the
    # verifier says yes to a platform its own policy calls too old,
    # and it has to stay visible.
    check v.flagged
    check v.below.len == 3
    check v.graceDays == days

proc driveSnpAFlaggedReportIsRefusedOutsideTheWindow() =
  ## The body of test
  ##   "t_snp_a_flagged_report_is_refused_outside_the_window"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let days = production.tcb.allowGraceDays
  for (label, report, _) in reports:
    checkpoint label
    let v = evaluateSnpTcb(report.reportedTcb,
                           production.tcb.sevSnpMinTcb, days,
                           FloorTookEffect,
                           FloorTookEffect + 30 * int64(SecondsPerDay))
    note(v)
    checkpoint v.detail
    check not v.isAcceptance
    check v.outcome == stoBelowFloorOutsideGrace
    check v.flagged

proc driveSnpTheWindowsLengthIsObservedNotComputed() =
  ## The body of test
  ##   "t_snp_the_windows_length_is_observed_not_computed"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Sweep the clock and read the boundary off the behaviour, then
  # compare it with the document. Two sources; nothing on both sides.
  let days = production.tcb.allowGraceDays
  let (_, report, _) = reports[0]
  var accepted: seq[int] = @[]
  for day in 0 .. 30:
    if acceptedOnDay(report, production.tcb.sevSnpMinTcb, days, day):
      accepted.add day
  check accepted.len == days + 1
  check accepted[0] == 0
  check accepted[^1] == days
  # Contiguous: the window is one interval, not a scatter.
  for i in 0 ..< accepted.len:
    check accepted[i] == i

proc driveSnpTheWindowMovesWhenTheDocumentMoves() =
  ## The body of test
  ##   "t_snp_the_window_moves_when_the_document_moves"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The strongest form of the claim: the boundary follows the policy
  # document. A verifier with a built-in window would pass the sweep
  # above and fail here.
  let (_, report, _) = reports[0]
  var observed: seq[int] = @[]
  for declared in [0, 1, 3, 14, 30]:
    let p = parseAttestationPolicy(graceDaysPolicyText(declared),
                                   "<grace-" & $declared & ">")
    check p.tcb.allowGraceDays == declared
    var last = -1
    for day in 0 .. 40:
      if acceptedOnDay(report, p.tcb.sevSnpMinTcb, p.tcb.allowGraceDays,
                       day):
        last = day
    observed.add last
  # Zero days is no window at all, so nothing is accepted and the
  # sweep never records a day.
  check observed == @[-1, 1, 3, 14, 30]

proc driveSnpTheEdgeIsPinnedAtFourAdjacentInstants() =
  ## The body of test
  ##   "t_snp_the_edge_is_pinned_at_four_adjacent_instants"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A single case at the boundary passes under both `<=` and `<`.
  let days = production.tcb.allowGraceDays
  let (_, report, _) = reports[0]
  let edge = FloorTookEffect + int64(days) * int64(SecondsPerDay)
  var outcomes: seq[SnpTcbOutcome] = @[]
  for at in [edge - 1, edge, edge + 1, edge + 2]:
    let v = evaluateSnpTcb(report.reportedTcb,
                           production.tcb.sevSnpMinTcb, days,
                           FloorTookEffect, at)
    note(v)
    check v.graceEndsAt == edge
    outcomes.add v.outcome
  check outcomes == @[stoBelowFloorWithinGrace, stoBelowFloorWithinGrace,
                      stoBelowFloorOutsideGrace, stoBelowFloorOutsideGrace]

proc driveSnpAWindowWithNoStartIsNotAWindow() =
  ## The body of test
  ##   "t_snp_a_window_with_no_start_is_not_a_window"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Fail-closed in both directions: a policy that allows days but
  # nothing says when they began grants nothing, and a start with no
  # days grants nothing either.
  let (_, report, _) = reports[0]
  for (days, startAt) in {14: 0'i64, 14: -1'i64, 0: FloorTookEffect,
                          -1: FloorTookEffect}:
    let v = evaluateSnpTcb(report.reportedTcb,
                           production.tcb.sevSnpMinTcb, days, startAt,
                           FloorTookEffect)
    note(v)
    check not v.isAcceptance
    check v.outcome == stoBelowFloorWithNoWindow
    check v.graceEndsAt == 0
  check MaxGraceDays == 365

proc driveSnpTheWindowIgnoresTheEndorsementCertificatesDate() =
  ## The body of test
  ##   "t_snp_the_window_ignores_the_endorsement_certificates_date"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The two parts' endorsement certificates are dated eighteen months
  # apart. If the window were anchored on that field the two would
  # disagree; they do not, because it is anchored on the verifier's
  # own instant.
  let a = evaluateAmdChain(bytesOfHex(VirteeMilanVcekDerHex), milanAsk,
                           milanArk, milanCrl, Now)
  let b = evaluateAmdChain(bytesOfHex(GsgMilanVcekDerHex), milanAsk,
                           milanArk, milanCrl, Now)
  check a.isAccepted and b.isAccepted
  check a.endorsedAt != b.endorsedAt
  check a.endorsedAt - b.endorsedAt > 180 * 86_400
  let days = production.tcb.allowGraceDays
  let edge = FloorTookEffect + int64(days) * int64(SecondsPerDay)
  for (label, report, _) in reports:
    checkpoint label
    let inside = evaluateSnpTcb(report.reportedTcb,
      production.tcb.sevSnpMinTcb, days, FloorTookEffect, edge)
    let outside = evaluateSnpTcb(report.reportedTcb,
      production.tcb.sevSnpMinTcb, days, FloorTookEffect, edge + 1)
    note(inside); note(outside)
    check inside.graceEndsAt == edge
    check outside.graceEndsAt == edge
    check inside.isAcceptance
    check not outside.isAcceptance

suite "the window":

  test "t_snp_a_flagged_report_is_accepted_inside_the_window":
    driveSnpAFlaggedReportIsAcceptedInsideTheWindow()

  test "t_snp_a_flagged_report_is_refused_outside_the_window":
    driveSnpAFlaggedReportIsRefusedOutsideTheWindow()

  test "t_snp_the_windows_length_is_observed_not_computed":
    driveSnpTheWindowsLengthIsObservedNotComputed()

  test "t_snp_the_window_moves_when_the_document_moves":
    driveSnpTheWindowMovesWhenTheDocumentMoves()

  test "t_snp_the_edge_is_pinned_at_four_adjacent_instants":
    driveSnpTheEdgeIsPinnedAtFourAdjacentInstants()

  test "t_snp_a_window_with_no_start_is_not_a_window":
    driveSnpAWindowWithNoStartIsNotAWindow()

  test "t_snp_the_window_ignores_the_endorsement_certificates_date":
    driveSnpTheWindowIgnoresTheEndorsementCertificatesDate()

proc driveSnpAReportIsBoundToItsOwnEndorsementCertificate() =
  ## The body of test
  ##   "t_snp_a_report_is_bound_to_its_own_endorsement_certificate"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  for (label, report, vcek) in reports:
    checkpoint label
    let chain = evaluateAmdChain(vcek, milanAsk, milanArk, milanCrl, Now)
    check chain.isAccepted
    let b = bindReportToEndorsement(report, chain)
    note(b)
    checkpoint b.detail
    check b.isBound
    check b.outcome == sboBound

proc driveSnpAReportIsNotBoundToAnotherPartsCertificate() =
  ## The body of test
  ##   "t_snp_a_report_is_not_bound_to_another_parts_certificate"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Crossed over. The identities differ, so this is the identity rule
  # and not the version rule — and the two parts happen to differ on
  # BOTH, so the case asserts which one fired.
  let (_, reportA, vcekA) = reports[0]
  let (_, reportB, vcekB) = reports[1]
  let chainA = evaluateAmdChain(vcekA, milanAsk, milanArk, milanCrl, Now)
  let chainB = evaluateAmdChain(vcekB, milanAsk, milanArk, milanCrl, Now)
  for (report, chain) in {reportA: chainB, reportB: chainA}:
    let b = bindReportToEndorsement(report, chain)
    note(b)
    checkpoint b.detail
    check not b.isBound
    check b.outcome == sboChipIdentityDisagrees
    check "two different parts" in b.detail

proc driveSnpAReportIsNotBoundToACertificateForAnotherVersion() =
  ## The body of test
  ##   "t_snp_a_report_is_not_bound_to_a_certificate_for_another_version"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Same part, different platform version. Built by taking the real
  # pairing and moving ONE component of the report's stated version,
  # so the identity still matches and only the version rule can fire.
  let (_, report, vcek) = reports[0]
  let chain = evaluateAmdChain(vcek, milanAsk, milanArk, milanCrl, Now)
  check chain.isAccepted
  var moved = report
  check moved.reportedTcb.snp == chain.endorsedTcb.snp
  moved.reportedTcb.snp = report.reportedTcb.snp + 1
  let b = bindReportToEndorsement(moved, chain)
  note(b)
  checkpoint b.detail
  check not b.isBound
  check b.outcome == sboPlatformVersionDisagrees
  check hexOfBytes(moved.chipId) == hexOfBytes(chain.hwId)
  check "is not evidence about another" in b.detail

suite "binding a report to the certificate that endorsed it":

  test "t_snp_a_report_is_bound_to_its_own_endorsement_certificate":
    driveSnpAReportIsBoundToItsOwnEndorsementCertificate()

  test "t_snp_a_report_is_not_bound_to_another_parts_certificate":
    driveSnpAReportIsNotBoundToAnotherPartsCertificate()

  test "t_snp_a_report_is_not_bound_to_a_certificate_for_another_version":
    driveSnpAReportIsNotBoundToACertificateForAnotherVersion()

# The cases above whose inputs build the TCB-outcome and binding-outcome census.
# The coverage case below drives every one of them itself: the suite
# runner executes each case in its own process (`--run suite::test`),
# so the census holds only what ran in THAT process, and a coverage
# case that read what earlier cases left behind would measure the
# execution mode rather than the code under test.
const TcbOutcomeDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("t_snp_two_real_parts_are_below_the_shipped_floor",
    driveSnpTwoRealPartsAreBelowTheShippedFloor),
  ("t_snp_the_same_reports_are_accepted_against_a_floor_they_meet",
    driveSnpTheSameReportsAreAcceptedAgainstAFloorTheyMeet),
  ("t_snp_each_component_is_compared_on_its_own",
    driveSnpEachComponentIsComparedOnItsOwn),
  ("t_snp_a_flagged_report_is_accepted_inside_the_window",
    driveSnpAFlaggedReportIsAcceptedInsideTheWindow),
  ("t_snp_a_flagged_report_is_refused_outside_the_window",
    driveSnpAFlaggedReportIsRefusedOutsideTheWindow),
  ("t_snp_the_windows_length_is_observed_not_computed",
    driveSnpTheWindowsLengthIsObservedNotComputed),
  ("t_snp_the_window_moves_when_the_document_moves",
    driveSnpTheWindowMovesWhenTheDocumentMoves),
  ("t_snp_the_edge_is_pinned_at_four_adjacent_instants",
    driveSnpTheEdgeIsPinnedAtFourAdjacentInstants),
  ("t_snp_a_window_with_no_start_is_not_a_window",
    driveSnpAWindowWithNoStartIsNotAWindow),
  ("t_snp_the_window_ignores_the_endorsement_certificates_date",
    driveSnpTheWindowIgnoresTheEndorsementCertificatesDate),
  ("t_snp_a_report_is_bound_to_its_own_endorsement_certificate",
    driveSnpAReportIsBoundToItsOwnEndorsementCertificate),
  ("t_snp_a_report_is_not_bound_to_another_parts_certificate",
    driveSnpAReportIsNotBoundToAnotherPartsCertificate),
  ("t_snp_a_report_is_not_bound_to_a_certificate_for_another_version",
    driveSnpAReportIsNotBoundToACertificateForAnotherVersion)]

suite "snp tcb outcome coverage":

  test "t_snp_every_tcb_outcome_and_binding_outcome_is_reached":
    # Drive every input the census is built from, HERE and from an
    # empty census, so the verdict is the same whether this case runs
    # alone (the runner gives each case its own process) or after
    # the cases above.
    reachedTcbOutcomes = {}
    reachedBindingOutcomes = {}
    for (name, drive) in TcbOutcomeDrivers:
      checkpoint("driving " & name)
      drive()
    var unreached: seq[string] = @[]
    for k in SnpTcbOutcome:
      if k notin reachedTcbOutcomes: unreached.add $k
    for k in SnpBindingOutcome:
      if k notin reachedBindingOutcomes: unreached.add $k
    if unreached.len > 0:
      checkpoint("never reached: " & unreached.join(", "))
    check unreached.len == 0
    check card(reachedTcbOutcomes) == 4
    check card(reachedBindingOutcomes) == 3
