## Gate ``e2e_addon_evidence_enrol`` (milestone A11; owner decision
## 2026-11-04; spec §6.2, §10.6).
##
## A host bootstrapped WITHOUT an Evidence sink (as every host before A11
## was) gets one with ``repro system addon evidence-enrol``: the verb
## creates the attestation key and the sink credential, applies generation
## 0's evidence objects and the egress observer as one switch, and records
## itself (``addon-bootstrap`` / ``evidence-enrol``, outcome
## ``aoOperatorAction``). Once the gate enrols the credential at its sink,
## the credential check of ``e2e_addon_evidence_credential_is_append_only``
## is green, and the host's tick reaches the sink. A second enrol is refused
## and changes nothing (the keys are never adopted or replaced).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=evidence-keys-adopted``):
## existing keys are not looked for; the second enrol is not refused by
## them -- red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const Gate = "e2e_addon_evidence_enrol"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  # Bootstrapped without a sink: no evidence objects, no keys.
  let bs = g.bootstrapWithAgent(repro, step)
  producer = bs.producer
  if not bs.ok: return
  step("no evidence objects before the enrol",
       g.exec("test ! -e /etc/repro/evidence.conf && " &
              "test ! -e /var/lib/repro/agent/attestation.key").exitCode == 0, "")
  g.provideSinkCa(sink)
  let e = g.exec(repro & " system addon evidence-enrol --evidence-sink " &
    HostFromGuest & ":" & $sink.port & " --evidence-sink-ca " & GuestSinkCa &
    " --heartbeat-interval " & $GateHeartbeatSec, timeoutSec = 1800)
  record["enrol"] = %(e.stdout & e.stderr)
  step("evidence-enrol applies the evidence objects as one switch",
       e.exitCode == 0 and "egress observer:      installed" in e.stdout,
       e.stdout & e.stderr)
  let host = g.enrol(sink)
  let c = g.exec(repro & " system addon evidence-credential-check")
  step("the enrolled credential appends and is refused list, read, " &
       "overwrite and delete", c.exitCode == 0, c.stdout & c.stderr)
  discard g.exec("systemctl start repro-addon-evidence.service")
  step("the enrol's own record reached the sink",
       sink.waitFor(host, "addon-bootstrap", "evidence-enrol", 180), "")
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a11-enrol", "x\n")))
  let t = g.tickUnits()
  step("a tick after the enrol applies", t.outcome == "aoApplied", $t)
  discard g.exec("systemctl start repro-addon-evidence.service")
  step("the tick's heartbeat reached the sink",
       sink.waitFor(host, "addon-agent-tick", "", 180), "")
  let again = g.exec(repro & " system addon evidence-enrol --evidence-sink " &
    HostFromGuest & ":" & $sink.port & " --evidence-sink-ca " & GuestSinkCa)
  step("a second enrol is refused", again.exitCode != 0, again.stdout & again.stderr)
  # Under the falsifying build the conf check would still refuse; the keys'
  # own refusal is what the mutation removes, so check it with the conf
  # moved aside.
  discard g.exec("mv /etc/repro/evidence.conf /root/evidence.conf.aside")
  let keys = g.exec(repro & " system addon evidence-enrol --evidence-sink " &
    HostFromGuest & ":" & $sink.port & " --evidence-sink-ca " & GuestSinkCa)
  discard g.exec("mv /root/evidence.conf.aside /etc/repro/evidence.conf")
  step("with the configuration aside, the existing keys alone refuse it",
       keys.exitCode != 0 and "existing evidence keys" in keys.stderr,
       keys.stdout & keys.stderr)
  # Re-keying (spec §13 decision 52; A11 drill D7): the old key signs a
  # hand-over, the sink follows it once the operator anchors the new
  # credential, and the old id is retired.
  let hostsFile = g.runDir / "hosts"
  writeFile(hostsFile, host & " " & AgentTarget & "\n")
  discard sink.sinkCli("addon-check --dir " & quoteShell(sink.storeDir) &
    " --hosts " & quoteShell(hostsFile) & " --update-hosts")
  let oldCert = g.exec("sha256sum " & GuestCredentialCert).stdout
  let rk = g.exec(repro & " system addon evidence-enrol --rekey", timeoutSec = 1800)
  step("evidence-enrol --rekey hands over and applies the new keys",
       rk.exitCode == 0 and "on the sink" in rk.stdout and
         g.exec("sha256sum " & GuestCredentialCert).stdout != oldCert,
       rk.stdout & rk.stderr)
  step("the hand-over, signed by the old key, reached the sink",
       sink.waitFor(host, "addon-evidence-keys", "rekey-handover", 60), "")
  let newHost = g.enrol(sink)
  step("the new credential is another host id", newHost != host, newHost)
  discard g.exec("systemctl start repro-addon-evidence.service")
  step("records now arrive under the new id",
       sink.waitFor(newHost, "addon-evidence-keys", "rekeyed", 180), "")
  let up = sink.sinkCli("addon-check --dir " & quoteShell(sink.storeDir) &
    " --hosts " & quoteShell(hostsFile) & " --update-hosts")
  let hostsNow = readFile(hostsFile)
  record["hostsAfterRekey"] = %hostsNow
  step("--update-hosts follows the hand-over: new id enrolled, old retired",
       newHost in hostsNow and (host & " ") in hostsNow and "retired@" in hostsNow,
       hostsNow & up.output)

suite Gate:
  test "evidence-enrol gives a pre-A11 host its sink":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
