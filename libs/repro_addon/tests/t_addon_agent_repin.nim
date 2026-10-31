## ``repro system addon agent-repin`` (spec §9.1, "Re-pinning the origins";
## A8 review M5): the plan re-renders exactly the fetch unit's egress
## allow-list and the agent's hosts file in generation 0's own profile, and
## nothing else of it; an unchanged resolution is no change; a host without
## the deploy agent has nothing to re-pin.
##
## The resolution itself (``freshAgentInputs``, DNS) and the switch that
## applies the plan are not exercised here: the switch is the one every
## apply runs, and the inputs are passed in as a resolution would return
## them. *Mocking.* None; the own profile is the one bootstrap renders.

import std/[strutils, unittest]

import repro_infra
import repro_addon/agent_repin
import repro_addon/generation0

proc ownFor(a: AgentUnitsInputs): string =
  renderOwnProfile(generation0Objects(Gen0Inputs(
    reproExe: "/repro/store/prefixes/repro-addon-bin/x/bin/repro",
    agent: a)), "/repro/store/prefixes/repro-addon-files/y")

let before = AgentUnitsInputs(target: "h1",
  sources: @["http://cache.example:8080/m"],
  allowedAddresses: @["192.0.2.1"],
  hosts: @[(address: "192.0.2.1", name: "cache.example")])

suite "re-pinning the deploy agent's origins":
  test "a moved origin changes the allow-list and the hosts file, and nothing else":
    var after = before
    after.allowedAddresses = @["198.51.100.7"]
    after.hosts = @[(address: "198.51.100.7", name: "cache.example")]
    let own = ownFor(before)
    let plan = repinOwnProfile(own, after, renderAgentHosts(before))
    check plan.changed
    check "IPAddressAllow=198.51.100.7" in plan.ownText
    check "IPAddressAllow=192.0.2.1" notin plan.ownText
    check "198.51.100.7 cache.example" in plan.ownText
    check plan.digest.len == 64
    var minus, plus = 0
    for l in plan.diff:
      if ": - " in l: inc minus
      if ": + " in l: inc plus
    check minus == 2 and plus == 2
    # Everything outside the two objects is byte for byte what it was.
    let p = parseSystemProfile(plan.ownText)
    let q = parseSystemProfile(own)
    check p.resources.len == q.resources.len
    for i in 0 ..< p.resources.len:
      checkpoint p.resources[i].address
      if p.resources[i].address notin [
          "systemUnit:" & AgentFetchUnit,
          "systemFile:" & AgentHostsPath]:
        check $p.resources[i] == $q.resources[i]

  test "the same resolution is no change":
    let own = ownFor(before)
    let plan = repinOwnProfile(own, before, renderAgentHosts(before))
    check not plan.changed

  test "a host without the deploy agent has nothing to re-pin":
    let own = ownFor(AgentUnitsInputs())
    expect RepinError:
      discard repinOwnProfile(own, before, "")
