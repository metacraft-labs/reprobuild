## Gate ``e2e_addon_stale_manifest_is_reported`` (milestone A8; spec §9.2,
## threat model G32, T37).
##
## A mirror frozen at sequence N whose ``issuedAt`` is older than the
## manifest's maximum age makes the tick report ``aoStale`` (exit 2) with an
## evidence record; the same sequence re-signed fresh reports
## ``aoConverged``. Both ticks go through the agent's two units.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=rdmf-ignores-issued-at``):
## the agent ignores ``issuedAt`` and reports ``aoConverged`` for the frozen
## mirror: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_stale_manifest_is_reported``).
##
## *Mocking.* None.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const Gate = "e2e_addon_stale_manifest_is_reported"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let prof = canonicalFile("/etc/repro/a8-stale", "one\n")
  discard producer.publish(PublishSpec(sequence: 5, profileText: prof,
    deploymentId: "frozen-5"))
  let t1 = g.tickUnits()
  step("sequence 5 is applied", t1.outcome == "aoApplied", $t1 & t1.applyLog)
  let before = g.exec("ls /var/lib/repro/system/addon/evidence/ 2>/dev/null | " &
                      "grep -c stale-manifest").stdout.strip()
  # The mirror froze an hour ago; the manifest allows ten minutes.
  discard producer.publish(PublishSpec(sequence: 5, profileText: prof,
    deploymentId: "frozen-5", issuedAt: getTime().toUnix() - 3600,
    maxAgeSeconds: 600))
  let t2 = g.tickUnits()
  step("the frozen mirror is aoStale, exit 2", t2.outcome == "aoStale" and
       t2.exitCode == 2 and t2.errorCode == "stale_manifest", $t2)
  let ev = g.exec("ls /var/lib/repro/system/addon/evidence/ | grep -c " &
                  "stale-manifest").stdout.strip()
  step("an evidence record of the stale manifest was written",
       ev.len > 0 and ev != "0" and ev != before, before & " -> " & ev)
  discard producer.publish(PublishSpec(sequence: 5, profileText: prof,
    deploymentId: "frozen-5"))
  let t3 = g.tickUnits()
  step("the same sequence re-signed fresh is aoConverged",
       t3.outcome == "aoConverged" and t3.exitCode == 0, $t3)

suite Gate:
  test "a manifest older than its maximum age is aoStale":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
