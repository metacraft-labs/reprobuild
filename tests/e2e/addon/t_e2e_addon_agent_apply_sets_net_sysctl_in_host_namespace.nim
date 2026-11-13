## Gate ``e2e_addon_agent_apply_sets_net_sysctl_in_host_namespace``
## (milestone A8; threat model G35).
##
## The A4 sysctl gate repeated through the agent: a v3 manifest setting
## ``net.ipv4.ip_forward`` is applied by ``repro-agent-apply.service``
## (``PrivateNetwork=yes``) and the host's ``/proc/sys`` value changes.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=sysctl-in-apply-namespace``):
## ``systemd-sysctl`` runs inside the apply unit's namespace and the host
## value stays unchanged: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_agent_apply_sets_net_sysctl_in_host_namespace"
  Profile = "addOn {\n  managedEtcPrefixes = []\n}\n\nlinux.sysctl {\n" &
            "  key = \"net.ipv4.ip_forward\"\n  value = \"1\"\n}\n"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let before = g.run("cat /proc/sys/net/ipv4/ip_forward").strip()
  step("vacuity guard: the base does not forward", before == "0", before)
  step("the apply unit has PrivateNetwork=yes", g.run(
       "systemctl show -p PrivateNetwork --value repro-agent-apply.service").strip() == "yes", "")
  discard producer.publish(PublishSpec(sequence: 1, profileText: Profile))
  let t = g.tickUnits()
  step("the agent applies it", t.outcome == "aoApplied", $t & t.applyLog)
  let after = g.run("cat /proc/sys/net/ipv4/ip_forward").strip()
  record["ipForwardAfter"] = %after
  step("the host's value changed (read over SSH)", after == "1", after)

suite Gate:
  test "a net.* sysctl applied by the agent's apply unit reaches the host":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
