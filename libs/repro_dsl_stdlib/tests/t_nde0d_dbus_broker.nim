## NDE0-D unit tests: native dbus-broker package (NDE-C migrated).
##
## Exercises the spec'd public surface of
## ``recipes/packages/de-foundation/dbus-broker/repro.nim`` through the
## DSL's M8 / M9.A / M9.B materialisation path
## (``fs.configFile`` / ``fs.managedBlock`` / ``fs.symlink`` /
## ``fs.directory`` registration + ``consumeConfigFile`` /
## ``consumeManagedBlock`` / ``consumeSymlink`` / ``consumeDirectory``
## materialisation), plus the M9.C extended service: surface and M9.D
## typed-enum config surface (FIRST native NDE recipe to exercise both),
## rather than the shim's deprecated ``materializeDbusBroker``
## orchestrator. The recipe's render* procs still come from the shim
## verbatim — only the on-disk emission path moved.
##
## Required test surfaces (preserved from the pre-NDE-C test; hashHex
## literal values change because the M9.A cache-key composition differs
## from the shim's, but the structural assertions survive):
##
##   1. dbus.socket planted at ``usr/lib/systemd/system/`` (cascade-G
##      fix). NOT-at-``lib/systemd/system/dbus.socket``.
##   2. dbus.service likewise (cascade-G fix).
##   3. messagebus user block has the NDE-spec-block triple-form
##      sentinel (open + close) with blockId =
##      ``system-user-messagebus`` + content =
##      ``messagebus:x:101:101:...``.
##   4. Configurable: changing ``messagebusUid`` changes the planted
##      block content.
##   5. Configurable: changing ``busActivationStrategy`` from basBroker
##      to basDaemon produces different unit-file content (M9.D enum
##      override).
##   6. Idempotency: same config → same store paths.
##   7. Cache-key invalidation: changing ``busActivationStrategy``
##      invalidates the dbusService store path but NOT the
##      messagebus user block path.
##   8. Byte-determinism across two independent materialize roots.
##   9. Belt-and-braces symlink target: /etc/systemd/system/dbus.socket
##      resolves to /usr/lib/systemd/system/dbus.socket. Assert the
##      recorded target string.
##  10. parseBusActivationStrategy round-trips + raises on unknown.
##  11. /var/lib/dbus spool placeholder via M9.B fs.directory.
##  12. system.conf default policy XML shape + messagebus user binding.
##  13. Cache-key isolation across artifacts (hash distinctness).
##
## Plus a "DSL surface" suite at the end pinning the new
## ``files <name>:`` artifact registration shape against the DSL's M3
## ``registeredArtifacts`` accessor + the M9.C ``service:`` block
## registration against ``registeredServices``, confirming the recipe
## genuinely exercises the typed surface rather than silently regressing
## to the legacy "configFile is a Nim proc the recipe calls directly"
## path.

import std/[os, strutils, tempfiles, unittest]

