## Gate ``e2e_addon_agent_end_to_end`` (milestone A8; spec §9.1, §9.2).
##
## A producer in the test network (this process, serving over HTTP at the
## host's loopback) publishes RDMF v3 manifests to a guest bootstrapped
## with the deploy agent's two units, and every apply goes through them --
## ``repro-agent-fetch.service`` (unprivileged, egress to the origin only)
## then ``repro-agent-apply.service`` (root, no network):
##
## 1. sequence 1 adds a service; applied (``aoApplied``), the service answers;
## 2. sequence 2 changes it; applied, the new page is served;
## 3. sequence 3 is bad: its health check cannot pass. The switch reverts
##    it (``aoRolledBack``, exit 2) and the host serves sequence 2's page;
## 4. a later tick does not retry sequence 3: ``aoRolledBack`` again
##    (``quarantined``) with no new apply attempt;
## 5. a fixed sequence 4 applies, and the quarantine is gone.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_agent_end_to_end``).
##
## *Mocking.* None: real units, a real HTTP origin, real signatures.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Port = 18081
  ConfirmTimeout = 20

proc service(page: string): string =
  "[Unit]\nDescription=A8 end-to-end fixture\n[Service]\n" &
    "ExecStartPre=/bin/sh -c 'mkdir -p /run/a8-www && " &
    "echo " & page & " > /run/a8-www/index.html'\n" &
    "ExecStart=/usr/bin/python3 -m http.server " & $Port &
    " --bind 127.0.0.1 --directory /run/a8-www\n\n" &
    "[Install]\nWantedBy=multi-user.target\n"

proc profile(page, check: string): string =
  "addOn {\n  managedEtcPrefixes = []\n  confirmTimeout = " &
    $ConfirmTimeout & "\n}\n\n" &
    "systemd.systemUnit {\n  name = \"a8-web.service\"\n" &
    "  content = \"" & service(page) & "\"\n  healthCheck = \"" & check &
    "\"\n}\n"

proc served(g: Guest): string =
  g.exec("for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf http://127.0.0.1:" &
         $Port & "/ && exit 0; sleep 1; done; exit 1").stdout.strip()

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  var producer: Producer
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let bs = g.bootstrapWithAgent(repro, step)
    producer = bs.producer
    if not bs.ok: return fails
    let good = "http://127.0.0.1:" & $Port & "/"
    discard producer.publish(PublishSpec(sequence: 1,
      profileText: profile("one", good)))
    let t1 = g.tickUnits()
    step("sequence 1 is applied through the two units", t1.outcome == "aoApplied" and
         t1.sequence == 1, $t1 & "\n" & t1.fetchLog & t1.applyLog)
    step("the service serves sequence 1", g.served() == "one", "")
    discard producer.publish(PublishSpec(sequence: 2,
      profileText: profile("two", good)))
    let t2 = g.tickUnits()
    step("sequence 2 is applied", t2.outcome == "aoApplied" and t2.sequence == 2,
         $t2 & "\n" & t2.applyLog)
    step("the service serves sequence 2", g.served() == "two", "")
    let rb0 = g.rolledBackRecords()
    discard producer.publish(PublishSpec(sequence: 3,
      profileText: profile("three", "tcp:127.0.0.1:1")))
    let t3 = g.tickUnits()
    step("the bad sequence 3 is reverted: aoRolledBack, exit 2",
         t3.outcome == "aoRolledBack" and t3.exitCode == 2 and
         t3.errorCode == "rolled_back", $t3 & "\n" & t3.applyLog)
    step("the host serves sequence 2 again", g.served() == "two", "")
    let rb1 = g.rolledBackRecords()
    step("the revert is recorded rolled-back", rb1 == rb0 + 1,
         $rb0 & " -> " & $rb1)
    let q = g.exec("cat /var/lib/repro/agent/state/deploy-agent/" &
                   AgentTarget & ".quarantine")
    step("deployment a8-3 is quarantined", q.exitCode == 0 and
         "3 a8-3" in q.stdout, q.stdout & q.stderr)
    let t4 = g.tickUnits()
    step("a later tick does not retry it (aoRolledBack, quarantined)",
         t4.outcome == "aoRolledBack" and t4.errorCode == "quarantined",
         $t4)
    step("no new apply attempt was made", g.rolledBackRecords() == rb1, "")
    step("the host still serves sequence 2", g.served() == "two", "")
    discard producer.publish(PublishSpec(sequence: 4,
      profileText: profile("four", good)))
    let t5 = g.tickUnits()
    step("the fixed sequence 4 is applied", t5.outcome == "aoApplied" and
         t5.sequence == 4, $t5 & "\n" & t5.applyLog)
    step("the service serves sequence 4", g.served() == "four", "")
    step("the quarantine is cleared", g.exec("test -e /var/lib/repro/agent/" &
         "state/deploy-agent/" & AgentTarget & ".quarantine").exitCode != 0, "")
    step("the sequence floor is 4", g.run("cat " & SeqFloor).strip() == "4", "")
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    producer.stop()
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_agent_end_to_end":
  test "apply, change, revert and quarantine a bad sequence, apply a fix":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_agent_end_to_end)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_agent_end_to_end",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_agent_end_to_end", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
