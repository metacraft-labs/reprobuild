## One character of kernel command line, and the disk does not open.
##
## ## The claim, which is TWO claims
##
## A machine booted an image differing from the one its state was sealed
## for by ONE CHARACTER of kernel command line. Two things had to happen,
## and they are asserted separately because they are separate:
##
##   1. **The TPM refused to release the key.** Both sealed objects,
##      `TPM_RC_POLICY_FAIL`.
##   2. **The state volumes stayed locked.** No device-mapper entry,
##      both volumes inactive, and the plaintext marker unreadable.
##
## **A refusal without the second is a real vulnerability, not a partial
## success.** A machine whose verifier says "no" and whose disk opens
## anyway is worse than one with no verifier at all: it has the
## appearance of enforcement and none of the substance, and every
## operator who reads the refusal will believe the data was protected.
##
## ## Why the two checks cannot stand in for one another
##
## This is not argued, and it is not established by reading the source.
## It is established by a REAL BOOT in which the two answers differ.
##
## `UnlockedDespiteRefusalTamperReport` is a second full run of the same
## harness with a recovery key slot enrolled and a fallback to it when
## the TPM refuses. The SAME tampered image — the digests are identical
## and both are pinned — produced the SAME refusal, `0x99D`, and then
## opened both volumes and read the marker in plaintext. Fed to the two
## predicates:
##
## | report | refused? | locked? |
## |---|---|---|
## | the tampered boot | TRUE | TRUE |
## | the fallback boot | TRUE | **FALSE** |
## | the ordinary reboot | FALSE | FALSE |
##
## Rows one and two share a refusal and disagree about the lock, so the
## lock check is not a function of the refusal check. Rows two and three
## share a lock state and disagree about the refusal, so the refusal
## check is not a function of the lock check. Neither is constant.
##
## ## The third way in, which no policy digest would reveal
##
## A sealed object whose `userWithAuth` attribute is set opens with an
## empty password and no policy session at all — the policy is perfect
## and the object is readable by anyone holding the blob. That path is
## probed on every cycle and refused with `TPM_RC_AUTH_UNAVAILABLE`, and
## the attribute is checked in the object's own public area.
##
## ## What this gate does NOT prove
##
## The tampering is a BUILD INPUT rather than a modification of an image
## on disk after the fact; without a signing key to forge, that is the
## strongest form available. The TPM is software. Nothing here says the
## register readings were attested — no quote is taken anywhere in this
## experiment — only that the firmware's own event log replays to them.
##
## ## Mocking
##
## None. Both the tampered boot and the fallback boot are real; see
## `sealed_state_vectors`.

import std/[strutils, unittest]

import repro_attest

include ./sealed_state_evidence

proc replayedPcr11(logHex: string): string =
  let log = parseEventLog(unhexBytes(logHex))
  hexOf(pcrValue(replayBank(log, TpmAlgSha256), 11))

proc templateSections(tmpl: string): seq[string] =
  result = @[]
  let parts = tmpl.split(';')
  for i in 2 ..< parts.len: result.add parts[i]

