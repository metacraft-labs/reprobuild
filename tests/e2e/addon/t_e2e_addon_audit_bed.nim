## The adversarial audit's test bed (milestone A11, MS-1 row 5): a running
## add-on host in a VM the bed creates, held open for an auditing agent.
##
## Not a pass/fail gate of its own. It stands up the host the audit attacks
## -- bootstrapped with the deploy agent (its fetch and apply units), the
## gate's own Evidence sink, a generation applied from a signed manifest
## with one service unit (the fixture floor waiver) -- checks that the
## detectors are live (so the audit attacks a working host, not a broken
## one), and with ``REPRO_ADDON_AUDIT_HOLD=1`` holds until the auditor
## creates ``<run dir>/audit/continue``. Meanwhile the auditor runs commands
## in the guest and copies files out through the request directory
## (``evidence_e2e_support.serveRequests``) and reads the sink's store
## locally; ``<run dir>/audit/README`` names every path. The record lists
## what the bed was (commit, base, artefact digest, sink) so each finding
## can name what it was measured against.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, sequtils, strutils, unittest]

import repro_test_support/reasoned_skip

import repro_addon/evidence_check

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const
  Gate = "addon_adversarial_audit_bed"
  Service = "repro-a11-audit.service"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags)
  producer = bs.producer
  if not bs.ok: return
  let host = g.enrol(sink)
  let signers = g.runDir / "deploy-signers.anchors"
  let bytes = producer.publish(PublishSpec(sequence: 1,
    # The fixture's floor waiver: /bin/sleep is not in an add-on closure.
    # The floor itself is A9's (its gates use store closures); the bed's
    # service stands for any declared service.
    profileText: unitProfile(Service, "/bin/sleep infinity") &
      canonicalFile("/etc/repro/a11-audit", "audited\n")))
  sink.archive(bytes, 1)
  let t = g.tickUnits()
  step("the audited generation applies", t.outcome == "aoApplied", $t)
  discard g.exec("systemctl start repro-agent-fetch.timer repro-addon-evidence.service")
  discard sink.waitFor(host, "addon-agent-tick", "", 180)
  let r = sink.check(host, signers)
  record["detectors"] = toJson(r)
  step("the detectors are live before the audit", r.statuses.filterIt(
       it.detector in ["addon-agent-tick", "addon-evidence-ship"]).allIt(
       it.status.startsWith("live")), render(r))
  record["sinkStore"] = %sink.storeDir
  record["guestHost"] = %host
  if getEnv("REPRO_ADDON_AUDIT_HOLD") == "1":
    let dir = g.runDir / "audit"
    createDir(dir)
    writeFile(dir / "hosts", host & " " & AgentTarget & "\n")
    writeFile(dir / "README",
      "Add-on adversarial audit bed (" & g.name & ").\n\n" &
      "Run a command in the guest as root: write " & dir / "requests/<n>.sh" &
        " and read <n>.out\n" &
      "Copy a guest path out: write the path to " & dir / "requests/<n>.copy" & "\n" &
      "Evidence sink store (read locally): " & sink.storeDir & "\n" &
      "Off-host check: " & sinkBinary() & " addon-check --dir " &
        sink.storeDir & " --hosts " & dir / "hosts" & " --manifests " &
        sink.published & " --deploy-signers " & signers & "\n" &
      "Producer: publish through this process only; the served directory is " &
        producer.dir & "\n" &
      "End the hold by creating " & dir / "continue" & "\n")
    let holdSec = try: parseInt(getEnv("REPRO_ADDON_AUDIT_HOLD_SEC", "28800"))
                  except ValueError: 28800
    echo "audit bed: holding; see ", dir / "README"
    g.serveRequests(dir, dir / "continue", holdSec)
    let after = sink.check(host, signers)
    record["detectorsAfterAudit"] = toJson(after)

suite Gate:
  test "the audit bed: a running add-on host held for the auditor":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
