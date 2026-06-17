## NDE-G1: native GNOME compositor package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-G1.
## This ``repro.nim`` is the user-facing package declaration; the actual
## implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
## desktop_environments/gnome.nim`` (mirrors the NDE-H1 (sway) +
## NDE0-K / NDE0-G / NDE0-D / NDE0-S split between
## ``recipes/packages/<group>/<name>/repro.nim`` +
## ``libs/repro_dsl_stdlib/.../<group>/<name>.nim``).
##
## ## NDE-G: DSL-port migration to typed fs.* + service: surface
##
## NDE-G (seventh NDE rewrite, after NDE-A/B/C/D/E/F) migrates this
## recipe from the previous "shim does everything, recipe is a config:
## shell" pattern to the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/gdm3/custom.conf", content = ...)
##       fs.managedBlock(path = "/etc/ld.so.conf.d/...", scope = bsSystem,
##                       priority = 500, packageName = "gnome", ...)
##
##   service displayManager:
##     description "GNOME Display Manager"
##     `type` "notify"
##     execStart  "/usr/sbin/gdm3"
##     wantedBy   "graphical.target"
##
## NDE-G is the **second compositor-side overlay** in the multi-contributor
## managedBlock cohort (after NDE-F sway): it appends a ``libpaths``
## contribution at **priority=500** to the
## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` block that NDE-D's
## graphics-stack anchors at priority=100. The merger sorts ``(priority,
## packageName, blockId)`` ascending so graphics-stack (priority=100)
## appears BEFORE gnome (priority=500). NDE-D pinned this ordering from
## the anchor side via its multi-contributor merge test; NDE-G pins it
## from the overlay side via a parallel test below — a synthetic
## priority=100 contribution is registered alongside the recipe's
## priority=500 contribution and ``mergedManagedBlockFile`` confirms
## graphics-stack sorts first.
##
## The three load-bearing identifiers for the libpaths contribution —
## the ``blockId``, the compositor ``priority``, and the kebab-cased
## packageName segment — are sourced from the shim's exported constants
## (``NdeG1LibpathsBlockId`` / ``NdeG1LibpathsPriority`` /
## ``NdeG1PackageName``) so a future rename or priority bump propagates
## across the cohort in one place.
##
## ## Configurables
##
## Per the spec NDE-G1 section. Each maps to a field on ``GnomeConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` / ``managedBlockSha256Of`` hash propagates the
## change atomically through ``consumeConfigFile`` /
## ``consumeManagedBlock``; the unaffected artifacts stay cached).
##
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred)
##     gnome-shell / mutter / gdm3 .deb consumption. Default
##     ``"ubuntu/jammy/20260615T000000Z"``. Part of every cache key so a
##     snapshot bump invalidates the ld.so.conf.d block atomically.
##   * ``autoLogin`` — bind into ``AutomaticLoginEnable=true|false`` of
##     /etc/gdm3/custom.conf. Default ``true`` per spec. The acceptance
##     toggles this to ``false`` to demonstrate cache-key propagation
##     (only gdmConfig re-keys).
##   * ``autoLoginUser`` — bind into ``AutomaticLogin=<user>`` of
##     /etc/gdm3/custom.conf. Default ``"repro"`` (matches NDE0-S's
##     ``defaultUser``).
##   * ``waylandSession`` — bind into ``WaylandEnable=true|false`` of
##     /etc/gdm3/custom.conf. Default ``true`` per spec.
##   * ``disableInitialSetup`` — suppress gnome-initial-setup on first
##     boot. Default ``true`` (the MVP runs on a serial console + an
##     autologin user; the welcome wizard would block boot).
##
## ## Honest deferrals
##
## * **gnome-shell / mutter / gdm3 .deb extraction is DEFERRED.** v1 of
##   NDE-G1 records the snapshot pin in every cache key but does NOT
##   extract the gnome-shell / mutter / gdm3 binary .debs into per-
##   package content-addressed store paths. The ld.so.conf.d block
##   lists stub paths whose hash is a pure function of the snapshot —
##   when the .deb extraction lands, the stub migrates to a real
##   extracted directory without breaking the cache-key contract.
##
## * **agent-harbor extension integration is DEFERRED to NDA-placeholder.**
##   GNOME-on-ReproOS will eventually surface an agent-harbor extension
##   pane. That requires the agent-harbor handshake protocol which
##   isn't merged yet; v1 of NDE-G1 emits no extension configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Switch generation → login screen behaviour changes
##   atomically") needs the system-generation switching layer (NDEM1)
##   to read this package's outputs and plant the live ``/etc/gdm3/``
##   symlinks. v1 emits the output handles; the consumer that turns
##   them into the live /etc/ tree is NDEM1.
##
## * **service displayManager: execStart literal**: The M5 ``service:``
##   parser captures ``execStart "literal"`` at macro-expansion time,
##   so the literal MUST be a compile-time string. The
##   ``"/usr/sbin/gdm3"`` literal recorded here matches the rendered
##   ``gdm.service`` unit-file's ExecStart= directive emitted by
##   ``renderGdmService()``. Both surfaces are kept in sync by
##   convention: any future update to the renderGdmService() body
##   should also propagate to the service-block literal below.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# GnomeConfig type + the per-output emission constants (NdeG1*).
# Imported under an alias so the recipe-side call sites stay readable
# (``gnomeImpl.renderGdmConfig()``). The shim's ``materializeGnome``
# orchestrator + the legacy on-disk emitter procs are still available
# to legacy callers but the recipe no longer invokes them — all on-disk
# materialisation now flows through the DSL's M8 / M9.A path.
import repro_dsl_stdlib/packages/desktop_environments/gnome as gnomeImpl
export gnomeImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const GnomePackageId* = "gnomeDesktop"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``gnomeImpl.NdeG1PackageName`` (= "gnome"); the kebab-cased form is
  ## the cohort-wide sentinel segment for the libpaths block, while
  ## ``GnomePackageId`` is the DSL-side package identifier the M3
  ## registry indexes by.

