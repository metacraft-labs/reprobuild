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
## (`unitsWithChangedDependencies`, `plannedOperationsFor`) against a plan
## envelope built the way the planner builds it. The `systemctl restart`
## itself needs root and systemd and is driven on the dogfood host.

import std/[sets, strutils, unittest]

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

  test "a no-op unit whose depends_on resource changes is promoted to a restart":
    let sp = profileWith(restartIfChanged = true)
    let fileAddr = "fs.systemFile:/etc/x/x.conf"
    let xAddr = "systemd.systemUnit:x.service"
    let yAddr = "systemd.systemUnit:y.service"
    # The file is updated; both units are unchanged by digest.
    let env = envelope([(fileAddr, "update"), (xAddr, "no-op"), (yAddr, "no-op")])
    check unitsWithChangedDependencies(sp, env) == toHashSet([xAddr])
    let text = renderSystemProfileToText(sp)
    let (planned, promoted) = plannedOperationsFor(text, env)
    check promoted == toHashSet([xAddr])
    var sawFile, sawX, sawY = false
    for p in planned:
      if p.operation.address == fileAddr: sawFile = true
      elif p.operation.address == xAddr:
        sawX = true
        check p.operation.suRestartRequested
      elif p.operation.address == yAddr: sawY = true
    check sawFile and sawX
    # y declares no dependency on the file: it stays a no-op even though
    # another resource changed.
    check not sawY

  test "negative controls: nothing changed, or the unit's own file changed":
    let sp = profileWith(restartIfChanged = true)
    let fileAddr = "fs.systemFile:/etc/x/x.conf"
    let xAddr = "systemd.systemUnit:x.service"
    check unitsWithChangedDependencies(sp,
      envelope([(fileAddr, "no-op"), (xAddr, "no-op")])).len == 0
    # A unit that is itself an update is dispatched as an update, not
    # promoted: the driver sees the file change and restarts on that.
    let env = envelope([(fileAddr, "update"), (xAddr, "update")])
    check unitsWithChangedDependencies(sp, env).len == 0
    let (planned, promoted) = plannedOperationsFor(
      renderSystemProfileToText(sp), env)
    check promoted.len == 0
    for p in planned:
      if p.operation.kind == pokSystemdSystemUnit:
        check not p.operation.suRestartRequested
