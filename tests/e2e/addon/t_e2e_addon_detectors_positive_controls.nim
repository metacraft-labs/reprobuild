## Gate ``e2e_addon_detectors_positive_controls`` (milestone A11; spec
## §10.4, §10.5; threat model §9, DET-4, DET-5, DET-6, G22, G23, G32).
##
## The gate creates its own Evidence sink and bootstraps the guest with the
## deploy agent (30 s poll), a profile compiler (the compromised stand-in
## below, used only for DET-AO-2) and the sink (30 s heartbeat). Then, for
## each detector of threat model §9, its committed positive control:
##
## | Detector  | Control (threat model §9)                                   |
## |-----------|-------------------------------------------------------------|
## | DET-AO-1  | a manifest signed by a key the host does not anchor          |
## | DET-AO-2  | a compiled resource set writing ``/etc/shadow`` (A8's)       |
## | DET-AO-3  | a connect to a third address from inside the fetch unit     |
## | DET-AO-4  | ``/etc/repro/static`` retargeted, then a reboot             |
## | DET-AO-5  | a store file corrupted between realise and flip (A9's), and |
## |           | a store byte changed after the switch and its receipt       |
## |           | deleted, found after a boot (session 2, G2)                 |
## | DET-AO-6  | an ``equivs`` package shipping a ledger path (A10's)         |
## | DET-AO-7  | a unit whose health check fails (A5's)                       |
## | DET-AO-8  | the timers stopped: silence past three intervals            |
## | DET-AO-9  | a locally modified generation (an operator's apply)         |
## | DET-AO-10 | a frozen mirror: the producer publishes, the host is served |
## |           | the old sequence past the new one's maximum age             |
##
## Each control is checked twice: the record reaches the gate's sink (it
## left the host, DET-6), and the off-host check over the sink's store
## raises the detector's alert. Before any control the check reports every
## detector live-idle and no alert: "nothing detected" is a state the gate
## sees, distinct from the silence DET-AO-8's control produces (DET-5).
##
## The seam build is required (DET-AO-5's pause at step 2).
##
## Falsifying mutation for the DET-AO-5 boot control:
## ``store-verify-trusts-receipt`` (the expectation read from the altered
## path's own receipt, which the control deleted: the mismatch and
## quarantine steps go red; A11 audit session 2, G2). For the DET-AO-10
## control: ``lag-ignores-check-state`` (the check forgets when it first
## saw the sequence, and the manifest directory holds only the re-signed
## copy: no lag alert; A11 review finding 7).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The profile compiler is a shell script standing for a
## compromised compiler, as in A8's ``e2e_addon_compromised_fetch_cannot_
## write_etc``: the threat under test. Nothing else.

