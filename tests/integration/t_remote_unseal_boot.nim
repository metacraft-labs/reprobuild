## A machine with no key to its own disk booted, because somebody else
## agreed that it should.
##
## ## The claim
##
## One guest, three power cycles, two real LUKS2 volumes. The machine has
## **no TPM, no sealed object, and no copy of the volume key anywhere on
## it** — that is read off the machine and off its images rather than
## asserted about them. What it has is a client that attests to a broker
## on the other side of a socket, and what the broker returns is the key,
## encrypted to an ephemeral public key that this boot minted and that
## the evidence binds.
##
## The boot then **continues into a root filesystem that is inside the
## encrypted volume**. That is what makes "it booted" a measurement: the
## `init` there, and the sentinel it prints, were written at enrolment
## and exist nowhere else afterwards. The harness checks the initramfs
## and the shared directory for that sentinel and finds neither, so a
## sentinel on the console is a statement that bytes from inside
## ciphertext executed.
##
## ## The three producers
##
## The key's SHA-256 is written by the broker that released it, by the
## client that opened it, and by the host that searched for it. All three
## are equal and the key itself is in no committed artifact.
##
## ## What this gate does NOT prove
##
## The guest's root of trust is a **software** one. There is no unified
## kernel image, no firmware and no TPM anywhere in this experiment, and
## the broker's own record says `accepted-without-a-root-of-trust` out
## loud — asserted below by value, so a reader does not have to take this
## paragraph's word for it. What is established is the *remote unseal*:
## that the key lives elsewhere, arrives over a network, and is what the
## machine comes up on. Binding that release to hardware evidence is a
## different question asked by a different gate.
##
## The transport is plaintext HTTP. `key_hits_root_volume=0` is reported
## below but is deliberately NOT leaned on: a search of an encrypted
## volume would come back empty whatever was written to it, and the
## searches this gate does rest on are the ones over the initramfs, the
## shared directory and the console logs, each with its own positive
## control.
##
## ## Mocking
##
## The live case executes a **recorder** in place of the volume opener,
## because what it measures is whether a process was created at all and
## that cannot be observed by executing the real thing. See
## `remote_unseal_harness`. Everything else is real: the pinned records
## come from real guests opening real LUKS2 volumes with the real
## `cryptsetup`, and the broker in the live case is the same code the
## guests attested to.

import std/[os, strutils, unittest]

import repro_attest_agent/unseal_cli

import ./remote_unseal_harness

include ./remote_unseal_evidence

runAsRecorderIfAsked()

const
  ExpectedVolumes = 2
  ReleasedKeyChars = 64
    ## The volume key is 64 printable hexadecimal characters: a realistic
    ## shape for a released credential, and one a reader can grep for by
    ## hand.

