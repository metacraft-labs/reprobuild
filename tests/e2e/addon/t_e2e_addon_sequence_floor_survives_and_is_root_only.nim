## Gate ``e2e_addon_sequence_floor_survives_and_is_root_only`` (milestone
## A8; spec §9.1, threat model G7).
##
## The last-applied sequence lives under ``/var/lib/repro/agent`` (``0700
## root``). While the fetch unit is paused (seam build), a process with its
## mount namespace and its dynamic user cannot read the floor or write it;
## the gate then tries, as that user, to reset the floor wherever the
## agent might keep it (its own state directory included). After a reboot,
## an older but validly signed and fresh manifest served by the test
## mirror is not applied (``aoConverged``) and the floor still names the
## newer sequence.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-floor-in-fetch-state``):
## the floor is kept in the fetch unit's state directory, where its user
## resets it, after which the older manifest applies: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_sequence_floor_survives_and_is_root_only"
  FetchFloor = "/var/lib/private/repro-agent-fetch/floor/deploy-agent/" &
               AgentTarget & ".seq"

proc asFetch(g: Guest; pid, cmd: string): ExecOut =
  ## ``cmd`` with the paused fetch unit's mount namespace and its user.
  let uid = g.run("stat -c %u /proc/" & pid).strip()
  let gid = g.run("stat -c %g /proc/" & pid).strip()
  g.exec("nsenter --target " & pid & " --mount --setuid " & uid &
         " --setgid " & gid & " sh -c '" & cmd & "'")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 7,
    profileText: canonicalFile("/etc/repro/a8-floor", "seven\n")))
  let t1 = g.tickUnits()
  step("sequence 7 is applied", t1.outcome == "aoApplied", $t1 & t1.applyLog)
  step("the agent directory is 0700 root", g.run(
       "stat -c %a:%U /var/lib/repro/agent").strip() == "700:root", "")
  step("the floor names 7", g.exec("cat " & SeqFloor).stdout.strip() == "7" or
       g.exec("cat " & FetchFloor).stdout.strip() == "7", "")
  # The mirror now serves an older, validly signed, fresh manifest. The
  # fetch unit selects it and pauses; as its user, in its mount namespace,
  # the gate reads and writes the floor, and resets it wherever the agent
  # might keep it that the fetch unit can write.
  discard producer.publish(PublishSpec(sequence: 3,
    profileText: canonicalFile("/etc/repro/a8-floor", "three\n")))
  g.armFetchSeam("agent-fetch-after-select")
  discard g.exec("rm -f " & TickStatus)
  g.startFetchNoWait()
  if g.waitSeam(FetchSeamDir, "agent-fetch-after-select"):
    let pid = g.fetchPid()
    let rd = g.asFetch(pid, "cat " & SeqFloor)
    step("the fetch unit cannot read the floor", rd.exitCode != 0,
         rd.stdout & rd.stderr)
    let wr = g.asFetch(pid, "echo 0 > " & SeqFloor)
    step("the fetch unit cannot write the floor", wr.exitCode != 0,
         wr.stdout & wr.stderr)
    let reset = g.asFetch(pid, "mkdir -p /var/lib/repro-agent-fetch/floor/" &
      "deploy-agent 2>/dev/null; echo 0 > /var/lib/repro-agent-fetch/" &
      "floor/deploy-agent/" & AgentTarget & ".seq")
    record["fetchStateFloorReset"] = %reset.exitCode
    g.resumeSeam(FetchSeamDir)
  else:
    step("the fetch unit paused", false, "")
  g.waitApplyIdle()
  let tOld = g.lastTick()
  step("the older sequence 3 is not applied", tOld.outcome == "aoConverged", $tOld)
  # After a reboot the floor still holds, and the older manifest still is
  # not applied.
  g.rebootGuest()
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  let t2 = g.tickUnits()
  step("after the reboot the older sequence 3 is not applied",
       t2.outcome == "aoConverged", $t2 & t2.applyLog)
  step("the floor still names 7", g.exec("cat " & SeqFloor).stdout.strip() == "7" or
       g.exec("cat " & FetchFloor).stdout.strip() == "7", "")
  step("/etc/repro/a8-floor still holds sequence 7's content",
       g.exec("cat /etc/repro/a8-floor").stdout == "seven\n", "")

suite Gate:
  test "the sequence floor survives a reboot and is root-only":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
