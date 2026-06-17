## NDE0-G: native graphics-stack package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-G.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## graphics_stack.nim`` (precedent: NDE0-D's identical layout, plus
## NDE0-A's apt-jammy package + ``apt_jammy.nim`` shim, plus NDE0-S's
## identical pattern).
##
## ## Why this layout
##
## The spec calls for a typed-DSL surface including ``files ldConf:``
## (an ``fs.managedBlock()`` contribution) and ``service ldconfigRefresh:``
## (a Type=oneshot unit). The current ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads — ``service`` and ``files`` are pure spec
## at this point (NDE0-A + NDE0-S + NDE0-D all documented the same
## limitation). The runtime semantics of the ``service ldconfigRefresh:``
## block live in the planted ``repro-ldconfig.service`` unit file emitted
## by the impl module + symlinked into the live /etc/ tree by the
## activation step (an NDEM milestone).
##
## ## Configurables
##
## Per the spec NDE0-G section. Each maps to a field on
## ``GraphicsStackConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it (the impl module's
## per-output ``configFile`` / ``managedBlock`` hashes propagate the
## change atomically; the unaffected outputs stay cached).
##
##   * ``aptSnapshot`` — the apt-jammy pin for the 6 jammy bundles
##     (mesa + libdrm + libwayland + libxkbcommon + fontconfig +
##     dejavu-fonts). v1 of NDE0-G records this in the package
##     fingerprint but does NOT extract .debs — the Tier-2 shell script
##     ``recipes/reproos-mvp-config/build-linux-graphics-stack.sh``
##     remains the path to a runnable graphics stack today; the native
##     package handles the ld.so.conf.d block + linker-cascade systemd
##     unit declaratively.
##   * ``enableHardwareGl`` — ``true`` (default) advertises the Mesa
##     hardware-GL closure in the planted ld.so.conf.d block's banner;
##     ``false`` advertises the software-rasterisation-only closure.
##     v1's .deb set is the same in both branches (see impl-module
##     honest-deferrals); the configurable's effect is mostly
##     documentary today.
##   * ``fontPackages`` — which font .deb names contribute to the
##     graphics-stack closure. Default = ``@["fonts-dejavu-core"]``.
##     Each entry adds a comment line to the planted block (which
##     invalidates the block's content-addressed store path).
##
## ## Honest deferrals
##
## * **6-package .deb extraction**: NDE0-G v1 emits a declarative
##   ld.so.conf.d block + the runtime linker-cascade unit but does NOT
##   extract the 6 jammy .debs into per-package content-addressed store
##   paths. That extraction work is what the Tier-2 shell script does
##   (``build-linux-graphics-stack.sh``); the NDE0-G migration shape is
##   "declarative front end + tier-2 backend until the per-package
##   extraction lands". When the apt-jammy extraction wires through, a
##   follow-up milestone migrates the unit-file emission to consume
##   ``installAptDeb(snapshot, debs=...)`` directly.
##
## * **Build-time ldconfig integration**: the spec's "the build engine
##   runs ``ldconfig -r`` across the union of all DE-foundation store
##   contributions to produce ``/etc/ld.so.cache`` in the active
##   generation" needs a build-time host-side ldconfig wrapper. For v1,
##   the runtime ``repro-ldconfig.service`` Type=oneshot is sufficient:
##   first boot's oneshot reads the planted
##   ``/etc/ld.so.conf.d/00-reproos-linux.conf`` and populates
##   ``/etc/ld.so.cache`` accordingly. Build-time integration lands as
##   a follow-up NDEM milestone alongside the per-generation apply step.
##
## * **``files ldConf:`` + ``service ldconfigRefresh:`` DSL blocks**:
##   pure DSL spec at this point. The semantics they would declare
##   (managedBlock priority=100 + Type=oneshot Before=multi-user.target)
##   are encoded directly in the planted block sentinels + emitted
##   .service unit file's [Unit]/[Service]/[Install] sections so the
##   runtime behaviour matches the spec even though the typed-DSL
##   surface doesn't exist yet.
##
## * **Multi-contributor /etc/ld.so.conf.d/ merge**: NDE-H/G/K each add
##   their own contribution to the libpaths block (per the spec's
##   worked example in Generated-Configuration-Files.md). v1 emits
##   NDE0-G's contribution to a content-addressed store path
##   independently; the activation layer that unions co-contributors
##   into a single live /etc/ld.so.conf.d/00-reproos-linux.conf is the
##   NDE-spec-block multi-contributor merge — landed in specs 923557d
##   2026-06-17 + scheduled for NDEM1 runtime implementation. v1's
##   sentinel shape is forward-compatible (priority=100 + spec'd
##   triple-form sentinel).
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-G emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# block / unit-file text. Imported here so it is in scope for downstream
# packages that ``uses: "graphics-stack >=0.1.0"`` and inline a ``build:``
# block invoking the procs directly.
import repro_dsl_stdlib/packages/de_foundation/graphics_stack as gfxImpl
export gfxImpl