suite "a machine with no local sealing boots by attesting to a broker":

  test "t_remote_unseal_boot":
    let guest = parseCycleRecord(RemoteUnsealUnsealReport)
    let client = parseUnsealRecord(RemoteUnsealUnsealClientReport)
    let broker = parseUnsealRecord(RemoteUnsealUnsealBrokerRecord)
    let rootfs = parseCycleRecord(RemoteUnsealUnsealRootfsReport)
    let search = parseUnsealRecord(RemoteUnsealSearchRecord)
    check guest.cycle == "unseal"
    check rootfs.cycle == "unseal"

    # ---- the machine had nothing to unlock itself with ---------------
    check machineHasNoLocalRootOfTrust(guest)
    check not machineCarriesALocalKey(guest)
    check search.intField("key_hits_initrd") == 0
    check search.intField("key_hits_outshare") == 0
    check search.intField("key_hits_console_unseal") == 0

    # ---- the broker released, and the client opened ------------------
    check brokerReleased(client)
    check not brokerRefused(client)
    check broker.field("release_decision") == "released"
    check broker.field("outcome") == "released"
    check openerWasExecuted(client)
    check volumesOpenedByClient(client) == ExpectedVolumes
    check client.intField("volumes_requested") == ExpectedVolumes
    check client.field("action") == $vaOpen
    check client.intField("exit") == ExitUnsealed
    check client.intField("released_key_bytes") == ReleasedKeyChars

    # ---- ONE value, THREE producers ----------------------------------
    # The broker that released it, the client that decrypted it and the
    # host that searched for it. None of them publishes the key.
    check broker.field("secret_sha256") == client.field("released_key_sha256")
    check broker.field("secret_sha256") == search.field("key_sha256")
    check broker.intField("secret_bytes") == ReleasedKeyChars

    # ---- the release was for THIS session ----------------------------
    check client.field("challenge") == broker.field("challenge")
    check client.field("challenge") == broker.field("audit_challenge")
    check client.field("ephemeral_pub") == broker.field("audit_ephemeral_pub")
    check client.field("challenge").len == 64
    check client.field("ephemeral_pub").len == 64
    # The relay carried ciphertext, said by measurement rather than by
    # claim: the broker looked for its own plaintext in what it sent.
    check broker.field("wrapped_carries_plaintext") == "false"
    check broker.intField("wrapped_bytes") > 0

    # ---- the volumes really opened -----------------------------------
    check stateVolumesOpen(guest)
    check not stateVolumesLocked(guest)
    for v in StateVolumes:
      check carriesLuksSignature(guest, v)
      check guest.marker(v).len == 64
      check volumeIdentity(guest, v).len == 36
    # Nothing was asked to open with a wrong key on this cycle, because
    # the mapping already existed. The record says so rather than being
    # silent about it.
    check guest.intField("probe_ran") == 0
    check not probeReachedTheKeySlots(guest)

    # ---- AND THE MACHINE CAME UP -------------------------------------
    # Not "the client exited 0": a root filesystem inside the encrypted
    # volume executed and said so.
    check bootReachedEncryptedRoot(search, "unseal")
    check guest.field("boot_outcome") == "handing-off"
    check guest.intField("sysroot_mounted") == 1
    check guest.intField("switch_root_attempted") == 1
    # The marker the root filesystem read of ITSELF is the marker the
    # initramfs read through the mapping: two readers, one volume.
    check rootfs.field("rootfs_marker") == guest.marker(uvRoot)
    # And the file that ran is the file the host put inside the volume.
    check rootfs.field("rootfs_init_sha256") ==
      search.field("rootfs_init_sha256")
    check rootfs.field("rootfs_sentinel_sha256") ==
      search.field("sentinel_sha256")

  test "t_remote_unseal_boot_says_what_it_rests_on":
    ## The verdict this boot rests on, pinned BY VALUE. A reader must not
    ## have to take the header's word for the fact that no hardware
    ## established anything here.
    let broker = parseUnsealRecord(RemoteUnsealUnsealBrokerRecord)
    check broker.field("verdict") == "accepted-without-a-root-of-trust"
    check broker.intField("require_root_of_trust") == 0
    check "deliberate opt-in" notin broker.field("release_reason")
    check broker.field("release_reason").startsWith(
      "the verdict is accepted-without-a-root-of-trust and the secret was")
    # The decision was recorded, with the challenge, the key, the policy
    # digest and the verdict — and WITHOUT the secret.
    let audit = RemoteUnsealUnsealAuditLog
    check "\"decision\":\"released\"" in audit
    check "\"verdict\":\"accepted-without-a-root-of-trust\"" in audit
    check broker.field("audit_policy_digest") in audit
    check broker.field("audit_ephemeral_pub") in audit
    check broker.field("policy_digest").startsWith("sha256:")

  test "t_remote_unseal_boot_created_the_volumes_from_the_released_key":
    ## The enrolling cycle, which is what makes "no local sealing" true
    ## rather than arranged: the volumes were CREATED with the broker's
    ## key, by a machine that at no point held it anywhere but in one
    ## process's memory.
    let format = parseUnsealRecord(RemoteUnsealEnrollFormatClientReport)
    let open = parseUnsealRecord(RemoteUnsealEnrollOpenClientReport)
    let guest = parseCycleRecord(RemoteUnsealEnrollReport)
    let search = parseUnsealRecord(RemoteUnsealSearchRecord)
    check guest.cycle == "enroll"
    check format.field("action") == $vaFormat
    check open.field("action") == $vaOpen
    check brokerReleased(format)
    check brokerReleased(open)
    check format.field("released_key_sha256") == search.field("key_sha256")
    check open.field("released_key_sha256") == search.field("key_sha256")
    # Two separate key agreements: a fresh challenge and a fresh
    # ephemeral key for each ask, because each ask is its own attestation.
    check format.field("challenge") != open.field("challenge")
    check format.field("ephemeral_pub") != open.field("ephemeral_pub")
    check guest.intField("format_rc") == ExitUnsealed
    check guest.intField("client_rc") == ExitUnsealed
    check guest.intField("mkfs_root_rc") == 0
    check guest.intField("rootfs_installed") == 1
    check stateVolumesOpen(guest)

  test "t_remote_unseal_boot_is_the_same_volume_every_cycle":
    ## A cycle that opened a FRESHLY FORMATTED volume would satisfy every
    ## check above and mean nothing. The LUKS header UUID is readable
    ## without any key and is what says these are the volumes the
    ## enrolling cycle made.
    let enroll = parseCycleRecord(RemoteUnsealEnrollReport)
    let unseal = parseCycleRecord(RemoteUnsealUnsealReport)
    let refuse = parseCycleRecord(RemoteUnsealRefuseReport)
    for v in StateVolumes:
      check volumeIdentity(enroll, v) == volumeIdentity(unseal, v)
      check volumeIdentity(enroll, v) == volumeIdentity(refuse, v)
      check volumeIdentity(enroll, v).len == 36
    # And the two volumes are two: a gate that read one field twice would
    # be satisfied by a machine with one disk.
    check volumeIdentity(unseal, uvRoot) != volumeIdentity(unseal, uvHome)
    check unseal.marker(uvRoot) != unseal.marker(uvHome)
    # The ciphertext at the data offset did not move between the cycle
    # that opened the volumes and the cycle that was refused.
    for v in StateVolumes:
      check ciphertextAt(unseal, v) == ciphertextAt(refuse, v)
      check ciphertextAt(unseal, v).len == 128

  test "t_remote_unseal_boot_the_searches_can_find_things":
    ## "Not found" is worth nothing from a search that finds nothing, and
    ## a token planted at the easiest place is not a coverage
    ## measurement. Every search this gate rests on is shown to work, and
    ## the strongest of the demonstrations is a BOOT rather than an
    ## argument.
    let search = parseUnsealRecord(RemoteUnsealSearchRecord)
    let control = parseUnsealRecord(UnlockedDespiteRefusalSearchRecord)

    # Planted at five offsets — the very front, a megabyte in, the
    # middle, near the end, and the final 64 bytes — and found at all
    # five.
    for f in ["key_coverage_root_volume", "sentinel_coverage_root_volume",
              "key_coverage_initrd", "sentinel_coverage_initrd"]:
      let c = coverage(search, f)
      check c.planted == 5
      check c.found == c.planted

    # THE ONE THAT IS A BOOT. The control run really does carry the
    # volume key in its initramfs, and the same search finds it there.
    # Without this, `key_hits_initrd=0` would be equally consistent with
    # a clean machine and with a grep that cannot see inside the archive
    # — which is exactly what it could not do until the archive stopped
    # being searched compressed.
    check search.intField("key_hits_initrd") == 0
    check control.intField("key_hits_initrd") == 1
    check control.intField("local_key_fallback") == 1
    check search.intField("local_key_fallback") == 0

    # The shared directory is the one writable filesystem that survives a
    # power cycle here, so it is where a client that wrote its key down
    # would have written it.
    check search.intField("key_hits_outshare") == 0
    check search.intField("outshare_search_finds_a_planted_file") == 1

    # The sentinel is in the shared directory for the enrolling cycle,
    # because that is how it gets into the volume — and for no later one.
    check search.intField("sentinel_in_share_before_enroll") == 1
    check search.intField("sentinel_in_share_before_unseal") == 0
    check search.intField("sentinel_in_share_before_refuse") == 0
    check search.intField("sentinel_hits_initrd") == 0

  test "t_remote_unseal_boot_over_a_real_socket":
    ## The same client, the same broker and the same transport, run here
    ## rather than in a guest, so the library has a consumer this suite
    ## exercises rather than one it reads about.
    ##
    ## What it adds to the pinned boot is a measurement the guest cannot
    ## make of itself: the argument vector the volume opener was handed,
    ## and the bytes it was handed on standard input.
    let dir = getTempDir() / "remote-unseal-live-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let recorder = dir / "opener.log"
    let key = "3a7b" & repeat("c4", 30)
    check key.len == ReleasedKeyChars

    var h = startBroker(harnessConfig(dir / "broker", key))
    defer: stopBroker(h)
    putEnv(RecorderLogEnv, recorder)
    defer: delEnv(RecorderLogEnv)

    let status = runRemoteUnseal(@[
      "--broker=" & h.brokerUrl,
      "--name=state-volume-key",
      "--generation=live-gate-generation",
      "--config-fingerprint=live-gate-fingerprint",
      "--verity-root-hash=" & repeat("0", 64),
      "--volume=/dev/does-not-exist:live-gate-root",
      "--cryptsetup=" & getAppFilename(),
      "--report=" & (dir / "client.txt"),
      "--timeout-seconds=20"])
    check status == ExitUnsealed

    let client = parseUnsealRecord(readFile(dir / "client.txt"))
    check brokerReleased(client)
    check openerWasExecuted(client)
    check client.field("released_key_sha256") == harnessSha256Hex(key)

    # The opener ran ONCE — once per volume, and one volume was asked
    # for. Four lines per invocation.
    let lines = recorderInvocations(recorder)
    check lines.len == 4
    check lines[0].startsWith("argv=")

    # THE KEY WAS NOT ON THE COMMAND LINE. Every process's arguments are
    # world-readable through /proc, so this is the difference between a
    # released key and a published one.
    check key notin lines[0]
    check "--key-file=-" in lines[0]
    check "/dev/does-not-exist" in lines[0]
    check "live-gate-root" in lines[0]

    # AND IT WAS ON STANDARD INPUT. The opener's own digest of what it
    # was handed is the key's digest — a fourth producer of the same
    # value, and the one that is on the other side of a process boundary.
    check lines[2] == "stdin_bytes=" & $key.len
    check lines[3] == "stdin_sha256=" & harnessSha256Hex(key)

  test "t_remote_unseal_boot_reads_a_record_that_says_so":
    ## A record that does not carry a field cannot answer a question
    ## about it. Every reader refuses rather than defaulting, because a
    ## default would make the emptiest evidence the most reassuring.
    proc refusalFor(text: string; body: proc(r: UnsealRecord)): string =
      try:
        body(parseUnsealRecord(text))
        ""
      except CatchableError as e:
        e.msg

    # A record the producer never finished writing is not a record.
    var truncated: seq[string] = @[]
    for line in RemoteUnsealUnsealReport.splitLines:
      if not line.startsWith("end="): truncated.add line
    check "is a PREFIX of a run" in
      refusalFor(truncated.join("\n"), proc(r: UnsealRecord) = discard)

    # A line that carries no key, BOTH WAYS, because there are two and
    # only one of them was here. A line with no `=` at all is one; a line
    # whose `=` is the FIRST character is the other, and it is a record
    # with an EMPTY KEY — which would otherwise be stored under "" and
    # answer to nothing. The bound is `<= 0` rather than `< 0` for
    # exactly that second case, and a mutation table measured that the
    # `== 0` half had no input at all: relaxing it to `< 0` was green on
    # every gate that built it in.
    check "carries no key" in
      refusalFor(RemoteUnsealUnsealReport & "\nthis is not a field\n",
                 proc(r: UnsealRecord) = discard)
    let emptyKeyRefusal =
      refusalFor(RemoteUnsealUnsealReport & "\n=a value with no key\n",
                 proc(r: UnsealRecord) = discard)
    check "carries no key" in emptyKeyRefusal
    # And the two are two: each refusal quotes the line that produced it,
    # so a reader can tell which input they are looking at.
    check "=a value with no key" in emptyKeyRefusal
    check "this is not a field" notin emptyKeyRefusal

    # A record with the volume fields stripped cannot be called open.
    var noVolumes: seq[string] = @[]
    for line in RemoteUnsealUnsealReport.splitLines:
      if not line.startsWith("status_") and not line.startsWith("marker_"):
        noVolumes.add line
    check "no field `status_root`" in
      refusalFor(noVolumes.join("\n"), proc(r: UnsealRecord) =
        discard stateVolumesOpen(r))

    # A record with the client's answer stripped cannot be called a
    # release.
    var noDecision: seq[string] = @[]
    for line in RemoteUnsealUnsealClientReport.splitLines:
      if not line.startsWith("unseal_decision"): noDecision.add line
    check "no field `unseal_decision`" in
      refusalFor(noDecision.join("\n"), proc(r: UnsealRecord) =
        discard brokerReleased(r))

    # A status that is not a number where one is required.
    check "is not a number" in
      refusalFor(RemoteUnsealUnsealClientReport.replace(
                   "broker_status=200", "broker_status=fine"),
                 proc(r: UnsealRecord) = discard brokerReleased(r))

    # A coverage field that is not <found>/<planted>.
    check "which is not <found>/<planted>" in
      refusalFor(RemoteUnsealSearchRecord.replace(
                   "key_coverage_initrd=5/5", "key_coverage_initrd=all"),
                 proc(r: UnsealRecord) =
                   discard coverage(r, "key_coverage_initrd"))
    check "whose halves are not numbers" in
      refusalFor(RemoteUnsealSearchRecord.replace(
                   "key_coverage_initrd=5/5", "key_coverage_initrd=five/5"),
                 proc(r: UnsealRecord) =
                   discard coverage(r, "key_coverage_initrd"))

    # A cycle record that does not say which cycle it is.
    var noCycle: seq[string] = @[]
    for line in RemoteUnsealUnsealReport.splitLines:
      if not line.startsWith("cycle="): noCycle.add line
    var cycleRefusal = ""
    try:
      discard parseCycleRecord(noCycle.join("\n"))
    except CatchableError as e:
      cycleRefusal = e.msg
    check "does not say which power cycle" in cycleRefusal