# The shim module — still owns the render* template procs +
# BusActivationStrategy enum + parseBusActivationStrategy +
# DbusBrokerConfig type + DefaultStoreRoot re-export. NDE-C does NOT
# remove the shim; the deprecated ``materializeDbusBroker`` + on-disk
# emitter procs stay reachable for any caller that still imports them.
import repro_dsl_stdlib/packages/de_foundation/dbus_broker

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` arm + the ``service systemBus:``
# arm so the M8/M9.A/M9.B + M9.C tables are pre-populated against the
# default configurables. The recipe also re-exports the per-artifact
# ``register*`` helpers the test fixture below uses to re-register
# after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/de-foundation/dbus-broker/repro" as recipe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc resetRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A/M9.B registry + materialiser
  ## row, drop any pending configurable overrides for the dbusBroker
  ## package, then re-register every fs.* output the recipe owns against
  ## the (now-default) configurables. ``registerStoreRoot`` runs LAST
  ## because ``resetDslPortMaterialiseState`` clears the store-root
  ## table along with the materialiser side-tables (the M9.A reset proc
  ## is "drop EVERY registered storeRoot + every materialisation side-
  ## table row" — see the proc's docstring).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetConfigurable("dbusBroker.aptSnapshot")
  resetConfigurable("dbusBroker.busActivationStrategy")
  resetConfigurable("dbusBroker.messagebusUid")
  resetConfigurable("dbusBroker.messagebusGid")
  registerStoreRoot("dbusBroker", storeRoot, dhaSha256)
  recipe.registerDbusBrokerFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9 entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it — see above).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  registerStoreRoot("dbusBroker", storeRoot, dhaSha256)
  recipe.registerDbusBrokerFiles()

# ---------------------------------------------------------------------------
# Convenience consumers — one per artifact. Centralises the per-output
# path the recipe uses so the test reads identically to the v1 shape.
# ---------------------------------------------------------------------------

proc consumeDbusSocket(): DslManagedFiles =
  consumeConfigFile("dbusBroker", "/usr/lib/systemd/system/dbus.socket")
proc consumeDbusService(): DslManagedFiles =
  consumeConfigFile("dbusBroker", "/usr/lib/systemd/system/dbus.service")
proc consumeDbusSocketUnmask(): DslManagedFiles =
  consumeSymlink("dbusBroker", "/etc/systemd/system/dbus.socket")
proc consumeMessagebusPasswd(): DslManagedFiles =
  consumeManagedBlock("/etc/passwd")
proc consumeMessagebusGroup(): DslManagedFiles =
  consumeManagedBlock("/etc/group")
proc consumeSystemConf(): DslManagedFiles =
  consumeConfigFile("dbusBroker", "/etc/dbus-1/system.conf")
proc consumeSpoolDir(): DslManagedFiles =
  consumeDirectory("dbusBroker", "/var/lib/dbus")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-D dbus-broker package":

  test "cascade-G fix: dbus.socket planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion: R9 systemd 257.9 dropped
    # /lib/systemd/system/ from the default UnitPath, so a unit
    # planted only under /lib/ would be invisible at boot. The
    # native package must plant at /usr/lib/.
    let root = createTempDir("nde0d_socket_path_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let dbusSocket = consumeDbusSocket()

    # AT: usr/lib/systemd/system/ (M9.A canonicalisePath strips leading /)
    check dbusSocket.relPath == "usr/lib/systemd/system/dbus.socket"
    check fileExists(dbusSocket.storePath /
                     "usr/lib/systemd/system/dbus.socket")
    # NOT-AT: lib/systemd/system/
    check not fileExists(dbusSocket.storePath /
                         "lib/systemd/system/dbus.socket")
    # Content sanity: it's a socket unit pointing at the canonical
    # system_bus_socket path.
    let bytes = readStoreFile(dbusSocket)
    check "[Socket]" in bytes
    check "ListenStream=/run/dbus/system_bus_socket" in bytes
    check "WantedBy=sockets.target" in bytes
    # Sanity: the store path is rooted under the override.
    check dbusSocket.storePath.startsWith(root)
    # M9.A sha256 hashes are 64 lower-hex chars (the shim's 16-char
    # truncated form is gone; the structural check is "non-empty hex").
    check dbusSocket.hashHex.len == 64

  test "cascade-G fix: dbus.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # Same cascade-G assertion for the .service unit.
    let root = createTempDir("nde0d_service_path_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let dbusService = consumeDbusService()

    check dbusService.relPath == "usr/lib/systemd/system/dbus.service"
    check fileExists(dbusService.storePath /
                     "usr/lib/systemd/system/dbus.service")
    check not fileExists(dbusService.storePath /
                         "lib/systemd/system/dbus.service")
    let bytes = readStoreFile(dbusService)
    check "[Service]" in bytes
    check "Requires=dbus.socket" in bytes
    check "Alias=dbus.service" in bytes
    # Default strategy is basBroker → broker-launch ExecStart=.
    check "/usr/bin/dbus-broker-launch" in bytes
    check "/usr/bin/dbus-daemon" notin bytes

  test "sentinel shape: messagebus user block uses NDE-spec-block triple form":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = dbusBroker (the M8/M9.A path uses
    # the DSL package identifier verbatim, not the kebab-cased shim
    # alias), blockId = system-user-messagebus.
    let root = createTempDir("nde0d_sentinel_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let passwdBlock = consumeMessagebusPasswd()
    let bytes = readStoreFile(passwdBlock)

    let expectOpen =
      "# >>> repro:system:dbusBroker:system-user-messagebus >>>"
    let expectClose =
      "# <<< repro:system:dbusBroker:system-user-messagebus <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # Open MUST come before close.
    check bytes.find(expectOpen) < bytes.find(expectClose)
    # And the rendered passwd line sits between them.
    let openIdx = bytes.find(expectOpen)
    let closeIdx = bytes.find(expectClose)
    let between = bytes[openIdx + expectOpen.len ..< closeIdx]
    check "messagebus:x:101:101" in between
    check "/var/lib/dbus" in between
    check "/usr/sbin/nologin" in between

  test "configurable: changing messagebusUid propagates to passwd block content":
    let root = createTempDir("nde0d_uid_", "")
    defer: removeDir(root)
    resetRecipeState(root)
    setConfigurable("dbusBroker.messagebusUid", 500)
    setConfigurable("dbusBroker.messagebusGid", 500)
    reregisterWithCurrentConfigurables(root)

    let passwdBytes = readStoreFile(consumeMessagebusPasswd())
    let groupBytes = readStoreFile(consumeMessagebusGroup())

    check "messagebus:x:500:500" in passwdBytes
    check "messagebus:x:101:101" notin passwdBytes
    check "messagebus:x:500:" in groupBytes
    check "messagebus:x:101:" notin groupBytes

  test "configurable: busActivationStrategy broker vs daemon produces different unit-file content (M9.D enum)":
    # The load-bearing strategy-toggle test exercising the M9.D
    # typed-enum config surface. Broker variant uses
    # /usr/bin/dbus-broker-launch; daemon variant uses
    # /usr/bin/dbus-daemon. The socket unit is strategy-agnostic.
    let rootA = createTempDir("nde0d_strat_brk_", "")
    let rootB = createTempDir("nde0d_strat_dmn_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A — default (basBroker).
    resetRecipeState(rootA)
    let brokerBytes = readStoreFile(consumeDbusService())

    # Pass B — flip the M9.D typed-enum to basDaemon.
    resetRecipeState(rootB)
    setConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy", basDaemon)
    reregisterWithCurrentConfigurables(rootB)
    let daemonBytes = readStoreFile(consumeDbusService())

    # The two service unit files MUST differ.
    check brokerBytes != daemonBytes

    # Broker variant: ExecStart= points at dbus-broker-launch.
    check "/usr/bin/dbus-broker-launch" in brokerBytes
    check "/usr/bin/dbus-daemon" notin brokerBytes

    # Daemon variant: ExecStart= points at dbus-daemon.
    check "/usr/bin/dbus-daemon" in daemonBytes
    check "/usr/bin/dbus-broker-launch" notin daemonBytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("nde0d_idem_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # First materialisation pass — every consume call writes the file +
    # records the handle in the M9 idempotency side-table.
    let sockA = consumeDbusSocket()
    let svcA = consumeDbusService()
    let umA = consumeDbusSocketUnmask()
    let pwA = consumeMessagebusPasswd()
    let grA = consumeMessagebusGroup()
    let cfA = consumeSystemConf()
    let dirA = consumeSpoolDir()

    # Second materialisation pass — every consume call returns the
    # cached handle (the M9 side-tables short-circuit on the second
    # call). Every output should land at exactly the same store path.
    let sockB = consumeDbusSocket()
    let svcB = consumeDbusService()
    let umB = consumeDbusSocketUnmask()
    let pwB = consumeMessagebusPasswd()
    let grB = consumeMessagebusGroup()
    let cfB = consumeSystemConf()
    let dirB = consumeSpoolDir()

    check sockA.storePath == sockB.storePath
    check svcA.storePath  == svcB.storePath
    check umA.storePath   == umB.storePath
    check pwA.storePath   == pwB.storePath
    check grA.storePath   == grB.storePath
    check cfA.storePath   == cfB.storePath
    check dirA.storePath  == dirB.storePath

  test "cache-key invalidation: strategy change re-keys dbusService but NOT messagebus / socket / system.conf":
    # This is the spec's contract: "Toggling
    # config.busActivationStrategy from broker to daemon rebuilds
    # only the affected files". The dbus.service unit-file content
    # depends on strategy; messagebus user blocks + dbus.socket +
    # system.conf + spool-dir don't.
    let root = createTempDir("nde0d_invalidation_", "")
    defer: removeDir(root)

    # Pass A — default basBroker.
    resetRecipeState(root)
    let sockA = consumeDbusSocket()
    let svcA = consumeDbusService()
    let umA = consumeDbusSocketUnmask()
    let pwA = consumeMessagebusPasswd()
    let grA = consumeMessagebusGroup()
    let cfA = consumeSystemConf()
    let dirA = consumeSpoolDir()

    # Pass B — strategy flipped to basDaemon. ``reregisterWith
    # CurrentConfigurables`` resets every M8/M9.A/M9.B side table AND
    # re-binds the store-root (the M9.A reset wipes it as part of the
    # symmetric "drop EVERY registered storeRoot" contract).
    setConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy", basDaemon)
    reregisterWithCurrentConfigurables(root)
    let sockB = consumeDbusSocket()
    let svcB = consumeDbusService()
    let umB = consumeDbusSocketUnmask()
    let pwB = consumeMessagebusPasswd()
    let grB = consumeMessagebusGroup()
    let cfB = consumeSystemConf()
    let dirB = consumeSpoolDir()

    # dbusService MUST land at a different store path.
    check svcA.storePath != svcB.storePath
    # Everything else MUST stay at the same store path.
    check sockA.storePath == sockB.storePath
    check umA.storePath   == umB.storePath
    check pwA.storePath   == pwB.storePath
    check grA.storePath   == grB.storePath
    check cfA.storePath   == cfB.storePath
    check dirA.storePath  == dirB.storePath

  test "determinism: every output byte-identical across two independent roots":
    # The idempotency test catches re-entry into the same store root
    # (a side-table cache hit could mask a non-deterministic writer);
    # this test forces a fresh write into a SECOND root and byte-
    # compares the result. Mirrors NDE0-S's determinism test.
    let rootA = createTempDir("nde0d_detA_", "")
    let rootB = createTempDir("nde0d_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A.
    resetRecipeState(rootA)
    let sockA = consumeDbusSocket()
    let svcA = consumeDbusService()
    let pwA = consumeMessagebusPasswd()
    let grA = consumeMessagebusGroup()
    let cfA = consumeSystemConf()

    # Pass B — fully fresh state, fresh root, same default configurables.
    resetRecipeState(rootB)
    let sockB = consumeDbusSocket()
    let svcB = consumeDbusService()
    let pwB = consumeMessagebusPasswd()
    let grB = consumeMessagebusGroup()
    let cfB = consumeSystemConf()

    # Hash-segment basenames match.
    check extractFilename(sockA.storePath) == extractFilename(sockB.storePath)
    check extractFilename(svcA.storePath)  == extractFilename(svcB.storePath)
    check extractFilename(pwA.storePath)   == extractFilename(pwB.storePath)
    check extractFilename(cfA.storePath)   == extractFilename(cfB.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(sockA) == readStoreFile(sockB)
    check readStoreFile(svcA)  == readStoreFile(svcB)
    check readStoreFile(pwA)   == readStoreFile(pwB)
    check readStoreFile(grA)   == readStoreFile(grB)
    check readStoreFile(cfA)   == readStoreFile(cfB)

  test "belt-and-braces cascade-G fix: /etc/systemd/system/dbus.socket records /usr/lib target":
    # The Tier-2 stage 5 belt-and-braces: even though dbus.socket
    # lives at /usr/lib/systemd/system/, we also plant an
    # /etc/systemd/system/dbus.socket symlink record so
    # ``systemctl status dbus.socket`` works even if a future overlay
    # segment shadows /usr/lib. The recorded target MUST be the
    # cascade-G-correct /usr/lib path, NOT the legacy /lib path that
    # R9 dropped. On POSIX hosts M9.B materialises a real OS-level
    # symlink; on Windows the recipe-side ``fs.symlink`` falls back
    # to a regular file with a ``# repro-symlink-intent`` header.
    let root = createTempDir("nde0d_belt_braces_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let umHandle = consumeDbusSocketUnmask()
    let expectedTarget = "/usr/lib/systemd/system/dbus.socket"

    when defined(windows):
      # Windows fallback: regular file with the intent header.
      let raw = readStoreFile(umHandle)
      let bytes = raw.strip()
      check expectedTarget in bytes
      check "/lib/systemd/system/dbus.socket" notin
        bytes.replace("/usr/lib/systemd/system/dbus.socket", "")
      check "# repro-symlink-intent" in raw
    else:
      # POSIX: real symlink. ``expandSymlink`` reads the target string.
      let linkPath = umHandle.storePath / umHandle.relPath
      let target = expandSymlink(linkPath)
      check target == expectedTarget
      check target != "/lib/systemd/system/dbus.socket"
    # The recorded relPath is the canonicalised host path (NO trailing
    # ``.unmask-target`` suffix — that was a shim-emitter artefact the
    # M9.B materialiser drops in favour of the real link).
    check umHandle.relPath == "etc/systemd/system/dbus.socket"

  test "parseBusActivationStrategy: round-trip + raises on unknown":
    # Shim helper still reachable for the deprecated string-typed
    # override pathway (the recipe now consumes the typed enum
    # directly via readConfigurable[BusActivationStrategy]).
    check parseBusActivationStrategy("broker") == basBroker
    check parseBusActivationStrategy("daemon") == basDaemon
    expect ValueError:
      discard parseBusActivationStrategy("unknown")
    expect ValueError:
      discard parseBusActivationStrategy("")

  test "/var/lib/dbus spool placeholder via M9.B fs.directory":
    # The activation-layer-readable intent recording: NDE0-D doesn't
    # mkdir /var/lib/dbus at build time (it can't chown to messagebus
    # without root); it emits a directory placeholder the activation
    # step consumes. Migrated from the shim's ``spoolDirPlaceholder``
    # marker-file pattern to the M9.B fs.directory surface.
    let root = createTempDir("nde0d_spool_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let dirHandle = consumeSpoolDir()

    check dirHandle.relPath == "var/lib/dbus"
    # M9.B consumeDirectory creates the directory on disk.
    check dirExists(dirHandle.storePath / dirHandle.relPath)
    # M9.A/B sha256 hashes are 64 lower-hex chars.
    check dirHandle.hashHex.len == 64

  test "system.conf default policy: <busconfig> XML with messagebus <user>":
    # The minimal default policy must (a) be XML-shaped (DOCTYPE +
    # <busconfig> root); (b) declare the daemon's drop-privileges
    # user as messagebus; (c) bind the standard
    # /run/dbus/system_bus_socket ListenStream path.
    let root = createTempDir("nde0d_sysconf_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let bytes = readStoreFile(consumeSystemConf())

    check "<!DOCTYPE busconfig" in bytes
    check "<busconfig>" in bytes
    check "</busconfig>" in bytes
    check "<user>messagebus</user>" in bytes
    check "<listen>unix:path=/run/dbus/system_bus_socket</listen>" in
          bytes

  test "cache-key isolation: per-output hashes are distinct":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace, an accidental collision would alias their store paths
    # and the caller would silently get the wrong bytes. The M9.A
    # configFile + managedBlock + M9.B symlink/directory digests each
    # mix a discriminator prefix into the sha256 input.
    let root = createTempDir("nde0d_isolation_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let sock = consumeDbusSocket()
    let svc = consumeDbusService()
    let um = consumeDbusSocketUnmask()
    let pw = consumeMessagebusPasswd()
    let gr = consumeMessagebusGroup()
    let cf = consumeSystemConf()
    let dir = consumeSpoolDir()

    # Distinct per-output hashes.
    check sock.hashHex != svc.hashHex
    check sock.hashHex != um.hashHex
    check svc.hashHex  != um.hashHex
    check pw.hashHex   != gr.hashHex
    check pw.hashHex   != sock.hashHex
    check dir.hashHex  != cf.hashHex
    check dir.hashHex  != sock.hashHex
    check cf.hashHex   != svc.hashHex

# ---------------------------------------------------------------------------
# NDE-C DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/de-foundation/dbus-broker/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` blocks + M8/M9.A
# ``fs.configFile`` / ``fs.managedBlock`` + M9.B ``fs.symlink`` /
# ``fs.directory`` + M9.C ``service:`` block + M9.D typed-enum config)
# rather than silently regressing to the legacy "shim does everything"
# shape. These are extra assertions on top of the v1 surface — the v1
# structural assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE0-D dbus-broker DSL surface":

  test "recipe registers exactly 7 files: artifacts":
    let arts = registeredArtifacts("dbusBroker")
    check arts.len == 7

  test "every recipe artifact is dakFiles":
    let arts = registeredArtifacts("dbusBroker")
    for a in arts:
      check a.kind == dakFiles

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("dbusBroker")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "dbusSocket"       in names
    check "dbusService"      in names
    check "dbusSocketUnmask" in names
    check "messagebusUser"   in names
    check "messagebusGroup"  in names
    check "systemConf"       in names
    check "spoolDir"         in names

  test "M9.C service systemBus: records the full systemd-unit metadata surface":
    # Pins the M9.C extended service: block. The recipe declares
    # description / `type` / wantedBy / wants / requires / before /
    # execStart / user / group; the M5+M9.C parser captures every
    # one verbatim into the DslServiceDef registry.
    let svcs = registeredServices("dbusBroker")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "systemBus"
    check svc.description == "D-Bus System Message Bus"
    check svc.serviceType == "dbus"
    check svc.wantedBy == @["multi-user.target"]
    check svc.wants    == @["dbus.socket"]
    check svc.requires == @["dbus.socket"]
    check svc.before   == @["basic.target"]
    check svc.execStart ==
      "/usr/bin/dbus-broker-launch --scope system --audit"
    check svc.user  == "messagebus"
    check svc.group == "messagebus"
    # No ``executable <ident>`` setter → both the legacy
    # ``executableRef`` and the new ``executable`` alias stay empty.
    check svc.executable == ""
    check svc.executableRef == ""
    check svc.args.len == 0

  test "M9.D busActivationStrategy: enum default + override round-trip via inspectConfigurable":
    # Pins the M9.D typed-enum config surface end-to-end. Reset the
    # cell first so we observe the default rather than a stale
    # override from a prior test.
    resetConfigurable("dbusBroker.busActivationStrategy")
    # Default via the typed reader.
    check readConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy") == basBroker
    # Storage shape verification: the macro captured the enum type
    # name + literal value name byte-for-byte.
    let stored = inspectConfigurable("dbusBroker.busActivationStrategy")
    check stored.kind == dskEnum
    check stored.enumTypeName == "BusActivationStrategy"
    # ``$basBroker`` evaluates to the enum's string representation
    # ("broker") because the shim's BusActivationStrategy enum literals
    # have explicit string-form values (basBroker = "broker"). The
    # macro captures ``$value`` which uses the string form. Both the
    # ord and the string form round-trip; the enum value identity is
    # the load-bearing invariant.
    check stored.enumValueName == "broker"
    check stored.enumOrd == ord(basBroker)
    # Override + read.
    setConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy", basDaemon)
    check readConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy") == basDaemon
    # Reset restores the default.
    resetConfigurable("dbusBroker.busActivationStrategy")
    check readConfigurable[BusActivationStrategy](
      "dbusBroker.busActivationStrategy") == basBroker
