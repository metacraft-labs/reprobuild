## NDE-K1: native KDE Plasma compositor package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-K1.
## This ``repro.nim`` is the user-facing package declaration; the actual
## implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
## desktop_environments/plasma.nim`` (mirrors the NDE-G1 (gnome) +
## NDE-H1 (sway) + NDE0-K / NDE0-G / NDE0-D / NDE0-S split between
## ``recipes/packages/<group>/<name>/repro.nim`` +
## ``libs/repro_dsl_stdlib/.../<group>/<name>.nim``).
##
## ## NDE-H: DSL-port migration to typed fs.* + service: surface
##
## NDE-H (eighth NDE rewrite, after NDE-A/B/C/D/E/F/G) migrates this
## recipe from the previous "shim does everything, recipe is a config:
## shell" pattern to the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/sddm.conf", content = ...)
##       fs.managedBlock(path = "/etc/ld.so.conf.d/...", scope = bsSystem,
##                       priority = 500, packageName = "plasma", ...)
##
##   service displayManager:
##     description "Simple Desktop Display Manager"
##     `type` "simple"
##     execStart  "/usr/bin/sddm"
##     wantedBy   "graphical.target"
##
## NDE-H is the **third compositor-side overlay** in the multi-contributor
## managedBlock cohort (after NDE-F sway + NDE-G gnome): it appends a
## ``libpaths`` contribution at **priority=500** to the
## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` block that NDE-D's
## graphics-stack anchors at priority=100. The merger sorts ``(priority,
## packageName, blockId)`` ascending so graphics-stack (priority=100)
## appears BEFORE plasma (priority=500). NDE-D pinned this ordering from
## the anchor side via its multi-contributor merge test; NDE-H pins it
## from the overlay side via a parallel test below — a synthetic
## priority=100 contribution is registered alongside the recipe's
## priority=500 contribution and ``mergedManagedBlockFile`` confirms
## graphics-stack sorts first.
##
## The three load-bearing identifiers for the libpaths contribution —
## the ``blockId``, the compositor ``priority``, and the kebab-cased
## packageName segment — are sourced from the shim's exported constants
## (``NdeK1LibpathsBlockId`` / ``NdeK1LibpathsPriority`` /
## ``NdeK1PackageName``) so a future rename or priority bump propagates
## across the cohort in one place.
##
## ## Plasma's extra artifact: /etc/pipewire/pipewire.conf
##
## Plasma is the largest DE cohort member — it ships FIVE files where
## sway + gnome ship four. The extra artifact is
## ``/etc/pipewire/pipewire.conf``: Plasma's audio + screen-capture
## stack runs on PipeWire (the spec literal notes "since Plasma brings
## PipeWire"). The ``pipewireEnabled`` configurable toggles the rendered
## content between an ENABLED daemon config and a DISABLED marker file
## so the activation step always has a stable target to symlink.
##
## ## Configurables
##
## Per the spec NDE-K1 section. Each maps to a field on ``PlasmaConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` / ``managedBlockSha256Of`` hash propagates the
## change atomically through ``consumeConfigFile`` /
## ``consumeManagedBlock``; the unaffected artifacts stay cached).
##
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred)
##     sddm / kwin / plasma-workspace / plasma-desktop / kf5-frameworks
##     / qt5-base .deb consumption. Default
##     ``"ubuntu/jammy/20260615T000000Z"``. Part of every cache key so a
##     snapshot bump invalidates the ld.so.conf.d block atomically.
##   * ``sddmAutoLogin`` — bind into ``[Autologin] User=...`` of
##     /etc/sddm.conf (when ``true``, the user line is populated; when
##     ``false``, blank). Default ``true`` per spec. The acceptance
##     toggles this to ``false`` to demonstrate cache-key propagation.
##   * ``sddmAutoLoginUser`` — bind into ``[Autologin] User=<user>``
##     of /etc/sddm.conf. Default ``"repro"`` (matches NDE0-S's
##     ``defaultUser`` + NDE-G1's autoLoginUser).
##   * ``waylandSession`` — bind into
##     ``[General] DisplayServer=wayland|x11`` of /etc/sddm.conf.
##     Default ``true`` per spec.
##   * ``pipewireEnabled`` — bind into the content of
##     /etc/pipewire/pipewire.conf. Default ``true`` per spec ("since
##     Plasma brings PipeWire"). When ``false``, a "disabled" marker
##     file is emitted so the activation step still has a stable
##     target to symlink.
##
## ## Honest deferrals
##
## * **sddm / kwin / plasma-workspace / plasma-desktop / kf5-frameworks
##   / qt5-base .deb extraction is DEFERRED.** v1 of NDE-K1 records the
##   snapshot pin in every cache key but does NOT extract the binary
##   .debs into per-package content-addressed store paths. The
##   ld.so.conf.d block lists stub paths whose hash is a pure function
##   of the snapshot — when the .deb extraction lands, the stub
##   migrates to a real extracted directory without breaking the
##   cache-key contract.
##
## * **agent-harbor plasmoid integration is DEFERRED to NDA-placeholder.**
##   Plasma-on-ReproOS will eventually surface an agent-harbor plasmoid
##   / widget. That requires the agent-harbor handshake protocol which
##   isn't merged yet; v1 of NDE-K1 emits no plasmoid configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Switch generation → login screen behaviour changes
##   atomically") needs the system-generation switching layer (NDEM1)
##   to read this package's outputs and plant the live ``/etc/sddm.conf``
##   + ``/etc/pipewire/`` symlinks. v1 emits the output handles; the
##   consumer that turns them into the live /etc/ tree is NDEM1.
##
## * **service displayManager: execStart literal**: The M5 ``service:``
##   parser captures ``execStart "literal"`` at macro-expansion time,
##   so the literal MUST be a compile-time string. The
##   ``"/usr/bin/sddm"`` literal recorded here matches the rendered
##   ``sddm.service`` unit-file's ExecStart= directive emitted by
##   ``renderSddmService()``. Both surfaces are kept in sync by
##   convention: any future update to the renderSddmService() body
##   should also propagate to the service-block literal below.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# PlasmaConfig type + the per-output emission constants (NdeK1*).
# Imported under an alias so the recipe-side call sites stay readable
# (``plasmaImpl.renderSddmConfig()``). The shim's ``materializePlasma``
# orchestrator + the legacy on-disk emitter procs are still available
# to legacy callers but the recipe no longer invokes them — all on-disk
# materialisation now flows through the DSL's M8 / M9.A path.
import repro_dsl_stdlib/packages/desktop_environments/plasma as plasmaImpl
export plasmaImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const PlasmaPackageId* = "plasmaDesktop"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``plasmaImpl.NdeK1PackageName`` (= "plasma"); the kebab-cased form
  ## is the cohort-wide sentinel segment for the libpaths block, while
  ## ``PlasmaPackageId`` is the DSL-side package identifier the M3
  ## registry indexes by.

