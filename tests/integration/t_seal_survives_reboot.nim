## The machine is switched off, switched on, and its disk opens again.
##
## ## The claim
##
## A volume key was created inside a guest, used to format two LUKS2
## volumes, and sealed to the TPM under a policy over the register the
## UEFI stub extends with the image's own sections. The machine was then
## POWER CYCLED. On the second start the TPM released the key, both
## volumes opened, and the plaintext marker the first cycle wrote is
## byte-for-byte the one the second cycle read.
##
## ## Why this is not the trivial claim it looks like
##
## "A TPM released a secret it was holding" is nearly worthless on its
## own — a TPM with no policy at all would do that. What makes it a
## claim about MEASUREMENT is that the policy the TPM required is
## computable from the image, and this gate computes it:
##
##     the section digests  ->  register 11  ->  the policy digest
##
## and the last of those equals the `authPolicy` inside the sealed
## object the TPM created. So the machine was not merely permitted to
## open its disk; it was permitted because it booted the image the key
## was sealed for, and a reader with nothing but the image can say in
## advance what those bytes will be.
##
## ## Four routes to one number
##
## Register 11 is established four independent ways and all four agree:
## the image's own section digests replayed offline, the value the
## enrolling boot read out of its sysfs, the value the SECOND boot read,
## and a replay of the TCG event log each boot's firmware wrote. The two
## firmware logs are NOT the same bytes — the first boot creates UEFI
## variables the second only reads — which is what makes "the same
## generation rebooted" a measured statement rather than a restatement
## of "nothing changed".
##
## ## The attribute nobody checks
##
## A sealed object carries a policy AND a set of attributes saying when
## the policy is required. With `userWithAuth` set, the object opens with
## an empty password and no policy session at all — a perfect policy
## digest over exactly the right measurement, and the object is readable
## on any machine that has the blob. This gate checks the attributes AND
## checks that the machine agreed: the no-session probe was refused with
## `TPM_RC_AUTH_UNAVAILABLE` on both cycles.
##
## ## What this gate does NOT prove
##
## The TPM is software. No quote is taken anywhere in this experiment and
## no signature is verified, so nothing here says the register readings
## were attested — they are corroborated by the firmware's own log and by
## the image's bytes, which is a different and weaker thing. The volumes
## carry a 64-byte marker rather than a filesystem, so nothing is proved
## about a root that boots from them.
##
## ## Mocking
##
## None. Every value read here came off a machine; see
## `sealed_state_vectors`.

import std/[strutils, unittest]

import repro_attest

include ./sealed_state_evidence

proc replayedPcr11(logHex: string): string =
  let log = parseEventLog(unhexBytes(logHex))
  hexOf(pcrValue(replayBank(log, TpmAlgSha256), 11))