import std/[json, os, sequtils, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import repro_addon/evidence_check

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const
  Gate = "e2e_addon_detectors_positive_controls"
  Compiler = "/opt/a11/compiler"
  StandInRevision = "a11-stand-in"
  Managed = "/etc/repro/a11-managed"
  Shadow = "addOn {\n  managedEtcPrefixes = [\"/etc/shadow\"]\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/shadow\"\n  content = \"root::0:0:99999:7:::\n\"\n}\n"
  PendingMarker = "/var/lib/repro/system/addon/pending"

proc compromise(g: Guest; evil: string) =
  ## The compromised compiler: ignores its input, emits ``evil``.
  writeFile(g.runDir / "evil.canonical", evil)
  discard g.run("mkdir -p /opt/a11")
  g.copyTo(g.runDir / "evil.canonical", "/opt/a11/evil.canonical")
  discard g.run("cat > " & Compiler & " <<'EOS'\n" &
    "#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in --canonical-out) c=$2;; " &
    "--actions-out) a=$2;; --revision-out) r=$2;; esac; shift; done\n" &
    "cat /opt/a11/evil.canonical > $c\nprintf '[]' > $a\n" &
    "[ -n \"$r\" ] && echo " & StandInRevision & " > $r\nexit 0\nEOS\nchmod 0755 " &
    Compiler & " && chmod 0644 /opt/a11/evil.canonical")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags &
    " --profile-compiler " & Compiler)
  producer = bs.producer
  if not bs.ok: return
  let prod = producer        # a ref: the closures below may capture it
  let host = g.enrol(sink)
  record["guestHost"] = %host
  let signers = g.runDir / "deploy-signers.anchors"
  var sequence = 0'u64
  proc publish(spec: PublishSpec): seq[byte] =
    result = prod.publish(spec)
    sink.archive(result, spec.sequence)
  proc ship() = discard g.exec("systemctl start repro-addon-evidence.service")
  proc alerted(det, trig: string; since: uint64): bool =
    sink.check(host, signers).alerts.anyIt(it.detector == det and
      (trig.len == 0 or it.trigger == trig) and
      (it.sinkSeq == 0 or it.sinkSeq > since))
  proc control(det, detector, trigger: string; since: uint64;
               alertTrigger = ""; timeoutSec = 180) =
    ship()
    let arrived = sink.waitFor(host, detector, trigger, timeoutSec = timeoutSec,
                               since = since)
    step(det & ": the record left the host and reached the sink", arrived,
         detector & "/" & trigger)
    let t = if alertTrigger.len > 0: alertTrigger else: trigger
    step(det & ": the off-host check raises its alert", alerted(det, t, since),
         render(sink.check(host, signers)))

  # The baseline: one applied sequence, timers running, nothing detected.
  inc sequence
  discard publish(PublishSpec(sequence: sequence,
    profileText: canonicalFile(Managed, "one\n")))
  let t1 = g.tickUnits()
  step("sequence 1 is applied", t1.outcome == "aoApplied", $t1)
  discard g.exec("systemctl start repro-agent-fetch.timer")
  # The store verification's first run (its timer fires once generation 0
  # enables it, before the sink knew the host) is made explicit, so the
  # baseline does not race it.
  discard g.exec("systemctl start repro-addon-store-verify.service", timeoutSec = 1200)
  ship()
  discard sink.waitFor(host, "addon-agent-tick", "", 180)
  discard sink.waitFor(host, "addon-store", "", 180)
  let base = sink.check(host, signers)
  record["baseline"] = toJson(base)
  step("baseline: nothing detected, every detector live-idle, no alert",
       base.alerts.len == 0 and
         base.statuses.filterIt(it.detector != "check-state").allIt(
           it.status == "live-idle") and
         # The check's own state: new at its first run, nothing else.
         base.statuses.filterIt(it.detector == "check-state").allIt(
           it.status == "new"),
       render(base))
  # Stopped, settled and recorded as the tick helper's baseline: a cycle
  # the timer ran before this point cannot have applied what the gate
  # publishes next (A9 review round 7, finding 7).
  g.recordTimerBaseline()

  # DET-AO-1: a manifest signed by a key the host does not anchor.
  var since = sink.headSeq()
  let rogue = Producer(dir: producer.dir, port: producer.port,
                       signer: peerAuth.generateKeypair())
  discard rogue.publish(PublishSpec(sequence: sequence + 10,
    profileText: canonicalFile(Managed, "rogue\n")))
  let tr = g.tickUnits()
  step("DET-AO-1: the unanchored manifest is aoRejected",
       tr.outcome == "aoRejected", $tr)
  control("DET-AO-1", "addon-manifest", "addon-manifest-refused", since)

  # DET-AO-2: the compromised compiler stages /etc/shadow; signed pin.
  since = sink.headSeq()
  g.compromise(Shadow)
  inc sequence
  discard publish(PublishSpec(sequence: sequence,
    profileText: "import repro_profile\n# source (" & $sequence & ")\n",
    compiledProfile: CompiledProfilePin(
      digest: compiledProfileDigest(Shadow, "[]", "addOn\n"),
      compilerRevision: StandInRevision, platform: "linux",
      arch: "x86_64", host: CompileHost, systemMode: "addOn")))
  let t2 = g.tickUnits()
  discard g.exec("systemctl reset-failed repro-agent-apply.service")
  step("DET-AO-2: the apply unit refuses the planted set",
       t2.outcome == "aoApplyFailed", $t2)
  control("DET-AO-2", "addon-apply-refusal", "addon-staging-refused", since)

  # DET-AO-3: a connect from the fetch unit to a third address. The unit's
  # IP filter refuses it; the add-on's nftables table counts it; the check
  # that follows every fetch records it.
  since = sink.headSeq()
  let fc = g.forbiddenConnectFromFetch()
  step("DET-AO-3: the fetch unit paused and its forbidden connect was refused",
       fc.paused and fc.connect != 0, $fc)
  control("DET-AO-3", "addon-egress", "egress-refused", since)

  # DET-AO-4: a ledger link changed, then a reboot.
  since = sink.headSeq()
  let staticTarget = g.exec("readlink /etc/repro/static").stdout.strip()
  discard g.exec("ln -sfn /nonexistent-a11 /etc/repro/static")
  g.rebootGuest()
  discard g.waitReasserted()
  # A retargeted static link that dangles reads ``degraded``, one that
  # resolves ``drift``: DET-AO-4 trips on either.
  control("DET-AO-4", "addon-reassert", "", since)
  discard g.exec("ln -sfn " & staticTarget & " /etc/repro/static")

  # DET-AO-5: a store file corrupted between realise and flip.
  since = sink.headSeq()
  inc sequence
  g.armApplySeam("step-2")
  discard publish(PublishSpec(sequence: sequence,
    profileText: canonicalFile(Managed, "five\n")))
  g.startFetchNoWait()
  if g.waitSeam(ApplySeamDir, "step-2"):
    let tree = g.exec("sed -n 's/^static\\t//p' " & PendingMarker).stdout.strip()
    let file = g.exec("find " & tree & " -type f | head -1").stdout.strip()
    discard g.exec("unshare --mount --propagation private /bin/sh -c " &
      quoteShell("mount -o remount,bind,rw /repro/store && printf tampered >> " &
                 file))
    g.resumeSeam(ApplySeamDir)
  g.waitApplyIdle()
  step("DET-AO-5: the switch refuses the corrupted store path",
       "EAddOnStoreChanged" in g.lastTick().message, $g.lastTick())
  control("DET-AO-5", "addon-store", "store-changed", since)

  # DET-AO-7: a unit whose health check fails.
  since = sink.headSeq()
  inc sequence
  discard publish(PublishSpec(sequence: sequence,
    profileText: "addOn {\n  confirmTimeout = 15\n}\n\n" &
      unitProfile("repro-a11-fail.service", "/bin/sleep infinity",
                  health = "tcp:127.0.0.1:9")))
  let t7 = g.tickUnits()
  step("DET-AO-7: the failing switch is aoRolledBack",
       t7.outcome == "aoRolledBack", $t7)
  control("DET-AO-7", "addon-rollback", "rolled-back", since)

  # DET-AO-9: a locally modified generation (an operator's apply).
  since = sink.headSeq()
  let local = g.applyProfile(repro, "a11-local", canonicalFile(Managed,
    "edited locally\n"))
  step("DET-AO-9: the local apply commits", local.exitCode == 0,
       local.stdout & local.stderr)
  control("DET-AO-9", "addon-apply", "applied", since,
          alertTrigger = "unpublished-generation")

  # DET-AO-5 at boot (decision 46): one byte of the current generation's
  # store path changed after its switch committed; the verification after
  # the next boot finds it, records it and quarantines the path.
  since = sink.headSeq()
  let tree = g.exec("readlink /etc/repro/static").stdout.strip()
  let victim = g.exec("find " & tree & " -type f | head -1").stdout.strip()
  # The tree's receipt goes with the change (A11 audit session 2, G2): the
  # expected digest is the ledger's, so a deleted receipt cannot demote the
  # mismatch to "unverifiable".
  let tampered = g.exec("unshare --mount --propagation private /bin/sh -c " &
    quoteShell("mount -o remount,bind,rw /repro/store && printf X >> " &
               victim & " && rm -f " & tree & "/.repro-receipt"))
  step("DET-AO-5 (boot): a byte of the current store path was changed, " &
       "its receipt deleted",
       tampered.exitCode == 0 and victim.len > 0 and
         g.exec("test -e " & tree & "/.repro-receipt").exitCode != 0,
       victim & tampered.stderr)
  g.rebootGuest()
  discard g.waitReasserted()
  step("DET-AO-5 (boot): the boot did not wait for the verification",
       g.exec("systemctl is-active repro-addon-reassert.service").stdout.strip() in
         ["active", "inactive"], "")
  # The verification's timer fires two minutes after boot.
  control("DET-AO-5", "addon-store", "store-digest-mismatch", since,
          timeoutSec = 480)
  step("DET-AO-5 (boot): the altered path is quarantined",
       tree in g.exec("cat /var/lib/repro/system/addon/store-quarantine").stdout,
       g.exec("cat /var/lib/repro/system/addon/store-quarantine").stdout)

  # DET-AO-10: a frozen mirror. The producer publishes a newer sequence
  # with a one-minute maximum age; the host keeps being served the old one.
  since = sink.headSeq()
  let oldBytes = readFile(producer.dir / AgentTarget / "latest.rdm")
  inc sequence
  discard publish(PublishSpec(sequence: sequence,
    profileText: canonicalFile(Managed, "ten\n"), maxAgeSeconds: 60))
  writeFile(producer.dir / AgentTarget / "latest.rdm", oldBytes)
  # The check runs while the first copy is published, as a deployment's
  # periodic check would, and keeps when it saw it in its own state.
  discard sink.check(host, signers)
  sleep(75_000)
  # The producer re-signs the sequence the host is frozen below (spec §9.2
  # expects it to), and the manifest directory keeps only the re-signed
  # copy: the lag still counts from the first publication, which the
  # check's own state holds (A11 audit F1, A11 review finding 7).
  let resigned = prod.publish(PublishSpec(sequence: sequence,
    profileText: canonicalFile(Managed, "ten\n"), maxAgeSeconds: 60))
  sink.archive(resigned, sequence)
  writeFile(producer.dir / AgentTarget / "latest.rdm", oldBytes)
  discard g.tickUnits()
  ship()
  discard sink.waitFor(host, "addon-agent-tick", "", 120, since = since)
  step("DET-AO-10: the off-host check raises the lag alert, the sequence " &
       "re-signed since",
       alerted("DET-AO-10", "lag", 0), render(sink.check(host, signers)))

  # DET-AO-6: an equivs package ships a ledger path (the local
  # generation's managed file).
  since = sink.headSeq()
  g.installEquivs()
  let deb = g.buildEquivsPackage("repro-a11-fixture", "1.0",
    @[(name: "a11-managed", content: "from a package\n", destDir: "/etc/repro")])
  discard g.exec("DEBIAN_FRONTEND=noninteractive apt-get install -y -q " &
    "-o Dpkg::Options::=--force-confnew " & deb, timeoutSec = 900)
  control("DET-AO-6", "addon-apt-hook", "hook-finding", since)
  discard g.exec("DEBIAN_FRONTEND=noninteractive apt-get purge -y -q " &
                 "repro-a11-fixture", timeoutSec = 900)

  # DET-AO-8: silence. The gate drives the ticks itself (the fetch timer
  # has been stopped since the baseline), so the tick's last heartbeat is
  # as old as the controls above took -- DET-AO-6's package build alone can
  # exceed its two-interval grace on a loaded host (measured at
  # b79ceba86c, debian-13: 206 s). One tick, shipped, makes "live before
  # the silence" a statement about the host rather than about the gate's
  # pace. Then every timer stops and three intervals pass.
  let pre8 = sink.headSeq()
  discard g.tickUnits()
  ship()
  discard sink.waitFor(host, "addon-agent-tick", "", 120, since = pre8)
  discard g.exec("systemctl stop repro-agent-fetch.timer " &
                 "repro-addon-evidence.timer repro-addon-evidence.path")
  let quiet = sink.check(host, signers)
  step("DET-AO-8: before the silence, the tick and the shipping unit are live",
       quiet.statuses.filterIt(it.detector in ["addon-agent-tick",
         "addon-evidence-ship"]).allIt(it.status.startsWith("live")),
       render(quiet))
  sleep((3 * (GatePollSec + 30) + 30) * 1000)
  let silent = sink.check(host, signers)
  record["silence"] = toJson(silent)
  step("DET-AO-8: the stopped tick is silent, distinct from idle",
       silent.alerts.anyIt(it.detector == "DET-AO-8" and it.trigger == "silent"),
       render(silent))

suite Gate:
  test "every detector fires on its positive control":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