proc currentGnomeCfg*(): gnomeImpl.GnomeConfig =
  ## Read every configurable cell into a ``GnomeConfig`` record the
  ## shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## All five NDE-G1 configurables are M9.D-supported scalar types
  ## (``string`` and ``bool``), so every cell flows through
  ## ``readConfigurable``. Unlike NDE-F's ``extraModelines: seq[string]``,
  ## there's no documentary-only field here.
  let defaults = gnomeImpl.defaultConfig()
  result = gnomeImpl.GnomeConfig(
    aptSnapshot: readConfigurable[string](
      "gnomeDesktop.aptSnapshot", defaults.aptSnapshot),
    autoLogin: readConfigurable[bool](
      "gnomeDesktop.autoLogin", defaults.autoLogin),
    autoLoginUser: readConfigurable[string](
      "gnomeDesktop.autoLoginUser", defaults.autoLoginUser),
    waylandSession: readConfigurable[bool](
      "gnomeDesktop.waylandSession", defaults.waylandSession),
    disableInitialSetup: readConfigurable[bool](
      "gnomeDesktop.disableInitialSetup", defaults.disableInitialSetup),
    storeRoot: defaults.storeRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerGnomeFiles()`` (below) directly with explicit packageName +
# artifactName so the call works outside a build: context.
# ---------------------------------------------------------------------------

proc registerGdmConfig*() =
  ## ``/etc/gdm3/custom.conf`` — the spec's load-bearing acceptance #1
  ## file. Content is the rendered INI text from
  ## ``gnomeImpl.renderGdmConfig(cfg)``. Configurables ``autoLogin`` /
  ## ``autoLoginUser`` / ``waylandSession`` / ``disableInitialSetup`` all
  ## propagate to the cache key via the rendered bytes.
  let cfg = currentGnomeCfg()
  fs.configFile(
    path = "/etc/gdm3/custom.conf",
    content = gnomeImpl.renderGdmConfig(cfg),
    packageName = GnomePackageId,
    artifactName = "gdmConfig")

proc registerLdConfContribution*() =
  ## The libpaths managedBlock — NDE-G's overlay contribution at
  ## priority=500 against the same ``/etc/ld.so.conf.d/00-reproos-linux
  ## .conf`` block NDE-D's graphics-stack anchors at priority=100. The
  ## blockId / priority / packageName triple is sourced from the shim's
  ## exported constants so the cohort-wide rename or priority bump
  ## propagates in one place. The merger sorts ``(priority, packageName,
  ## blockId)`` ascending so graphics-stack (priority=100) sorts before
  ## gnome (priority=500).
  let cfg = currentGnomeCfg()
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = gnomeImpl.NdeG1LibpathsBlockId,
    scope = bsSystem,
    content = gnomeImpl.renderLdConfBlockContent(cfg),
    priority = gnomeImpl.NdeG1LibpathsPriority,   # =500 (compositor sort key)
    packageName = gnomeImpl.NdeG1PackageName,
    artifactName = "ldConfContribution")

proc registerGdmService*() =
  ## ``gdm.service`` Type=notify unit at the cascade-G fix path
  ## /usr/lib/systemd/system/ (NOT the legacy /lib/systemd/system/
  ## which R9 systemd 257.9 dropped from the default UnitPath).
  let cfg = currentGnomeCfg()
  fs.configFile(
    path = "/usr/lib/systemd/system/gdm.service",
    content = gnomeImpl.renderGdmService(cfg),
    packageName = GnomePackageId,
    artifactName = "gdmService")

proc registerSessionDesktopEntry*() =
  ## ``/etc/wayland-sessions/gnome.desktop`` — XDG Desktop Entry the
  ## display-manager greeters (gdm itself, plus sddm if installed
  ## alongside) read to populate the session-picker dropdown.
  let cfg = currentGnomeCfg()
  fs.configFile(
    path = "/etc/wayland-sessions/gnome.desktop",
    content = gnomeImpl.renderSessionDesktopEntry(cfg),
    packageName = GnomePackageId,
    artifactName = "sessionDesktopEntry")

