## A machine seals its state key for a boot that has not happened.
##
## ## The claim
##
## While generation A was running, the machine computed the register
## value generation B WOULD produce — from generation B's image bytes,
## with generation B never having run — and re-sealed the volume key
## under a policy over that value. It was then power cycled onto
## generation B, and the TPM released the key. Both volumes opened and
## the markers are the ones generation A wrote.
##
## ## Why this is the whole point of a precomputed measurement
##
## Without it there is no such thing as an unattended update. The key
## could only be re-sealed once the new generation was already running,
## and a machine that cannot open its own state has no way to get there:
## the update would have to be trusted to succeed before anything could
## verify that it had.
##
## What makes the precomputation possible is that the policy digest is a
## PURE FUNCTION of the image:
##
##     B's section digests -> B's register 11 -> B's policy digest
##
## This gate walks that function offline, and the answer equals the
## `authPolicy` inside the object generation A sealed — an object created
## before generation B existed as a running machine.
##
## ## The four-cornered discrimination
##
## Two generations, two sealed objects, and every combination was tried
## on a real machine:
##
## |             | object A     | object B     |
## |-------------|--------------|--------------|
## | on gen A    | RELEASED     | refused 0x99D |
## | on gen B    | refused 0x99D | RELEASED     |
##
## The top-right corner is the one that makes "sealed for a boot that has
## not happened" a measured statement: the object was created on
## generation A and immediately refused to open there. Without it, an
## object that opened everywhere would produce the same bottom-right
## success.
##
## ## The causal isolation
##
## The two images' replay templates agree in five of six measured
## sections and differ in exactly one, `.cmdline`. That is what licenses
## reading the difference in register 11 as a consequence of the
## generation and not of an unrelated rebuild.
##
## ## What this gate does NOT prove
##
## The generation switch is performed by the harness writing a different
## image onto the EFI system partition between power cycles; no bootloader
## entry is written, no generation directory is rotated, and nothing here
## exercises the product's own generation switching. What is exercised is
## the SEALING half: the re-seal, the prediction it rests on, and the
## four-cornered outcome. The TPM is software, and no quote is taken.
##
## ## Mocking
##
## None. See `sealed_state_vectors`.

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