proc currentPlasmaCfg*(): plasmaImpl.PlasmaConfig =
  ## Read every configurable cell into a ``PlasmaConfig`` record the
  ## shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## All five NDE-K1 configurables are M9.D-supported scalar types
  ## (``string`` and ``bool``), so every cell flows through
  ## ``readConfigurable``. Unlike NDE-F's ``extraModelines: seq[string]``,
  ## there's no documentary-only field here.
  let defaults = plasmaImpl.defaultConfig()
  result = plasmaImpl.PlasmaConfig(
    aptSnapshot: readConfigurable[string](
      "plasmaDesktop.aptSnapshot", defaults.aptSnapshot),
    sddmAutoLogin: readConfigurable[bool](
      "plasmaDesktop.sddmAutoLogin", defaults.sddmAutoLogin),
    sddmAutoLoginUser: readConfigurable[string](
      "plasmaDesktop.sddmAutoLoginUser", defaults.sddmAutoLoginUser),
    waylandSession: readConfigurable[bool](
      "plasmaDesktop.waylandSession", defaults.waylandSession),
    pipewireEnabled: readConfigurable[bool](
      "plasmaDesktop.pipewireEnabled", defaults.pipewireEnabled),
    storeRoot: defaults.storeRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerPlasmaFiles()`` (below) directly with explicit packageName +
# artifactName so the call works outside a build: context.
# ---------------------------------------------------------------------------

proc registerSddmConfig*() =
  ## ``/etc/sddm.conf`` — the spec's load-bearing acceptance #1 file.
  ## Content is the rendered INI text from
  ## ``plasmaImpl.renderSddmConfig(cfg)``. Configurables
  ## ``sddmAutoLogin`` / ``sddmAutoLoginUser`` / ``waylandSession`` all
  ## propagate to the cache key via the rendered bytes.
  let cfg = currentPlasmaCfg()
  fs.configFile(
    path = "/etc/sddm.conf",
    content = plasmaImpl.renderSddmConfig(cfg),
    packageName = PlasmaPackageId,
    artifactName = "sddmConfig")

proc registerLdConfContribution*() =
  ## The libpaths managedBlock — NDE-H's overlay contribution at
  ## priority=500 against the same ``/etc/ld.so.conf.d/00-reproos-linux
  ## .conf`` block NDE-D's graphics-stack anchors at priority=100. The
  ## blockId / priority / packageName triple is sourced from the shim's
  ## exported constants so the cohort-wide rename or priority bump
  ## propagates in one place. The merger sorts ``(priority, packageName,
  ## blockId)`` ascending so graphics-stack (priority=100) sorts before
  ## plasma (priority=500).
  let cfg = currentPlasmaCfg()
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = plasmaImpl.NdeK1LibpathsBlockId,
    scope = bsSystem,
    content = plasmaImpl.renderLdConfBlockContent(cfg),
    priority = plasmaImpl.NdeK1LibpathsPriority,   # =500 (compositor sort key)
    packageName = plasmaImpl.NdeK1PackageName,
    artifactName = "ldConfContribution")

