## The broker said no, and the disk stayed shut.
##
## ## The claim, which is THREE claims
##
## A machine that cannot unlock its own volumes asked a broker for the
## key and was turned down. Three things had to happen, and they are
## asserted separately because they are separate:
##
##   1. **The broker refused.** It answered, it decided, and it declined
##      — status 403, `release-status`, `withheld` in its own record.
##   2. **The state volumes stayed locked.** No device-mapper entry, both
##      volumes inactive, and the marker inside each one unreadable — on
##      a real LUKS2 volume that turned a real unlock attempt away.
##   3. **The boot did not continue.** The root filesystem lives inside
##      the encrypted volume, and it did not run.
##
## **A refusal without the second is a real vulnerability, not a partial
## success.** A machine whose client says "no" and whose disk opens
## anyway is worse than one with no client at all: it has the appearance
## of enforcement and none of the substance, and every operator who reads
## the refusal will believe the data was protected.
##
## ## Why the checks cannot stand in for one another
##
## This is not argued, and it is not established by reading the source.
## It is established by a REAL BOOT in which the answers differ.
##
## `UnlockedDespiteRefusal*` is a second full run of the same harness
## whose initramfs carries a local copy of the volume key — which is the
## arrangement remote unsealing removes — and whose init falls back to it
## when the client comes back empty-handed. The SAME broker produced the
## SAME refusal, with the same status and the same sentence, and the
## machine then opened both volumes and came up. Fed to the three
## predicates:
##
## | run                       | refused? | locked? | came up? |
## |---|---|---|---|
## | the refused boot          | TRUE     | TRUE    | FALSE    |
## | the locally-keyed boot    | TRUE     | **FALSE** | **TRUE** |
## | the ordinary unseal       | FALSE    | FALSE   | TRUE     |
##
## Rows one and two share a refusal and disagree about both the lock and
## the boot, so neither is a function of the refusal. Rows two and three
## share a lock state and a boot and disagree about the refusal, so the
## refusal is not a function of either. None is constant.
##
## ## And the client never ran the opener at all
##
## The pinned records say `opener_ran=0` on both refused boots, and a
## live case here measures the same thing from outside the program: a
## refusing broker, a `--cryptsetup` that records every invocation, and
## an empty record — with a releasing broker filling the same record as
## the positive control.
##
## ## What this gate does NOT prove
##
## The machine's root of trust is a software one and the broker's verdict
## says so; see `t_remote_unseal_boot`. The two refused boots are two
## different machines with two different volumes, and they have to be: a
## machine that never cached the key cannot be made to have cached it
## after the fact. What they share is the image recipe, the broker, the
## policy and the refusal.
##
## ## Mocking
##
## The live cases execute a recorder in place of the volume opener,
## because what they measure is whether a process was created at all.
## See `remote_unseal_harness`. The pinned records come from real guests
## and real LUKS2 volumes.

import std/[os, strutils, times, unittest]

import repro_attest
import repro_attest/x25519_kem
import repro_attest_agent/agent
import repro_attest_agent/remote_unseal
import repro_attest_agent/unseal_cli

import ./remote_unseal_harness

include ./remote_unseal_evidence

runAsRecorderIfAsked()