proc registerGnomeFiles*() =
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
  registerGdmConfig()
  registerLdConfContribution()
  registerGdmService()
  registerSessionDesktopEntry()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gnomeDesktop:
  ## NDE-G1 native GNOME compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the recipe's fs.* artifacts through the
  ## DSL's ``consumeConfigFile`` / ``consumeManagedBlock`` materialiser:
  ##
  ##   * /etc/gdm3/custom.conf — the spec'd configurable-driven INI
  ##     contents (daemon + chooser + debug + security + xdmcp +
  ##     InitialSetupEnable sections).
  ##   * /etc/ld.so.conf.d/00-reproos-linux.conf — managedBlock
  ##     contribution (scope=system, packageName=gnome, blockId=libpaths,
  ##     priority=500). Unions with NDE-D's graphics-stack contribution
  ##     at NDEM1 multi-contributor merge step.
  ##   * /usr/lib/systemd/system/gdm.service — Type=notify display-
  ##     manager unit (cascade-G fix path).
  ##   * /etc/wayland-sessions/gnome.desktop — XDG session entry.

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) gnome-shell / mutter
    ## / gdm3 .deb input. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part
    ## of every cache key so a snapshot bump invalidates the libpaths
    ## block atomically.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Automatic login enable. Default ``true`` per spec NDE-G1.
    ## Toggling this is the load-bearing acceptance demo: only
    ## /etc/gdm3/custom.conf re-keys.
    autoLogin: bool = true

    ## Account used when ``autoLogin`` is ``true``. Default
    ## ``"repro"`` (matches NDE0-S's ``defaultUser``).
    autoLoginUser: string = "repro"

    ## Wayland session default. Default ``true`` per spec.
    waylandSession: bool = true

    ## Suppress gnome-initial-setup on first boot. Default ``true``
    ## (the ReproOS MVP runs on serial console + autologin; the
    ## wizard would block boot).
    disableInitialSetup: bool = true

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) gnome-shell / mutter / gdm3 / gnome-settings-daemon
    ## / at-spi2-core / gnome-session .deb input. v1 of NDE-G1
    ## records this dependency for fingerprint purposes but does not
    ## yet exercise ``installAptDeb()`` for the compositor bundles.
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
    ## ``DefaultStoreRoot`` helpers + the PAM stacks + the user-
    ## session targets gdm hooks against.
    "systemd-session >=0.1.0"

    ## NDE0-D native dbus-broker — supplies the system bus runtime.
    ## gdm uses accountsservice + logind + GNOME Shell via D-Bus.
    "dbus-broker >=0.1.0"

    ## NDE0-G native graphics-stack — supplies the Mesa + libdrm +
    ## libwayland + libxkbcommon + fontconfig prerequisites mutter
    ## needs. The libpaths block contribution NDE-G1 emits here
    ## (priority=500) unions with NDE0-G's (priority=100) at the NDEM1
    ## multi-contributor merge step.
    "graphics-stack >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files gdmConfig:
    ## /etc/gdm3/custom.conf — the load-bearing user-facing gdm
    ## configuration. Configurables (autoLogin, autoLoginUser,
    ## waylandSession, disableInitialSetup) all propagate through
    ## ``renderGdmConfig(cfg)`` to the cache key.
    build:
      registerGdmConfig()

  files ldConfContribution:
    ## /etc/ld.so.conf.d/00-reproos-linux.conf — NDE-G's overlay
    ## contribution at priority=500 (cohort packageName="gnome",
    ## blockId="libpaths"). Unions with NDE-D graphics-stack's
    ## priority=100 anchor at the merge step.
    build:
      registerLdConfContribution()

  files gdmService:
    ## /usr/lib/systemd/system/gdm.service — Type=notify display-
    ## manager unit at the cascade-G fix path (NOT
    ## /lib/systemd/system/ — R9 dropped that from UnitPath).
    build:
      registerGdmService()

  files sessionDesktopEntry:
    ## /etc/wayland-sessions/gnome.desktop — XDG session entry the
    ## display-manager greeters read to populate the session-picker.
    build:
      registerSessionDesktopEntry()

  # -------------------------------------------------------------------------
  # service: block — M9.C extended systemd-unit metadata recorded into
  # the DslServiceDef registry. Activation-layer consumers (NDEM1)
  # read this to plant the unit-file's [Install] section, set up
  # WantedBy= aliases, etc. The literal ``execStart`` here records the
  # ``/usr/sbin/gdm3`` binary path that matches the rendered
  # ``gdm.service`` unit-file's ExecStart= directive emitted by
  # ``renderGdmService()``.
  # -------------------------------------------------------------------------

  service displayManager:
    ## gdm3 GNOME Display Manager.
    description "GNOME Display Manager"
    `type` "notify"
    execStart "/usr/sbin/gdm3"
    wantedBy "graphical.target"
    after "systemd-user-sessions.service"
