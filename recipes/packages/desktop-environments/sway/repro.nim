## NDE-H1: native sway compositor package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-H1.
## This ``repro.nim`` is the user-facing package declaration; the actual
## implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
## desktop_environments/sway.nim`` (mirrors the NDE0-K / NDE0-G /
## NDE0-D / NDE0-S split between ``recipes/packages/<group>/<name>/
## repro.nim`` + ``libs/repro_dsl_stdlib/.../<group>/<name>.nim``).
##
## ## Naming decision (load-bearing)
##
## The campaign spec's Tier-2 work (DE-H1) shipped ``sway`` as a
## Hyprland surrogate for advisory expediency. The user clarified on
## 2026-06-17 that Tier-1 native packages should be true to their
## identity:
##
##   * This package is named ``sway`` (kebab-case sentinel /
##     ``swayCompositor`` for the camelCase DSL form). It documents
##     itself as the **minimal wlroots-tiling Wayland compositor** —
##     the canonical i3-on-Wayland project.
##   * The NDE-spec-block sentinel packageName segment is ``sway``,
##     NOT ``hyprland`` and NOT ``sway-as-hyprland``. The triple-form
##     sentinel is ``# >>> repro:system:sway:<blockId> >>>``.
##   * **Hyprland-the-package** (a separate wlroots-derived compositor
##     with its own configuration syntax + ecosystem) is a **future
##     NDE-Hp1 milestone**, not in scope here. NDE-H1's surface is
##     sway-shaped: ``/etc/sway/config`` with sway's native bindsym
##     syntax, ``sway-session.service``, ``/etc/wayland-sessions/
##     sway.desktop`` with ``Name=Sway`` + ``Exec=sway``.
##
## ## NDE-F: DSL-port migration to typed fs.* + service: surface
##
## NDE-F (sixth NDE rewrite, after NDE-A/B/C/D/E) migrates this recipe
## from the previous "shim does everything, recipe is a config: shell"
## pattern to the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/sway/config", content = ...)
##       fs.managedBlock(path = "/etc/ld.so.conf.d/...", scope = bsSystem,
##                       priority = 500, packageName = "sway", ...)
##
##   service sessionManager:
##     description "..."
##     `type` "oneshot"
##     execStart  "..."
##     wantedBy   "graphical-session.target"
##
## NDE-F is the **first compositor-side overlay** in the multi-contributor
## managedBlock cohort: it appends a ``libpaths`` contribution at
## **priority=500** to the ``/etc/ld.so.conf.d/00-reproos-linux.conf``
## block that NDE-D's graphics-stack anchors at priority=100. The merger
## sorts ``(priority, packageName, blockId)`` ascending so graphics-stack
## (priority=100) appears BEFORE sway (priority=500). NDE-D pinned this
## ordering from the anchor side via its multi-contributor merge test;
## NDE-F pins it from the overlay side via a parallel test below — a
## synthetic priority=100 contribution is registered alongside the
## recipe's priority=500 contribution and ``mergedManagedBlockFile``
## confirms graphics-stack sorts first.
##
## The three load-bearing identifiers for the libpaths contribution —
## the ``blockId``, the compositor ``priority``, and the kebab-cased
## packageName segment — are sourced from the shim's exported constants
## (``NdeH1LibpathsBlockId`` / ``NdeH1LibpathsPriority`` /
## ``NdeH1PackageName``) so a future rename or priority bump propagates
## across the cohort in one place.
##
## ## Configurables
##
## Per the spec NDE-H1 section. Each maps to a field on ``SwayConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` / ``managedBlockSha256Of`` hash propagates the
## change atomically through ``consumeConfigFile`` /
## ``consumeManagedBlock``; the unaffected artifacts stay cached).
##
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred) sway
##     + wlroots .deb consumption. Default
##     ``"ubuntu/jammy/20260615T000000Z"``. Part of every cache key so a
##     snapshot bump invalidates the ld.so.conf.d block atomically.
##   * ``superKey`` — modifier key bound to ``$mod`` in
##     ``/etc/sway/config``. Default ``"Super_L"`` per spec.
##   * ``terminalApp`` — terminal launched by ``$mod+Return``. Default
##     ``"foot"`` per spec. The acceptance toggles this from ``"foot"``
##     to ``"alacritty"`` to demonstrate cache-key propagation.
##   * ``launcherApp`` — application launcher launched by ``$mod+d``.
##     Default ``"wofi"`` per spec.
##   * ``extraModelines`` — optional ``output`` configurations. Default
##     ``@[]`` (sway auto-configures every connected output). NB: M2/M9.D
##     ``recordConfigDefault`` does not yet cover ``seq[string]`` — the
##     entry is declared in the ``config:`` block for documentary
##     purposes and forward compatibility but the recipe's helper reads
##     the impl module's ``defaultConfig().extraModelines`` default
##     rather than a configurable cell. When M3+ widens the runtime to
##     cover ``seq[string]``, the helper migrates to ``readConfigurable``
##     like the scalar configurables above. Same pattern as NDE-D's
##     ``fontPackages`` configurable.
##
## ## Honest deferrals
##
## * **sway / wlroots .deb extraction is DEFERRED.** v1 of NDE-H1
##   records the snapshot pin in every cache key but does NOT extract
##   the sway-1.7 / wlroots binary .debs into per-package content-
##   addressed store paths. The ld.so.conf.d block lists stub paths
##   whose hash is a pure function of the snapshot — when the .deb
##   extraction lands, the stub migrates to a real extracted directory
##   without breaking the cache-key contract.
##
## * **agent-harbor pane integration is DEFERRED to NDA-placeholder.**
##   Sway-on-ReproOS will eventually host an agent-harbor status pane
##   as a side-bar surface. That requires the agent-harbor handshake
##   protocol which isn't merged yet; v1 of NDE-H1 emits no pane
##   configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Generation switch atomically activates") needs the
##   system-generation switching layer (NDEM1) to read this package's
##   outputs and plant the live ``/etc/sway/config`` symlink. v1 emits
##   the output handles; the consumer that turns them into the live
##   /etc/ tree is NDEM1.
##
## * **service sessionManager: execStart literal**: The M5 ``service:``
##   parser captures ``execStart "literal"`` at macro-expansion time,
##   so the literal MUST be a compile-time string. The
##   ``"/usr/bin/sway"`` literal recorded here matches the rendered
##   ``sway-session.service`` unit-file's ExecStart= directive emitted
##   by ``renderSessionService()``. Both surfaces are kept in sync by
##   convention: any future update to the renderSessionService() body
##   should also propagate to the service-block literal below.
##
## * **extraModelines configurable propagation**: as documented above,
##   v1 declares the ``seq[string]`` config entry but the runtime can
##   only store scalar types today; toggling extraModelines via
##   ``setConfigurable`` is not supported yet. The library's render proc
##   still consumes the ``SwayConfig`` struct (constructed from defaults
##   for ``extraModelines``), so the rendered content is correct on
##   first emission. The cache key still propagates honestly because
##   the rendered bytes flow through ``configFileSha256Of(content)``.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# SwayConfig type + the per-output emission constants (NdeH1*).
# Imported under an alias so the recipe-side call sites stay readable
# (``swayImpl.renderSwayConfig()``). The shim's ``materializeSway``
# orchestrator + the legacy on-disk emitter procs are still available
# to legacy callers but the recipe no longer invokes them — all on-disk
# materialisation now flows through the DSL's M8 / M9.A path.
import repro_dsl_stdlib/packages/desktop_environments/sway as swayImpl
export swayImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const SwayPackageId* = "swayCompositor"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``swayImpl.NdeH1PackageName`` (= "sway"); the kebab-cased form is
  ## the cohort-wide sentinel segment for the libpaths block, while
  ## ``SwayPackageId`` is the DSL-side package identifier the M3
  ## registry indexes by.

