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
## 5. ``containment``: ``repro system addon contain`` -- its signed record
##    reaches the sink before the agent stops; the fetch timer and units
##    do not start while contained (a start is skipped on the containment
##    condition); the off-host check reports the agent ``contained``, not
##    silent, even after its silence window; the preserved staging copy the
##    refusal record names is taken off the host (EVID-5); the host is shown
##    on its last good generation with the payload absent. The check must
##    print exactly the refusal alerts the drill caused (computed from the
##    sink's entries) and no other; an acknowledgement of another kind at a
##    refusal's sequence leaves it alerting; the investigator then
##    acknowledges exactly those refusals at the sink
##    (``repro-evidence-sink ack``), never whatever the check printed.
## 6. ``recovery``: the honest compiler is restored, ``repro system addon
##    release`` resumes the agent, the producer publishes sequence 3 and the
##    natural tick applies it; the documented off-host check, run as the
##    user guide prints it, exits 0 with the refusal listed as handled.
##
## The drill runs the host as a host runs: the fetch timer and the
## shipping path unit do the work; the gate never starts the shipping unit,
## never stops the fetch timer and never resets a unit (A11 drill finding
## D8). Its waits are for records at the sink.
##
## The record (``build/addon-gates/records/``) is the drill report's
## evidence: ``reprobuild-pm/spec/Test-Designs`` holds the report
## template the investigator fills in.
##
## Falsifying builds (sink side): ``ack-by-sequence-only`` (the
## mistyped-kind acknowledgement handles the refusal),
## ``check-ignores-acks``, ``check-ignores-containment``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The compiler is a shell script standing for a compromised
## one: the compromise under drill. Nothing else.

