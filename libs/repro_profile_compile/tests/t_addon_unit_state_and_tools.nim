## Add-On Mode: relying on a distribution unit, and operator tools from a
## `package(apt)` closure.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §4.1, the
## `unitState` class and the paragraph after the table on commands an
## operator runs by hand. Two needs the first Add-On profile (rpi2) hit:
##
##   * `avahi-daemon.service` is the distribution's (it publishes the mDNS
##     name the fleet uses) and must be enabled and active, but the add-on
##     may not own its unit file or conffiles. `systemd.unitState` records
##     the requirement and converges only enable/disable and start/stop.
##   * `ipmitool` and `wakeonlan` come from apt closures and must be on an
##     operator's PATH; the add-on never writes into `/usr`. `linux.addOnTool`
##     writes a wrapper under `/etc/repro/bin` that runs the closure's binary
##     through `reprobuild-sandbox-launcher` with the closure's `/usr` bound
##     over `/usr`, and `addOnToolPath()` is the `/etc/profile.d` hook.
##
## Exercised with no mocks: DSL -> adapter -> text -> parser -> operation ->
## RBEB frame for both kinds; the broker's validation of names; the pure
## renderers of the wrapper and launcher manifest; and the pure reading of
## `systemctl show` output the unitState driver observes with. `systemctl`
## and the writes need root and are driven on the dogfood host.

