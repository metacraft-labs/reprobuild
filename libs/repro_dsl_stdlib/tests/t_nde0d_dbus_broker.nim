## NDE0-D unit tests: native dbus-broker package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## dbus_broker.nim`` against synthetic configurations. Mirrors the
## NDE0-S test layout (precedent: 13 scenarios + per-output
## ``ManagedFiles`` round-trip).
##
## Required test surfaces (per the NDE0-D sub-agent prompt §"Unit tests"):
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
##   5. Configurable: changing ``busActivationStrategy`` from "broker"
##      to "daemon" produces different unit-file content
##      (broker uses ExecStart=/usr/bin/dbus-broker-launch ...;
##      daemon uses ExecStart=/usr/bin/dbus-daemon ...).
##   6. Idempotency: same config → same store paths.
##   7. Cache-key invalidation: changing ``busActivationStrategy``
##      invalidates the dbus.service store path but NOT the
##      messagebus user block path.
##   8. Byte-determinism across two independent materialize roots.
##   9. Belt-and-braces symlink target: /etc/systemd/system/dbus.socket
##      resolves to /usr/lib/systemd/system/dbus.socket (cascade-G
##      belt-and-braces). Assert the recorded target string.
##
## Plus a handful of additional invariants that catch common
## regressions (parser failure path on unknown strategy, cache-key
## isolation across outputs, hash hex length, .keep-empty marker
## present).
##
## No try/except swallows. Failure paths use ``expect``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/de_foundation/dbus_broker

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-S test
  ## helper exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): DbusBrokerConfig =
  result = defaultDbusBrokerConfig()
  result.storeRoot = storeRoot

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

    let outs = materializeDbusBroker(configWithRoot(root))

    # AT: usr/lib/systemd/system/
    check outs.dbusSocket.relPath == "usr/lib/systemd/system/dbus.socket"
    check fileExists(outs.dbusSocket.storePath /
                     "usr/lib/systemd/system/dbus.socket")
    # NOT-AT: lib/systemd/system/
    check not fileExists(outs.dbusSocket.storePath /
                         "lib/systemd/system/dbus.socket")
    # Content sanity: it's a socket unit pointing at the canonical
    # system_bus_socket path.
    let bytes = readStoreFile(outs.dbusSocket)
    check "[Socket]" in bytes
    check "ListenStream=/run/dbus/system_bus_socket" in bytes
    check "WantedBy=sockets.target" in bytes

  test "cascade-G fix: dbus.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # Same cascade-G assertion for the .service unit.
    let root = createTempDir("nde0d_service_path_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))

    check outs.dbusService.relPath == "usr/lib/systemd/system/dbus.service"
    check fileExists(outs.dbusService.storePath /
                     "usr/lib/systemd/system/dbus.service")
    check not fileExists(outs.dbusService.storePath /
                         "lib/systemd/system/dbus.service")
    let bytes = readStoreFile(outs.dbusService)
    check "[Service]" in bytes
    check "Requires=dbus.socket" in bytes
    check "Alias=dbus.service" in bytes

  test "sentinel shape: messagebus user block uses NDE-spec-block triple form":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = dbus-broker, blockId =
    # system-user-messagebus.
    let root = createTempDir("nde0d_sentinel_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))
    let bytes = readStoreFile(outs.messagebusPasswd)

    let expectOpen =
      "# >>> repro:system:dbus-broker:system-user-messagebus >>>"
    let expectClose =
      "# <<< repro:system:dbus-broker:system-user-messagebus <<<"

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

    var cfg = configWithRoot(root)
    cfg.messagebusUid = 500
    cfg.messagebusGid = 500
    let outs = materializeDbusBroker(cfg)
    let passwdBytes = readStoreFile(outs.messagebusPasswd)
    let groupBytes = readStoreFile(outs.messagebusGroup)

    check "messagebus:x:500:500" in passwdBytes
    check "messagebus:x:101:101" notin passwdBytes
    check "messagebus:x:500:" in groupBytes
    check "messagebus:x:101:" notin groupBytes

  test "configurable: busActivationStrategy broker vs daemon produces different unit-file content":
    # The load-bearing strategy-toggle test. Broker variant uses
    # /usr/bin/dbus-broker-launch; daemon variant uses
    # /usr/bin/dbus-daemon. The socket unit is strategy-agnostic.
    let rootA = createTempDir("nde0d_strat_brk_", "")
    let rootB = createTempDir("nde0d_strat_dmn_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    var cfgA = configWithRoot(rootA)
    cfgA.busActivationStrategy = basBroker
    let outsA = materializeDbusBroker(cfgA)
    let brokerBytes = readStoreFile(outsA.dbusService)

    var cfgB = configWithRoot(rootB)
    cfgB.busActivationStrategy = basDaemon
    let outsB = materializeDbusBroker(cfgB)
    let daemonBytes = readStoreFile(outsB.dbusService)

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

    let outsA = materializeDbusBroker(configWithRoot(root))
    let outsB = materializeDbusBroker(configWithRoot(root))

    # Every output should land at exactly the same store path on a
    # second invocation (content-addressed hash is a pure function of
    # the inputs).
    check outsA.dbusSocket.storePath        == outsB.dbusSocket.storePath
    check outsA.dbusService.storePath       == outsB.dbusService.storePath
    check outsA.dbusSocketUnmask.storePath  == outsB.dbusSocketUnmask.storePath
    check outsA.messagebusPasswd.storePath  == outsB.messagebusPasswd.storePath
    check outsA.messagebusGroup.storePath   == outsB.messagebusGroup.storePath
    check outsA.spoolPlaceholder.storePath  == outsB.spoolPlaceholder.storePath
    check outsA.systemConf.storePath        == outsB.systemConf.storePath

  test "cache-key invalidation: strategy change re-keys dbus.service but NOT messagebus blocks":
    # This is the spec's contract: "Toggling
    # config.busActivationStrategy from broker to daemon rebuilds
    # only the affected files". The dbus.service unit-file content
    # depends on strategy; messagebus user blocks + dbus.socket
    # don't.
    let root = createTempDir("nde0d_invalidation_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.busActivationStrategy = basBroker
    let outsA = materializeDbusBroker(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.busActivationStrategy = basDaemon
    let outsB = materializeDbusBroker(cfgB)

    # dbus.service MUST land at different store paths.
    check outsA.dbusService.storePath != outsB.dbusService.storePath
    # dbus.socket + messagebus user blocks + spool placeholder +
    # system.conf MUST stay at the same store path.
    check outsA.dbusSocket.storePath        == outsB.dbusSocket.storePath
    check outsA.messagebusPasswd.storePath  == outsB.messagebusPasswd.storePath
    check outsA.messagebusGroup.storePath   == outsB.messagebusGroup.storePath
    check outsA.spoolPlaceholder.storePath  == outsB.spoolPlaceholder.storePath
    check outsA.systemConf.storePath        == outsB.systemConf.storePath
    check outsA.dbusSocketUnmask.storePath  == outsB.dbusSocketUnmask.storePath

  test "determinism: every output byte-identical across two independent roots":
    # The idempotency test catches re-entry into the same store root
    # (a marker-file short-circuit could mask a non-deterministic
    # writer); this test forces a fresh write into a SECOND root and
    # byte-compares the result. Mirrors NDE0-S's determinism test.
    let rootA = createTempDir("nde0d_detA_", "")
    let rootB = createTempDir("nde0d_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeDbusBroker(configWithRoot(rootA))
    let outsB = materializeDbusBroker(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.dbusSocket.storePath) ==
          extractFilename(outsB.dbusSocket.storePath)
    check extractFilename(outsA.dbusService.storePath) ==
          extractFilename(outsB.dbusService.storePath)
    check extractFilename(outsA.messagebusPasswd.storePath) ==
          extractFilename(outsB.messagebusPasswd.storePath)
    check extractFilename(outsA.systemConf.storePath) ==
          extractFilename(outsB.systemConf.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.dbusSocket)       ==
          readStoreFile(outsB.dbusSocket)
    check readStoreFile(outsA.dbusService)      ==
          readStoreFile(outsB.dbusService)
    check readStoreFile(outsA.dbusSocketUnmask) ==
          readStoreFile(outsB.dbusSocketUnmask)
    check readStoreFile(outsA.messagebusPasswd) ==
          readStoreFile(outsB.messagebusPasswd)
    check readStoreFile(outsA.messagebusGroup)  ==
          readStoreFile(outsB.messagebusGroup)
    check readStoreFile(outsA.spoolPlaceholder) ==
          readStoreFile(outsB.spoolPlaceholder)
    check readStoreFile(outsA.systemConf)       ==
          readStoreFile(outsB.systemConf)

  test "belt-and-braces cascade-G fix: /etc/systemd/system/dbus.socket records /usr/lib target":
    # The Tier-2 stage 5 belt-and-braces: even though dbus.socket
    # lives at /usr/lib/systemd/system/, we also plant an
    # /etc/systemd/system/dbus.socket symlink record so
    # ``systemctl status dbus.socket`` works even if a future overlay
    # segment shadows /usr/lib. The recorded target MUST be the
    # cascade-G-correct /usr/lib path, NOT the legacy /lib path that
    # R9 dropped.
    let root = createTempDir("nde0d_belt_braces_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))
    let recordedTarget = readStoreFile(outs.dbusSocketUnmask).strip()

    check recordedTarget == "/usr/lib/systemd/system/dbus.socket"
    # And the recorded target MUST NOT be the legacy /lib path.
    check recordedTarget != "/lib/systemd/system/dbus.socket"
    # The unmask manifest file's rel path encodes both the source and
    # the .unmask-target suffix so the activation layer can find it.
    check outs.dbusSocketUnmask.relPath ==
      "etc/systemd/system/dbus.socket.unmask-target"

  test "cache-key isolation: per-output hashes are distinct":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. The hashes are 16-
    # hex-char truncations of sha256 — collisions are astronomically
    # unlikely but the test catches "I forgot to vary the prefix"
    # mistakes at code-review time. Mirrors NDE0-S's isolation test.
    let root = createTempDir("nde0d_isolation_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))

    check outs.dbusSocket.hashHex       != outs.dbusService.hashHex
    check outs.dbusSocket.hashHex       != outs.dbusSocketUnmask.hashHex
    check outs.dbusService.hashHex      != outs.dbusSocketUnmask.hashHex
    check outs.messagebusPasswd.hashHex != outs.messagebusGroup.hashHex
    check outs.messagebusPasswd.hashHex != outs.dbusSocket.hashHex
    check outs.spoolPlaceholder.hashHex != outs.systemConf.hashHex
    check outs.spoolPlaceholder.hashHex != outs.dbusSocket.hashHex
    check outs.systemConf.hashHex       != outs.dbusService.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors NDE0-A +
    # NDE0-S).
    check outs.dbusSocket.hashHex.len       == 16
    check outs.dbusService.hashHex.len      == 16
    check outs.dbusSocketUnmask.hashHex.len == 16
    check outs.messagebusPasswd.hashHex.len == 16
    check outs.messagebusGroup.hashHex.len  == 16
    check outs.spoolPlaceholder.hashHex.len == 16
    check outs.systemConf.hashHex.len       == 16

  test "/var/lib/dbus spool placeholder: .keep-empty marker present":
    # The activation-layer-readable intent recording: NDE0-D doesn't
    # mkdir /var/lib/dbus at build time (it can't chown to messagebus
    # without root); it emits a marker file the activation step
    # consumes. The marker file's path encodes the intent.
    let root = createTempDir("nde0d_spool_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))

    check outs.spoolPlaceholder.relPath == "var/lib/dbus/.keep-empty"
    let bytes = readStoreFile(outs.spoolPlaceholder)
    # Documents the intent for the activation layer.
    check "messagebus" in bytes
    check "0755" in bytes

  test "system.conf default policy: <busconfig> XML with messagebus <user>":
    # The minimal default policy must (a) be XML-shaped (DOCTYPE +
    # <busconfig> root); (b) declare the daemon's drop-privileges
    # user as messagebus; (c) bind the standard
    # /run/dbus/system_bus_socket ListenStream path.
    let root = createTempDir("nde0d_sysconf_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))
    let bytes = readStoreFile(outs.systemConf)

    check "<!DOCTYPE busconfig" in bytes
    check "<busconfig>" in bytes
    check "</busconfig>" in bytes
    check "<user>messagebus</user>" in bytes
    check "<listen>unix:path=/run/dbus/system_bus_socket</listen>" in
          bytes
    check outs.systemConf.relPath == "etc/dbus-1/system.conf"

  test "parseBusActivationStrategy: unknown value raises ValueError":
    # Failure-path test using ``expect`` per the prompt rules. The
    # configurable-validation layer (NDEM milestone) will surface
    # this as a friendly validation error; today the impl helper
    # raises directly.
    check parseBusActivationStrategy("broker") == basBroker
    check parseBusActivationStrategy("daemon") == basDaemon
    expect ValueError:
      discard parseBusActivationStrategy("unknown")
    expect ValueError:
      discard parseBusActivationStrategy("")

  test "stable activation order: storePaths enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # unit files first (sockets.target sees them), then system-user
    # blocks (daemon drops privileges to messagebus), then spool
    # placeholder + default policy. A regression here would change
    # the apply-step ordering and could mask a unit not-found at
    # boot.
    let root = createTempDir("nde0d_order_", "")
    defer: removeDir(root)

    let outs = materializeDbusBroker(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 7
    check paths[0] == outs.dbusSocket.storePath
    check paths[1] == outs.dbusService.storePath
    check paths[2] == outs.dbusSocketUnmask.storePath
    check paths[3] == outs.messagebusPasswd.storePath
    check paths[4] == outs.messagebusGroup.storePath
    check paths[5] == outs.spoolPlaceholder.storePath
    check paths[6] == outs.systemConf.storePath
