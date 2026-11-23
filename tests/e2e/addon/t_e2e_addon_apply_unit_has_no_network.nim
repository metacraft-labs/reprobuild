## Gate ``e2e_addon_apply_unit_has_no_network`` (milestone A8; spec §9.1,
## DET-AO-3).
##
## The apply unit is paused (seam build) after it verified its copy; from
## inside its network namespace (``nsenter --net`` on its main process) a
## connect to the cache origin -- the same address the producer serves
## from, which the fetch unit reaches -- fails, and so does one from its
## control group's own sockets. Vacuity guard: the same connect from the
## host's namespace succeeds.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-apply-has-network``):
## the unit has no ``PrivateNetwork=yes`` / ``IPAddressDeny=any`` and the
## connect succeeds: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const Gate = "e2e_addon_apply_unit_has_no_network"

proc connectCmd(host: string; port: int): string =
  "timeout 10 bash -c 'exec 3<>/dev/tcp/" & host & "/" & $port & "'"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a8-net", "x\n")))
  step("vacuity guard: the origin is reachable from the host's namespace",
       g.exec(connectCmd(HostFromGuest, producer.port)).exitCode == 0, "")
  g.armApplySeam("agent-apply-after-verify")
  g.startFetchNoWait()
  let paused = g.waitSeam(ApplySeamDir, "agent-apply-after-verify")
  step("the apply unit paused after verifying", paused, "")
  if paused:
    let pid = g.applyPid()
    let ns = g.exec("nsenter --target " & pid & " --net " &
                    connectCmd(HostFromGuest, producer.port))
    record["nsConnectExit"] = %ns.exitCode
    record["nsConnectStderr"] = %ns.stderr
    step("a connect to the cache origin from the apply unit's namespace fails",
         ns.exitCode != 0, "exit " & $ns.exitCode & " " & ns.stderr)
    let cg = g.exec("echo $$ > /sys/fs/cgroup/system.slice/" &
      "repro-agent-apply.service/cgroup.procs && " &
      "nsenter --target " & pid & " --net " &
      connectCmd(HostFromGuest, producer.port))
    step("and from a process in its control group", cg.exitCode != 0,
         "exit " & $cg.exitCode & " " & cg.stderr)
    g.resumeSeam(ApplySeamDir)
  g.waitApplyIdle()
  let t = g.lastTick()
  step("the apply completes", t.outcome == "aoApplied", $t)

suite Gate:
  test "the apply unit cannot reach the cache origin":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
