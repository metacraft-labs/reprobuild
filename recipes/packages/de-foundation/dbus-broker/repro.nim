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
## ## Why this layout
##
## The spec calls for a typed-DSL surface including a ``service
## systemBus:`` block declaring the system-bus daemon + ``Wants=
## dbus.socket``. The current ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads — ``service`` and ``files`` are pure spec
## at this point (NDE0-A + NDE0-S both documented the same limitation).
## The runtime semantics of the ``service systemBus:`` block live in
## the planted .service unit file (``dbus.service``) emitted by the
## impl module + symlinked into the live /etc/ tree by the
## activation step (an NDEM milestone).
##
## ## Configurables
##
## Per the spec NDE0-D section. Each maps to a field on
## ``DbusBrokerConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it (the impl module's
## per-output ``configFile`` / ``managedBlock`` hashes propagate the
## change atomically; the unaffected outputs stay cached).
##
##   * ``aptSnapshot`` — the apt-jammy pin for the dbus-broker /
##     dbus-user-session .deb input. v1 of NDE0-D records this in the
##     package fingerprint but does NOT extract .debs — dbus-broker_*.deb
##     is not vendored under
##     ``recipes/reproos-mvp-config/vendored-archives/linux/``. The
##     emitted unit-file content is hardcoded to match upstream shape.
##   * ``busActivationStrategy`` — ``"broker"`` (default) picks the
##     dbus-broker-launch ExecStart=; ``"daemon"`` picks the
##     dbus-daemon ExecStart= (fallback for hosts without dbus-broker
##     installed).
##   * ``messagebusUid`` / ``messagebusGid`` — propagate to the
##     /etc/passwd + /etc/group managed blocks. 101 is the Debian/Ubuntu
##     convention for the messagebus account.
##
## ## Honest deferrals
##
## * **dbus-broker / dbus-user-session .deb extraction**: NDE0-D v1
##   emits hardcoded unit-file content (dbus.socket + dbus.service)
##   matching upstream dbus-broker .service shape. The actual broker
##   binaries (/usr/bin/dbus-broker-launch + the .so libraries) are NOT
##   extracted because no dbus-broker_*.deb is vendored — only consumer
##   libs (libdbusmenu, libkf5dbusaddons, libqt5dbus5) ship under
##   ``recipes/reproos-mvp-config/vendored-archives/linux/``. The
##   Tier-2 shell script ``recipes/reproos-mvp-config/de0-dbus.sh``
##   remains the path to a runnable broker today; the native package
##   handles unit-file + system-user + spool-dir intent declaratively.
##
## * **``service systemBus:`` block**: pure DSL spec at this point. The
##   semantics it would declare (``Wants=dbus.socket``,
##   ``Requires=dbus.socket``) are encoded directly in the emitted
##   .service unit file's ``[Unit]`` section so the runtime behaviour
##   matches the spec even though the typed-DSL surface doesn't exist
##   yet.
##
## * **Multi-contributor /etc/passwd merge**: NDE0-S emits a ``repro``
##   user managed block; NDE0-D emits a ``messagebus`` user managed
##   block. Both target ``/etc/passwd`` with the same NDE-spec-block
##   triple-form sentinel (different blockIds). v1 emits each block to
##   a content-addressed store path independently; the activation
##   layer that unions them into a single live /etc/passwd file is the
##   NDE-spec-block multi-contributor merge — landed in specs 923557d
##   2026-06-17 + scheduled for NDEM1 runtime implementation. v1's
##   sentinel shape is forward-compatible: the merge step consuming
##   both blocks sees spec-shape-compatible contributions.
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-D emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# unit-file text. Imported here so it is in scope for downstream
# packages that ``uses: "dbus-broker >=0.1.0"`` and inline a ``build:``
# block invoking the procs directly.
import repro_dsl_stdlib/packages/de_foundation/dbus_broker as brokerImpl
export brokerImpl

package dbusBroker:
  ## NDE0-D native dbus-broker package.
  ##
  ## Downstream Tier-1 packages (NDE-H/G/K) ``uses:`` this and consume
  ## the exported ``materializeDbusBroker`` proc to obtain the emission
  ## outputs (dbus.socket + dbus.service unit files at the cascade-G
  ## fix path, messagebus system user managed blocks, /var/lib/dbus
  ## spool placeholder, /etc/dbus-1/system.conf default policy).
  ##
  ## Conceptual service declaration (DSL surface not yet implemented;
  ## semantics encoded directly in the planted dbus.service .service
  ## unit's [Unit] + [Install] sections):
  ##
  ##   service systemBus:
  ##     description = "D-Bus System Message Bus"
  ##     wants = "dbus.socket"
  ##     wantedBy = "multi-user.target"

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) dbus-broker .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the whole
    ## package's emissions atomically — even when the .deb extraction
    ## is deferred, the fingerprint hygiene is preserved.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Selects which daemon ExecStart= line lands in the emitted
    ## ``dbus.service`` unit. ``"broker"`` (default) uses
    ## ``/usr/bin/dbus-broker-launch``; ``"daemon"`` uses
    ## ``/usr/bin/dbus-daemon`` (fallback for hosts without
    ## dbus-broker installed). The socket unit + system-user blocks +
    ## default policy are strategy-agnostic.
    busActivationStrategy: string = "broker"

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
    ## not yet exercise ``installAptDeb()`` for dbus-broker/dbus-user-
    ## session (those .debs are not vendored).
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``symlinkUnmask`` helpers
    ## (re-exported via dbus_broker.nim's import chain). When the spec'd
    ## ``fs.configFile`` / ``fs.managedBlock`` surface lands as a
    ## standalone module, NDE0-D + NDE0-S both migrate to that
    ## together.
    "systemd-session >=0.1.0"
