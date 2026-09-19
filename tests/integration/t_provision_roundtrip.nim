## A machine was handed a secret over a network, and after it was power
## cycled the secret was not on its disk — **and that was established by
## searching the block device**, not by reading the code path that wrote
## it.
##
## ## What the experiment was
##
## `attested_boot/take-provisioned-secret-evidence.sh`: one guest, one
## raw disk image attached as a virtio block device, two power cycles.
## In the first the guest brings up the attestation agent; the host —
## a different process, on the other side of a forwarded TCP port —
## mints a nonce, takes a key agreement, verifies it against a policy,
## encrypts a 64-character credential to the ephemeral key that evidence
## bound, and posts the ciphertext. The guest decrypts it into its
## runtime directory. Then it writes twenty-four blobs and a **planted
## token** to the persistent disk, and powers off. The second cycle boots
## the same machine, confirms the disk still carries what the first wrote
## and the runtime directory does not, and powers off. Then the host
## greps the image.
##
## ## The three things that make "absent" a measurement
##
## A negative result from a search is worth exactly what the search is
## worth, so the search is shown to work three separate ways:
##
##   1. **The planted token IS found** in the same image, written by the
##      same guest to the same filesystem in the same cycle.
##   2. **The same search finds the secret when the secret is there** —
##      the harness appends it to a copy of the image and re-runs the
##      grep.
##   3. **A whole second run**, in which the guest copies its released
##      secret onto the disk on purpose, reports `secret_hits=1`. That is
##      the failure this gate exists to detect, in evidence form, and it
##      is a boot rather than an argument.
##
## ## And the join nobody can fake
##
## The guest computed the SHA-256 of the file it decrypted, from inside
## itself. The host computed the SHA-256 of the plaintext it released.
## The search recorded the SHA-256 of the token it looked for. All three
## are pinned and all three are equal, so "the machine really got the
## secret" and "the searched-for token is the released secret" are both
## checked, without the secret being published anywhere.
##
## ## What this does NOT establish
##
## Stated here because it is the more important half. There is no
## unified kernel image, no firmware, no TPM and **no measured boot** in
## this experiment: the guest's root of trust is a software one and the
## verifier declared the matching opt-in, which the pinned verdict says
## out loud. Binding a release to hardware evidence is a different
## question; it is asked by the gate beside this one. The disk is an
## ordinary unencrypted ext4 filesystem — deliberately, because an
## encrypted volume would make "the secret is not on the disk" true for a
## reason that has nothing to do with the property under test.
##
## ## Mocking
##
## None. Every line read below was written by a real machine, a real
## host process or a real `grep` over a real block device.

import std/[json, strutils, tables, unittest]

import ./provisioned_secret_vectors

type
  Record = Table[string, string]

  EvidenceError = object of CatchableError

proc parseRecord(text: string): Record =
  ## A flat `key=value` record, strictly: a line that is not one is a
  ## refusal rather than something to skip past. A reader that skipped
  ## would turn a truncated report into a short one.
  result = initTable[string, string]()
  for raw in text.strip.splitLines:
    let line = raw.strip
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(EvidenceError,
        "the record carries the line " & line.escape() &
        ", which is not key=value")
    if result.hasKey(line[0 ..< eq]):
      raise newException(EvidenceError,
        "the record repeats the key " & line[0 ..< eq].escape())
    result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc field(r: Record; key: string): string =
  ## A missing field is a REFUSAL, not the empty string. Every assertion
  ## below rests on a value being present, and a reader that returned ""
  ## would turn a field the harness forgot to write into a comparison
  ## that quietly succeeded against another empty one.
  if not r.hasKey(key):
    raise newException(EvidenceError,
      "the record has no field " & key.escape() & "; it carries " &
      $r.len & " fields and this gate will not read an absent one as " &
      "an empty one")
  r[key]

proc intField(r: Record; key: string): int =
  try:
    parseInt(r.field(key))
  except ValueError:
    raise newException(EvidenceError,
      "the field " & key.escape() & " is " & r.field(key).escape() &
      ", which is not a number")