suite "a broker's refusal leaves the volumes locked and the boot failed":

  test "t_remote_unseal_broker_refusal_fails_closed":
    let guest = parseCycleRecord(RemoteUnsealRefuseReport)
    let client = parseUnsealRecord(RemoteUnsealRefuseClientReport)
    let broker = parseUnsealRecord(RemoteUnsealRefuseBrokerRecord)
    let search = parseUnsealRecord(RemoteUnsealSearchRecord)
    check guest.cycle == "refuse"

    # ---- CLAIM ONE: the broker refused, and for the right reason -----
    check brokerRefused(client)
    check not brokerReleased(client)
    check client.intField("broker_status") == BrokerRefusedStatus
    check client.field("unseal_refusal") == $urReleaseStatus
    check broker.field("release_decision") == "withheld"
    check broker.field("outcome") == "withheld"
    check broker.intField("wrapped_bytes") == 0
    check client.intField("released_key_bytes") == 0
    check client.field("released_key_sha256") == "-"
    check client.intField("exit") == ExitBrokerRefused
    # The client did not even run the volume opener. Its own account of
    # the thing the live case below measures from outside.
    check not openerWasExecuted(client)
    check volumesOpenedByClient(client) == 0

    # ---- CLAIM TWO: the volumes stayed shut --------------------------
    # Read from fields the refusal check never touches, in a record the
    # client did not write.
    check stateVolumesLocked(guest)
    check not stateVolumesOpen(guest)
    check guest.field("mapper_entries") == ""
    for v in StateVolumes:
      check guest.field("status_" & $v) == "inactive"
      check guest.marker(v) == "-"
      # The attempt REACHED the key slots and was turned away there:
      # these are real LUKS2 volumes refusing a wrong key, not a step
      # this experiment skipped.
      check carriesLuksSignature(guest, v)
    check probeReachedTheKeySlots(guest)
    check not probeOpenedTheVolumes(guest)
    check guest.field("probe_key_source") == "zero-filled"

    # ---- CLAIM THREE: the machine did not come up --------------------
    # The root filesystem is inside the encrypted volume. It did not run,
    # and the sentinel it would have printed is in no other place the
    # machine could have printed it from.
    check not bootReachedEncryptedRoot(search, "refuse")
    check search.intField("console_sentinel_refuse") == 0
    check search.intField("rootfs_report_refuse") == 0
    check search.intField("handoff_refuse") == 0
    check search.intField("sentinel_hits_initrd") == 0
    check search.intField("sentinel_in_share_before_refuse") == 0
    check guest.field("boot_outcome") == "failed"
    check guest.intField("sysroot_mounted") == 0
    check guest.intField("switch_root_attempted") == 0

    # ---- and this machine had no second way in -----------------------
    check machineHasNoLocalRootOfTrust(guest)
    check not machineCarriesALocalKey(guest)

  test "t_remote_unseal_broker_refusal_refused_does_not_imply_locked":
    ## THE CONTROL, and the reason this gate exists in the shape it does.
    ##
    ## A real boot of the same image recipe, refused by the same broker
    ## with the same status and the same sentence, whose volumes opened
    ## anyway and whose machine came up. The refusal check must still say
    ## TRUE on it; the other two must say the opposite of what they say
    ## above.
    let guest = parseCycleRecord(UnlockedDespiteRefusalReport)
    let client = parseUnsealRecord(UnlockedDespiteRefusalClientReport)
    let broker = parseUnsealRecord(UnlockedDespiteRefusalBrokerRecord)
    let search = parseUnsealRecord(UnlockedDespiteRefusalSearchRecord)
    let rootfs = parseCycleRecord(UnlockedDespiteRefusalRootfsReport)
    check guest.cycle == "refuse"

    # Same refusal. Same status, same client verdict, same broker
    # sentence, same rule of the library declining.
    let honest = parseUnsealRecord(RemoteUnsealRefuseClientReport)
    let honestBroker = parseUnsealRecord(RemoteUnsealRefuseBrokerRecord)
    check brokerRefused(client)
    check client.intField("broker_status") ==
      honest.intField("broker_status")
    check client.field("unseal_refusal") == honest.field("unseal_refusal")
    check broker.field("release_reason") ==
      honestBroker.field("release_reason")
    check broker.field("verdict") == honestBroker.field("verdict")
    check broker.intField("require_root_of_trust") == 1
    # The client still opened nothing; the machine did it afterwards,
    # with a key of its own.
    check not openerWasExecuted(client)
    check volumesOpenedByClient(client) == 0

    # DIFFERENT OUTCOME. THIS IS THE VULNERABILITY.
    check not stateVolumesLocked(guest)
    check stateVolumesOpen(guest)
    check machineCarriesALocalKey(guest)
    check guest.field("probe_key_source") == "cached-local-key"
    check probeOpenedTheVolumes(guest)
    check not probeReachedTheKeySlots(guest)
    for v in StateVolumes:
      check guest.marker(v).len == 64
      check guest.marker(v) != "-"

    # AND IT CAME UP. The sentinel that only exists inside the encrypted
    # volume reached this machine's console.
    check bootReachedEncryptedRoot(search, "refuse")
    check guest.field("boot_outcome") == "handing-off"
    check rootfs.field("rootfs_marker") == guest.marker(uvRoot)
    check rootfs.field("rootfs_sentinel_sha256") ==
      search.field("sentinel_sha256")

    # The honest refused boot disagrees with it on exactly the second and
    # third questions, and agrees on the first.
    let honestGuest = parseCycleRecord(RemoteUnsealRefuseReport)
    let honestSearch = parseUnsealRecord(RemoteUnsealSearchRecord)
    check brokerRefused(honest) == brokerRefused(client)
    check stateVolumesLocked(honestGuest) != stateVolumesLocked(guest)
    check bootReachedEncryptedRoot(honestSearch, "refuse") !=
      bootReachedEncryptedRoot(search, "refuse")

    # AND THE ONE THING THAT DIFFERS BETWEEN THE TWO MACHINES is the
    # local copy of the key, which is what makes this a control rather
    # than an unrelated run.
    check machineCarriesALocalKey(honestGuest) == false
    check search.intField("local_key_fallback") == 1
    check honestSearch.intField("local_key_fallback") == 0
    check search.intField("key_hits_initrd") == 1
    check honestSearch.intField("key_hits_initrd") == 0

  test "t_remote_unseal_broker_refusal_no_check_is_constant":
    ## Each predicate is exercised in both directions by real boots, so
    ## none is a function that returns the answer this gate wants.
    let refused = parseUnsealRecord(RemoteUnsealRefuseClientReport)
    let unlocked = parseUnsealRecord(UnlockedDespiteRefusalClientReport)
    let released = parseUnsealRecord(RemoteUnsealUnsealClientReport)
    let refusedGuest = parseCycleRecord(RemoteUnsealRefuseReport)
    let unlockedGuest = parseCycleRecord(UnlockedDespiteRefusalReport)
    let releasedGuest = parseCycleRecord(RemoteUnsealUnsealReport)
    let honestSearch = parseUnsealRecord(RemoteUnsealSearchRecord)
    let controlSearch = parseUnsealRecord(UnlockedDespiteRefusalSearchRecord)

    # The refusal check: TRUE on two boots, FALSE on one.
    check brokerRefused(refused)
    check brokerRefused(unlocked)
    check not brokerRefused(released)
    check brokerReleased(released)

    # The lock check: TRUE on one, FALSE on two.
    check stateVolumesLocked(refusedGuest)
    check not stateVolumesLocked(unlockedGuest)
    check not stateVolumesLocked(releasedGuest)

    # The boot check: FALSE on one, TRUE on two.
    check not bootReachedEncryptedRoot(honestSearch, "refuse")
    check bootReachedEncryptedRoot(controlSearch, "refuse")
    check bootReachedEncryptedRoot(honestSearch, "unseal")

    # The pairs that break each functional dependency.
    check brokerRefused(refused) == brokerRefused(unlocked)
    check stateVolumesLocked(refusedGuest) != stateVolumesLocked(unlockedGuest)
    check stateVolumesLocked(unlockedGuest) == stateVolumesLocked(releasedGuest)
    check brokerRefused(unlocked) != brokerRefused(released)

    # "Released" is NOT the negation of "refused". A client that failed
    # for some other reason is neither, and this is the only input in the
    # evidence that can tell the two definitions apart — so it is
    # constructed, and labelled as constructed. It is not a claim about a
    # machine: it is the input the distinction needs.
    let unreachable = RemoteUnsealRefuseClientReport
      .replace("unseal_refusal=" & $urReleaseStatus,
               "unseal_refusal=" & $urBrokerUnreachable)
      .replace("broker_status=" & $BrokerRefusedStatus, "broker_status=0")
    check unreachable != RemoteUnsealRefuseClientReport
    let neither = parseUnsealRecord(unreachable)
    check not brokerRefused(neither)
    check not brokerReleased(neither)

  test "t_remote_unseal_broker_refusal_each_reading_can_say_no_on_its_own":
    ## "The volumes stayed locked" rests on THREE readings and "the
    ## machine did not come up" on three more, and each has to be able to
    ## answer on its own or it is decoration. On a machine that behaves,
    ## the readings move together — every real record here has them
    ## agreeing — so no captured boot can tell them apart.
    ##
    ## The records below are therefore CONSTRUCTED, edited field by field
    ## out of the real refused boot's records, and they are labelled as
    ## such rather than dressed up as captures. A machine whose
    ## bookkeeping says shut while its plaintext is readable is the
    ## failure the marker reading exists for, and it is not a failure any
    ## correct machine will ever demonstrate.
    let real = RemoteUnsealRefuseReport
    check stateVolumesLocked(parseUnsealRecord(real))

    let mapperLeft = real.replace("mapper_entries=",
                                  "mapper_entries=reproos-state-root,")
    check mapperLeft != real
    check not stateVolumesLocked(parseUnsealRecord(mapperLeft))

    let statusActive = real.replace("status_root=inactive",
                                    "status_root=active")
    check statusActive != real
    check not stateVolumesLocked(parseUnsealRecord(statusActive))

    let markerReadable = real.replace("marker_root=-",
      "marker_root=" & repeat("ab", 32))
    check markerReadable != real
    check not stateVolumesLocked(parseUnsealRecord(markerReadable))

    # Each edit moved exactly one reading: the other two still say shut.
    for edited in [mapperLeft, statusActive, markerReadable]:
      let r = parseUnsealRecord(edited)
      check r.field("status_home") == "inactive"
      check r.marker(uvHome) == "-"

    # THE OTHER VOLUME HAS TO BE ABLE TO MOVE THE ANSWER ON ITS OWN.
    # Every edit above is on the root volume, and every real record has
    # the two agreeing, so nothing so far distinguished "both volumes"
    # from "the first volume twice".
    let homeActive = real.replace("status_home=inactive",
                                  "status_home=active")
    check homeActive != real
    check not stateVolumesLocked(parseUnsealRecord(homeActive))
    check parseUnsealRecord(homeActive).field("status_root") == "inactive"
    let homeReadable = real.replace("marker_home=-",
      "marker_home=" & repeat("cd", 32))
    check homeReadable != real
    check not stateVolumesLocked(parseUnsealRecord(homeReadable))
    check parseUnsealRecord(homeReadable).marker(uvRoot) == "-"

    # And the mirror of it for the OPEN predicate, over the control's
    # record, which needs each of its clauses given an input for the same
    # reason.
    let open = UnlockedDespiteRefusalReport
    let openRec = parseUnsealRecord(open)
    check stateVolumesOpen(openRec)
    let markerGone = open.replace(
      "marker_root=" & openRec.marker(uvRoot), "marker_root=-")
    check markerGone != open
    check not stateVolumesOpen(parseUnsealRecord(markerGone))
    let mapperGone = open.replace(
      "mapper_entries=" & openRec.field("mapper_entries"), "mapper_entries=")
    check mapperGone != open
    check not stateVolumesOpen(parseUnsealRecord(mapperGone))
    let statusInactive = open.replace("status_root=active",
                                      "status_root=inactive")
    check statusInactive != open
    check not stateVolumesOpen(parseUnsealRecord(statusInactive))

    # THE BOOT CHECK's three readings, the same way. A console that
    # printed the sentinel while no record was written, or a record
    # written with no handoff, is a contradiction rather than a machine
    # that came up, and the predicate must decline both.
    let search = UnlockedDespiteRefusalSearchRecord
    check bootReachedEncryptedRoot(parseUnsealRecord(search), "refuse")
    for edit in ["console_sentinel_refuse=1|console_sentinel_refuse=0",
                 "rootfs_report_refuse=1|rootfs_report_refuse=0",
                 "handoff_refuse=1|handoff_refuse=0"]:
      let parts = edit.split('|')
      let edited = search.replace(parts[0], parts[1])
      check edited != search
      check not bootReachedEncryptedRoot(parseUnsealRecord(edited), "refuse")

    # And the LUKS signature reading, which every real record satisfies
    # and which therefore never said no to anything. A block device that
    # carries no LUKS2 header is not a state volume that stayed locked —
    # it is a different disk, or a wiped one.
    check carriesLuksSignature(parseUnsealRecord(real), uvRoot)
    let notLuks = real.replace("raw_magic_root=" & LuksSignatureHex,
                               "raw_magic_root=000000000000")
    check notLuks != real
    check not carriesLuksSignature(parseUnsealRecord(notLuks), uvRoot)
    check carriesLuksSignature(parseUnsealRecord(notLuks), uvHome)

    # And the probe, whose two clauses separate "nothing was asked" from
    # "something was asked and turned away".
    check probeReachedTheKeySlots(parseUnsealRecord(real))
    let probeSkipped = real.replace("probe_ran=1", "probe_ran=0")
    check probeSkipped != real
    check not probeReachedTheKeySlots(parseUnsealRecord(probeSkipped))
    let probeOpenedRoot = real.replace("probe_root_rc=2", "probe_root_rc=0")
    check probeOpenedRoot != real
    check not probeReachedTheKeySlots(parseUnsealRecord(probeOpenedRoot))
    let probeOpenedHome = real.replace("probe_home_rc=2", "probe_home_rc=0")
    check probeOpenedHome != real
    check not probeReachedTheKeySlots(parseUnsealRecord(probeOpenedHome))

  test "t_remote_unseal_broker_refusal_never_executes_the_opener":
    ## Measured from OUTSIDE the program, in one shell, against one
    ## recorder file used by both halves.
    ##
    ## A refusing broker, then a releasing one. The file is empty after
    ## the first and carries an invocation after the second, so "nothing
    ## was executed" is a measurement rather than a property of an
    ## instrument that never records anything.
    let dir = getTempDir() / "remote-unseal-refuse-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let recorder = dir / "opener.log"
    let key = "9f1e" & repeat("77", 30)

    putEnv(RecorderLogEnv, recorder)
    defer: delEnv(RecorderLogEnv)

    proc attempt(h: BrokerHarness; report: string): int =
      runRemoteUnseal(@[
        "--broker=" & h.brokerUrl,
        "--name=state-volume-key",
        "--generation=refusal-gate-generation",
        "--config-fingerprint=refusal-gate-fingerprint",
        "--verity-root-hash=" & repeat("0", 64),
        "--volume=/dev/does-not-exist:refusal-gate-root",
        "--cryptsetup=" & getAppFilename(),
        "--report=" & (dir / report),
        "--timeout-seconds=20"])

    # ---- the refusal -------------------------------------------------
    var refusing = startBroker(harnessConfig(dir / "refusing", key,
                                             requireRootOfTrust = true))
    let refusedStatus = attempt(refusing, "refused.txt")
    stopBroker(refusing)
    check refusedStatus == ExitBrokerRefused
    let refusedClient = parseUnsealRecord(readFile(dir / "refused.txt"))
    check brokerRefused(refusedClient)
    check refusedClient.field("unseal_refusal") == $urReleaseStatus
    check not openerWasExecuted(refusedClient)

    # NOTHING WAS EXECUTED.
    check recorderInvocations(recorder).len == 0

    # ---- the positive control, same recorder, same file --------------
    var releasing = startBroker(harnessConfig(dir / "releasing", key))
    let releasedStatus = attempt(releasing, "released.txt")
    stopBroker(releasing)
    check releasedStatus == ExitUnsealed
    let releasedClient = parseUnsealRecord(readFile(dir / "released.txt"))
    check brokerReleased(releasedClient)
    check openerWasExecuted(releasedClient)

    let lines = recorderInvocations(recorder)
    check lines.len == 4
    check "--key-file=-" in lines[0]
    check lines[3] == "stdin_sha256=" & harnessSha256Hex(key)

    # ---- and the rule about WHICH program, at its call site ----------
    # `requireAbsoluteOpener` is tested directly elsewhere. Directly is
    # not enough: a rule that holds as a function and is not called is a
    # rule the program does not have, and deleting the call from
    # `openVolume` left every gate green. So the whole command is run
    # once more, with a broker that RELEASES and an opener named the way
    # an initramfs with a wrong `PATH` would name it. Nothing may be
    # executed — the recorder gains no line — and the client must say
    # why.
    let before = recorderInvocations(recorder).len
    var releasingAgain = startBroker(harnessConfig(dir / "relative", key))
    let relativeStatus = runRemoteUnseal(@[
      "--broker=" & releasingAgain.brokerUrl,
      "--name=state-volume-key",
      "--generation=refusal-gate-generation",
      "--config-fingerprint=refusal-gate-fingerprint",
      "--verity-root-hash=" & repeat("0", 64),
      "--volume=/dev/does-not-exist:refusal-gate-root",
      "--cryptsetup=" & getAppFilename().extractFilename,
      "--report=" & (dir / "relative.txt"),
      "--timeout-seconds=20"])
    stopBroker(releasingAgain)
    # The broker DID release — this is not the refusal path — and the
    # volume still did not open, which is the fourth exit code and not
    # the third.
    check relativeStatus == ExitVolumeWouldNotOpen
    let relativeClient = parseUnsealRecord(readFile(dir / "relative.txt"))
    check brokerReleased(relativeClient)
    check "is not an absolute path" in
      relativeClient.field("open_error_refusal-gate-root")
    check recorderInvocations(recorder).len == before

    # ---- and the rule about /proc, at ITS call site ------------------
    # Same shape, same repair. `requireKeyNotOnCommandLine` is tested
    # directly elsewhere, and deleting its CALL from `openVolume` was
    # green on every gate too — because `unlockArguments` cannot put the
    # key in the vector, so today the call is belt-and-braces over a
    # constructor that does not need it. It is not unreachable, though:
    # the DEVICE is operator-supplied and goes into the vector verbatim,
    # so a device named the same as the key is an argument carrying the
    # key, which is exactly what the rule refuses. The refusal happens
    # BEFORE a process exists, and the recorder is what says so.
    let beforeArgv = recorderInvocations(recorder).len
    var argvRefusal = ""
    try:
      discard openVolume(getAppFilename(), vaOpen,
                         VolumeSpec(device: key, mapping: "argv-gate"), key)
    except ValueError as err:
      argvRefusal = err.msg
    check "world-readable through" in argvRefusal
    check recorderInvocations(recorder).len == beforeArgv
    # And the same call with a device that does NOT carry the key really
    # does create a process, so the line above measures a refusal rather
    # than an opener that never runs.
    discard openVolume(getAppFilename(), vaOpen,
                       VolumeSpec(device: "/dev/does-not-exist",
                                  mapping: "argv-gate"), key)
    check recorderInvocations(recorder).len == beforeArgv + 4

    # The broker's own records agree about which of the two happened, and
    # the refusing one is the library's rule declining rather than a
    # status this harness chose.
    let refusedRecord = parseUnsealRecord(
      readFile(dir / "refusing" / "broker-1.txt"))
    let releasedRecord = parseUnsealRecord(
      readFile(dir / "releasing" / "broker-1.txt"))
    check refusedRecord.field("release_decision") == "withheld"
    check releasedRecord.field("release_decision") == "released"
    check refusedRecord.field("verdict") == releasedRecord.field("verdict")
    check "deliberate opt-in this request did not make" in
      refusedRecord.field("release_reason")

  test "t_remote_unseal_broker_refusal_has_no_key_to_open_with":
    ## The fail-closed property at the seam it lives at, rather than at
    ## the program that consumes it.
    ##
    ## A refused outcome has no key field. That is checked in three ways:
    ## the accessor declines to run its body, the field does not exist on
    ## the branch, and the field that DOES exist on the other branch is
    ## not reachable from outside the module at all.
    var refusing = startBroker(harnessConfig(
      getTempDir() / "remote-unseal-seam-" & $getCurrentProcessId(),
      "9f1e" & repeat("77", 30), requireRootOfTrust = true))
    defer:
      stopBroker(refusing)
      removeDir(getTempDir() / "remote-unseal-seam-" &
                $getCurrentProcessId())
    let outcome = performRemoteUnseal(
      newHttpUnsealTransport(refusing.brokerUrl),
      newMockDriver(), newX25519KeySource(),
      AgentIdentity(generation: "seam-gate-generation",
                    configFingerprint: "seam-gate-fingerprint",
                    verityRootHash: repeat("0", 64)),
      "state-volume-key", int64(epochTime() * 1000.0))
    check outcome.decision == udRefused
    check outcome.refusal == urReleaseStatus
    check outcome.brokerStatus == BrokerRefusedStatus

    # The accessor is the only way to a key, and it did not run.
    var bodyRuns = 0
    check outcome.withReleasedKey(proc (key: string) = inc bodyRuns) == false
    check bodyRuns == 0

    # The instrument: these DO compile, so a `not compiles` below is
    # about the field rather than about the spelling.
    check compiles(outcome.brokerStatus)
    check compiles(outcome.decision)
    check compiles(outcome.reason)
    check compiles(outcome.releasedKeyBytes)
    # And this does not, because the field is unexported. There is no
    # spelling outside `remote_unseal` that reaches a released key except
    # through the accessor above.
    check not compiles(outcome.releasedKey)

    # A refusal has no key to withhold, and says everything it has. The
    # `repr` that keeps a released key out of a log must not also keep
    # the one thing a refused boot is worth reading.
    check ("refusal: " & $urReleaseStatus) in repr(outcome)
    check "the broker refused to release" in repr(outcome)
    check WithheldKeyMark notin repr(outcome)
    check "releasedKey" notin repr(outcome)

    # AND THE CLIENT REACHED NO VERDICT. "It decides nothing" is one of
    # this module's headline claims and it needs a case: an outcome with
    # a verdict, a policy or a failed-check list on it would be a client
    # that had done the broker's job, and none of those spellings
    # compiles. The four positive controls above are what make these
    # three statements about the TYPE rather than about the spelling.
    check not compiles(outcome.verdict)
    check not compiles(outcome.policy)
    check not compiles(outcome.failedChecks)