proc registerSddmService*() =
  ## ``sddm.service`` Type=simple unit at the cascade-G fix path
  ## /usr/lib/systemd/system/ (NOT the legacy /lib/systemd/system/
  ## which R9 systemd 257.9 dropped from the default UnitPath).
  let cfg = currentPlasmaCfg()
  fs.configFile(
    path = "/usr/lib/systemd/system/sddm.service",
    content = plasmaImpl.renderSddmService(cfg),
    packageName = PlasmaPackageId,
    artifactName = "sddmService")

proc registerSessionDesktopEntry*() =
  ## ``/etc/wayland-sessions/plasma.desktop`` — XDG Desktop Entry the
  ## display-manager greeters (sddm itself, plus gdm if installed
  ## alongside) read to populate the session-picker dropdown.
  let cfg = currentPlasmaCfg()
  fs.configFile(
    path = "/etc/wayland-sessions/plasma.desktop",
    content = plasmaImpl.renderSessionDesktopEntry(cfg),
    packageName = PlasmaPackageId,
    artifactName = "sessionDesktopEntry")

proc registerPipewireConfig*() =
  ## ``/etc/pipewire/pipewire.conf`` — Plasma's audio + screen-capture
  ## daemon config. The ``pipewireEnabled`` configurable toggles between
  ## an ENABLED daemon config and a DISABLED marker file. The extra
  ## fifth artifact (vs NDE-F sway + NDE-G gnome's four-artifact shape)
  ## that makes Plasma the largest DE cohort member.
  let cfg = currentPlasmaCfg()
  fs.configFile(
    path = "/etc/pipewire/pipewire.conf",
    content = plasmaImpl.renderPipewireConfig(cfg),
    packageName = PlasmaPackageId,
    artifactName = "pipewireConfig")

