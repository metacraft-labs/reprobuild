## The hardening floor refuses a floored unit whose own ordering forms a
## cycle with the boot re-assertion (ReproOS Add-On Mode spec §10.1, "A
## floored unit's own ordering"; reprobuild-pm issue
## 2026-11-15-floor-a-floored-units-own-ordering-can-form-a-cycle-with-the-boot-reassertion).
##
## §13 decision 144 orders every floored unit (floor version 5) after
## ``repro-addon-reassert.service``. A unit that is also ordered before
## the re-assertion -- ``Before=repro-addon-reassert.service``, or
## ``DefaultDependencies=no`` with ``Before=sysinit.target``, which the
## re-assertion runs after -- is an ordering cycle: at every boot systemd
## deletes a job of its own choosing to break it, so either the unit never
## starts or the re-assertion does not run. Before the fix both of the
## issue's profiles parsed, rendered and applied.
##
## Covered here, each in both halves:
##
## - the parse-time half (``checkFloorBootOrdering``) refuses the issue's
##   two profiles, a chain through another profile unit (its ``Before=``,
##   another unit's ``After=``, a profile target's implicit ordering, a
##   profile socket's, timer's or path unit's boot target, a drop-in), with
##   its reason, and accepts the orderings that are not a
##   cycle;
## - the effective half (``effectiveFloorProblems``) refuses the cycle from
##   systemd's ``Before=`` report, through units the generation does not
##   install, and accepts a unit systemd does not order after the
##   re-assertion;
## - ``ReassertWaitsFor`` names every unit generation 0 orders the
##   re-assertion after, transitively.
##
## Falsifying build, red here: ``boot-ordering-cycles-allowed``.
##
## *Mocking.* The effective half is fed ``systemctl show`` text and an
## ``orderedBeforeOf`` table standing for systemd's ``Before=`` of other
## units, as in ``t_addon_floor_round7``: the comparison is under test, and
## the boot itself is the VM probe the issue records.

