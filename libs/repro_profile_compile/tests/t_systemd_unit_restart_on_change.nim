## A changed `systemd.systemUnit` takes effect: the §7.3 restart rows.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §7.3
## "Service transitions": a running unit whose file, closure or a resource
## it `depends_on` changed in this apply is restarted, unless the profile
## says `restartIfChanged = false`, in which case the apply reports a
## pending restart. Before this the driver wrote the file, ran
## `daemon-reload` and `enable --now` (which does not restart a running
## unit), so a configuration change to a running daemon waited for whatever
## restarted it next (rpi2 Bring-Up-Plan.md §6 item 4).
##
## What is exercised, with no mocks: the DSL -> adapter -> text -> parser ->
## operation -> RBEB frame path for the new field; the pure transition
## decision the driver applies (`systemdUnitTransition`); and the apply
## step's promotion of a no-op unit whose dependency changed
## (`markDependencyRestarts`, to a fixpoint, and `plannedOperationsFor`)
## against plan records built the way the planner builds them. The `systemctl restart`
## itself needs root and systemd and is driven on the dogfood host.

import std/[strutils, tables, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

const Unit = "[Service]\nExecStart=/usr/bin/true\n"

proc profileWith(restartIfChanged: bool): SystemProfile =
  var intent = ProfileIntent(name: "restart")
  fsSystemFile(intent.resources, path = "/etc/x/x.conf", content = "a=1\n")
  systemdSystemUnit(intent.resources, name = "x.service", content = Unit,
    restartIfChanged = restartIfChanged,
    dependsOn = @["fs.systemFile:/etc/x/x.conf"])
  systemdSystemUnit(intent.resources, name = "y.service", content = Unit)
  profileIntentToSystemProfile(intent)

proc unitNamed(sp: SystemProfile; name: string): SystemResource =
  for r in sp.resources:
    if r.kind == srkSystemdSystemUnit and r.suName == name:
      return r
  raise newException(KeyError, name)

proc envelope(actions: openArray[(string, string)]): PlanEnvelope =
  ## A plan with one record per (address, action), as `producePlan` emits.
  for (address, action) in actions:
    result.operations.add(PlannedOperationRecord(address: address,
      action: action, baselineDigestHex: "00", desiredDigestHex: "11"))

suite "systemd.systemUnit: restart on change (Add-On §7.3)":
  test "restartIfChanged travels DSL -> text -> op -> wire; default restarts":
    let held = profileWith(restartIfChanged = false)
    let x = held.unitNamed("x.service")
    check x.suRestartHeld
    check not held.unitNamed("y.service").suRestartHeld
    let text = renderSystemProfileToText(held)
    check "restartIfChanged = false" in text
    # The default is not written out: an unchanged profile text is the
    # evidence that an omitted flag means "restart".
    check text.count("restartIfChanged") == 1
    let back = parseSystemProfile(text)
    check back.unitNamed("x.service").suRestartHeld
    check not back.unitNamed("y.service").suRestartHeld
    var op = toPrivilegedOperation(back.unitNamed("x.service"))
    check op.suRestartHeld
    check not op.suRestartRequested
    op.suRestartRequested = true
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.suRestartHeld
    check dec.operation.suRestartRequested
    # The editor's stanza form carries it too.
    check "  restartIfChanged = false" in renderStanza(x)
    check "restartIfChanged" notin renderStanza(held.unitNamed("y.service")).join("\n")

  test "the transition table":
    # (wasActive, fileChanged, dependencyChanged, restartHeld) -> transition
    check systemdUnitTransition(true, true, false, false) == sutRestart
    check systemdUnitTransition(true, false, true, false) == sutRestart
    check systemdUnitTransition(true, true, true, true) == sutPendingRestart
    check systemdUnitTransition(true, false, false, false) == sutNone
    # An inactive unit is never started by a change: a timer-driven
    # oneshot must not be run by an apply.
    check systemdUnitTransition(false, true, true, false) == sutNone
    check systemdUnitTransition(false, true, false, true) == sutNone

  test "the plan marks a no-op unit whose depends_on resource changes as restart":
    let sp = profileWith(restartIfChanged = true)
    let fileAddr = "fs.systemFile:/etc/x/x.conf"
    let xAddr = "systemd.systemUnit:x.service"
    let yAddr = "systemd.systemUnit:y.service"
    # The file is updated; both units are unchanged by digest.
    var env = envelope([(fileAddr, "update"), (xAddr, "no-op"), (yAddr, "no-op")])
    markDependencyRestarts(sp, env.operations)
    var byAddr = initTable[string, PlannedOperationRecord]()
    for rec in env.operations: byAddr[rec.address] = rec
    check byAddr[xAddr].action == DependencyRestartAction
    check byAddr[xAddr].summary ==
      "restart system-unit x.service (depends_on changed: " & fileAddr & ")"
    # y declares no dependency on the file: it stays a no-op even though
    # another resource changed.
    check byAddr[yAddr].action == "no-op"
    check byAddr[fileAddr].action == "update"
    # The apply dispatches the marked unit with the restart request, and
    # only it.
    let planned = plannedOperationsFor(renderSystemProfileToText(sp), env)
    var sawFile, sawX, sawY = false
    for p in planned:
      if p.operation.address == fileAddr: sawFile = true
      elif p.operation.address == xAddr:
        sawX = true
        check p.operation.suRestartRequested
      elif p.operation.address == yAddr: sawY = true
    check sawFile and sawX
    check not sawY

  test "the marking is transitive: a unit depending on a restarted unit restarts":
    var intent = ProfileIntent(name: "chain")
    fsSystemFile(intent.resources, path = "/etc/x/x.conf", content = "a=1\n")
    systemdSystemUnit(intent.resources, name = "x.service", content = Unit,
      dependsOn = @["fs.systemFile:/etc/x/x.conf"])
    systemdSystemUnit(intent.resources, name = "z.service", content = Unit,
      dependsOn = @["systemd.systemUnit:x.service"])
    systemdSystemUnit(intent.resources, name = "w.service", content = Unit,
      dependsOn = @["systemd.systemUnit:z.service"])
    let sp = profileIntentToSystemProfile(intent)
    # Records in an order where the dependent comes BEFORE its dependency,
    # so a single pass would miss it; the fixpoint does not.
    var env = envelope([
      ("systemd.systemUnit:w.service", "no-op"),
      ("systemd.systemUnit:z.service", "no-op"),
      ("systemd.systemUnit:x.service", "no-op"),
      ("fs.systemFile:/etc/x/x.conf", "update")])
    markDependencyRestarts(sp, env.operations)
    for rec in env.operations:
      if rec.address == "fs.systemFile:/etc/x/x.conf":
        check rec.action == "update"
      else:
        check rec.action == DependencyRestartAction

  test "negative controls: nothing changed, or the unit's own file changed":
    let sp = profileWith(restartIfChanged = true)
    let fileAddr = "fs.systemFile:/etc/x/x.conf"
    let xAddr = "systemd.systemUnit:x.service"
    var quiet = envelope([(fileAddr, "no-op"), (xAddr, "no-op")])
    markDependencyRestarts(sp, quiet.operations)
    for rec in quiet.operations:
      check rec.action == "no-op"
    # A unit that is itself an update is dispatched as an update, not
    # marked: the driver sees the file change and restarts on that.
    var env = envelope([(fileAddr, "update"), (xAddr, "update")])
    markDependencyRestarts(sp, env.operations)
    for rec in env.operations:
      check rec.action == "update"
    for p in plannedOperationsFor(renderSystemProfileToText(sp), env):
      if p.operation.kind == pokSystemdSystemUnit:
        check not p.operation.suRestartRequested
