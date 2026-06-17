## NDE0-D: native dbus-broker package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-D.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## dbus_broker.nim`` (precedent: NDE0-A's apt-jammy package +
## ``apt_jammy.nim`` shim, plus NDE0-S's identical pattern).
##
## ## NDE-C: DSL-port migration to typed fs.* + service: + M9.D surface
##
## NDE-C (third NDE rewrite, after NDE-A/B) migrates this recipe from the
## previous "shim does everything, recipe is a config: shell" pattern to
## the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/...", content = ...)
##       fs.managedBlock(path = "/etc/...", scope = bsSystem, ...)
##       fs.directory(path = "/var/lib/dbus", mode = 0o755)
##
##   service systemBus:
##     description "..."
##     `type` "dbus"
##     wantedBy "multi-user.target"
##     wants "dbus.socket"
##     requires "dbus.socket"
##     before "basic.target"
##     execStart "..."
##     user "messagebus"
##     group "messagebus"
##
##   config:
##     busActivationStrategy: BusActivationStrategy = basBroker  # M9.D enum
##
## Each emitted file is its own ``files:`` artifact so the cache-key
## isolation is visible at the DSL level (toggling
## ``busActivationStrategy`` invalidates only ``dbusService``; toggling
## ``messagebusUid`` invalidates only ``messagebusUser`` /
## ``messagebusGroup``). The shim module still owns the render procs
## verbatim — only the on-disk emitter procs
## (``configFile`` / ``managedBlock`` / ``symlinkUnmask`` /
## ``spoolDirPlaceholder``) stay deprecated in the shim while the recipe
## drives the DSL's M8 / M9.A / M9.B materialisation path.
##
## ## Configurables
##
## Per the spec NDE0-D section. Each maps to a field on
## ``DbusBrokerConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it.
##
##   * ``aptSnapshot`` — the apt-jammy pin for the (deferred) dbus-broker
##     / dbus-user-session .deb input. Records in fingerprint only.
##   * ``busActivationStrategy`` — typed enum
##     (``BusActivationStrategy``) selecting the dbus.service unit-file
##     daemon: ``basBroker`` (default) for ``dbus-broker-launch``,
##     ``basDaemon`` for the reference ``dbus-daemon`` fallback.
##   * ``messagebusUid`` / ``messagebusGid`` — propagate to the
##     /etc/passwd + /etc/group managed blocks. 101 is the Debian/Ubuntu
##     convention.
##
## ## Honest deferrals
##
## * **service systemBus: execStart strategy split**: The M5 ``service:``
##   parser captures ``execStart "literal"`` at macro-expansion time,
##   so the literal MUST be a compile-time string. The strategy split
##   IS fully realised at the file artifact layer
##   (``files dbusService: build: fs.configFile(... renderDbusService(
##   cfg.busActivationStrategy) ...)``) — the rendered ``dbus.service``
##   unit-file picks the right ExecStart= at runtime. The ``service
##   systemBus:`` block's execStart records the default-strategy
##   literal verbatim into the M9.C DslServiceDef registry as
##   diagnostic / activation-step metadata.
##
## * **dbus-broker / dbus-user-session .deb extraction**: v1 emits
##   hardcoded unit-file content matching upstream dbus-broker .service
##   shape. The broker binaries (/usr/bin/dbus-broker-launch + the .so
##   libraries) are NOT extracted — no dbus-broker_*.deb is vendored.
##
## * **Multi-contributor /etc/passwd merge**: NDE0-S emits a ``repro``
##   user block; NDE0-D emits a ``messagebus`` user block. Both target
##   ``/etc/passwd`` with NDE-spec-block sentinels (different blockIds).
##   v1 emits each block to a content-addressed store path independently;
##   activation-layer union into the live /etc/passwd is NDEM1.
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-D emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# DbusBrokerConfig type + BusActivationStrategy enum (basBroker /
# basDaemon). Imported under an alias so the recipe-side call sites
# stay readable (``brokerImpl.renderDbusSocket()``). The shim's
# ``materializeDbusBroker`` orchestrator + ``configFile`` /
# ``managedBlock`` / ``symlinkUnmask`` / ``spoolDirPlaceholder``
# on-disk emitters are still available to legacy callers but the
# recipe no longer invokes them — all on-disk materialisation now
# flows through the DSL's M8 / M9.A / M9.B path.
import repro_dsl_stdlib/packages/de_foundation/dbus_broker as brokerImpl
export brokerImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const DbusBrokerPackageId* = "dbusBroker"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## (``dbusBroker`` → ``dbus-broker``) propagates in one place.

