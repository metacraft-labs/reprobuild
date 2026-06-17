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
## ## Why this layout
##
## The spec worked example uses two DSL block forms not yet recognised
## by ``parsePackageDef`` at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``:
##
##   files sddmConfig:
##     build:
##       fs.configFile(
##         path = "/etc/sddm.conf",
##         content = iniContent:
##           Autologin:
##             Relogin = "false"
##             Session = "plasma"
##             User    = config.sddmAutoLoginUser
##           General:
##             DisplayServer = "wayland"
##       )
##
##   service displayManager:
##     description = "Simple Desktop Display Manager"
##     type        = simple
##     execStart   = "/usr/bin/sddm"
##     wantedBy    = "graphical.target"
##
## ``parsePackageDef`` currently recognises only ``executable`` /
## ``library`` / ``uses`` / ``config`` / ``outputs`` section heads —
## ``files <name>:`` block form + ``service <name>:`` block form are
## pure DSL spec at this point. NDE0-A + NDE0-S + NDE0-D + NDE0-G +
## NDE0-K + NDE-H1 + NDE-G1 all documented the same limitation. The
## runtime semantics of these blocks live in the planted
## ``/etc/sddm.conf`` + ``sddm.service`` +
## ``/etc/wayland-sessions/plasma.desktop`` + ``/etc/pipewire/pipewire.conf``
## files emitted by the impl module's ``materializePlasma`` proc.
##
## ## Configurables
##
## Per the spec NDE-K1 section. Each maps to a field on ``PlasmaConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the impl module's per-output hash
## derivation propagates the change atomically; the unaffected outputs
## stay cached). See the impl module's ``PlasmaOutputs`` docstring for
## the full invalidation matrix.
##
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
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred)
##     sddm / kwin / plasma-workspace / plasma-desktop / kf5-frameworks
##     / qt5-base .deb consumption. Part of every cache key.
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
## * **``files sddmConfig:`` + ``service displayManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from the impl module.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# /etc/sddm.conf / unit-file / desktop-entry / pipewire.conf text.
# Imported here so it is in scope for downstream packages that
# ``uses: "plasma >=0.1.0"`` and inline a ``build:`` block invoking
# the procs directly.
import repro_dsl_stdlib/packages/desktop_environments/plasma as plasmaImpl
export plasmaImpl

package plasmaDesktop:
  ## NDE-K1 native KDE Plasma compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the exported ``materializePlasma``
  ## proc to obtain the emission outputs (the /etc/sddm.conf INI
  ## text; the /etc/ld.so.conf.d/00-reproos-linux.conf libpaths
  ## managed block contribution with priority=500; the sddm.service
  ## unit at the cascade-G path /usr/lib/systemd/system/; the
  ## /etc/wayland-sessions/plasma.desktop XDG session entry; the
  ## /etc/pipewire/pipewire.conf daemon config).
  ##
  ## Conceptual DSL declarations (surface not yet implemented;
  ## semantics encoded directly in the impl module's helpers):
  ##
  ##   files sddmConfig:
  ##     build:
  ##       fs.configFile(
  ##         path = "/etc/sddm.conf",
  ##         content = iniContent:
  ##           Autologin:
  ##             Relogin = "false"
  ##             Session = "plasma"
  ##             User    = config.sddmAutoLoginUser
  ##           General:
  ##             DisplayServer = "wayland"
  ##       )
  ##
  ##   service displayManager:
  ##     description = "Simple Desktop Display Manager"
  ##     type        = simple
  ##     execStart   = "/usr/bin/sddm"
  ##     wantedBy    = "graphical.target"

  defaultToolProvisioning "path"

  config:
    ## apt-jammy snapshot pin. Default ``ubuntu/jammy/20260615T000000Z``
    ## (matches NDE0-G's + NDE-H1's + NDE-G1's foundation pin). Part
    ## of every cache key so a snapshot bump invalidates the
    ## ld.so.conf.d block atomically.
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
    ## unions with NDE0-G's at the NDEM1 multi-contributor merge step.
    "graphics-stack >=0.1.0"
