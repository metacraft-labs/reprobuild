## Add-On Mode: a ``systemd.systemUnit`` with a ``package(apt)`` closure,
## from the profile DSL to the broker's wire frame.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §2.3 and
## §8.3 item 5. A unit that consumes a ``package(apt, ...)`` closure is
## installed with native ``BindReadOnlyPaths=`` directives, NOT with its
## ``ExecStart`` wrapped in ``reprobuild-sandbox-launcher``, so that
## ``AmbientCapabilities=``, ``DynamicUser=``, ``LoadCredential=`` and
## ``DeviceAllow=`` keep their native meaning.
##
## The path exercised is the one a deployed profile takes:
## ``systemdSystemUnit(..., aptClosureLock = ...)`` (``repro_profile``) ->
## ``profileIntentToSystemProfile`` (``repro_profile_compile``) ->
## ``toPrivilegedOperation`` (``repro_infra``) -> ``operationValidationError``
## and the RBEB frame codec (``repro_elevation``) — plus the ``system.nim``
## text form both ways. The lock is a real one: the pinned Debian trixie armhf
## closure of ``prometheus-node-exporter`` that
## ``repro_dsl_stdlib/tests/t_addon_apt_closure_trixie_armhf.nim`` realises
## from the real archive. No mocks; nothing here touches the host (the
## driver's apply needs root and systemd and is exercised on the dogfood
## host, see the D2 report).

import std/[strutils, tables, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile
import repro_dsl_stdlib/packages/apt_closure

const LockText = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

const Unit = """[Unit]
Description=Prometheus blackbox exporter (Add-On)

[Service]
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=127.0.0.1:9100
DynamicUser=yes
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
LoadCredential=token:/run/repro/secrets/exporter-token
DeviceAllow=char-usb_device rw
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
"""

proc expectedBindLine(): string =
  "BindReadOnlyPaths=" & aptClosurePrefixPath(AddOnSystemStoreRoot,
    parseAptClosureLock(LockText)) & "/usr:/usr"

proc unitFromDsl(lock: string): SystemResource =
  var intent = ProfileIntent(name: "rpi2")
  systemdSystemUnit(intent.resources, name = "node-exporter.service",
    content = Unit, aptClosureLock = lock)
  let sp = profileIntentToSystemProfile(intent)
  check sp.resources.len == 1
  sp.resources[0]

suite "Add-On: systemd.systemUnit with a package(apt) closure":
  test "the installed unit binds the closure natively, with no wrapper":
    let r = unitFromDsl(LockText)
    check r.kind == srkSystemdSystemUnit
    check r.suAptClosureLock == LockText
    let op = toPrivilegedOperation(r)
    let lines = op.suContent.splitLines()
    # The binding, at the pinned prefix, in [Service].
    check expectedBindLine() in lines
    check "InaccessiblePaths=-/etc/ld.so.preload" in lines
    check lines.find(expectedBindLine()) == lines.find("[Service]") + 1
    check expectedBindLine().startsWith("BindReadOnlyPaths=/repro/store/" &
      "prefixes/apt-closure-prometheus-node-exporter/1.9.0-1_b4-")
    # ExecStart names the daemon directly; no sandbox launcher anywhere.
    check "ExecStart=/usr/bin/prometheus-node-exporter " &
      "--web.listen-address=127.0.0.1:9100" in lines
    check "sandbox-launcher" notin op.suContent
    # The native service features are carried through unchanged.
    for l in ["DynamicUser=yes", "AmbientCapabilities=CAP_NET_RAW",
              "CapabilityBoundingSet=CAP_NET_RAW",
              "LoadCredential=token:/run/repro/secrets/exporter-token",
              "DeviceAllow=char-usb_device rw", "ProtectSystem=strict"]:
      check l in lines
    # The broker gets the lock to realise, and accepts the frame.
    check op.suAptClosureLock == LockText
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: ""))).body)
    check dec.operation.suAptClosureLock == LockText
    check dec.operation.suContent == op.suContent

  test "negative control: without a lock the unit is installed verbatim":
    let op = toPrivilegedOperation(unitFromDsl(""))
    check op.suContent == Unit
    check "BindReadOnlyPaths=" notin op.suContent
    check op.suAptClosureLock == ""

  test "the broker refuses a frame whose content does not bind its lock":
    var op = toPrivilegedOperation(unitFromDsl(LockText))
    op.suContent = Unit
    check operationValidationError(op).contains("bind line")
    op = toPrivilegedOperation(unitFromDsl(LockText))
    op.suAptClosureLock = LockText.replace("root prometheus-node-exporter",
      "root nonexistent")
    check operationValidationError(op).len > 0
    # The renderer's refusals hold on the frame too, not only the presence
    # of the bind line: a later empty assignment resets systemd's list, a
    # tmpfs over /usr hides the closure, a second bind line is not the
    # rendered unit.
    let good = toPrivilegedOperation(unitFromDsl(LockText))
    check operationValidationError(good) == ""
    for tail in ["BindReadOnlyPaths=\n", "InaccessiblePaths=\n",
                 "TemporaryFileSystem=/usr\n", "RootDirectory=/srv\n",
                 expectedBindLine() & "\n"]:
      op = good
      op.suContent = good.suContent & tail
      check operationValidationError(op).len > 0
    # A commented-out directive is not read.
    op = good
    op.suContent = good.suContent & "# RootDirectory=/srv\n"
    check operationValidationError(op) == ""

  test "a malformed lock or an unbindable unit is refused at plan time":
    expect ESystemProfileInvalid:
      discard unitFromDsl("not a lock")
    var intent = ProfileIntent(name: "rpi2")
    systemdSystemUnit(intent.resources, name = "wrapped.service",
      content = Unit.replace("ExecStart=/usr/bin/",
        "ExecStart=/usr/local/bin/reprobuild-sandbox-launcher -- /usr/bin/"),
      aptClosureLock = LockText)
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(intent)
    for bad in ["BindReadOnlyPaths=", "TemporaryFileSystem=/usr/lib",
                "RootImage=/srv/x.img"]:
      var i2 = ProfileIntent(name: "rpi2")
      systemdSystemUnit(i2.resources, name = "bad.service",
        content = Unit.replace("ProtectSystem=strict", bad),
        aptClosureLock = LockText)
      expect ESystemProfileInvalid:
        discard profileIntentToSystemProfile(i2)

  test "the system.nim text form carries the lock both ways":
    let r = unitFromDsl(LockText)
    let text = renderSystemProfileToText(SystemProfile(resources: @[r]))
    check "aptClosureLock = " in text
    let back = parseSystemProfile(text)
    check back.resources.len == 1
    check back.resources[0].suAptClosureLock.strip() == LockText.strip()
    check toPrivilegedOperation(back.resources[0]).suContent.splitLines().
      contains(expectedBindLine())
    let stanza = renderStanza(r).join("\n")
    check "aptClosureLock = " in stanza
