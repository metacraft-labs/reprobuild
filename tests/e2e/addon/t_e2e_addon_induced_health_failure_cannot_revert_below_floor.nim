## Gate ``e2e_addon_induced_health_failure_cannot_revert_below_floor``
## (milestone A8; spec §7.5, threat model G31, T36).
##
## Generation 2 is applied from a manifest carrying rollback floor 2; an
## external fixture (``/run/a8-fail-<version>``, which the service's start
## command reads) makes its health check fail during ``confirmTimeout``. The host
## stays on generation 2 (its unit file is in place), the agent reports
## ``failed_at_floor`` and the switch records ``failed-at-floor`` with an
## evidence record. A generation 3 without a floor whose check fails
## reverts to 2 as before (``aoRolledBack``).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=floor-ignored``): the
## confirm-or-revert ignores the floor and reverts to generation 1: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_induced_health_failure_cannot_revert_below_floor"
  Port = 18082

proc profile(version: string): string =
  "addOn {\n  managedEtcPrefixes = []\n  confirmTimeout = 15\n}\n\n" &
    "systemd.systemUnit {\n  name = \"a8-floor.service\"\n  content = \"" &
    "[Unit]\nDescription=A8 floor fixture " & version & "\n[Service]\n" &
    "ExecStart=/bin/sh -c 'test ! -e /run/a8-fail-" & version & " && exec /usr/bin/python3 " &
    "-m http.server " & $Port & " --bind 127.0.0.1 --directory /tmp'\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n  healthCheck = " &
    "\"tcp:127.0.0.1:" & $Port & "\"\n}\n"

proc unitVersion(g: Guest): string =
  g.exec("sed -n 's/^Description=A8 floor fixture //p' " &
         "/etc/systemd/system/a8-floor.service").stdout.strip()

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 1, profileText: profile("v1")))
  let t1 = g.tickUnits()
  step("generation 1 (sequence 1) applies", t1.outcome == "aoApplied", $t1 & t1.applyLog)
  discard g.run("touch /run/a8-fail-v2")
  discard producer.publish(PublishSpec(sequence: 2, profileText: profile("v2"),
    rollbackFloor: 2))
  let t2 = g.tickUnits()
  step("sequence 2 (floor 2) fails its check and is not reverted: failed_at_floor",
       t2.outcome == "aoApplyFailed" and t2.errorCode == "failed_at_floor",
       $t2 & "\n" & t2.applyLog)
  step("the host stays on generation 2", g.unitVersion() == "v2", g.unitVersion())
  step("the apply log records failed-at-floor", g.exec(
       "grep -a -l failed-at-floor /var/lib/repro/system/generations/*/log/apply.log").exitCode == 0, "")
  step("an evidence record of failed-at-floor", g.exec(
       "ls /var/lib/repro/system/addon/evidence/ | grep -q failed-at-floor").exitCode == 0, "")
  step("the sequence floor is 2", g.run("cat " & SeqFloor).strip() == "2", "")
  # The fixture lets generation 2 run again; generation 3's own check is
  # made to fail. Without a floor it reverts to 2 as before.
  discard g.run("rm -f /run/a8-fail-v2 && systemctl restart a8-floor.service && " &
                "touch /run/a8-fail-v3")
  discard producer.publish(PublishSpec(sequence: 3, profileText: profile("v3")))
  let t3 = g.tickUnits()
  step("sequence 3 (no floor) fails and is reverted: aoRolledBack",
       t3.outcome == "aoRolledBack", $t3 & "\n" & t3.applyLog)
  step("the host is back on generation 2", g.unitVersion() == "v2", g.unitVersion())
  discard g.run("rm -f /run/a8-fail-v3")

suite Gate:
  test "an induced health failure cannot revert below the signed floor":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