suite "a switched generation re-seals under its own measurement":

  test "t_reseal_on_generation_switch":
    let reseal = parseCycleReport(SealedStateResealReport)
    let switch = parseCycleReport(SealedStateSwitchReport)
    check reseal.phase == "reseal"
    check switch.phase == "switch"

    # ---- the prediction, made before generation B ever ran ----------
    # The re-seal happened while generation A was running: the cycle's
    # own register reading is A's.
    check reseal.pcr11 == SealedStateAPredictedPcr11
    check reseal.field("next_generation_pcr11") == SealedStateBPredictedPcr11
    # And that number is what B's IMAGE BYTES say, replayed here rather
    # than copied from the report.
    check replayEventLogTemplate(SealedStateBTemplate) ==
      SealedStateBPredictedPcr11
    # ...and what generation B's own firmware log says once it booted.
    check switch.pcr11 == SealedStateBPredictedPcr11
    check replayedPcr11(SealedStateSwitchEventLogHex) ==
      SealedStateBPredictedPcr11

    # ---- the policy the TPM will require, computed from the image ----
    let objB = parseSealedObjectPublic(unhexBytes(SealedStateSealBPublicHex))
    check hexOf(objB.authPolicy) == SealedStateSealBPolicyHex
    check hexOf(launchPolicyDigest(SealedStateBPredictedPcr11)) ==
      SealedStateSealBPolicyHex
    check hexOf(sealedObjectName(objB)) == SealedStateSealBNameHex
    check policyIsTheOnlyAuthorisation(objB)
    check authValueWasRefused(switch, "b")

    # ---- the four corners, all from real boots ----------------------
    # Each corner is asserted with BOTH predicates, in both directions.
    # "Released" and "refused" are not each other's negation — a failure
    # for some other reason is neither — so a corner stated with only
    # one of them would be satisfied by a predicate that always said
    # yes. That is not a hypothetical: the first mutation pass made
    # `sealedObjectRefused` constantly TRUE and this gate stayed green.
    check sealedObjectReleased(reseal, "a")     # A's object, on A
    check not sealedObjectRefused(reseal, "a")
    check sealedObjectRefused(reseal, "b")      # B's object, on A
    check not sealedObjectReleased(reseal, "b")
    check sealedObjectRefused(switch, "a")      # A's object, on B
    check not sealedObjectReleased(switch, "a")
    check sealedObjectReleased(switch, "b")     # B's object, on B
    check not sealedObjectRefused(switch, "b")

    # ---- the state crossed the switch --------------------------------
    check stateVolumesOpen(switch)
    check switch.field("open_key_source") == "unsealed"
    let enroll = parseCycleReport(SealedStateEnrollReport)
    for v in StateVolumes:
      check switch.marker(v) == enroll.marker(v)
      check switch.volumeIdentity(v) == enroll.volumeIdentity(v)
      check switch.ciphertextAt(v) == enroll.ciphertextAt(v)
      check carriesLuksSignature(switch, v)

  test "t_reseal_on_generation_switch_binds_two_different_policies":
    ## The two objects are sealed under DIFFERENT policies, and each is
    ## the one its own generation's measurement produces. Without this,
    ## the four corners above would be satisfied by two objects that
    ## happened to be created at different times.
    let objA = parseSealedObjectPublic(unhexBytes(SealedStateSealAPublicHex))
    let objB = parseSealedObjectPublic(unhexBytes(SealedStateSealBPublicHex))
    check objA.authPolicy != objB.authPolicy
    check SealedStateAPredictedPcr11 != SealedStateBPredictedPcr11

    # Each policy belongs to its own generation and to no other. The
    # cross terms are what make this a binding rather than a coincidence.
    check hexOf(launchPolicyDigest(SealedStateAPredictedPcr11)) ==
      hexOf(objA.authPolicy)
    check hexOf(launchPolicyDigest(SealedStateBPredictedPcr11)) ==
      hexOf(objB.authPolicy)
    check hexOf(launchPolicyDigest(SealedStateBPredictedPcr11)) !=
      hexOf(objA.authPolicy)
    check hexOf(launchPolicyDigest(SealedStateAPredictedPcr11)) !=
      hexOf(objB.authPolicy)

    # The objects differ ONLY where a sealed object may differ: the
    # policy and the encrypted unique field. Same type, same name
    # algorithm, same attributes — so the refusal above is about the
    # policy and not about one of them being a different kind of object.
    check objA.nameAlg == objB.nameAlg
    check objA.objectAttributes == objB.objectAttributes
    check objA.unique != objB.unique

  test "t_reseal_on_generation_switch_moves_one_section":
    ## The causal isolation, measured from the templates rather than
    ## asserted. Five of six measured sections are byte-identical between
    ## the two generations; exactly one differs.
    let a = templateSections(SealedStateATemplate)
    let b = templateSections(SealedStateBTemplate)
    check a.len == 6
    check b.len == 6
    var differing: seq[string] = @[]
    for i in 0 ..< a.len:
      check a[i].split('=')[0] == b[i].split('=')[0]
      if a[i] != b[i]: differing.add a[i].split('=')[0]
    check differing == @[".cmdline"]
    check SealedStateACmdline != SealedStateBCmdline
    check SealedStateACmdline.len == SealedStateBCmdline.len
    check SealedStateAUkiSha256 != SealedStateBUkiSha256

  test "t_reseal_on_generation_switch_prediction_is_not_a_readback":
    ## THE CONTROL that stops the prediction from being circular. If the
    ## harness had simply read the register after booting generation B
    ## and called that a prediction, every equality above would still
    ## hold. It cannot have: the value was written into the sealed object
    ## DURING the `reseal` cycle, whose own register reading is
    ## generation A's.
    ##
    ## That cycle's own firmware log is NOT among the four brought home —
    ## `enroll`, `reboot`, `switch` and `tamper` are — so the reading is
    ## corroborated by the two other generation-A boots' logs rather than
    ## by its own. What this case rests on instead is the pair below: the
    ## register the cycle reported, and the fact that the object it
    ## produced would not open on the machine that produced it.
    let reseal = parseCycleReport(SealedStateResealReport)
    check reseal.pcr11 == SealedStateAPredictedPcr11
    check reseal.pcr11 != SealedStateBPredictedPcr11
    check reseal.field("seal_b_source") == "supplied-value"
    check reseal.intField("seal_b_rc") == 0
    # The object it produced would not open on the machine that produced
    # it. A readback of the live register could not have that property.
    check sealedObjectRefused(reseal, "b")
    check reseal.field("unseal_b_tpm_rc") == PolicyFailureCode