proc currentSwayCfg*(): swayImpl.SwayConfig =
  ## Read every configurable cell into a ``SwayConfig`` record the
  ## shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## ``extraModelines`` is sourced from ``defaultConfig()`` rather than
  ## ``readConfigurable``: the M2/M9.D surface does not yet cover
  ## ``seq[string]`` and the ``config:`` block's entry is silently
  ## passed through at macro-expansion time (same pattern as NDE-D's
  ## ``fontPackages``). The cache-key propagates honestly because the
  ## rendered bytes still flow through ``configFileSha256Of``.
  let defaults = swayImpl.defaultConfig()
  result = swayImpl.SwayConfig(
    aptSnapshot: readConfigurable[string](
      "swayCompositor.aptSnapshot", defaults.aptSnapshot),
    superKey: readConfigurable[string](
      "swayCompositor.superKey", defaults.superKey),
    terminalApp: readConfigurable[string](
      "swayCompositor.terminalApp", defaults.terminalApp),
    launcherApp: readConfigurable[string](
      "swayCompositor.launcherApp", defaults.launcherApp),
    extraModelines: defaults.extraModelines,
    storeRoot: defaults.storeRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerSwayFiles()`` (below) directly with explicit packageName +
# artifactName so the call works outside a build: context.
# ---------------------------------------------------------------------------

proc registerSwayConfig*() =
  ## ``/etc/sway/config`` — the spec's load-bearing acceptance #1 file.
  ## Content is the rendered bindsym + exec-once + output configuration
  ## text from ``swayImpl.renderSwayConfig(cfg)``. Configurables
  ## ``superKey`` / ``terminalApp`` / ``launcherApp`` / ``extraModelines``
  ## all propagate to the cache key via the rendered bytes.
  let cfg = currentSwayCfg()
  fs.configFile(
    path = "/etc/sway/config",
    content = swayImpl.renderSwayConfig(cfg),
    packageName = SwayPackageId,
    artifactName = "config")

proc registerLdConfContribution*() =
  ## The libpaths managedBlock — NDE-F's overlay contribution at
  ## priority=500 against the same ``/etc/ld.so.conf.d/00-reproos-linux
  ## .conf`` block NDE-D's graphics-stack anchors at priority=100. The
  ## blockId / priority / packageName triple is sourced from the shim's
  ## exported constants so the cohort-wide rename or priority bump
  ## propagates in one place. The merger sorts ``(priority, packageName,
  ## blockId)`` ascending so graphics-stack (priority=100) sorts before
  ## sway (priority=500).
  let cfg = currentSwayCfg()
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = swayImpl.NdeH1LibpathsBlockId,
    scope = bsSystem,
    content = swayImpl.renderLdConfBlockContent(cfg),
    priority = swayImpl.NdeH1LibpathsPriority,   # =500 (compositor sort key)
    packageName = swayImpl.NdeH1PackageName,
    artifactName = "ldConfContribution")