proc currentDbusBrokerCfg*(): brokerImpl.DbusBrokerConfig =
  ## Read every configurable cell into a ``DbusBrokerConfig`` record
  ## the shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## ``busActivationStrategy`` is the M9.D typed-enum surface — first
  ## NDE recipe to exercise it.
  result = brokerImpl.DbusBrokerConfig(
    aptSnapshot: readConfigurable[string](
      "dbusBroker.aptSnapshot", "ubuntu/jammy/20260615T000000Z"),
    busActivationStrategy: readConfigurable[brokerImpl.BusActivationStrategy](
      "dbusBroker.busActivationStrategy", brokerImpl.basBroker),
    messagebusUid: readConfigurable[int]("dbusBroker.messagebusUid", 101),
    messagebusGid: readConfigurable[int]("dbusBroker.messagebusGid", 101),
    storeRoot: brokerImpl.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerDbusBrokerFiles()`` (below) directly with explicit
# packageName + artifactName so the call works outside a build:
# context.
# ---------------------------------------------------------------------------

proc registerDbusSocket*() =
  ## ``dbus.socket`` system-bus socket-activation unit at the cascade-G
  ## fix path /usr/lib/systemd/system/ (NOT the legacy /lib/systemd/
  ## system/ which R9 systemd 257.9 dropped from the default UnitPath).
  fs.configFile(
    path = "/usr/lib/systemd/system/dbus.socket",
    content = brokerImpl.renderDbusSocket(),
    packageName = DbusBrokerPackageId,
    artifactName = "dbusSocket")

proc registerDbusService*() =
  ## ``dbus.service`` unit at the cascade-G path. Content depends on
  ## the configurable ``busActivationStrategy``: ``basBroker``
  ## (default) → dbus-broker-launch ExecStart=; ``basDaemon`` →
  ## reference dbus-daemon ExecStart=. The strategy split lives here
  ## (not in the ``service systemBus:`` block, whose execStart literal
  ## is captured at macro time).
  let cfg = currentDbusBrokerCfg()
  fs.configFile(
    path = "/usr/lib/systemd/system/dbus.service",
    content = brokerImpl.renderDbusService(cfg.busActivationStrategy),
    packageName = DbusBrokerPackageId,
    artifactName = "dbusService")

proc registerDbusSocketUnmask*() =
  ## Belt-and-braces cascade-G fix: an /etc/systemd/system/dbus.socket
  ## symlink record pointing at the /usr/lib/... unit so
  ## ``systemctl status dbus.socket`` works even if a future overlay
  ## segment shadows /usr/lib. The recorded target MUST be the
  ## cascade-G-correct /usr/lib path, NOT the legacy /lib path.
  fs.symlink(
    path = "/etc/systemd/system/dbus.socket",
    target = "/usr/lib/systemd/system/dbus.socket",
    packageName = DbusBrokerPackageId,
    artifactName = "dbusSocketUnmask")

proc registerMessagebusUser*() =
  ## /etc/passwd contribution via fs.managedBlock — NDE-spec-block
  ## sentinel ``# >>> repro:system:dbusBroker:system-user-messagebus
  ## >>>`` (note packageName = ``dbusBroker``, the DSL package
  ## identifier; the shim's standalone-contributor emission used the
  ## kebab-cased ``dbus-broker``, which is the multi-contributor
  ## merge target — a forward-compatible difference per the
  ## per-artifact docstring).
  let cfg = currentDbusBrokerCfg()
  fs.managedBlock(
    path = "/etc/passwd",
    blockId = "system-user-messagebus",
    scope = bsSystem,
    content = brokerImpl.renderMessagebusPasswd(
      cfg.messagebusUid, cfg.messagebusGid),
    priority = 500,  # NDE0-D is foundation, ordering after NDE0-S=100
    packageName = DbusBrokerPackageId,
    artifactName = "messagebusUser")

proc registerMessagebusGroup*() =
  let cfg = currentDbusBrokerCfg()
  fs.managedBlock(
    path = "/etc/group",
    blockId = "system-user-messagebus",
    scope = bsSystem,
    content = brokerImpl.renderMessagebusGroup(cfg.messagebusGid),
    priority = 500,
    packageName = DbusBrokerPackageId,
    artifactName = "messagebusGroup")

proc registerSystemConf*() =
  ## /etc/dbus-1/system.conf minimal default policy.
  fs.configFile(
    path = "/etc/dbus-1/system.conf",
    content = brokerImpl.renderSystemConf(),
    packageName = DbusBrokerPackageId,
    artifactName = "systemConf")

proc registerSpoolDir*() =
  ## /var/lib/dbus directory placeholder via M9.B fs.directory. The
  ## activation layer (NDEM1) reads this and mkdir + chown
  ## messagebus:messagebus at apply time. mode 0o755 matches the
  ## Tier-2 stage 3 tmpfiles.d shape.
  fs.directory(
    path = "/var/lib/dbus",
    mode = 0o755,
    packageName = DbusBrokerPackageId,
    artifactName = "spoolDir")

proc registerDbusBrokerFiles*() =
  ## Register every fs.* output the recipe owns. Idempotent at the
  ## per-call level only — call ``resetDslPortFsState`` +
  ## ``resetDslPortFsExtState`` before re-invoking, otherwise each
  ## fs.* call appends a fresh row to the registry.
  ##
  ## Used by the unit-test fixture to re-register after a configurable
  ## toggle. The recipe's ``files <name>: build:`` arms below each
  ## invoke a single per-artifact helper so the M4 ``beginBuildContext``
  ## push carries the spec'd artifact name; the per-artifact helpers'
  ## ``packageName = DbusBrokerPackageId`` argument keeps the
  ## registration well-formed when called outside a build: context (as
  ## the test fixture does).
  registerDbusSocket()
  registerDbusService()
  registerDbusSocketUnmask()
  registerMessagebusUser()
  registerMessagebusGroup()
  registerSystemConf()
  registerSpoolDir()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package dbusBroker:
  ## NDE0-D native dbus-broker package.
  ##
  ## Downstream Tier-1 packages (NDE-H/G/K) ``uses:`` this and consume
  ## the recipe's fs.* artifacts through the DSL's ``consumeConfigFile``
  ## / ``consumeManagedBlock`` / ``consumeSymlink`` / ``consumeDirectory``
  ## materialiser. The ``files <name>:`` arms below each register one
  ## emission so the per-artifact cache key isolates the downstream
  ## invalidation surface.

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) dbus-broker .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the whole
    ## package's emissions atomically — even when the .deb extraction
    ## is deferred, the fingerprint hygiene is preserved.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Selects which daemon ExecStart= line lands in the emitted
    ## ``dbus.service`` unit. Typed M9.D enum (FIRST native NDE recipe
    ## to exercise the typed-enum config surface): ``basBroker``
    ## (default) uses ``/usr/bin/dbus-broker-launch``; ``basDaemon``
    ## uses ``/usr/bin/dbus-daemon`` (fallback for hosts without
    ## dbus-broker installed). The socket unit + system-user blocks +
    ## default policy are strategy-agnostic.
    busActivationStrategy: BusActivationStrategy = basBroker

    ## User-namespace ID for the messagebus system account. 101 is
    ## the Debian/Ubuntu convention. The Tier-2 shell script's stage
    ## 3 pins these deterministically (matching the same DE0-S
    ## precedent — the repro user is also pinned not sysusers-spawned).
    messagebusUid: int = 101

    ## Primary group ID for the messagebus account.
    messagebusGid: int = 101

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) dbus-broker + dbus-user-session .deb input. v1 of
    ## NDE0-D records this dependency for fingerprint purposes but does
    ## not yet exercise ``installAptDeb()`` for dbus-broker /
    ## dbus-user-session (those .debs are not vendored).
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the user-session
    ## targets the dbus user-instance hooks against + the
    ## ``BlockScope`` / ``ManagedFiles`` typed-output helpers
    ## re-exported via dbus_broker.nim.
    "systemd-session >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files dbusSocket:
    ## /usr/lib/systemd/system/dbus.socket — system-bus
    ## socket-activation unit. Strategy-agnostic content.
    build:
      registerDbusSocket()

  files dbusService:
    ## /usr/lib/systemd/system/dbus.service — daemon-launch unit. The
    ## ``busActivationStrategy`` configurable picks broker vs daemon
    ## variant at runtime via ``renderDbusService(cfg)``.
    build:
      registerDbusService()

  files dbusSocketUnmask:
    ## /etc/systemd/system/dbus.socket → /usr/lib/... symlink (belt-
    ## and-braces cascade-G fix). Recorded target is the /usr/lib
    ## path, NEVER the legacy /lib path R9 dropped.
    build:
      registerDbusSocketUnmask()

  files messagebusUser:
    ## /etc/passwd contribution — messagebus user managed block with
    ## the NDE-spec-block triple-form sentinel.
    build:
      registerMessagebusUser()

  files messagebusGroup:
    ## /etc/group contribution — symmetric with messagebusUser.
    build:
      registerMessagebusGroup()

  files systemConf:
    ## /etc/dbus-1/system.conf — minimal default system-bus policy.
    build:
      registerSystemConf()

  files spoolDir:
    ## /var/lib/dbus directory placeholder via M9.B fs.directory.
    ## The activation layer mkdir + chown messagebus:messagebus at
    ## apply time.
    build:
      registerSpoolDir()

  # -------------------------------------------------------------------------
  # service: block — M9.C extended systemd-unit metadata recorded into
  # the DslServiceDef registry. Activation-layer consumers (NDEM1)
  # read this to plant the unit-file's [Install] section, set up
  # WantedBy= aliases, etc. The literal ``execStart`` here records the
  # DEFAULT-strategy variant (basBroker); the per-strategy split at
  # build-time lives in ``files dbusService:`` via
  # ``renderDbusService(cfg.busActivationStrategy)``. The two surfaces
  # are kept in sync by convention: any future strategy literal
  # update in the renderDbusServiceBroker() / renderDbusServiceDaemon()
  # bodies should also propagate to the service-block default below.
  # -------------------------------------------------------------------------

  service systemBus:
    ## D-Bus system bus daemon (broker variant, default).
    description "D-Bus System Message Bus"
    `type` "dbus"
    wantedBy "multi-user.target"
    wants "dbus.socket"
    requires "dbus.socket"
    before "basic.target"
    execStart "/usr/bin/dbus-broker-launch --scope system --audit"
    user "messagebus"
    group "messagebus"
