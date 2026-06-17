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
## ## Why this layout
##
## The spec worked example uses two DSL block forms not yet recognised
## by ``parsePackageDef`` at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``:
##
##   files gdmConfig:
##     build:
##       fs.configFile(
##         path = "/etc/gdm3/custom.conf",
##         content = iniContent:
##           daemon:
##             WaylandEnable = "true"
##             AutomaticLoginEnable = $config.autoLogin
##             AutomaticLogin = config.autoLoginUser
##           chooser:
##             Multicast = "false"
##       )
##
##   service displayManager:
##     description = "GNOME Display Manager"
##     type        = notify
##     execStart   = "/usr/sbin/gdm3"
##     wantedBy    = "graphical.target"
##
## ``parsePackageDef`` currently recognises only ``executable`` /
## ``library`` / ``uses`` / ``config`` / ``outputs`` section heads —
## ``files <name>:`` block form + ``service <name>:`` block form are
## pure DSL spec at this point. NDE0-A + NDE0-S + NDE0-D + NDE0-G +
## NDE0-K + NDE-H1 all documented the same limitation. The runtime
## semantics of these blocks live in the planted ``/etc/gdm3/custom.conf``
## + ``gdm.service`` + ``/etc/wayland-sessions/gnome.desktop`` files
## emitted by the impl module's ``materializeGnome`` proc.
##
## ## Configurables
##
## Per the spec NDE-G1 section. Each maps to a field on ``GnomeConfig``
## in the impl module. Toggling any of them invalidates only the
## outputs that consume it (the impl module's per-output hash
## derivation propagates the change atomically; the unaffected outputs
## stay cached). See the impl module's ``GnomeOutputs`` docstring for
## the full invalidation matrix.
##
##   * ``autoLogin`` — bind into ``AutomaticLoginEnable=true|false`` of
##     /etc/gdm3/custom.conf. Default ``true`` per spec. The acceptance
##     toggles this to ``false`` to demonstrate cache-key propagation.
##   * ``autoLoginUser`` — bind into ``AutomaticLogin=<user>`` of
##     /etc/gdm3/custom.conf. Default ``"repro"`` (matches NDE0-S's
##     ``defaultUser``).
##   * ``waylandSession`` — bind into ``WaylandEnable=true|false`` of
##     /etc/gdm3/custom.conf. Default ``true`` per spec.
##   * ``disableInitialSetup`` — suppress gnome-initial-setup on first
##     boot. Default ``true`` (the MVP runs on a serial console + an
##     autologin user; the welcome wizard would block boot).
##   * ``aptSnapshot`` — apt-jammy snapshot pin for the (deferred)
##     gnome-shell / mutter / gdm3 .deb consumption. Part of every
##     cache key.
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
## * **``files gdmConfig:`` + ``service displayManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from the impl module.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# /etc/gdm3/custom.conf / unit-file / desktop-entry text. Imported here
# so it is in scope for downstream packages that ``uses: "gnome >=0.1.0"``
# and inline a ``build:`` block invoking the procs directly.
import repro_dsl_stdlib/packages/desktop_environments/gnome as gnomeImpl
export gnomeImpl

package gnomeDesktop:
  ## NDE-G1 native GNOME compositor package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the exported ``materializeGnome``
  ## proc to obtain the emission outputs (the /etc/gdm3/custom.conf
  ## INI text; the /etc/ld.so.conf.d/00-reproos-linux.conf libpaths
  ## managed block contribution with priority=500; the gdm.service
  ## unit at the cascade-G path /usr/lib/systemd/system/; the
  ## /etc/wayland-sessions/gnome.desktop XDG session entry).
  ##
  ## Conceptual DSL declarations (surface not yet implemented;
  ## semantics encoded directly in the impl module's helpers):
  ##
  ##   files gdmConfig:
  ##     build:
  ##       fs.configFile(
  ##         path = "/etc/gdm3/custom.conf",
  ##         content = iniContent:
  ##           daemon:
  ##             WaylandEnable = "true"
  ##             AutomaticLoginEnable = $config.autoLogin
  ##             AutomaticLogin = config.autoLoginUser
  ##           chooser:
  ##             Multicast = "false"
  ##       )
  ##
  ##   service displayManager:
  ##     description = "GNOME Display Manager"
  ##     type        = notify
  ##     execStart   = "/usr/sbin/gdm3"
  ##     wantedBy    = "graphical.target"

  defaultToolProvisioning "path"

  config:
    ## apt-jammy snapshot pin. Default ``ubuntu/jammy/20260615T000000Z``
    ## (matches NDE0-G's + NDE-H1's foundation pin). Part of every
    ## cache key so a snapshot bump invalidates the ld.so.conf.d
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
    ## unions with NDE0-G's at the NDEM1 multi-contributor merge step.
    "graphics-stack >=0.1.0"