let
  provisionCycle = parseRecord(ProvisionedSecretProvisionCycleReport)
  afterReboot = parseRecord(ProvisionedSecretAfterRebootCycleReport)
  diskSearch = parseRecord(ProvisionedSecretDiskSearchRecord)
  releaser = parseRecord(ProvisionedSecretReleaserReport)
  leakingCycle = parseRecord(ProvisionedSecretLeakingProvisionCycleReport)
  leakingSearch = parseRecord(ProvisionedSecretLeakingDiskSearchRecord)
  leakingReleaser = parseRecord(ProvisionedSecretLeakingReleaserReport)

suite "a released secret lives in memory and dies with the boot":

  test "t_provision_roundtrip_the_secret_is_absent_from_the_block_device":
    ## THE ASSERTION. A grep over the whole raw image, after the machine
    ## had been power cycled, by the host, with no guest involved.
    check diskSearch.intField("secret_hits") == 0

    # And the three things that make that a measurement rather than a
    # property of the searcher. Each is a different producer.
    check diskSearch.intField("planted_hits") >= 1
    check diskSearch.intField("secret_hits_when_planted") >= 1
    check leakingSearch.intField("secret_hits") >= 1

    # The two runs disagree about the one number this gate is about, so
    # it is not a constant. They are also genuinely two runs: three
    # values drawn independently per run differ.
    check diskSearch.field("secret_hits") != leakingSearch.field("secret_hits")
    check diskSearch.field("secret_sha256") !=
          leakingSearch.field("secret_sha256")
    check diskSearch.field("planted_sha256") !=
          leakingSearch.field("planted_sha256")
    check releaser.field("challenge") != leakingReleaser.field("challenge")

    # The image was a real, used filesystem rather than a blank file.
    check diskSearch.intField("image_bytes") >= 64 * 1024 * 1024
    check afterReboot.intField("state_files") == 24

  test "t_provision_roundtrip_the_machine_really_decrypted_what_was_released":
    ## Three producers, one value, and none of them is the secret. The
    ## host hashed the plaintext it released; the guest hashed the file
    ## it decrypted, from inside itself; the search hashed the token it
    ## looked for. If these were not equal, the search above would be a
    ## search for something else.
    let digest = releaser.field("secret_sha256")
    check digest.len == 64
    check provisionCycle.field("secret_sha256") == digest
    check diskSearch.field("secret_sha256") == digest
    check provisionCycle.intField("secret_bytes") ==
          releaser.intField("secret_bytes")
    check releaser.intField("provision_bytes") ==
          releaser.intField("secret_bytes")

    # The relay carried ciphertext. Measured by the releaser, over the
    # bytes it was about to send.
    check releaser.field("wrapped_carries_plaintext") == "false"
    check releaser.intField("wrapped_secret_base64_len") > 0
    check releaser.field("wrapped_secret_sha256") != digest

    # The whole protocol ran over a socket, and each step is a status
    # code rather than a claim.
    check releaser.field("key_agreement_status") == "200"
    check releaser.field("provision_status") == "200"
    check releaser.field("report_purpose") == "key-agreement"
    check releaser.field("report_binds_challenge") == "true"
    check releaser.field("report_ephemeral_pub").len == 64

    # The key's single use was spent by the release, across a real
    # network: the same body again is refused.
    check releaser.field("replay_status") == "404"

  test "t_provision_roundtrip_the_secret_landed_on_a_filesystem_with_no_backing_store":
    ## Where it went, as the machine saw it. The agent refuses to write
    ## anywhere else — that refusal has its own gate — and this is the
    ## machine confirming it did not have to.
    check provisionCycle.field("secret_present") == "1"
    check provisionCycle.field("secrets_dir_fstype") == "tmpfs"
    check provisionCycle.field("run_fstype") == "tmpfs"
    check provisionCycle.field("secret_mode") == "-rw-------"
    check releaser.field("provision_path").startsWith("/run/")
    check releaser.field("health_secrets_dir") ==
          "/run/attested-secrets"

    # The disk it did NOT go to is a real filesystem that really mounted,
    # so "not on the disk" is not "there was no disk".
    check provisionCycle.field("state_fstype") == "ext4"
    check provisionCycle.intField("state_mount_rc") == 0
    check provisionCycle.intField("state_files") == 24

    # And the machine had the mechanism, not a placeholder.
    check releaser.field("health_key_agreement") ==
          "hpke-x25519-hkdf-sha256-aes128gcm"
    check releaser.field("health_can_release") == "true"

  test "t_provision_roundtrip_the_reboot_kept_the_disk_and_lost_the_secret":
    ## The power cycle really happened and really was a power cycle: the
    ## disk carries what the first boot wrote, and the runtime directory
    ## does not exist at all.
    check afterReboot.field("cycle") == "after-reboot"
    check afterReboot.field("planted_on_disk") == "1"
    check afterReboot.field("planted_matches") == "1"
    check afterReboot.field("state_fstype") == "ext4"
    check afterReboot.field("secrets_dir_present") == "0"
    check afterReboot.intField("secrets_dir_entries") == 0
    check afterReboot.field("leaked_on_disk") == "0"
    check afterReboot.field("done") == "1"
    check provisionCycle.field("done") == "1"

  test "t_provision_roundtrip_the_negative_control_is_a_real_boot":
    ## A whole second run of the same harness whose guest copies the
    ## released secret onto the disk. Same code, same image size, same
    ## search — one line of guest behaviour different, and the number
    ## this gate is about changes.
    check leakingCycle.field("leak_requested") == "1"
    check leakingCycle.field("leaked_to_disk") == "1"
    check provisionCycle.field("leak_requested") == "0"
    check provisionCycle.field("leaked_to_disk") == "0"
    check leakingSearch.field("leak_requested") == "1"
    check diskSearch.field("leak_requested") == "0"

    # Everything the two runs share, they share — so the difference in
    # `secret_hits` is attributable to the leak and not to the harness
    # having been run differently.
    check leakingSearch.field("image_bytes") == diskSearch.field("image_bytes")
    check leakingSearch.field("token_chars") == diskSearch.field("token_chars")
    check leakingCycle.field("secrets_dir_fstype") ==
          provisionCycle.field("secrets_dir_fstype")
    check leakingReleaser.field("provision_status") ==
          releaser.field("provision_status")
    check leakingReleaser.field("release_decision") ==
          releaser.field("release_decision")
    # The leaking run's guest decrypted its own, different secret.
    check leakingCycle.field("secret_sha256") ==
          leakingReleaser.field("secret_sha256")
    check leakingCycle.field("secret_sha256") !=
          provisionCycle.field("secret_sha256")

  test "t_provision_roundtrip_the_release_decision_was_recorded":
    ## The audit hook, over a real release. One line per decision, and
    ## it names the four things a reviewer needs plus which key the
    ## secret went to.
    let lines = ProvisionedSecretReleaseAuditLog.strip.splitLines
    check lines.len == 1
    let rec = parseJson(lines[0])
    check rec["schema"].getStr == "reproos.attestation-release-audit.v1"
    check rec["decision"].getStr == "released"
    check rec["challenge"].getStr == releaser.field("challenge")
    check rec["ephemeralPub"].getStr == releaser.field("report_ephemeral_pub")
    check rec["policyDigest"].getStr == releaser.field("policy_digest")
    check rec["verdict"].getStr == releaser.field("verdict")
    check rec["secretName"].getStr == releaser.field("secret_name")
    check rec["reason"].getStr.len > 0
    # The secret is not in the log, and neither is any part of it.
    check rec["measurement"].getStr == "-"
    check releaser.field("secret_sha256") notin ProvisionedSecretReleaseAuditLog

  test "t_provision_roundtrip_states_what_it_did_not_establish":
    ## The verdict this release rests on, pinned by value rather than
    ## described in prose. A run against a real root of trust would carry
    ## a different word here, and a reader must not have to take the
    ## header's word for which one this was.
    check releaser.field("verdict") == "accepted-without-a-root-of-trust"
    check releaser.field("health_tier") == "mock"
    check releaser.field("health_backend") == "mock"
    check leakingReleaser.field("verdict") == releaser.field("verdict")

  test "t_provision_roundtrip_the_reader_refuses_a_record_it_cannot_read":
    ## The reader itself, because every assertion above is only as good
    ## as its refusal to invent a value.
    expect EvidenceError: discard parseRecord("cycle").field("cycle")
    expect EvidenceError: discard parseRecord("=novalue")
    expect EvidenceError: discard parseRecord("a=1\na=2")
    expect EvidenceError: discard parseRecord("a=1").field("b")
    expect EvidenceError: discard parseRecord("a=x").intField("a")
    # And the positive control, so the refusals above are not the only
    # thing this reader can do.
    check parseRecord("a=1\nb=two").field("b") == "two"
    check parseRecord("a=1").intField("a") == 1
    check parseRecord("a=b=c").field("a") == "b=c"
