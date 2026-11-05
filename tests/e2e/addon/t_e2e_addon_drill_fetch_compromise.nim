## Drill ``addon_drill_report`` (milestone A11, MS-1 row 6; threat model
## §2 "Fetch/compile unit", DET-AO-2, EVID-1, EVID-5): a simulated
## compromise of the deploy agent's fetch unit with a planted payload,
## from detection to verified recovery, in a VM the drill creates.
##
## Timeline (each phase is a record entry with its UTC time and the sink
## sequence numbers of the evidence it produced):
##
## 1. ``setup``: the gate's own Evidence sink; the guest bootstrapped with
##    the deploy agent, a profile compiler and the sink; sequence 1 applied
##    through an honest compile (the stand-in reproduces the producer's pin).
## 2. ``compromise``: the fetch unit's compiler is replaced by one that, for
##    whatever source it is given, emits a resource set planting a root cron
##    job (``/etc/cron.d/a11-drill``, writing ``/run/a11-drill-owned``) --
##    the planted payload. The producer publishes sequence 2, pinned to the
##    honest compile.
## 3. ``detection``: the apply unit refuses the staged set (its digest is
##    not the pin); the refusal record, carrying the planted bytes, reaches
##    the sink, and the off-host check raises DET-AO-2.
## 4. ``investigation``: with ``REPRO_ADDON_DRILL_HOLD=1`` the drill stops
##    here and hands the run to an investigating agent (see
##    ``<run dir>/drill/README`` written below): it reads the sink store
##    locally, runs commands in the guest through a request directory, and
##    copies files out; it ends the hold by creating ``drill/continue``.
##    Without the hold, the drill's own scripted investigation runs: it
##    finds the refusal by its sink sequence, the payload in it, and the
##    preserved staged copy on the guest.
## 5. ``containment``: the fetch timer is stopped (no more network-fed
##    input), the preserved staging copy is taken off the host (EVID-5),
##    and the host is shown on its last good generation with the payload
##    absent.
## 6. ``recovery``: the honest compiler is restored, the producer publishes
##    sequence 3, it applies; the off-host check finds the new generation's
##    attestation matching the producer's publication and the host live.
##
## The record (``build/addon-gates/records/``) is the drill report's
## evidence: ``reprobuild-pm/spec/Test-Designs`` holds the report
## template the investigator fills in.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The compiler is a shell script standing for a compromised
## one: the compromise under drill. Nothing else.

