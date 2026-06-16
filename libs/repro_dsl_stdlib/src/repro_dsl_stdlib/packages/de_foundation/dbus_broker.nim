## NDE0-D: native dbus-broker package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-D.
##
## This module is the build-time implementation backing the package
## declaration at ``recipes/packages/de-foundation/dbus-broker/repro.nim``.
## Mirrors the NDE0-S layout: the DSL ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files <name>:`` block form
## doesn't yet work and the impl is exposed as ordinary Nim procs.
## The ``service systemBus:`` block from the spec is documented as a
## comment in the package preamble + handled via the planted .service
## file (the runtime semantics are the activation step's responsibility,
## an NDEM milestone).
##
## ## What this package owns
##
## Per spec §NDE0-D, the native package subsumes the Tier-2 shell script
## at ``recipes/reproos-mvp-config/de0-dbus.sh``. The file-emission
## outputs:
##
##   * ``dbus.socket`` unit file planted at
##     ``<storeRoot>/<hash>/usr/lib/systemd/system/dbus.socket`` (NOT
##     ``lib/systemd/system/``; that's the cascade-G fix — R9 systemd
##     257.9's default UnitPath dropped /lib/systemd/system/).
##   * ``dbus.service`` unit at
##     ``<storeRoot>/<hash>/usr/lib/systemd/system/dbus.service``.
##     Content is either the dbus-broker variant (default) or the
##     dbus-daemon fallback, selected by the ``busActivationStrategy``
##     configurable.
##   * Belt-and-braces: an ``/etc/systemd/system/dbus.socket`` un-mask
##     handle whose recorded target is
##     ``/usr/lib/systemd/system/dbus.socket`` (cascade-G belt-and-braces).
##   * ``messagebus:101:101`` system user via ``fs.managedBlock()`` on
##     /etc/passwd + /etc/group. The NDE-spec-block triple-form sentinel
##     uses blockId = ``system-user-messagebus``.
##   * ``/var/lib/dbus/`` directory placeholder — emitted as a
##     ``.keep-empty`` marker file that records intent for the activation
##     layer (which will mkdir + chown messagebus:messagebus at apply
##     time per the Tier-2 stage 3 + tmpfiles.d pattern).
##   * ``/etc/dbus-1/system.conf`` minimal default policy via
##     ``fs.configFile()``.
##
## ## What this package consumes
##
## Per spec NDE0-D ``uses: apt-jammy(snapshot, debs=@[dbus-broker,
## dbus-user-session])``. v1 records the snapshot pin in every cache key
## but does NOT extract the .debs themselves: ``dbus-broker_*.deb`` is
## not vendored under
## ``recipes/reproos-mvp-config/vendored-archives/linux/`` (the only
## dbus-* .debs vendored are consumer-side libraries — libdbusmenu,
## libkf5dbusaddons, libqt5dbus5 — not the broker daemon). The unit-
## file content this module emits is hardcoded to match upstream dbus-
## broker .service shape; when the .deb fixture lands, a future
## milestone migrates the unit-file extraction to
## ``installSystemdUnit(installAptDeb(snapshot, debs=@[...]))``.
##
## ## Reuse from NDE0-S
##
## NDE0-S's ``systemd_session.nim`` already exports the minimal-viable
## ``configFile`` / ``managedBlock`` / ``symlinkUnmask`` helpers + the
## ``BlockScope`` enum + ``ManagedFiles`` typed output handle (verified:
## every helper is declared with ``*`` export marker). This module
## imports them directly and re-uses them. No ``fs_helpers.nim``
## extraction is necessary — the helpers are already in the right place
## (a shared ``de_foundation/`` directory) and an extraction would just
## move them sideways for no incremental capability.
##
## **Deferred (NOT in NDE0-D scope)**: full spec'd surface composability
## (cross-contributor merge for /etc/passwd between NDE0-S's ``repro``
## user contribution and NDE0-D's ``messagebus`` user contribution),
## activation-step symlinking under live /etc/, generation-switching
## semantics. These land in NDEM1.

import std/[algorithm, os]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ./systemd_session

# Re-export the symbols downstream consumers need so a ``uses:
# "dbus-broker >=0.1.0"`` package can do everything from one import.
# (NB: the impl module's whole public surface is re-exported via a
# ``export systemd_session`` blanket — the constituent type / enum /
# const need to be in scope at compile-time in this module too, so
# qualifying ``systemd_session.X`` for individual names doesn't gain
# anything and triggers a Nim dotted-export parse hazard.)
export apt_jammy.AptFiles
export systemd_session

# ---------------------------------------------------------------------------
# Version constant — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  Nde0dVersion* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/de-foundation/dbus-broker/repro.nim``.
  Nde0dPackageName* = "dbus-broker"