package graphicsStack:
  ## NDE0-G native graphics-stack package.
  ##
  ## Downstream Tier-1 packages (NDE-H/G/K) ``uses:`` this and consume
  ## the exported ``materializeGraphicsStack`` proc to obtain the
  ## emission outputs (the libpaths managed block at
  ## /etc/ld.so.conf.d/00-reproos-linux.conf with priority=100; the
  ## ``repro-ldconfig.service`` Type=oneshot unit at the cascade-G
  ## /usr/lib/systemd/system/ path; the belt-and-braces /etc record;
  ## the multi-user.target.wants activation symlink record).
  ##
  ## Conceptual DSL declarations (surface not yet implemented; semantics
  ## encoded directly in the planted block + .service unit):
  ##
  ##   files ldConf:
  ##     path     = "/etc/ld.so.conf.d/00-reproos-linux.conf"
  ##     scope    = bsSystem
  ##     blockId  = "libpaths"
  ##     priority = 100
  ##     content  = (planted store paths' lib dirs)
  ##
  ##   service ldconfigRefresh:
  ##     description = "ReproOS ldconfig refresh (linker cascade fix)"
  ##     type        = oneshot
  ##     before      = "multi-user.target sysinit.target"
  ##     execStart   = "/sbin/ldconfig"
  ##     wantedBy    = "multi-user.target"

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) 6-bundle .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the whole
    ## package's emissions atomically — even when the .deb extraction
    ## is deferred, the fingerprint hygiene is preserved (the bundle
    ## stub hashes that appear in the planted ld.so.conf.d block are
    ## a pure function of the snapshot pin).
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Selects which GL mode banner lands in the emitted ld.so.conf.d
    ## block. ``true`` (default) advertises hardware-GL Mesa closure;
    ## ``false`` advertises software-rasterisation-only closure. v1
    ## plants the same .deb set in both branches (see impl-module
    ## honest-deferrals); the configurable's effect is mostly
    ## documentary today but the cache-key propagates honestly.
    enableHardwareGl: bool = true

    ## Font packages provisioned into the graphics-stack closure. Each
    ## entry contributes a comment line to the planted block. Default
    ## = ``@["fonts-dejavu-core"]`` matches the Tier-2 catalog tier.
    fontPackages: seq[string] = @["fonts-dejavu-core"]

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) 6-bundle .deb input. v1 of NDE0-G records this
    ## dependency for fingerprint purposes but does not yet exercise
    ## ``installAptDeb()`` for the graphics-stack bundles (Tier-2's
    ## ``build-linux-graphics-stack.sh`` remains the runnable path).
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``symlinkUnmask`` helpers
    ## (re-exported via graphics_stack.nim's import chain). When the
    ## spec'd ``fs.configFile`` / ``fs.managedBlock`` surface lands as
    ## a standalone module, NDE0-G + NDE0-S + NDE0-D all migrate to
    ## that together.
    "systemd-session >=0.1.0"