import std/[strutils, tables, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/generation0

const
  Prefix = "/repro/store/prefixes/svc/1.0"
  Exe = "/repro/store/prefixes/repro/1.0/bin/repro"

proc unitStanza(name: string; unitExtra = ""; install = "multi-user.target";
                extra = ""): string =
  ## A floored service ``name`` with ``unitExtra`` in its ``[Unit]``.
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n" & unitExtra & "\n[Service]\nUser=a\nExecStart=" &
    Prefix & "/bin/svc\n\n[Install]\nWantedBy=" & install & "\n\"\n" &
    extra & "}\n"

proc rawUnit(name, content: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
    content & "\"\n}\n"

proc refused(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

const Cycle = "an ordering cycle"

suite "the parse-time half refuses a floored unit ordered before the re-assertion":
  test "the issue's first profile: Before=repro-addon-reassert.service":
    let m = refused(unitStanza("a9cb.service",
      "Before=repro-addon-reassert.service\n"))
    checkpoint m
    check Cycle in m
    check "'a9cb.service'" in m
    check "a9cb.service -> repro-addon-reassert.service" in m
  test "the issue's second profile: DefaultDependencies=no before sysinit.target":
    let m = refused(unitStanza("a9cs.service",
      "DefaultDependencies=no\nBefore=sysinit.target\n",
      install = "sysinit.target"))
    checkpoint m
    check Cycle in m
    check "sysinit.target, which the boot re-assertion" in m
  test "before a unit the re-assertion waits for, by each name":
    for u in ["basic.target", "sockets.target", "local-fs.target",
              "repro-store.mount", "repro-addon-secrets.service"]:
      checkpoint u
      check Cycle in refused(unitStanza("a.service", "Before=" & u & "\n"))
  test "through another profile unit's Before=":
    let m = refused(unitStanza("a.service", "Before=b.target\n") &
      rawUnit("b.target", "[Unit]\nBefore=repro-addon-reassert.service\n"))
    checkpoint m
    check "a.service -> b.target -> repro-addon-reassert.service" in m
  test "through another profile unit's After= naming it":
    let m = refused(unitStanza("a.service") &
      rawUnit("c.target", "[Unit]\nAfter=a.service\nBefore=basic.target\n"))
    checkpoint m
    check "a.service -> c.target -> basic.target" in m
  test "through a profile target's implicit After= on what it pulls in":
    # systemd.target(5): a target with default dependencies is ordered
    # after the units it wants.
    let m = refused(unitStanza("a.service", install = "c.target") &
      rawUnit("c.target", "[Unit]\nBefore=repro-addon-reassert.service\n"))
    checkpoint m
    check "a.service -> c.target -> repro-addon-reassert.service" in m
  test "through a profile socket, timer or path unit's boot target":
    # systemd.socket(5), systemd.timer(5), systemd.path(5): with default
    # dependencies each is ordered before sockets.target, timers.target or
    # paths.target, which basic.target is after.
    for (u, body, target) in [
        ("b.socket", "[Socket]\nListenStream=/run/b.sock\n", "sockets.target"),
        ("b.timer", "[Timer]\nOnBootSec=5\n", "timers.target"),
        ("b.path", "[Path]\nPathExists=/run/b\n", "paths.target")]:
      let m = refused(unitStanza("a.service", "Before=" & u & "\n") &
                      rawUnit(u, body))
      checkpoint m
      check ("a.service -> " & u & " -> " & target) in m
  test "before the boot-hold unit (A9 review round 16, finding 6)":
    # The re-assertion is after sysinit.target, which the boot-hold unit is
    # before; the reviewer's probe p_boot_hold_cycle.nim.
    for extra in ["Before=repro-addon-boot-hold.service\n",
                  "DefaultDependencies=no\nBefore=repro-addon-boot-hold.service\n"]:
      checkpoint extra
      check Cycle in refused(unitStanza("a9p.service", extra))
  test "before the egress observer's slice":
    check Cycle in refused(unitStanza("a.service",
      "Before=system-reproagent.slice\n"))
  test "through a drop-in onto the floored unit":
    let m = refused(unitStanza("a.service") &
      "systemd.systemDropIn {\n  unit = \"a.service\"\n  name = \"10-order\"\n" &
      "  content = \"[Unit]\nBefore=repro-addon-reassert.service\n\"\n}\n")
    checkpoint m
    check Cycle in m

suite "the parse-time half accepts what is not a cycle":
  test "ordered before units the re-assertion does not wait for":
    for extra in ["", "Before=multi-user.target\n",
                  "Before=repro-addon.target\n",
                  "After=network-online.target\nBefore=nginx.service\n",
                  "DefaultDependencies=no\n"]:
      checkpoint extra
      check refused(unitStanza("a.service", extra)) == ""
  test "before a profile socket without default dependencies":
    check refused(unitStanza("a.service", "Before=b.socket\n") &
      rawUnit("b.socket", "[Unit]\nDefaultDependencies=no\n\n[Socket]\n" &
              "ListenStream=/run/b.sock\n")) == ""
  test "DefaultDependencies=no pulled into sysinit.target, not ordered before it":
    check refused(unitStanza("a.service", "DefaultDependencies=no\n",
                             install = "sysinit.target")) == ""
  test "a target that orders itself before the unit it pulls in":
    check refused(unitStanza("a.service", install = "c.target") &
      rawUnit("c.target", "[Unit]\nBefore=a.service repro-addon-reassert.service\n")) == ""
  test "a unit that waives the whole floor is not ordered after the re-assertion":
    check refused(unitStanza("a.service", "Before=repro-addon-reassert.service\n",
      extra = "  floorExceptions = [\"serviceFloor: a fixture\"]\n")) == ""

proc input(after, before: string;
           others: Table[string, seq[string]]): EffectiveInput =
  ## A floored unit as systemd shows it, with only its ordering filled in,
  ## and ``others`` standing for systemd's ``Before=`` of every other unit.
  result = EffectiveInput(unit: "a.service", version: FloorVersion,
    show: parseShow("LoadState=loaded\nAfter=" & after & "\nBefore=" &
                    before & "\n"),
    partialShow: true)
  let o = others
  result.orderedBeforeOf = proc (u: string): seq[string] = o.getOrDefault(u)

proc orderingProblems(e: EffectiveInput): seq[string] =
  for l in effectiveFloorProblems(e):
    if "[rule:boot-ordering" in l: result.add(l)

const Reassert = "repro-addon-reassert.service"
let defaultAfter = "basic.target sysinit.target system.slice " & Reassert

suite "the effective half refuses the cycle systemd reports":
  test "the unit's own Before= names the re-assertion":
    let p = orderingProblems(input(defaultAfter,
      "multi-user.target shutdown.target " & Reassert,
      initTable[string, seq[string]]()))
    checkpoint p.join("\n")
    check p.len == 1
    check "a.service -> " & Reassert in p.join("\n")
  test "through units the generation does not install":
    # DefaultDependencies=no, Before= a base unit that is before
    # sysinit.target, which is before basic.target, which the re-assertion
    # is after (the issue's second profile, by another route the parse-time
    # half cannot see). The walk stops at the first unit that runs before
    # sysinit.target (§13 decision 172, ``runsBeforeSysinit``).
    let others = {"a9-early.service": @["sysinit.target"],
                  "sysinit.target": @["basic.target", "emergency.target"],
                  "basic.target": @["multi-user.target", Reassert]}.toTable
    let p = orderingProblems(input(Reassert, "a9-early.service", others))
    checkpoint p.join("\n")
    check p.len == 1
    check "a.service -> a9-early.service -> sysinit.target" in p.join("\n")
  test "before a unit the base orders before sysinit.target":
    let p = orderingProblems(input(Reassert, "systemd-tmpfiles-setup.service",
      initTable[string, seq[string]]()))
    checkpoint p.join("\n")
    check p.len == 1
    check "a.service -> systemd-tmpfiles-setup.service" in p.join("\n")

suite "the effective half accepts what is not a cycle":
  test "ordered before what runs after the re-assertion":
    let others = {"multi-user.target": @["graphical.target", "shutdown.target"],
                  "shutdown.target": @["final.target"]}.toTable
    check orderingProblems(input(defaultAfter,
      "multi-user.target shutdown.target", others)).len == 0
  test "a unit systemd does not order after the re-assertion":
    # A unit rendered with floor version 4 has no such ordering, so being
    # before the re-assertion is no cycle.
    check orderingProblems(input("basic.target", Reassert,
      initTable[string, seq[string]]())).len == 0

suite "ReassertWaitsFor names what generation 0 orders the re-assertion after":
  test "every unit generation 0 orders the re-assertion after, transitively":
    # The closure of "the re-assertion is ordered after X" over generation
    # 0's own units: a unit's After= (and its slice, which systemd orders it
    # after; systemd.slice(5)), and another unit's Before= naming one
    # already in it (systemd.unit(5): each is the other's inverse).
    let objs = generation0Objects(Gen0Inputs(reproExe: Exe,
      agent: AgentUnitsInputs(target: "h1",
        sources: @["https://example.invalid/deploy"],
        allowedAddresses: @["10.0.2.2"]),
      egress: EgressObserverInputs(nft: "/usr/sbin/nft",
                                   allowedAddresses: @["10.0.2.2"])))
    var units = initTable[string, string]()
    for o in objs:
      if o.kind == ookUnit: units[o.unit] = o.content
    check ReassertUnit in units
    check EgressUnit in units
    check FloorReassertUnit == ReassertUnit
    var closure = @[ReassertUnit]
    # The re-assertion keeps systemd's default dependencies, which order it
    # after sysinit.target and basic.target (systemd.service(5), "Default
    # Dependencies"); a unit ordered before either is ordered before it (A9
    # review round 16, finding 6: the boot-hold unit's Before=sysinit.target).
    if "DefaultDependencies=no" notin units[ReassertUnit]:
      closure.add(["sysinit.target", "basic.target"])
    var changed = true
    while changed:
      changed = false
      for name, content in units:
        for d in sectionDirectives(content, ["Unit", "Service"]):
          var reached: seq[string]
          if d.key in ["After", "Slice"] and name in closure:
            reached = d.value.splitWhitespace()
          elif d.key == "Before" and name notin closure:
            for t in d.value.splitWhitespace():
              if t in closure: reached = @[name]
          for t in reached:
            if t notin closure:
              closure.add(t)
              changed = true
    var missing: seq[string]
    for u in closure:
      if u != ReassertUnit and u notin ReassertWaitsFor: missing.add(u)
    checkpoint "closure: " & closure.join(" ")
    checkpoint "missing: " & missing.join("; ")
    check missing.len == 0
    # The egress observer's slice is reached only through the observer.
    check AgentSlice in closure
    check BootHoldUnit in closure