proc registerSessionService*() =
  ## ``sway-session.service`` Type=oneshot unit at the cascade-G fix
  ## path /usr/lib/systemd/system/ (NOT the legacy /lib/systemd/system/
  ## which R9 systemd 257.9 dropped from the default UnitPath).
  fs.configFile(
    path = "/usr/lib/systemd/system/sway-session.service",
    content = swayImpl.renderSessionService(),
    packageName = SwayPackageId,
    artifactName = "sessionService")

proc registerSessionDesktopEntry*() =
  ## ``/etc/wayland-sessions/sway.desktop`` — XDG Desktop Entry the
  ## display-manager greeters (gdm, sddm) read to populate the session-
  ## picker dropdown.
  fs.configFile(
    path = "/etc/wayland-sessions/sway.desktop",
    content = swayImpl.renderSessionDesktopEntry(),
    packageName = SwayPackageId,
    artifactName = "sessionDesktopEntry")

proc registerSwayFiles*() =
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
  registerSwayConfig()
  registerLdConfContribution()
  registerSessionService()
  registerSessionDesktopEntry()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package swayCompositor:
  ## NDE-H1 native sway compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the recipe's fs.* artifacts through the
  ## DSL's ``consumeConfigFile`` / ``consumeManagedBlock`` materialiser:
  ##
  ##   * /etc/sway/config — the spec'd configurable-driven bindsym +
  ##     exec-once + output configurations.
  ##   * /etc/ld.so.conf.d/00-reproos-linux.conf — managedBlock
  ##     contribution (scope=system, packageName=sway, blockId=libpaths,
  ##     priority=500). Unions with NDE-D's graphics-stack contribution
  ##     at NDEM1 multi-contributor merge step.
  ##   * /usr/lib/systemd/system/sway-session.service — Type=oneshot
  ##     user-session unit (cascade-G fix path).
  ##   * /etc/wayland-sessions/sway.desktop — XDG session entry.

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) sway + wlroots .deb
    ## input. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of every
    ## cache key so a snapshot bump invalidates the libpaths block
    ## atomically.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Modifier key bound to ``$mod`` in /etc/sway/config. Default
    ## ``"Super_L"`` per spec.
    superKey: string = "Super_L"

    ## Terminal launched by ``$mod+Return``. Default ``"foot"`` per
    ## spec. Toggling this is the load-bearing acceptance #1 demo.
    terminalApp: string = "foot"

    ## Application launcher launched by ``$mod+d``. Default ``"wofi"``
    ## per spec.
    launcherApp: string = "wofi"

    ## Optional sway ``output`` configurations. Each entry is the
    ## argument portion of an ``output`` line. Insertion-order
    ## preserved (sway honours first-match-wins for output configs).
    ## Default ``@[]`` — sway auto-configures every connected output.
    ## NB: M2/M9.D ``recordConfigDefault`` does not yet cover
    ## ``seq[string]`` — the entry is documentary; the helper reads
    ## the impl module's default. See module-preamble honest deferrals.
    extraModelines: seq[string] = @[]

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) sway + wlroots .deb input. v1 of NDE-H1 records this
    ## dependency for fingerprint purposes but does not yet exercise
    ## ``installAptDeb()`` for the compositor bundles.
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
    ## ``DefaultStoreRoot`` helpers + the
    ## ``graphical-session.target`` / ``graphical-session-pre.target``
    ## user-instance anchors the sway-session.service unit hooks
    ## against.
    "systemd-session >=0.1.0"

    ## NDE0-D native dbus-broker — supplies the system bus runtime.
    ## Sway uses D-Bus for portals + session management.
    "dbus-broker >=0.1.0"

    ## NDE0-G native graphics-stack — supplies the wlroots
    ## prerequisites (Mesa DRM userland + libwayland + libxkbcommon +
    ## fontconfig + fonts-dejavu-core). The libpaths block
    ## contribution NDE-H1 emits here (priority=500) unions with
    ## NDE0-G's (priority=100) at the NDEM1 multi-contributor merge
    ## step.
    "graphics-stack >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files config:
    ## /etc/sway/config — the load-bearing user-facing keybind surface.
    ## Configurables (superKey, terminalApp, launcherApp,
    ## extraModelines) all propagate through ``renderSwayConfig(cfg)``
    ## to the cache key.
    build:
      registerSwayConfig()

  files ldConfContribution:
    ## /etc/ld.so.conf.d/00-reproos-linux.conf — NDE-F's overlay
    ## contribution at priority=500 (cohort packageName="sway",
    ## blockId="libpaths"). Unions with NDE-D graphics-stack's
    ## priority=100 anchor at the merge step.
    build:
      registerLdConfContribution()

  files sessionService:
    ## /usr/lib/systemd/system/sway-session.service — Type=oneshot
    ## user-session unit at the cascade-G fix path (NOT
    ## /lib/systemd/system/ — R9 dropped that from UnitPath).
    build:
      registerSessionService()

  files sessionDesktopEntry:
    ## /etc/wayland-sessions/sway.desktop — XDG session entry the
    ## display-manager greeters read to populate the session-picker.
    build:
      registerSessionDesktopEntry()

  # -------------------------------------------------------------------------
  # service: block — M9.C extended systemd-unit metadata recorded into
  # the DslServiceDef registry. Activation-layer consumers (NDEM1)
  # read this to plant the unit-file's [Install] section, set up
  # WantedBy= aliases, etc. The literal ``execStart`` here records the
  # ``/usr/bin/sway`` binary path that matches the rendered
  # ``sway-session.service`` unit-file's ExecStart= directive emitted
  # by ``renderSessionService()``.
  # -------------------------------------------------------------------------

  service sessionManager:
    ## Sway user-session manager (the compositor itself).
    description "Sway wlroots-tiling Wayland compositor session"
    `type` "oneshot"
    execStart "/usr/bin/sway"
    wantedBy "graphical-session.target"
    after "graphical-session-pre.target"