# ---------------------------------------------------------------------------
# sha256 helper (used for the cascade-G symlink unmask + .keep-empty
# marker; the other emissions go through NDE0-S's helpers which embed
# their own per-output Nde0sVersion in the hash).
# ---------------------------------------------------------------------------

proc sha256OfBytes(bytes: openArray[byte]): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfString(s: string): string =
  if s.len == 0:
    sha256OfBytes(default(array[0, byte]))
  else:
    sha256OfBytes(cast[ptr UncheckedArray[byte]](
      s[0].unsafeAddr).toOpenArray(0, s.len - 1))

# ---------------------------------------------------------------------------
# Strategy enum: which bus activation daemon ships with the unit files.
# ---------------------------------------------------------------------------

type
  BusActivationStrategy* = enum
    ## Per spec NDE0-D ``busActivationStrategy: enum = "broker"``. The
    ## values match the Tier-2 ``DAEMON`` shell variable strings.
    basBroker = "broker"
    basDaemon = "daemon"

proc parseBusActivationStrategy*(s: string): BusActivationStrategy =
  ## Convert a configurable's string value (as it would arrive from the
  ## DSL ``configurable`` resolution layer) to the enum. Raises
  ## ``ValueError`` on an unknown value — callers should treat that as
  ## a configurable-validation failure (NDEM milestone wires this into
  ## the ``validate:`` clause).
  case s
  of "broker": basBroker
  of "daemon": basDaemon
  else:
    raise newException(ValueError,
      "unknown busActivationStrategy: " & s &
      " (expected: broker | daemon)")

# ---------------------------------------------------------------------------
# dbus.socket unit-file content rendering.
# ---------------------------------------------------------------------------

proc renderDbusSocket*(): string =
  ## ``dbus.socket`` system-bus socket-activation unit. Same shape as
  ## upstream dbus-broker / dbus-daemon ship (the socket unit is
  ## strategy-agnostic — both daemons bind the same path).
  ##
  ## ListenStream= path matches the canonical system-bus address
  ## ``/run/dbus/system_bus_socket`` (referenced in /etc/dbus-1/system.conf
  ## via ``<listen>unix:path=...</listen>``).
  result = "# NDE0-D: D-Bus system-bus socket unit.\n" &
           "[Unit]\n" &
           "Description=D-Bus System Message Bus Socket\n" &
           "Documentation=man:dbus-daemon(1)\n" &
           "\n" &
           "[Socket]\n" &
           "ListenStream=/run/dbus/system_bus_socket\n" &
           "\n" &
           "[Install]\n" &
           "WantedBy=sockets.target\n"

# ---------------------------------------------------------------------------
# dbus.service unit-file content rendering (strategy-dependent).
# ---------------------------------------------------------------------------

proc renderDbusServiceBroker*(): string =
  ## ``dbus.service`` content when ``busActivationStrategy = broker``.
  ## ExecStart= points at the dbus-broker-launch binary (upstream's
  ## dbus-broker(1) installer ships this under /usr/bin/).
  ##
  ## Type=notify means systemd waits for sd_notify(READY=1) from the
  ## broker before considering the unit active — matches what the
  ## upstream dbus-broker.service ships.
  result = "# NDE0-D: D-Bus system bus service (dbus-broker variant).\n" &
           "[Unit]\n" &
           "Description=D-Bus System Message Bus (dbus-broker)\n" &
           "Documentation=man:dbus-broker-launch(1)\n" &
           "Requires=dbus.socket\n" &
           "\n" &
           "[Service]\n" &
           "Type=notify\n" &
           "ExecStart=/usr/bin/dbus-broker-launch --scope system " &
             "--audit\n" &
           "ExecReload=/usr/bin/busctl call org.freedesktop.DBus " &
             "/org/freedesktop/DBus org.freedesktop.DBus ReloadConfig\n" &
           "\n" &
           "[Install]\n" &
           "Alias=dbus.service\n" &
           "WantedBy=multi-user.target\n"

proc renderDbusServiceDaemon*(): string =
  ## ``dbus.service`` content when ``busActivationStrategy = daemon``
  ## (fallback for hosts without dbus-broker). ExecStart= points at the
  ## reference dbus-daemon under /usr/bin/.
  result = "# NDE0-D: D-Bus system bus service (dbus-daemon variant).\n" &
           "[Unit]\n" &
           "Description=D-Bus System Message Bus (dbus-daemon)\n" &
           "Documentation=man:dbus-daemon(1)\n" &
           "Requires=dbus.socket\n" &
           "\n" &
           "[Service]\n" &
           "Type=notify\n" &
           "ExecStart=/usr/bin/dbus-daemon --system --address=systemd: " &
             "--nofork --nopidfile --systemd-activation --syslog-only\n" &
           "ExecReload=/usr/bin/dbus-send --print-reply --system " &
             "--type=method_call --dest=org.freedesktop.DBus " &
             "/ org.freedesktop.DBus.ReloadConfig\n" &
           "\n" &
           "[Install]\n" &
           "Alias=dbus.service\n" &
           "WantedBy=multi-user.target\n"