proc registerPlasmaFiles*() =
  ## Register every fs.* output the recipe owns. Idempotent at the
  ## per-call level only — call ``resetDslPortFsState`` +
  ## ``resetDslPortFsExtState`` before re-invoking, otherwise each fs.*
  ## call appends a fresh row to the registry.
  ##
  ## Used by the unit-test fixture to re-register after a configurable
  ## toggle. The recipe's ``files <name>: build:`` arms below each
  ## invoke a single per-artifact helper so the M4 ``beginBuildContext``
  ## push carries the spec'd artifact name; the per-artifact helpers'
  ## explicit packageName argument keeps the registration well-formed
  ## when called outside a build: context (as the test fixture does).
  registerSddmConfig()
  registerLdConfContribution()
  registerSddmService()
  registerSessionDesktopEntry()
  registerPipewireConfig()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package plasmaDesktop:
  ## NDE-K1 native KDE Plasma compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the recipe's fs.* artifacts through the
  ## DSL's ``consumeConfigFile`` / ``consumeManagedBlock`` materialiser:
  ##
  ##   * /etc/sddm.conf — the spec'd configurable-driven INI contents
  ##     ([Autologin] + [General] + [Wayland] + [Theme] sections).
  ##   * /etc/ld.so.conf.d/00-reproos-linux.conf — managedBlock
  ##     contribution (scope=system, packageName=plasma, blockId=libpaths,
  ##     priority=500). Unions with NDE-D's graphics-stack contribution
  ##     at NDEM1 multi-contributor merge step.
  ##   * /usr/lib/systemd/system/sddm.service — Type=simple display-
  ##     manager unit (cascade-G fix path).
  ##   * /etc/wayland-sessions/plasma.desktop — XDG session entry.
  ##   * /etc/pipewire/pipewire.conf — PipeWire daemon config (the
  ##     extra fifth artifact making Plasma the largest cohort member).

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) sddm / kwin /
    ## plasma-workspace / plasma-desktop / kf5-frameworks / qt5-base
    ## .deb input. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the libpaths
    ## block atomically.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## sddm automatic login enable. Default ``true`` per spec NDE-K1.
    ## Toggling this is the load-bearing acceptance demo: only
    ## /etc/sddm.conf re-keys.
    sddmAutoLogin: bool = true

    ## Account used when ``sddmAutoLogin`` is ``true``. Default
    ## ``"repro"`` (matches NDE0-S's ``defaultUser`` + NDE-G1's
    ## autoLoginUser).
    sddmAutoLoginUser: string = "repro"

    ## Wayland session default. Default ``true`` per spec.
    waylandSession: bool = true

    ## PipeWire enable. Default ``true`` per spec ("since Plasma
    ## brings PipeWire"). When ``false``, a "disabled" marker file is
    ## emitted at /etc/pipewire/pipewire.conf so the activation step
    ## still has a stable target to symlink.
    pipewireEnabled: bool = true

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) sddm / kwin / plasma-workspace / plasma-desktop /
    ## kf5-frameworks / qt5-base .deb input. v1 of NDE-K1 records
    ## this dependency for fingerprint purposes but does not yet
    ## exercise ``installAptDeb()`` for the compositor bundles.
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
    ## ``DefaultStoreRoot`` helpers + the PAM stacks + the user-
    ## session targets sddm hooks against.
    "systemd-session >=0.1.0"

    ## NDE0-D native dbus-broker — supplies the system bus runtime.
    ## sddm uses accountsservice + logind via D-Bus; KDE apps use
    ## kded5 + various KIO slaves over D-Bus.
    "dbus-broker >=0.1.0"

    ## NDE0-G native graphics-stack — supplies the Mesa + libdrm +
    ## libwayland + libxkbcommon + fontconfig prerequisites kwin
    ## needs. The libpaths block contribution NDE-K1 emits here
    ## (priority=500) unions with NDE0-G's (priority=100) at the NDEM1
    ## multi-contributor merge step.
    "graphics-stack >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files sddmConfig:
    ## /etc/sddm.conf — the load-bearing user-facing sddm configuration.
    ## Configurables (sddmAutoLogin, sddmAutoLoginUser, waylandSession)
    ## all propagate through ``renderSddmConfig(cfg)`` to the cache key.
    build:
      registerSddmConfig()

  files ldConfContribution:
    ## /etc/ld.so.conf.d/00-reproos-linux.conf — NDE-H's overlay
    ## contribution at priority=500 (cohort packageName="plasma",
    ## blockId="libpaths"). Unions with NDE-D graphics-stack's
    ## priority=100 anchor at the merge step.
    build:
      registerLdConfContribution()

  files sddmService:
    ## /usr/lib/systemd/system/sddm.service — Type=simple display-
    ## manager unit at the cascade-G fix path (NOT
    ## /lib/systemd/system/ — R9 dropped that from UnitPath).
    build:
      registerSddmService()

  files sessionDesktopEntry:
    ## /etc/wayland-sessions/plasma.desktop — XDG session entry the
    ## display-manager greeters read to populate the session-picker.
    build:
      registerSessionDesktopEntry()

  files pipewireConfig:
    ## /etc/pipewire/pipewire.conf — PipeWire daemon config (Plasma's
    ## audio + screen-capture stack). The extra fifth artifact making
    ## Plasma the largest DE cohort member.
    build:
      registerPipewireConfig()

  # -------------------------------------------------------------------------
  # service: block — M9.C extended systemd-unit metadata recorded into
  # the DslServiceDef registry. Activation-layer consumers (NDEM1)
  # read this to plant the unit-file's [Install] section, set up
  # WantedBy= aliases, etc. The literal ``execStart`` here records the
  # ``/usr/bin/sddm`` binary path that matches the rendered
  # ``sddm.service`` unit-file's ExecStart= directive emitted by
  # ``renderSddmService()``.
  # -------------------------------------------------------------------------

  service displayManager:
    ## sddm Simple Desktop Display Manager.
    description "Simple Desktop Display Manager"
    `type` "simple"
    execStart "/usr/bin/sddm"
    wantedBy "graphical.target"
    after "systemd-user-sessions.service"