import std/[algorithm, json, os, sequtils, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest
import repro_peer_cache/evidence
import repro_peer_cache/types

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
  let drill = g.runDir / "drill"
  createDir(drill)
  writeFile(drill / "hosts", host & " " & AgentTarget & "\n")
  proc publish(sequence: uint64) =
    let bytes = prod.publish(PublishSpec(sequence: sequence,
      profileText: "import repro_profile\n# drill source (" & $sequence & ")\n",
      compiledProfile: pinOf(Honest)))
    sink.archive(bytes, sequence)
  # The user guide's check, spelled as the guide spells it (space-separated
  # options, D2).
  let checkCmd = "addon-check --dir " & quoteShell(sink.storeDir) &
    " --hosts " & quoteShell(drill / "hosts") & " --manifests " &
    quoteShell(sink.published) & " --deploy-signers " & quoteShell(signers)
  # The host runs on its own from here: its fetch timer, its path unit.
  discard g.exec("systemctl start repro-agent-fetch.timer")
  let waitSec = 6 * GatePollSec + 60

  # 1. setup
  let s0 = sink.headSeq()
  publish(1)
  step("setup: sequence 1 applies through the honest compile, by the timer",
       sink.waitFor(host, "addon-apply", "applied", waitSec, since = s0), "")
  let fp0 = g.takeFingerprint(repro)
  phase("setup", %*{"sinkHost": sink.hostId, "guestHost": host,
                    "sinkStore": sink.storeDir})

  # 2. compromise: the planted payload.
  let before = sink.headSeq()
  g.installCompiler(Planted)
  let compilerSha = g.exec("sha256sum " & Compiler & " | cut -d' ' -f1").stdout.strip()
  publish(2)
  phase("compromise", %*{"payload": Planted, "payloadPath": "/etc/cron.d/a11-drill"})

  # 3. detection: shipped by the path unit alone (D1).
  step("detection: the refusal left the host by itself", sink.waitFor(host,
       "addon-apply-refusal", "addon-staging-refused", waitSec, since = before), "")
  var evidenceIds: seq[uint64]
  var payloadSeen = false
  var stagingCopy, recCompiler, recCompilerSha = ""
  for e in sink.entries():
    if e.seq > before and e.kind == ekRecord and
        e.record.trigger == "addon-staging-refused":
      evidenceIds.add(e.seq)
      payloadSeen = payloadSeen or cast[string](e.record.payload) == Planted
      stagingCopy = e.record.field("stagingCopy")
      recCompiler = e.record.field("compiler")
      recCompilerSha = e.record.field("compilerSha256")
  step("detection: the record carries the planted bytes (EVID-1)", payloadSeen, "")
  step("detection: the record names its staging copy and the compiler (D6)",
       stagingCopy.startsWith("/var/lib/repro/agent/refused/") and
         recCompiler == Compiler and recCompilerSha == compilerSha,
       stagingCopy & " " & recCompiler & " " & recCompilerSha)
  let c1 = sink.sinkCli(checkCmd)
  step("detection: the documented off-host check raises DET-AO-2 (exit 1)",
       c1.code == 1 and "DET-AO-2" in c1.output, c1.output)
  phase("detection", %*{"evidenceIds": evidenceIds})

  # 4. investigation
  if getEnv("REPRO_ADDON_DRILL_HOLD") == "1":
    writeFile(drill / "README",
      "Add-on drill: investigation hold.\n\n" &
      "Follow docs/user-guide/addon-evidence.md, \"Responding to a detection\".\n" &
      "Sink store (read it locally): " & sink.storeDir & "\n" &
      "Sink tool: " & sinkBinary() & " read --dir " & sink.storeDir & "\n" &
      "A record's payload: " & sinkBinary() & " payload --dir " & sink.storeDir &
        " --seq <n>\n" &
      "Off-host check: " & sinkBinary() & " " & checkCmd & " --update-hosts\n" &
      "Acknowledge a handled alert: " & sinkBinary() & " ack --dir " &
        sink.storeDir & " --seq <n> --alert <detector>/<trigger> " &
        "--operator <you> --reason <text>\n" &
      "Evidence ids of the detection: " & evidenceIds.mapIt($it).join(" ") & "\n" &
      "Run a command in the guest: write " & drill / "requests/<n>.sh" &
        " and read <n>.out\n" &
      "Copy a guest path out: write the path to " & drill / "requests/<n>.copy" & "\n" &
      "Contain: repro system addon contain --operator <you> --reason <text>\n" &
      "The drill's own containment and recovery run after you create " &
        drill / "continue" & " (or do them yourself first; the drill " &
        "checks the result).\n")
    let holdSec = try: parseInt(getEnv("REPRO_ADDON_DRILL_HOLD_SEC", "14400"))
                  except ValueError: 14400
    echo "drill: holding for the investigator; see ", drill / "README"
    g.serveRequests(drill, drill / "continue", holdSec)
    step("investigation: the investigator ended the hold",
         fileExists(drill / "continue"), "hold timed out")
    if fileExists(drill / "findings.json"):
      record["investigatorFindings"] = parseJson(readFile(drill / "findings.json"))
  let shown = sink.sinkCli("payload --dir " & quoteShell(sink.storeDir) &
    " --seq " & $evidenceIds[0])
  step("investigation: the sink shows the captured payload, marked untrusted (D3)",
       shown.code == 0 and "BEGIN UNTRUSTED PAYLOAD" in shown.output and
         "/run/a11-drill-owned" in shown.output, shown.output)
  step("investigation: the refused staging copy the record names is preserved",
       g.exec("test -d " & quoteShell(stagingCopy)).exitCode == 0, stagingCopy)
  phase("investigation")

  # 5. containment
  let beforeContain = sink.headSeq()
  let ct = g.exec(repro & " system addon contain --operator drill " &
    "--reason " & quoteShell("compromised profile compiler"), timeoutSec = 600)
  step("containment: contain succeeds and its record reached the sink first",
       ct.exitCode == 0 and "reached the sink" in ct.stdout and
         sink.waitFor(host, "addon-containment", "operator-contained", 60,
                      since = beforeContain), ct.stdout & ct.stderr)
  # Contained means unstartable, not merely stopped: a start is skipped on
  # the containment condition.
  discard g.exec("systemctl start repro-agent-fetch.timer " &
                 "repro-agent-fetch.service repro-agent-apply.service")
  let cond = g.exec("systemctl show -p ConditionResult --value " &
    "repro-agent-fetch.service").stdout.strip()
  step("containment: the agent's units do not start while contained",
       cond == "no" and g.exec("systemctl is-active repro-agent-fetch.timer " &
         "repro-agent-fetch.service").stdout.splitLines().allIt(
           it.strip() != "active"),
       cond & " " & g.exec("systemctl status repro-agent-fetch.timer " &
           "--no-pager | head -8").stdout)
  let snap = drill / "snapshot"
  createDir(snap)
  try:
    g.copyFrom(stagingCopy, snap)
    step("containment: the preserved staging copy is off the host",
         walkDirRec(snap).toSeq.len > 0, snap)
  except CatchableError as e:
    step("containment: the preserved staging copy is off the host", false, e.msg)
  step("containment: the payload never landed",
       g.exec("test ! -e /etc/cron.d/a11-drill && test ! -e /run/a11-drill-owned").exitCode == 0, "")
  # The agent's units are the only difference containment makes: masked,
  # stopped and with no failed state (``contain`` clears it, D8).
  let id = identityReport(fp0, g.takeFingerprint(repro), [
    "unit-files:repro-agent-fetch.timer", "unit-files:repro-agent-fetch.service",
    "unit-files:repro-agent-apply.service", "active-units:repro-agent-fetch.timer",
    "active-units:repro-agent-fetch.service",
    "active-units:repro-agent-apply.service"])
  step("containment: the host is on its last good generation (fingerprint " &
       "unchanged but for the contained agent units)", id.ok, id.text)
  # Silence past the tick's window: contained, not silent.
  sleep((3 * GatePollSec + 60) * 1000)
  let c2 = sink.sinkCli(checkCmd)
  step("containment: the check reports the agent contained, not silent (D5)",
       "addon-agent-tick contained" in c2.output and
         "DET-AO-8 silent addon-agent-tick" notin c2.output, c2.output)
  # Every refused tick before the containment raised its own refusal
  # alert (the timer kept fetching the compromised compile), and nothing
  # else may alert: the gate computes the alerts the scenario caused from
  # the sink's entries, requires the check to print exactly those, and
  # acknowledges only those, by sequence AND kind (A11 review finding 9 and
  # round 2: the gate used to acknowledge whatever the check printed, so it
  # drove the state it then asserted).
  proc alertSet(output: string): seq[string] =
    for line in output.splitLines():
      let f = line.splitWhitespace()
      # Every ALERT line, those without a sequence too (a silence, a state
      # the check cannot use): any alert the scenario did not cause fails
      # the comparison (A11 review round 3).
      if f.len >= 4 and f[0] == "ALERT":
        let sq = if f.len >= 5 and f[4].startsWith("seq="): f[4]["seq=".len .. ^1]
                 else: "-"
        result.add(sq & " " & f[2] & "/" & f[3])
    result.sort()
  var expected: seq[string]
  for e in sink.entries():
    if e.seq > before and e.kind == ekRecord and $e.senderHostId == host and
        e.record.trigger == "addon-staging-refused":
      expected.add($e.seq & " DET-AO-2/addon-staging-refused")
  expected.sort()
  record["expectedAlerts"] = %expected
  step("containment: the check alerts exactly the refusals the drill caused",
       expected.len > 0 and alertSet(c2.output) == expected,
       "expected " & $expected & ", printed " & $alertSet(c2.output))
  proc ack(sq, kind, reason: string): tuple[code: int; output: string] =
    sink.sinkCli("ack --dir " & quoteShell(sink.storeDir) & " --seq " & sq &
      " --alert " & quoteShell(kind) & " --operator drill --reason " &
      quoteShell(reason))
  # An acknowledgement of another kind at a refusal's sequence handles
  # nothing: the refusal still alerts.
  let first = expected[0].split(' ')
  let wrong = ack(first[0], "DET-AO-9/attestation-invalid", "mistyped kind")
  let afterWrong = sink.sinkCli(checkCmd)
  step("containment: an acknowledgement of another kind leaves the refusal alerting",
       wrong.code == 0 and alertSet(afterWrong.output) == expected,
       wrong.output & afterWrong.output)
  var acked: seq[string]
  for x in expected:
    let f = x.split(' ')
    let r = ack(f[0], f[1], "investigated: compromised compiler, contained")
    acked.add(x)
    step("containment: the investigator acknowledges " & f[1] & " at " & f[0],
         r.code == 0, r.output)
  record["acknowledged"] = %acked
  phase("containment", %*{"snapshot": snap})

  # 6. recovery
  let beforeRecovery = sink.headSeq()
  g.installCompiler(Honest)
  # The host's own credential self-test, as the user guide prints it, is
  # part of the recovery check; it must not raise G34 alerts (D9).
  let cc = g.exec(repro & " system addon evidence-credential-check")
  step("recovery: the credential self-test passes", cc.exitCode == 0, cc.stdout)
  let rl = g.exec(repro & " system addon release --operator drill " &
    "--reason " & quoteShell("honest compiler restored"), timeoutSec = 600)
  step("recovery: release succeeds and its record reached the sink",
       rl.exitCode == 0 and sink.waitFor(host, "addon-containment",
         "operator-released", 60, since = beforeRecovery), rl.stdout & rl.stderr)
  publish(3)
  step("recovery: sequence 3 applies through the honest compile, by the timer",
       sink.waitFor(host, "addon-apply", "applied", waitSec,
                    since = beforeRecovery), "")
  # A tick heartbeat after the apply, so the tick reads live.
  let afterApply = sink.headSeq()
  discard sink.waitFor(host, "addon-agent-tick", "", waitSec, since = afterApply)
  let c3 = sink.sinkCli(checkCmd)
  record["recoveryCheck"] = %c3.output
  step("recovery: the documented check exits 0, the refusal handled (D4)",
       c3.code == 0 and "HANDLED" in c3.output and "ALERT" notin c3.output,
       c3.output)
  step("recovery: the credential self-test reads as one (D9)",
       "sink-credential self-test" in c3.output, c3.output)
  step("recovery: the host's tick is live",
       "addon-agent-tick live" in c3.output, c3.output)
  # Every record left the host as it landed (D1): none waited for the
  # heartbeat timer (30 s here). The worst wait, from the record's writing
  # on the host to its receipt at the sink.
  var worst = (ms: 0'i64, seq: 0'u64, what: "")
  for e in sink.entries():
    if e.kind == ekRecord and $e.senderHostId == host and e.seq > s0 and
        e.record.senderTimeMs > 0:
      let d = e.receivedAtMs - e.record.senderTimeMs
      if d > worst.ms:
        worst = (d, e.seq, e.record.detector & "/" & e.record.trigger)
  record["worstShipDelayMs"] = %worst.ms
  step("every record left the host within 15 s of being written (D1)",
       worst.ms < 15_000, $worst)
  phase("recovery", %*{"check": c3.output})

suite Gate:
  test "the drill: a compromised fetch unit, from detection to recovery":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