proc renderDbusService*(strategy: BusActivationStrategy): string =
  case strategy
  of basBroker: renderDbusServiceBroker()
  of basDaemon: renderDbusServiceDaemon()

# ---------------------------------------------------------------------------
# messagebus user + group block rendering (NDE0-D stage 3).
# ---------------------------------------------------------------------------

proc renderMessagebusPasswd*(uid, gid: int): string =
  ## /etc/passwd entry for the messagebus user. Matches the Tier-2
  ## stage 3 line shape:
  ##   ``messagebus:x:101:101:DBus Messagebus:/var/lib/dbus:/usr/sbin/nologin``
  ## The home /var/lib/dbus is dbus's spool dir (machine-id-derived
  ## random ID writes here on first boot). Shell is /usr/sbin/nologin
  ## — the account exists only to own the bus daemon process.
  result = "messagebus:x:" & $uid & ":" & $gid &
           ":DBus Messagebus:/var/lib/dbus:/usr/sbin/nologin\n"

proc renderMessagebusGroup*(gid: int): string =
  ## /etc/group entry for the messagebus group.
  result = "messagebus:x:" & $gid & ":\n"

# ---------------------------------------------------------------------------
# /etc/dbus-1/system.conf minimal default policy rendering.
# ---------------------------------------------------------------------------

proc renderSystemConf*(): string =
  ## Minimal default system-bus policy. This is a stripped-down version
  ## of what the upstream dbus package ships at
  ## /usr/share/dbus-1/system.conf — sized for the NDE0-D MVP scope
  ## (logind + the user-session shim talking to the broker; no Polkit
  ## yet, no Avahi yet, no NetworkManager yet).
  ##
  ## Format is the DTD-style XML the dbus daemon parses. Indented for
  ## human review; emitted verbatim.
  result = "<!DOCTYPE busconfig PUBLIC\n" &
           " \"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN\"\n" &
           " \"http://www.freedesktop.org/standards/dbus/1.0/" &
             "busconfig.dtd\">\n" &
           "<busconfig>\n" &
           "  <!-- NDE0-D: minimal system-bus default policy. -->\n" &
           "  <type>system</type>\n" &
           "  <user>messagebus</user>\n" &
           "  <listen>unix:path=/run/dbus/system_bus_socket</listen>\n" &
           "  <pidfile>/run/dbus/pid</pidfile>\n" &
           "  <auth>EXTERNAL</auth>\n" &
           "  <standard_system_servicedirs/>\n" &
           "  <policy context=\"default\">\n" &
           "    <deny send_destination=\"*\" eavesdrop=\"true\"/>\n" &
           "    <deny eavesdrop=\"true\"/>\n" &
           "    <allow send_destination=\"org.freedesktop.DBus\"/>\n" &
           "    <allow receive_sender=\"org.freedesktop.DBus\"/>\n" &
           "  </policy>\n" &
           "  <limit name=\"max_message_size\">134217728</limit>\n" &
           "  <limit name=\"max_completed_connections\">2048</limit>\n" &
           "</busconfig>\n"

# ---------------------------------------------------------------------------
# Configurables struct + materializer
# ---------------------------------------------------------------------------

type
  DbusBrokerConfig* = object
    ## NDE0-D configurables per the spec example. Defaults match the
    ## Tier-2 shell script (DAEMON=broker; messagebus 101:101).
    aptSnapshot*: string
    busActivationStrategy*: BusActivationStrategy
    messagebusUid*: int
    messagebusGid*: int

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  DbusBrokerOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent — toggling ``busActivationStrategy`` re-emits only
    ## the dbus.service unit-file; toggling ``messagebusUid`` re-emits
    ## only the /etc/passwd + /etc/group blocks; the dbus.socket unit +
    ## /etc/dbus-1/system.conf stay cached across strategy/UID changes.
    dbusSocket*:        ManagedFiles
    dbusService*:       ManagedFiles
    dbusSocketUnmask*:  ManagedFiles  # belt-and-braces /etc symlink record
    messagebusPasswd*:  ManagedFiles
    messagebusGroup*:   ManagedFiles
    spoolPlaceholder*:  ManagedFiles  # /var/lib/dbus/.keep-empty marker
    systemConf*:        ManagedFiles