import std/[os, strutils, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile
import repro_dsl_stdlib/packages/apt_closure

const LockText = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

proc compiled(): SystemProfile =
  var intent = ProfileIntent(name: "rpi2")
  systemdUnitState(intent.resources, name = "avahi-daemon.service")
  systemdUnitState(intent.resources, name = "bluetooth.service",
    enabled = false, state = "Stopped")
  addOnTool(intent.resources, command = "node_exporter",
    aptClosureLock = LockText, program = "/usr/bin/prometheus-node-exporter")
  addOnTool(intent.resources, command = "wakeonlan", aptClosureLock = LockText)
  addOnToolPath(intent.resources)
  profileIntentToSystemProfile(intent)

proc byAddress(sp: SystemProfile; address: string): SystemResource =
  for r in sp.resources:
    if r.address == address: return r
  raise newException(KeyError, address)

suite "Add-On: systemd.unitState and linux.addOnTool":
  test "systemd.unitState: DSL -> text -> op -> wire, enabled/state carried":
    let sp = compiled()
    let avahi = sp.byAddress("systemd.unitState:avahi-daemon.service")
    check avahi.kind == srkSystemdUnitState
    check avahi.usName == "avahi-daemon.service"
    check avahi.usEnabled and avahi.usRunning
    let bt = sp.byAddress("systemd.unitState:bluetooth.service")
    check not bt.usEnabled and not bt.usRunning
    let back = parseSystemProfile(renderSystemProfileToText(sp))
    let bt2 = back.byAddress("systemd.unitState:bluetooth.service")
    check not bt2.usEnabled and not bt2.usRunning
    let op = toPrivilegedOperation(back.byAddress(
      "systemd.unitState:avahi-daemon.service"))
    check op.kind == pokSystemdUnitState
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.usName == "avahi-daemon.service"
    check dec.operation.usEnabled and dec.operation.usRunning
    check not dec.operation.usDestroy
    # The editor's stanza form round-trips too.
    let stanza = renderStanza(bt).join("\n")
    check "systemd.unitState {" in stanza
    check "enabled = false" in stanza and "Stopped" in stanza
    # The desired digest is over the two flags, nothing else.
    check posixSystemDesiredDigestHex(op) ==
      posixDigestHexOfText(unitStateDigestText(enabled = true, active = true))

  test "systemd.unitState: the broker refuses an unsafe unit name":
    var op = toPrivilegedOperation(compiled().byAddress(
      "systemd.unitState:avahi-daemon.service"))
    op.usName = "../x.service"
    check operationValidationError(op).len > 0
    op.usName = "no-suffix"
    check operationValidationError(op).len > 0

  test "systemd.unitState: reading systemctl show":
    let active = parseUnitStateShow(
      "LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n")
    check active.loaded and active.enabled and active.active
    let inactive = parseUnitStateShow(
      "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n")
    check inactive.loaded and not inactive.enabled and not inactive.active
    # A unit that cannot be enabled or disabled counts as enabled: the
    # requirement "this must be enabled" is met, and `systemctl enable`
    # would only print a warning.
    for s in ["static", "alias", "indirect", "generated", "transient"]:
      let st = parseUnitStateShow("LoadState=loaded\nActiveState=active\n" &
        "UnitFileState=" & s & "\n")
      check st.enabled and st.fixedEnablement
    check parseUnitStateShow("UnitFileState=enabled-runtime\n").enabled
    check not parseUnitStateShow("UnitFileState=enabled\n").fixedEnablement
    check not active.fixedEnablement
    # A oneshot without RemainAfterExit is active only while it runs.
    check parseUnitStateShow("Type=oneshot\nRemainAfterExit=no\n").transientOneshot
    check not parseUnitStateShow("Type=oneshot\nRemainAfterExit=yes\n").transientOneshot
    check not parseUnitStateShow("Type=simple\nRemainAfterExit=no\n").transientOneshot
    check not parseUnitStateShow(
      "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n").loaded
    check not parseUnitStateShow(
      "LoadState=masked\nActiveState=inactive\nUnitFileState=masked\n").loaded

  test "linux.addOnTool: DSL -> text -> op -> wire, with the lock":
    let sp = compiled()
    let wol = sp.byAddress("linux.addOnTool:wakeonlan")
    check wol.kind == srkLinuxAddOnTool
    check wol.atCommand == "wakeonlan"
    check wol.atProgram == "/usr/bin/wakeonlan"   # the default
    check wol.atAptClosureLock == LockText
    let ne = sp.byAddress("linux.addOnTool:node_exporter")
    check ne.atProgram == "/usr/bin/prometheus-node-exporter"
    let back = parseSystemProfile(renderSystemProfileToText(sp))
    let ne2 = back.byAddress("linux.addOnTool:node_exporter")
    check ne2.atProgram == "/usr/bin/prometheus-node-exporter"
    check ne2.atAptClosureLock == LockText
    let op = toPrivilegedOperation(ne2)
    check op.kind == pokLinuxAddOnTool
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.atCommand == "node_exporter"
    check dec.operation.atProgram == "/usr/bin/prometheus-node-exporter"
    check dec.operation.atAptClosureLock == LockText

  test "linux.addOnTool: what lands on disk":
    let lock = parseAptClosureLock(LockText)
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, lock)
    check addOnToolWrapperPath("wakeonlan") == "/etc/repro/bin/wakeonlan"
    check addOnToolManifestPath("wakeonlan") ==
      "/etc/repro/bin/wakeonlan.launcher.manifest"
    let manifest = renderAddOnToolManifest(prefix, "/usr/bin/wakeonlan")
    # The closure's /usr over /usr, read-only, and the program by its FHS
    # path inside: the same view the unit binding gives a service.
    check (prefix & "/usr:/usr:rbind,ro") in manifest.splitLines()
    check "exec=/usr/bin/wakeonlan" in manifest.splitLines()
    let wrapper = renderAddOnToolWrapper(addOnToolManifestPath("wakeonlan"))
    check wrapper.startsWith("#!/bin/sh\n")
    # The wrapper names the LINK, never an install directory: its bytes, and
    # so the desired digest, are the same whichever `repro` computes them.
    check AddOnToolLauncherLink == "/etc/repro/bin/.reprobuild-sandbox-launcher"
    check "exec '/etc/repro/bin/.reprobuild-sandbox-launcher' " &
      "--manifest='/etc/repro/bin/wakeonlan.launcher.manifest' -- \"$@\"" in
      wrapper.splitLines()
    check getAppDir() notin wrapper
    check addOnToolLauncherPath().endsWith("/reprobuild-sandbox-launcher")
    # The desired digest covers both files, so a hand-edited wrapper or a
    # changed closure (a different prefix) is drift.
    let op = toPrivilegedOperation(compiled().byAddress("linux.addOnTool:wakeonlan"))
    check posixSystemDesiredDigestHex(op) == posixDigestHexOfText(
      addOnToolDigestText(wrapper, manifest))

  test "linux.addOnTool: refusals":
    var intent = ProfileIntent(name: "rpi2")
    addOnTool(intent.resources, command = "../sh", aptClosureLock = LockText)
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(intent)
    intent = ProfileIntent(name: "rpi2")
    addOnTool(intent.resources, command = "x", aptClosureLock = "not a lock")
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(intent)
    intent = ProfileIntent(name: "rpi2")
    addOnTool(intent.resources, command = "x", aptClosureLock = LockText,
      program = "relative/bin/x")
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(intent)
    var op = toPrivilegedOperation(compiled().byAddress("linux.addOnTool:wakeonlan"))
    op.atCommand = "a b"
    check operationValidationError(op).len > 0

  test "addOnToolPath is the /etc/profile.d hook, declared once":
    let sp = compiled()
    let hook = sp.byAddress("fs.systemFile:/etc/profile.d/repro-addon.sh")
    check hook.kind == srkFsSystemFile
    check hook.sfContent == AddOnToolPathScript
    check "/etc/repro/bin" in hook.sfContent
    check hook.sfContent.startsWith("#")

  test "a unit declared as both unitState and systemUnit is refused on both paths":
    var intent = ProfileIntent(name: "rpi2")
    systemdUnitState(intent.resources, name = "x.service")
    systemdSystemUnit(intent.resources, name = "x.service",
      content = "[Service]\nExecStart=/usr/bin/true\n")
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(intent)
    expect ESystemProfileInvalid:
      discard parseSystemProfile(
        "systemd.unitState { name = \"x.service\" }\n" &
        "systemd.systemUnit { name = \"x.service\" content = \"[Service]\" }\n")
    # Different names are fine.
    intent = ProfileIntent(name: "rpi2")
    systemdUnitState(intent.resources, name = "x.service")
    systemdSystemUnit(intent.resources, name = "y.service",
      content = "[Service]\nExecStart=/usr/bin/true\n")
    check profileIntentToSystemProfile(intent).resources.len == 2