suite "state sealed to a measured boot survives a power cycle":

  test "t_seal_survives_reboot":
    let enroll = parseCycleReport(SealedStateEnrollReport)
    let reboot = parseCycleReport(SealedStateRebootReport)
    check enroll.phase == "enroll"
    check reboot.phase == "reboot"

    # ---- one register value, four independent routes ---------------
    let fromImage = replayEventLogTemplate(SealedStateATemplate)
    check fromImage == SealedStateAPredictedPcr11
    check enroll.pcr11 == fromImage
    check reboot.pcr11 == fromImage
    check replayedPcr11(SealedStateEnrollEventLogHex) == fromImage
    check replayedPcr11(SealedStateRebootEventLogHex) == fromImage

    # TWO POWER CYCLES, NOT ONE READING TWICE. The logs differ; the
    # value they replay to does not.
    check SealedStateEnrollEventLogHex != SealedStateRebootEventLogHex

    # ---- what the TPM required, computed from the image -------------
    let obj = parseSealedObjectPublic(unhexBytes(SealedStateSealAPublicHex))
    check hexOf(obj.authPolicy) == SealedStateSealAPolicyHex
    check hexOf(launchPolicyDigest(fromImage)) == SealedStateSealAPolicyHex

    # The pinned public area and the pinned name check each other.
    check hexOf(sealedObjectName(obj)) == SealedStateSealANameHex

    # ---- the policy is the only way in -----------------------------
    check policyIsTheOnlyAuthorisation(obj)
    check (obj.objectAttributes and AttrUserWithAuth) == 0'u32
    check (obj.objectAttributes and AttrAdminWithPolicy) != 0'u32
    # And the machine agreed, on both cycles.
    check authValueWasRefused(enroll, "a")
    check authValueWasRefused(reboot, "a")

    # ---- the second cycle opened the FIRST cycle's volumes ----------
    check sealedObjectReleased(reboot, "a")
    check not sealedObjectRefused(reboot, "a")
    check stateVolumesOpen(reboot)
    check reboot.intField("open_var_rc") == 0
    check reboot.intField("open_home_rc") == 0
    check reboot.field("open_key_source") == "unsealed"
    for v in StateVolumes:
      check reboot.marker(v) == enroll.marker(v)
      check reboot.marker(v).len == 64
      check reboot.volumeIdentity(v) == enroll.volumeIdentity(v)
    # The two volumes are not the same volume wearing two names.
    check enroll.marker(vnVar) != enroll.marker(vnHome)
    check enroll.volumeIdentity(vnVar) != enroll.volumeIdentity(vnHome)

  test "t_seal_survives_reboot_over_real_encrypted_volumes":
    ## The volumes are LUKS2 and the marker is genuinely encrypted at
    ## rest. Without this, "the marker read back" would be satisfied by
    ## two plain block devices and a mapping that did nothing.
    let enroll = parseCycleReport(SealedStateEnrollReport)
    let reboot = parseCycleReport(SealedStateRebootReport)
    for v in StateVolumes:
      check carriesLuksSignature(enroll, v)
      check carriesLuksSignature(reboot, v)
      # What the disk holds where the marker sits, with no mapping in
      # the way, is not the marker.
      check enroll.ciphertextAt(v).len == 128
      check enroll.ciphertextAt(v) != enroll.marker(v)
      check enroll.ciphertextAt(v) != repeat('0', 128)
      # And it did not change across the power cycle: the same disk.
      check reboot.ciphertextAt(v) == enroll.ciphertextAt(v)
    check enroll.ciphertextAt(vnVar) != enroll.ciphertextAt(vnHome)

  test "t_seal_survives_reboot_a_perfect_policy_can_still_be_no_lock":
    ## The two ways a sealed object can carry exactly the right policy
    ## digest and still not be protected by it. Both are built out of the
    ## REAL object, so nothing else differs between the object that is
    ## policy-protected and the object that is not.
    ##
    ## Neither clause had a reachable input when this gate was first
    ## written — every object a machine here produced has `userWithAuth`
    ## clear and a policy — so deleting either changed no answer
    ## anywhere. A rule with no reachable input is not a rule; the first
    ## mutation pass measured that, and these are the inputs.
    let good = unhexBytes(SealedStateSealAPublicHex)
    check policyIsTheOnlyAuthorisation(parseSealedObjectPublic(good))

    # ONE BIT. `userWithAuth` set means the authorisation VALUE satisfies
    # user-role commands, and `TPM2_Unseal` is one, so the object opens
    # with an empty password and no policy session at all.
    var permissive = good
    permissive[9] = char(uint8(permissive[9]) or uint8(AttrUserWithAuth))
    let loose = parseSealedObjectPublic(permissive)
    check hexOf(loose.authPolicy) == SealedStateSealAPolicyHex
    check (loose.objectAttributes and AttrUserWithAuth) != 0'u32
    check not policyIsTheOnlyAuthorisation(loose)
    check "THE POLICY IS NOT THE ONLY WAY IN" in explainSealedObject(loose)
    check "THE POLICY IS NOT THE ONLY WAY IN" notin
      explainSealedObject(parseSealedObjectPublic(good))

    # And an object carrying NO policy at all: the attributes can say
    # `adminWithPolicy` all they like, there is nothing for a session to
    # be checked against.
    var noPolicy = "\x00\x2e" & good[2 .. 9] & "\x00\x00" & good[44 .. 79]
    let bare = parseSealedObjectPublic(noPolicy)
    check bare.authPolicy.len == 0
    check bare.objectAttributes == loose.objectAttributes - AttrUserWithAuth
    check (bare.objectAttributes and AttrAdminWithPolicy) != 0'u32
    check not policyIsTheOnlyAuthorisation(bare)

    # THE THIRD CLAUSE, which had no reachable input either and which the
    # first sweep did not reach: `adminWithPolicy` CLEAR. An object whose
    # administrative role is not policy-only is one whose policy can be
    # got around administratively, and `TPM2_Create` will not produce the
    # combination — but a hand-assembled object can carry it, and this
    # reader's job is to look rather than to assume.
    var noAdmin = good
    noAdmin[9] = char(uint8(noAdmin[9]) and not uint8(AttrAdminWithPolicy))
    let unbolted = parseSealedObjectPublic(noAdmin)
    check hexOf(unbolted.authPolicy) == SealedStateSealAPolicyHex
    check (unbolted.objectAttributes and AttrUserWithAuth) == 0'u32
    check (unbolted.objectAttributes and AttrAdminWithPolicy) == 0'u32
    check not policyIsTheOnlyAuthorisation(unbolted)
    check "THE POLICY IS NOT THE ONLY WAY IN" in explainSealedObject(unbolted)

    # THE ATTRIBUTE BIT NUMBERS THEMSELVES, pinned to the values TPM 2.0
    # Part 2 assigns them. Everything else in this file uses these
    # constants on BOTH sides — the object above is edited with
    # `AttrUserWithAuth` and then read back with `AttrUserWithAuth` — so a
    # constant carrying the wrong bit is self-consistent and invisible.
    # That is not hypothetical: renumbering `AttrUserWithAuth` to a bit
    # the real object also has clear left every gate green, which is what
    # a literal-against-constant check exists to catch. These are WIRE
    # values; a wire value must be pinned to the wire.
    check AttrFixedTpm == 0x00000002'u32
    check AttrFixedParent == 0x00000010'u32
    check AttrSensitiveDataOrigin == 0x00000020'u32
    check AttrUserWithAuth == 0x00000040'u32
    check AttrAdminWithPolicy == 0x00000080'u32
    check AttrNoDa == 0x00000400'u32
    # And the word the TPM actually wrote, so the six above are a
    # decomposition of a real object's attributes and not six free
    # numbers.
    check parseSealedObjectPublic(good).objectAttributes == 0x00000492'u32

  test "t_seal_survives_reboot_reads_a_sealed_object_exactly":
    ## The refusals in the sealed-object reader, each reached by an input
    ## and each identified by its own phrase. A reader that accepted a
    ## key of the wrong type as a sealed blob would take `authPolicy`
    ## from the wrong offset and compare equal to nothing at all.
    let good = unhexBytes(SealedStateSealAPublicHex)

    proc refusalFor(blob: string): string =
      try:
        discard parseSealedObjectPublic(blob)
        ""
      except CatchableError as e:
        e.msg

    # A declared size of zero.
    check "zero-length public area" in refusalFor("\0\0")
    # A declared size longer than what follows.
    check "bytes of public area but" in refusalFor(good[0 ..< good.len - 4])
    # Bytes after the structure.
    check "bytes follow the public area" in refusalFor(good & "\x00\x01")
    # A type that is not keyed hash: an ECC key's public area read as a
    # sealed blob.
    var wrongType = good
    wrongType[2] = '\x00'; wrongType[3] = '\x23'
    check "is a keyed-hash object" in refusalFor(wrongType)
    # A name algorithm whose digest length is unknown here.
    var wrongNameAlg = good
    wrongNameAlg[4] = '\x00'; wrongNameAlg[5] = '\x99'
    check "neither the object's name nor its policy digest" in
      refusalFor(wrongNameAlg)
    # A keyed-hash object with an HMAC scheme: a signing key, not sealed
    # data. The scheme sits after the policy, so this also exercises the
    # policy field being read at the right length.
    var wrongScheme = good
    wrongScheme[44] = '\x00'; wrongScheme[45] = '\x05'
    check "rather than sealed data" in refusalFor(wrongScheme)

  test "t_seal_survives_reboot_refuses_an_unusable_register_value":
    ## The policy calculator's own refusals. A truncated or non-hex
    ## register value must not produce a policy digest at all: it would
    ## be a plausible 32 bytes that no machine can ever satisfy, and the
    ## machine that could not open its state would be the first to find
    ## out.
    proc refusalFor(v: string): string =
      try:
        discard launchPolicyDigest(v)
        ""
      except CatchableError as e:
        e.msg

    check "hex characters, got 63" in
      refusalFor(SealedStateAPredictedPcr11[0 ..< 63])
    # And one level below that: a hex string with an odd number of
    # characters is refused rather than decoded a nibble short. Found by
    # instrumenting every refusal in these two modules and measuring
    # which ones any case reaches — this was the one that none did, and
    # a rule with no reachable input is not a rule.
    var oddLength = false
    try:
      discard unhexBytes(SealedStateSealAPolicyHex[0 ..< 63])
    except CatchableError as e:
      oddLength = "even number of characters" in e.msg
    check oddLength
    check "is not hexadecimal" in
      refusalFor("zz" & SealedStateAPredictedPcr11[2 .. ^1])
    # An algorithm with no digest length here cannot be predicted for.
    var unknownAlg = false
    try:
      discard pcrPolicyDigest(TpmAlgId(0x0099'u16),
        pcrSelection(TpmAlgSha256, [Pcr11]),
        [selectedPcr(TpmAlgSha256, Pcr11,
                     unhexBytes(SealedStateAPredictedPcr11))])
    except CatchableError as e:
      unknownAlg = "is not a digest this build" in e.msg
    check unknownAlg

  test "t_seal_survives_reboot_policy_digest_is_a_value_not_a_shape":
    ## The policy digest must MOVE when the register moves. A calculator
    ## that ignored its input would satisfy every equality above, because
    ## every one of them compares two things this build produced from the
    ## same constant.
    let a = hexOf(launchPolicyDigest(SealedStateAPredictedPcr11))
    let b = hexOf(launchPolicyDigest(SealedStateBPredictedPcr11))
    let t = hexOf(launchPolicyDigest(SealedStateTamperedPredictedPcr11))
    check a == SealedStateSealAPolicyHex
    check b == SealedStateSealBPolicyHex
    check a != b
    check a != t
    check b != t
    # One flipped bit in the register is a different policy.
    var moved = SealedStateAPredictedPcr11
    moved[0] = (if moved[0] == '9': '8' else: '9')
    check hexOf(launchPolicyDigest(moved)) != a