proc defaultDbusBrokerConfig*(): DbusBrokerConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation.
  result = DbusBrokerConfig(
    aptSnapshot:           "ubuntu/jammy/20260615T000000Z",
    busActivationStrategy: basBroker,
    messagebusUid:         101,
    messagebusGid:         101,
    storeRoot:             systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# /var/lib/dbus placeholder emission. Mirrors the symlinkUnmask shape
# from NDE0-S — a small dedicated helper writing a marker file that the
# activation layer reads at apply time.
# ---------------------------------------------------------------------------

proc spoolDirPlaceholder(storeRoot: string): ManagedFiles =
  ## Records intent for the activation layer to mkdir
  ## ``/var/lib/dbus`` with ownership messagebus:messagebus + mode 0755.
  ## The Tier-2 script handles this via ``mkdir -p`` + the tmpfiles.d
  ## snippet; the native package records it declaratively here.
  let rel = "var/lib/dbus/.keep-empty"
  let composed = "spoolDirPlaceholder" & Nde0dVersion & rel
  let hash = sha256OfString(composed)[0 ..< 16]
  let storePath = storeRoot / hash
  let marker = storePath / ".nde0d-spool"
  result.storePath = storePath
  result.relPath = rel
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker)
    if existing.len > 0 and existing[0 ..< min(hash.len, existing.len)] == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / rel
  createDir(dest.parentDir)
  let body = "# NDE0-D: placeholder for /var/lib/dbus spool dir.\n" &
             "# Activation layer mkdir + chown messagebus:messagebus + mode 0755.\n"
  writeFile(dest, body)
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE0-D output.
# ---------------------------------------------------------------------------

proc materializeDbusBroker*(cfg: DbusBrokerConfig): DbusBrokerOutputs =
  ## Emit every NDE0-D output. Each helper invocation is independent so
  ## the cache keys are per-output — see the docstring for
  ## ``DbusBrokerOutputs`` for the invalidation matrix.
  ##
  ## NB: dbus.socket + dbus.service are planted at
  ## ``usr/lib/systemd/system/`` (the cascade-G fix); they are NOT
  ## planted at ``lib/systemd/system/``. R9 systemd 257.9's default
  ## UnitPath dropped the legacy /lib/systemd/system entry, so anything
  ## planted there would be invisible at boot. See the Tier-2 stage 5
  ## comment block for the full historical analysis.

  result.dbusSocket = configFile(
    path = "usr/lib/systemd/system/dbus.socket",
    content = renderDbusSocket(),
    storeRoot = cfg.storeRoot)

  result.dbusService = configFile(
    path = "usr/lib/systemd/system/dbus.service",
    content = renderDbusService(cfg.busActivationStrategy),
    storeRoot = cfg.storeRoot)

  # Belt-and-braces cascade-G fix: record the /etc/systemd/system/dbus.socket
  # un-mask target so the activation layer plants the live symlink.
  result.dbusSocketUnmask = symlinkUnmask(
    path = "etc/systemd/system/dbus.socket",
    target = "/usr/lib/systemd/system/dbus.socket",
    storeRoot = cfg.storeRoot)

  # messagebus system user — emitted as managed blocks under
  # /etc/passwd + /etc/group so a future multi-contributor merge with
  # NDE0-S's ``repro`` user contribution composes cleanly.
  const messagebusBlockId = "system-user-messagebus"
  result.messagebusPasswd = managedBlock(
    path = "etc/passwd",
    scope = bsSystem,
    packageName = Nde0dPackageName,
    blockId = messagebusBlockId,
    content = renderMessagebusPasswd(cfg.messagebusUid, cfg.messagebusGid),
    priority = 100,          # foundation packages default per spec
    storeRoot = cfg.storeRoot)

  result.messagebusGroup = managedBlock(
    path = "etc/group",
    scope = bsSystem,
    packageName = Nde0dPackageName,
    blockId = messagebusBlockId,
    content = renderMessagebusGroup(cfg.messagebusGid),
    priority = 100,
    storeRoot = cfg.storeRoot)

  result.spoolPlaceholder = spoolDirPlaceholder(cfg.storeRoot)

  result.systemConf = configFile(
    path = "etc/dbus-1/system.conf",
    content = renderSystemConf(),
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: DbusBrokerOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: unit files first (so
  ## sockets.target sees them), then system-user blocks (so the daemon
  ## can drop privileges at startup), then the spool dir + default
  ## policy.
  result = @[
    outs.dbusSocket.storePath,
    outs.dbusService.storePath,
    outs.dbusSocketUnmask.storePath,
    outs.messagebusPasswd.storePath,
    outs.messagebusGroup.storePath,
    outs.spoolPlaceholder.storePath,
    outs.systemConf.storePath]

proc sortedStorePaths*(outs: DbusBrokerOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])
