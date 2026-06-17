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
## ## Why this layout
##
## The spec worked example uses two DSL block forms not yet recognised
## by ``parsePackageDef`` at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``:
##
##   files config:
##     build:
##       fs.configFile(
##         path = "/etc/sway/config",
##         content = iniContent:
##           # sway-config-shaped template — see impl module for the
##           # render logic
##       )
##
##   service sessionManager:
##     description = "Sway wlroots-tiling Wayland compositor session"
##     type        = oneshot
##     execStart   = "/usr/bin/sway"
##     wantedBy    = "graphical-session.target"
##
## ``parsePackageDef`` currently recognises only ``executable`` /
## ``library`` / ``uses`` / ``config`` / ``outputs`` section heads —
## ``files <name>:`` block form + ``service <name>:`` block form are
## pure DSL spec at this point. NDE0-A + NDE0-S + NDE0-D + NDE0-G +
## NDE0-K all documented the same limitation. The runtime semantics of
## these blocks live in the planted ``/etc/sway/config`` +
## ``sway-session.service`` + ``/etc/wayland-sessions/sway.desktop``
## files emitted by the impl module's ``materializeSway`` proc.
##
## ## Configurables
##
## Per the spec NDE-H1 section. Each maps to a field on ``SwayConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the impl module's per-output hash
## derivation propagates the change atomically; the unaffected outputs
## stay cached). See the impl module's ``SwayOutputs`` docstring for
## the full invalidation matrix.
##
##   * ``superKey`` — modifier key bound to ``$mod`` in
##     ``/etc/sway/config``. Default ``"Super_L"`` per spec.
##   * ``terminalApp`` — terminal launched by ``$mod+Return``. Default
##     ``"foot"`` per spec. The acceptance toggles this from ``"foot"``
##     to ``"alacritty"`` to demonstrate cache-key propagation.
##   * ``launcherApp`` — application launcher launched by ``$mod+d``.
##     Default ``"wofi"`` per spec.
##   * ``extraModelines`` — optional ``output`` configurations. Default
##     ``@[]`` (sway auto-configures every connected output).
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred) sway
##     + wlroots .deb consumption. Part of every cache key.
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
## * **``files config:`` + ``service sessionManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from the impl module.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# /etc/sway/config / unit-file / desktop-entry text. Imported here so
# it is in scope for downstream packages that ``uses: "sway >=0.1.0"``
# and inline a ``build:`` block invoking the procs directly.
import repro_dsl_stdlib/packages/desktop_environments/sway as swayImpl
export swayImpl

package swayCompositor:
  ## NDE-H1 native sway compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the exported ``materializeSway``
  ## proc to obtain the emission outputs (the /etc/sway/config text;
  ## the /etc/ld.so.conf.d/00-reproos-linux.conf libpaths managed
  ## block contribution with priority=500; the sway-session.service
  ## unit at the cascade-G path /usr/lib/systemd/system/; the
  ## /etc/wayland-sessions/sway.desktop XDG session entry).
  ##
  ## Conceptual DSL declarations (surface not yet implemented;
  ## semantics encoded directly in the impl module's helpers):
  ##
  ##   files config:
  ##     build:
  ##       fs.configFile(
  ##         path = "/etc/sway/config",
  ##         content = iniContent:
  ##           # ... sway-config-shaped template ...
  ##       )
  ##
  ##   service sessionManager:
  ##     description = "Sway wlroots-tiling Wayland compositor session"
  ##     type        = oneshot
  ##     execStart   = "/usr/bin/sway"
  ##     wantedBy    = "graphical-session.target"

  defaultToolProvisioning "path"

  config:
    ## apt-jammy snapshot pin. Default ``ubuntu/jammy/20260615T000000Z``
    ## (matches NDE0-G's foundation pin). Part of every cache key so a
    ## snapshot bump invalidates the ld.so.conf.d block atomically.
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
    ## prerequisites (Mesa DRM userland + libwayland + libxkbcommon
    ## + fontconfig + fonts-dejavu-core). The libpaths block
    ## contribution NDE-H1 emits here unions with NDE0-G's at the
    ## NDEM1 multi-contributor merge step.
    "graphics-stack >=0.1.0"
