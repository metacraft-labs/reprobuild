## The adversarial audit's test bed (milestone A11, MS-1 row 5): a running
## add-on host in a VM the bed creates, held open for an auditing agent.
##
## The bed (A11 second audit session) also: runs a service under the full
## hardening floor (``repro-a11-audit-floored.service``, no waiver, from the
## store); publishes and re-signs further sequences on request
## (``requests/<n>.publish``), including ones signed by an unanchored key or
## archived without being served (a frozen mirror); and reboots the guest on
## request (``requests/<n>.reboot``) with the request channel kept, since the
## bed serves it. The seam build is required (the floored service's sleep).
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

import std/[json, os, sequtils, strutils, times, unittest]

import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import repro_test_support/reasoned_skip

import repro_addon/evidence_check

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const
  Gate = "addon_adversarial_audit_bed"
  Service = "repro-a11-audit.service"
  FlooredService = "repro-a11-audit-floored.service"

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
  # Two services: one under the fixture waiver, and one under the full
  # hardening floor (no waiver), running from the store -- the add-on's own
  # binary's seam-build sleep, inside the closure the floor confines
  # execution to.
  let reproExe = g.exec("ls -d /repro/store/prefixes/repro-addon/*/bin/repro | head -1").stdout.strip()
  let bytes = producer.publish(PublishSpec(sequence: 1,
    profileText: unitProfile(Service, "/bin/sleep infinity") &
      unitProfile(FlooredService, reproExe & " system addon test-sleep 864000",
                  floorWaiver = false) &
      canonicalFile("/etc/repro/a11-audit", "audited\n")))
  sink.archive(bytes, 1)
  let t = g.tickUnits()
  step("the audited generation applies", t.outcome == "aoApplied", $t)
  step("the floored service runs under the floor",
       g.exec("systemctl is-active " & FlooredService).stdout.strip() == "active",
       g.exec("systemctl status " & FlooredService & " | tail -20").stdout)
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
      "Publish a manifest: write JSON to " & dir / "requests/<n>.publish" &
        " -- {\"sequence\": N, \"profileText\": \"...\", \"issuedAgo\": seconds, " &
        "\"maxAgeSeconds\": s, \"deploymentId\": \"...\", \"signer\": " &
        "\"producer\" or \"rogue\" (an unanchored key), \"serve\": false " &
        "(archive only: a frozen mirror; re-publish the same sequence to " &
        "re-sign it), \"plainV2\": true (no attestation block)}\n" &
      "Reboot the guest: create " & dir / "requests/<n>.reboot" &
        "; the request channel survives (the bed, not the guest, serves it)\n" &
      "Services: " & Service & " (fixture floor waiver) and " & FlooredService &
        " (the full hardening floor, running from the store)\n" &
      "Evidence sink store (read locally): " & sink.storeDir & "\n" &
      "Read it: " & sinkBinary() & " read --dir=" & sink.storeDir & "\n" &
      "Off-host check: " & sinkBinary() & " addon-check --dir=" &
        sink.storeDir & " --hosts=" & dir / "hosts" & " --manifests=" &
        sink.published & " --deploy-signers=" & signers & " --update-hosts\n" &
      "Producer: publish through requests only; the served directory is " &
        producer.dir & "\n" &
      "End the hold by creating " & dir / "continue" & "\n")
    let holdSec = try: parseInt(getEnv("REPRO_ADDON_AUDIT_HOLD_SEC", "28800"))
                  except ValueError: 28800
    let prod = producer
    let rogue = peerAuth.generateKeypair()
    proc handle(name, ext, content: string): tuple[handled: bool; output: string] =
      case ext
      of ".publish":
        # {"sequence": N, "profileText": "...", "issuedAgo": s,
        #  "maxAgeSeconds": s, "deploymentId": "...", "signer":
        #  "producer"|"rogue", "serve": true|false, "plainV2": false}
        let j = parseJson(content)
        let rogueSigned = j{"signer"}.getStr("producer") == "rogue"
        let spec = PublishSpec(sequence: uint64(j["sequence"].getInt()),
          profileText: j{"profileText"}.getStr(canonicalFile(
            "/etc/repro/a11-audit", "sequence " & $j["sequence"].getInt() & "\n")),
          issuedAt: getTime().toUnix() - j{"issuedAgo"}.getBiggestInt(0),
          maxAgeSeconds: uint64(j{"maxAgeSeconds"}.getInt(0)),
          deploymentId: j{"deploymentId"}.getStr(""),
          plainV2: j{"plainV2"}.getBool(false))
        var before = ""
        try: before = readFile(prod.dir / AgentTarget / "latest.rdm")
        except IOError: discard
        let signer = if rogueSigned: rogue else: prod.signer
        let p2 = Producer(dir: prod.dir, port: prod.port, signer: signer)
        let m = p2.publish(spec)
        if not rogueSigned: sink.archive(m, spec.sequence)
        if not j{"serve"}.getBool(true):
          writeFile(prod.dir / AgentTarget / "latest.rdm", before)
        (true, "published sequence " & $spec.sequence & " signed by " &
          (if rogueSigned: "an unanchored key" else: "the producer") &
          (if j{"serve"}.getBool(true): ", served" else:
            ", archived only (the host keeps being served the previous one)") &
          "\n")
      of ".reboot":
        g.rebootGuest()
        let journal = g.waitReasserted()
        (true, "rebooted; the re-assert unit's journal of this boot:\n" &
          journal)
      else: (false, "")
    echo "audit bed: holding; see ", dir / "README"
    g.serveRequests(dir, dir / "continue", holdSec, handle)
    let after = sink.check(host, signers)
    record["detectorsAfterAudit"] = toJson(after)

suite Gate:
  test "the audit bed: a running add-on host held for the auditor":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
