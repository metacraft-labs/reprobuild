## Gate ``t_addon_agent_apply_unit_lacks_cap_net_admin`` (milestone A9;
## spec §9.1, §13 Q6; threat model G10).
##
## The deploy agent's apply unit may not hold ``CAP_NET_ADMIN`` while the
## management-path guard (§13 Q6) stays deferred: every class that would
## need it -- the firewall, the network class, sshd drop-ins -- is refused
## in agent applies, so the capability could only serve an attacker who
## holds the unit. Two checks:
##
## 1. the rendered unit text: its ``CapabilityBoundingSet=`` does not name
##    ``CAP_NET_ADMIN`` (no guest needed);
## 2. the running unit: the apply unit is paused (seam build) after it
##    verified its copy, and the ``CapBnd`` of its main process in
##    ``/proc/<pid>/status`` has bit 12 (``CAP_NET_ADMIN``,
##    ``linux/capability.h``) clear. Vacuity guard: PID 1's ``CapBnd`` has
##    it set, so the parse reads a bit that can be set.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-apply-has-cap-net-admin``,
## and ``-d:reproAddonMutation=`` for check 1): the unit's bounding set
## gains ``CAP_NET_ADMIN``; both checks go red.
##
## Opt-in for check 2: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None: the real renderer, the real unit under the guest's
## systemd.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_addon/generation0

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "t_addon_agent_apply_unit_lacks_cap_net_admin"
  CapNetAdminBit = 12   ## CAP_NET_ADMIN, linux/capability.h

proc capBnd(status: string): uint64 =
  for l in status.splitLines():
    if l.startsWith("CapBnd:"):
      return fromHex[uint64](l["CapBnd:".len .. ^1].strip())
  raise newException(ValueError, "no CapBnd line in: " & status)

proc hasBit(v: uint64; bit: int): bool = (v and (1'u64 shl bit)) != 0

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a9-cap", "x\n")))
  let pid1 = capBnd(g.exec("cat /proc/1/status").stdout)
  step("vacuity guard: PID 1's bounding set has CAP_NET_ADMIN",
       pid1.hasBit(CapNetAdminBit), toHex(pid1))
  g.armApplySeam("agent-apply-after-verify")
  g.startFetchNoWait()
  let paused = g.waitSeam(ApplySeamDir, "agent-apply-after-verify")
  step("the apply unit paused after verifying", paused, "")
  if paused:
    let pid = g.applyPid()
    let st = g.exec("cat /proc/" & pid & "/status")
    let bnd = capBnd(st.stdout)
    record["applyCapBnd"] = %toHex(bnd)
    record["pid1CapBnd"] = %toHex(pid1)
    step("inside the running apply unit CapBnd has bit 12 clear",
         st.exitCode == 0 and not bnd.hasBit(CapNetAdminBit), toHex(bnd))
    g.resumeSeam(ApplySeamDir)
  g.waitApplyIdle()
  let t = g.lastTick()
  step("the apply completes", t.outcome == "aoApplied", $t)

suite Gate:
  test "the rendered apply unit's bounding set lacks CAP_NET_ADMIN":
    let unit = agentApplyUnit("/repro/store/prefixes/repro-addon/x/bin/repro")
    var bounding = ""
    for l in unit.splitLines():
      if l.startsWith("CapabilityBoundingSet="): bounding = l
    checkpoint bounding
    check bounding.len > 0
    check "CAP_NET_ADMIN" notin bounding

  test "the running apply unit's CapBnd lacks CAP_NET_ADMIN":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