suite "a tampered image is refused, and the state stays shut":

  test "t_tampered_uki_fails_unseal":
    let tampered = parseCycleReport(SealedStateTamperReport)
    check tampered.phase == "tamper"

    # ---- the machine really booted the altered image -----------------
    check tampered.field("cmdline") == SealedStateTamperedCmdline
    check tampered.pcr11 == SealedStateTamperedPredictedPcr11
    check replayEventLogTemplate(SealedStateTamperedTemplate) ==
      SealedStateTamperedPredictedPcr11
    check replayedPcr11(SealedStateTamperEventLogHex) ==
      SealedStateTamperedPredictedPcr11

    # ---- CLAIM ONE: the TPM refused, and for the right reason --------
    check sealedObjectRefused(tampered, "a")
    check sealedObjectRefused(tampered, "b")
    check tampered.field("unseal_a_tpm_rc") == PolicyFailureCode
    check tampered.field("unseal_b_tpm_rc") == PolicyFailureCode

    # ---- CLAIM TWO: the volumes stayed shut --------------------------
    # Read from fields the refusal check never touches.
    check stateVolumesLocked(tampered)
    check tampered.field("mapper_entries") == ""
    for v in StateVolumes:
      check tampered.field("status_" & $v) == "inactive"
      check tampered.marker(v) == "-"
      # The attempt REACHED the key slots and was turned away there: the
      # volume is a real LUKS2 volume that refused a wrong key, not a
      # step this experiment skipped.
      check carriesLuksSignature(tampered, v)
    check tampered.field("open_key_source") == "zero-filled"
    check tampered.intField("open_var_rc") != 0
    check tampered.intField("open_home_rc") != 0

    # ---- the third way in, refused too -------------------------------
    check authValueWasRefused(tampered, "a")
    check authValueWasRefused(tampered, "b")
    let objA = parseSealedObjectPublic(unhexBytes(SealedStateSealAPublicHex))
    let objB = parseSealedObjectPublic(unhexBytes(SealedStateSealBPublicHex))
    check policyIsTheOnlyAuthorisation(objA)
    check policyIsTheOnlyAuthorisation(objB)

    # ---- why it was refused, computed from the image bytes -----------
    # The policy this boot could satisfy is neither object's.
    let reachable = hexOf(launchPolicyDigest(
      SealedStateTamperedPredictedPcr11))
    check reachable != hexOf(objA.authPolicy)
    check reachable != hexOf(objB.authPolicy)
    # The calculator saying so is a calculator that is RIGHT about the
    # two generations that DID open: it reproduces both objects' own
    # policies. Without this anchor the two inequalities above would be
    # satisfied by ANY function of the register — including one that
    # ignored the register — and every way of breaking the policy
    # computation would leave this gate green. That is not a
    # hypothetical; it is what the first mutation pass measured.
    check hexOf(launchPolicyDigest(SealedStateAPredictedPcr11)) ==
      hexOf(objA.authPolicy)
    check hexOf(launchPolicyDigest(SealedStateBPredictedPcr11)) ==
      hexOf(objB.authPolicy)

  test "t_tampered_uki_fails_unseal_refusal_does_not_imply_locked":
    ## THE CONTROL, and the reason this gate exists in the shape it does.
    ##
    ## A real boot of the SAME tampered image, refused by the TPM with
    ## the SAME code, whose volumes opened anyway. The refusal check must
    ## still say TRUE on it; the locked check must say FALSE.
    let unlocked = parseCycleReport(UnlockedDespiteRefusalTamperReport)
    check unlocked.phase == "tamper"
    check UnlockedDespiteRefusalTamperedUkiSha256 ==
      SealedStateTamperedUkiSha256
    check unlocked.field("cmdline") == SealedStateTamperedCmdline
    check unlocked.pcr11 == SealedStateTamperedPredictedPcr11

    # Same refusal.
    check sealedObjectRefused(unlocked, "a")
    check unlocked.field("unseal_a_tpm_rc") == PolicyFailureCode

    # Different outcome. THIS is the vulnerability.
    check not stateVolumesLocked(unlocked)
    check stateVolumesOpen(unlocked)
    check unlocked.field("open_key_source") == "recovery"
    check unlocked.intField("open_var_rc") == 0
    check unlocked.intField("open_home_rc") == 0
    for v in StateVolumes:
      check unlocked.marker(v).len == 64
      check unlocked.marker(v) != "-"

    # A FAILURE THAT IS NOT A POLICY FAILURE IS NOT A CAUGHT TAMPER.
    # The control machine never had a second sealed object, so its slot
    # `b` failed for a reason that says nothing about measurement, and
    # both predicates must decline to call it one. Without these two the
    # status codes would be decoration: dropping them from either
    # predicate changed no answer anywhere, which the first mutation
    # pass measured rather than guessed.
    check unlocked.intField("unseal_b_rc") != 0
    check unlocked.field("unseal_b_tpm_rc") == "absent"
    check not sealedObjectRefused(unlocked, "b")
    check unlocked.intField("unseal_b_noauth_rc") != 0
    check unlocked.field("unseal_b_noauth_tpm_rc") == "absent"
    check not authValueWasRefused(unlocked, "b")
    # AND IT WAS NOT RELEASED EITHER. "Released" is not the negation of
    # "refused" — a failure for some other reason is NEITHER — and this
    # slot is the only input in the whole evidence that can tell the two
    # definitions apart. Without this line, defining `sealedObjectReleased`
    # as `not sealedObjectRefused` changes no answer on any gate, which
    # a later mutation pass measured rather than supposed.
    check not sealedObjectReleased(unlocked, "b")

    # And the honest tampered boot disagrees with it on exactly the
    # second question and on no other.
    let tampered = parseCycleReport(SealedStateTamperReport)
    check sealedObjectRefused(tampered, "a") == sealedObjectRefused(unlocked, "a")
    check stateVolumesLocked(tampered) != stateVolumesLocked(unlocked)

  test "t_tampered_uki_fails_unseal_neither_check_is_constant":
    ## Each predicate is exercised in both directions by real boots, so
    ## neither is a function that returns the answer this gate wants.
    let tampered = parseCycleReport(SealedStateTamperReport)
    let unlocked = parseCycleReport(UnlockedDespiteRefusalTamperReport)
    let reboot = parseCycleReport(SealedStateRebootReport)

    # The refusal check: TRUE on two boots, FALSE on one.
    check sealedObjectRefused(tampered, "a")
    check sealedObjectRefused(unlocked, "a")
    check not sealedObjectRefused(reboot, "a")
    check sealedObjectReleased(reboot, "a")

    # The lock check: TRUE on one boot, FALSE on two.
    check stateVolumesLocked(tampered)
    check not stateVolumesLocked(unlocked)
    check not stateVolumesLocked(reboot)

    # The pair separates the fallback boot from the ordinary one by the
    # refusal, and from the honest tampered one by the lock. It is those
    # two disagreements together that make the two checks independent.
    check sealedObjectRefused(unlocked, "a") != sealedObjectRefused(reboot, "a")
    check stateVolumesLocked(unlocked) != stateVolumesLocked(tampered)

  test "t_tampered_uki_fails_unseal_each_reading_can_say_no_on_its_own":
    ## "The volumes stayed locked" rests on THREE readings, and each has
    ## to be able to answer on its own or it is decoration. On a machine
    ## that behaves, the three move together — every real report here has
    ## them agreeing — so no captured boot can tell them apart, and the
    ## first mutation pass measured exactly that: deleting the
    ## device-mapper reading or the marker reading changed no answer
    ## anywhere.
    ##
    ## The records below are therefore CONSTRUCTED, edited field by field
    ## out of the real tampered boot's record, and they are labelled as
    ## such rather than dressed up as captures. They are not claims about
    ## a machine. They are the inputs that make each clause a clause:
    ## a machine whose bookkeeping says shut while its plaintext is
    ## readable is the failure the marker reading exists for, and it is
    ## not a failure any correct machine will ever demonstrate.
    let real = SealedStateTamperReport
    check stateVolumesLocked(parseCycleReport(real))

    # The mapping is gone and the plaintext is unreadable — but a
    # device-mapper entry is still there.
    let mapperLeft = real.replace("mapper_entries=",
                                  "mapper_entries=reproos-state-var,")
    check mapperLeft != real
    check not stateVolumesLocked(parseCycleReport(mapperLeft))

    # No mapping, nothing in the table — and cryptsetup says active.
    let statusActive = real.replace("status_var=inactive", "status_var=active")
    check statusActive != real
    check not stateVolumesLocked(parseCycleReport(statusActive))

    # Everything says shut, and the plaintext reads back anyway.
    let markerReadable = real.replace(
      "marker_var=-", "marker_var=" & SealedStateAPredictedPcr11)
    check markerReadable != real
    check not stateVolumesLocked(parseCycleReport(markerReadable))

    # Each edit moved exactly one reading: the other two still say shut,
    # so the refusals above are each attributable to the clause named.
    for edited in [mapperLeft, statusActive, markerReadable]:
      let r = parseCycleReport(edited)
      check r.field("status_home") == "inactive"
      check r.marker(vnHome) == "-"

    # THE OTHER VOLUME HAS TO BE ABLE TO MOVE THE ANSWER ON ITS OWN.
    # Every edit above is on `var`, and every real report has the two
    # volumes agreeing, so nothing here distinguished "both volumes" from
    # "the first volume twice" — a later mutation pass measured that
    # replacing the volume list with `[vnVar, vnVar]` changed no answer
    # on any gate. A machine
    # that shut one volume and left the other open is the whole reason the
    # predicate takes both.
    let homeActive = real.replace("status_home=inactive", "status_home=active")
    check homeActive != real
    check not stateVolumesLocked(parseCycleReport(homeActive))
    check parseCycleReport(homeActive).field("status_var") == "inactive"
    let homeReadable = real.replace(
      "marker_home=-", "marker_home=" & SealedStateBPredictedPcr11)
    check homeReadable != real
    check not stateVolumesLocked(parseCycleReport(homeReadable))
    check parseCycleReport(homeReadable).marker(vnVar) == "-"

    # And the mirror of it for the OPEN predicate, which needs all three
    # of its clauses given an input for the same reason the locked one
    # did. On a machine that behaves, an open volume answers "yes" three
    # times, so only a constructed record can move one of them.
    let reboot = parseCycleReport(SealedStateRebootReport)
    check stateVolumesOpen(reboot)
    let markerGone = SealedStateRebootReport.replace(
      "marker_var=" & reboot.marker(vnVar), "marker_var=-")
    check markerGone != SealedStateRebootReport
    check not stateVolumesOpen(parseCycleReport(markerGone))
    # Nothing in `/dev/mapper`, and the rest still claiming the volumes
    # are up: that is not an open volume, it is a record contradicting
    # itself, and the predicate must not say yes to it.
    let mapperGone = SealedStateRebootReport.replace(
      "mapper_entries=" & reboot.field("mapper_entries"), "mapper_entries=")
    check mapperGone != SealedStateRebootReport
    check not stateVolumesOpen(parseCycleReport(mapperGone))
    # And `cryptsetup` itself saying the mapping is not active.
    let statusInactive = SealedStateRebootReport.replace(
      "status_var=active", "status_var=inactive")
    check statusInactive != SealedStateRebootReport
    check not stateVolumesOpen(parseCycleReport(statusInactive))

    # THE LUKS SIGNATURE READING, which every real report satisfies and
    # which therefore never said no to anything. A block device that
    # carries no LUKS2 header is not a state volume that stayed locked —
    # it is a different disk, or a wiped one, and reading "locked" off it
    # would be reading a property of the wrong object.
    check carriesLuksSignature(parseCycleReport(real), vnVar)
    let notLuks = real.replace("raw_magic_var=" & LuksSignatureHex,
                               "raw_magic_var=000000000000")
    check notLuks != real
    check not carriesLuksSignature(parseCycleReport(notLuks), vnVar)
    check carriesLuksSignature(parseCycleReport(notLuks), vnHome)

  test "t_tampered_uki_fails_unseal_moves_one_section":
    ## The tamper is one section, measured from the templates. Without
    ## this, a rebuild that also moved the initrd would make "the command
    ## line moved the measurement" untestable.
    let honest = templateSections(SealedStateATemplate)
    let bad = templateSections(SealedStateTamperedTemplate)
    check honest.len == 6
    check bad.len == 6
    var differing: seq[string] = @[]
    for i in 0 ..< honest.len:
      check honest[i].split('=')[0] == bad[i].split('=')[0]
      if honest[i] != bad[i]: differing.add honest[i].split('=')[0]
    check differing == @[".cmdline"]
    check SealedStateACmdline.len == SealedStateTamperedCmdline.len
    var diffChars = 0
    for i in 0 ..< SealedStateACmdline.len:
      if SealedStateACmdline[i] != SealedStateTamperedCmdline[i]:
        inc diffChars
    check diffChars == 1
    check SealedStateAUkiSha256 != SealedStateTamperedUkiSha256

  test "t_tampered_uki_fails_unseal_reads_a_report_that_says_so":
    ## A record that does not carry a field cannot answer a question
    ## about it. Both predicates refuse rather than defaulting, because a
    ## default would make the emptiest evidence the most reassuring.
    proc refusalFor(text: string; body: proc(r: CycleReport)): string =
      try:
        body(parseCycleReport(text))
        ""
      except CatchableError as e:
        e.msg

    # A record with the volume fields stripped cannot be called locked.
    var trimmed: seq[string] = @[]
    for line in SealedStateTamperReport.splitLines:
      if not line.startsWith("status_") and not line.startsWith("marker_"):
        trimmed.add line
    check "no field `status_var`" in
      refusalFor(trimmed.join("\n"), proc(r: CycleReport) =
        discard stateVolumesLocked(r))

    # A record with the unseal fields stripped cannot be called refused.
    var noUnseal: seq[string] = @[]
    for line in SealedStateTamperReport.splitLines:
      if not line.startsWith("unseal_"): noUnseal.add line
    check "no field `unseal_a_rc`" in
      refusalFor(noUnseal.join("\n"), proc(r: CycleReport) =
        discard sealedObjectRefused(r, "a"))

    # A record the guest never finished writing is not a record.
    var truncated: seq[string] = @[]
    for line in SealedStateTamperReport.splitLines:
      if not line.startsWith("end="): truncated.add line
    check "is a PREFIX of a cycle" in
      refusalFor(truncated.join("\n"), proc(r: CycleReport) = discard)

    # A line that carries no key.
    check "carries no key" in
      refusalFor(SealedStateTamperReport & "\nthis is not a field\n",
                 proc(r: CycleReport) = discard)

    # A record that does not say which cycle it is.
    var noPhase: seq[string] = @[]
    for line in SealedStateTamperReport.splitLines:
      if not line.startsWith("phase="): noPhase.add line
    check "does not say which" in
      refusalFor(noPhase.join("\n"), proc(r: CycleReport) = discard)

    # A status field that is not a number where one is required.
    check "is not a number" in
      refusalFor(SealedStateTamperReport.replace("unseal_a_rc=1",
                                                 "unseal_a_rc=yes"),
                 proc(r: CycleReport) = discard sealedObjectRefused(r, "a"))