import std/[json, os, sequtils, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest
import repro_peer_cache/evidence

import repro_addon/evidence_check

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const
  Gate = "addon_drill_report"
  Compiler = "/opt/a11/compiler"
  StandInRevision = "a11-drill-stand-in"
  Honest = "fs.systemFile {\n  path = \"/etc/repro/a11-drill\"\n" &
    "  content = \"honest\n\"\n}\n"
  Planted = "addOn {\n  managedEtcPrefixes = [\"/etc/cron.d/\"]\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/cron.d/a11-drill\"\n" &
    "  content = \"* * * * * root touch /run/a11-drill-owned\n\"\n}\n"

proc installCompiler(g: Guest; emits: string) =
  ## The fetch unit's profile compiler: emits ``emits`` whatever its input.
  writeFile(g.runDir / "emits.canonical", emits)
  discard g.run("mkdir -p /opt/a11")
  g.copyTo(g.runDir / "emits.canonical", "/opt/a11/emits.canonical")
  discard g.run("cat > " & Compiler & " <<'EOS'\n" &
    "#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in --canonical-out) c=$2;; " &
    "--actions-out) a=$2;; --revision-out) r=$2;; esac; shift; done\n" &
    "cat /opt/a11/emits.canonical > $c\nprintf '[]' > $a\n" &
    "[ -n \"$r\" ] && echo " & StandInRevision & " > $r\nexit 0\nEOS\nchmod 0755 " &
    Compiler & " && chmod 0644 /opt/a11/emits.canonical")

proc pinOf(text: string): CompiledProfilePin =
  CompiledProfilePin(digest: compiledProfileDigest(text, "[]", "addOn\n"),
    compilerRevision: StandInRevision, platform: "linux", arch: "x86_64",
    host: CompileHost, systemMode: "addOn")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let timeline = newJArray()
  record["timeline"] = timeline
  proc phase(name: string; extra: JsonNode = newJObject()) =
    var e = %*{"phase": name, "utc": $now().utc}
    for k, v in extra: e[k] = v
    timeline.add(e)
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  g.installCompiler(Honest)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags &
    " --profile-compiler " & Compiler)
  producer = bs.producer
  if not bs.ok: return
  let prod = producer
  let host = g.enrol(sink)
  let signers = g.runDir / "deploy-signers.anchors"
  proc publish(sequence: uint64) =
    let bytes = prod.publish(PublishSpec(sequence: sequence,
      profileText: "import repro_profile\n# drill source (" & $sequence & ")\n",
      compiledProfile: pinOf(Honest)))
    sink.archive(bytes, sequence)
  proc ship() = discard g.exec("systemctl start repro-addon-evidence.service")

  # 1. setup
  publish(1)
  let t1 = g.tickUnits()
  step("setup: sequence 1 applies through the honest compile",
       t1.outcome == "aoApplied", $t1)
  ship()
  let fp0 = g.takeFingerprint(repro)
  phase("setup", %*{"sinkHost": sink.hostId, "guestHost": host,
                    "sinkStore": sink.storeDir})

  # 2. compromise: the planted payload.
  let before = sink.headSeq()
  g.installCompiler(Planted)
  publish(2)
  phase("compromise", %*{"payload": Planted, "payloadPath": "/etc/cron.d/a11-drill"})

  # 3. detection
  let t2 = g.tickUnits()
  discard g.exec("systemctl reset-failed repro-agent-apply.service")
  step("detection: the apply unit refuses the planted set",
       t2.outcome == "aoApplyFailed" and "EAddOnCompiledProfile" in t2.message, $t2)
  ship()
  step("detection: the refusal left the host", sink.waitFor(host,
       "addon-apply-refusal", "addon-staging-refused", 180, since = before), "")
  var evidenceIds: seq[uint64]
  var payloadSeen = false
  for e in sink.entries():
    if e.seq > before and e.kind == ekRecord and
        e.record.trigger == "addon-staging-refused":
      evidenceIds.add(e.seq)
      payloadSeen = payloadSeen or cast[string](e.record.payload) == Planted
  step("detection: the record carries the planted bytes (EVID-1)", payloadSeen, "")
  let alerts = sink.check(host, signers).alerts.filterIt(
    it.detector == "DET-AO-2" and it.sinkSeq > before)
  step("detection: the off-host check raises DET-AO-2", alerts.len > 0,
       render(sink.check(host, signers)))
  phase("detection", %*{"evidenceIds": evidenceIds,
                        "alerts": alerts.mapIt(it.trigger)})

  # 4. investigation
  let drill = g.runDir / "drill"
  createDir(drill)
  if getEnv("REPRO_ADDON_DRILL_HOLD") == "1":
    writeFile(drill / "README",
      "Add-on drill: investigation hold.\n\n" &
      "Sink store (read it locally): " & sink.storeDir & "\n" &
      "Sink tool: " & sinkBinary() & " read --dir " & sink.storeDir & "\n" &
      "Off-host check: " & sinkBinary() & " addon-check --dir " &
        sink.storeDir & " --hosts " & drill / "hosts" & " --manifests " &
        sink.published & " --deploy-signers " & signers & "\n" &
      "Evidence ids of the detection: " & evidenceIds.mapIt($it).join(" ") & "\n" &
      "Run a command in the guest: write " & drill / "requests/<n>.sh" &
        " and read <n>.out\n" &
      "Copy a guest path out: write the path to " & drill / "requests/<n>.copy" & "\n" &
      "Preserved staging on the guest: /var/lib/repro/agent/refused/\n" &
      "Containment and recovery run after you create " & drill / "continue" &
        " (or do them yourself first; the drill checks the result).\n")
    writeFile(drill / "hosts", host & " " & AgentTarget & "\n")
    let holdSec = try: parseInt(getEnv("REPRO_ADDON_DRILL_HOLD_SEC", "14400"))
                  except ValueError: 14400
    echo "drill: holding for the investigator; see ", drill / "README"
    g.serveRequests(drill, drill / "continue", holdSec)
    step("investigation: the investigator ended the hold",
         fileExists(drill / "continue"), "hold timed out")
    if fileExists(drill / "findings.json"):
      record["investigatorFindings"] = parseJson(readFile(drill / "findings.json"))
  else:
    let refused = g.exec("ls -1 /var/lib/repro/agent/refused/").stdout.strip()
    step("investigation: the refused staging copy is preserved on the host",
         refused.len > 0, refused)
  phase("investigation")

  # 5. containment
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  let snap = drill / "snapshot"
  createDir(snap)
  try:
    g.copyFrom("/var/lib/repro/agent/refused", snap)
    step("containment: the preserved staging copy is off the host",
         walkDirRec(snap).toSeq.len > 0, snap)
  except CatchableError as e:
    step("containment: the preserved staging copy is off the host", false, e.msg)
  step("containment: the payload never landed",
       g.exec("test ! -e /etc/cron.d/a11-drill && test ! -e /run/a11-drill-owned").exitCode == 0, "")
  let id = identityReport(fp0, g.takeFingerprint(repro))
  step("containment: the host is on its last good generation (fingerprint unchanged)",
       id.ok, id.text)
  phase("containment", %*{"snapshot": snap})

  # 6. recovery
  let beforeRecovery = sink.headSeq()
  g.installCompiler(Honest)
  publish(3)
  let t3 = g.tickUnits()
  step("recovery: sequence 3 applies through the honest compile",
       t3.outcome == "aoApplied", $t3)
  discard g.exec("systemctl start repro-agent-fetch.timer")
  ship()
  discard sink.waitFor(host, "addon-apply", "applied", 180, since = beforeRecovery)
  let r = sink.check(host, signers)
  step("recovery: no attestation alert for the recovered generation",
       not r.alerts.anyIt(it.detector == "DET-AO-9" and it.sinkSeq > beforeRecovery),
       render(r))
  step("recovery: the host's tick is live", r.statuses.anyIt(
       it.detector == "addon-agent-tick" and it.status.startsWith("live")), render(r))
  phase("recovery", %*{"alerts": r.alerts.mapIt(it.detector & "/" & it.trigger)})

suite Gate:
  test "the drill: a compromised fetch unit, from detection to recovery":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
