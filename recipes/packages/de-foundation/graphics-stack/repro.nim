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
## ## NDE-D: DSL-port migration to typed fs.* surface
##
## NDE-D (fourth NDE rewrite, after NDE-A/B/C) migrates this recipe from
## the previous "shim does everything, recipe is a config: shell" pattern
## to the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/...", content = ...)
##       fs.managedBlock(path = "/etc/...", scope = bsSystem, ...)
##       fs.symlink(path = "/etc/...", target = "...")
##
## NDE-D is the **anchor** for the multi-contributor managedBlock cohort:
## it registers ``/etc/ld.so.conf.d/00-reproos-linux.conf`` with the
## ``libpaths`` blockId at **priority=100** (lowest, sorts first); NDE-F
## sway / NDE-G gnome / NDE-K plasma will later append their own
## contributions to the same block at priority=500 and merge into a
## single live file at activation time.
##
## The three load-bearing identifiers for this cohort — the libpaths
## ``blockId``, the foundation ``priority``, and the kebab-cased package
## name segment — are sourced from the shim's exported constants
## (``Nde0gLibpathsBlockId`` / ``Nde0gLibpathsPriority`` /
## ``Nde0gPackageName``) so a future rename or priority bump propagates
## across the cohort in one place.
##
## ## Configurables
##
## Per the spec NDE0-G section. Each maps to a field on
## ``GraphicsStackConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` / ``managedBlockSha256Of`` hash propagates the
## change atomically through ``consumeConfigFile`` /
## ``consumeManagedBlock``; the unaffected artifacts stay cached).
##
##   * ``aptSnapshot`` — the apt-jammy pin for the 6 jammy bundles
##     (mesa + libdrm + libwayland + libxkbcommon + fontconfig +
##     dejavu-fonts). v1 of NDE0-G records this in every cache key but
##     does NOT extract .debs — the Tier-2 shell script
##     ``recipes/reproos-mvp-config/build-linux-graphics-stack.sh``
##     remains the runnable path; the native package handles the
##     ld.so.conf.d block + linker-cascade systemd unit declaratively.
##   * ``enableHardwareGl`` — ``true`` (default) advertises the Mesa
##     hardware-GL closure in the planted ld.so.conf.d block's banner;
##     ``false`` advertises software-rasterisation-only. v1's .deb set
##     is the same in both branches (see impl-module honest-deferrals);
##     the configurable's runtime effect is documentary today but the
##     cache-key propagates honestly.
##   * ``fontPackages`` — which font .deb names contribute to the
##     graphics-stack closure. Default = ``@["fonts-dejavu-core"]``.
##     ``seq[string]`` is not yet covered by the M2/M9.D
##     ``recordConfigDefault`` surface — the entry is declared in the
##     ``config:`` block for documentary purposes and forward
##     compatibility but the recipe's helper reads the impl module's
##     ``defaultGraphicsStackConfig().fontPackages`` default rather than
##     a configurable cell. When M3+ widens the runtime to cover
##     ``seq[string]``, the helper migrates to ``readConfigurable`` like
##     the scalar configurables above.
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
## * **fontPackages cell**: as documented above, NDE0-G v1 declares the
##   seq[string] config entry but the runtime can only store scalar
##   types today; toggling fontPackages via ``setConfigurable`` is not
##   supported yet. The library's render proc still consumes the
##   ``GraphicsStackConfig`` struct (constructed from defaults), so the
##   block content is correct on first emission. The cache key still
##   propagates honestly because the rendered bytes flow through
##   ``managedBlockSha256Of(mergedContent)``.
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-G emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# GraphicsStackConfig type + the cohort-anchor constants
# (Nde0gLibpathsPriority / Nde0gLibpathsBlockId / Nde0gPackageName).
# Imported under an alias so the recipe-side call sites stay readable
# (``gfxImpl.renderLdConfBlockContent()``). The shim's
# ``materializeGraphicsStack`` orchestrator + ``configFile`` /
# ``managedBlock`` / ``symlinkUnmask`` on-disk emitters are still
# available to legacy callers but the recipe no longer invokes them —
# all on-disk materialisation now flows through the DSL's M8 / M9.A /
# M9.B path.
import repro_dsl_stdlib/packages/de_foundation/graphics_stack as gfxImpl
export gfxImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const GraphicsStackPackageId* = "graphicsStack"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``gfxImpl.Nde0gPackageName`` (= "graphics-stack"); the kebab-cased
  ## form is the cohort-wide sentinel segment that NDE-F/G/K all share,
  ## while ``GraphicsStackPackageId`` is the DSL-side package identifier
  ## the M3 registry indexes by.

proc currentGraphicsStackCfg*(): gfxImpl.GraphicsStackConfig =
  ## Read every configurable cell into a ``GraphicsStackConfig`` record
  ## the shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## ``fontPackages`` is sourced from ``defaultGraphicsStackConfig()``
  ## rather than ``readConfigurable``: the M2/M9.D surface does not yet
  ## cover ``seq[string]`` and the ``config:`` block's entry is silently
  ## passed through at macro-expansion time. The cache-key propagates
  ## honestly because the rendered block bytes still flow through
  ## ``managedBlockSha256Of``.
  let defaults = gfxImpl.defaultGraphicsStackConfig()
  result = gfxImpl.GraphicsStackConfig(
    aptSnapshot: readConfigurable[string](
      "graphicsStack.aptSnapshot", defaults.aptSnapshot),
    enableHardwareGl: readConfigurable[bool](
      "graphicsStack.enableHardwareGl", defaults.enableHardwareGl),
    fontPackages: defaults.fontPackages,
    storeRoot: defaults.storeRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerGraphicsStackFiles()`` (below) directly with explicit
# packageName + artifactName so the call works outside a build:
# context.
# ---------------------------------------------------------------------------

proc registerLdConf*() =
  ## The libpaths managedBlock — THE anchor for the multi-contributor
  ## cohort. The blockId / priority / packageName triple is sourced
  ## from the shim's exported constants so the cohort-wide rename or
  ## priority bump propagates in one place. NDE-F sway / NDE-G gnome /
  ## NDE-K plasma will later append their own contributions to the same
  ## block at priority=500; the merger sorts ``(priority, packageName,
  ## blockId)`` ascending so NDE0-G (priority=100) sorts first.
  let cfg = currentGraphicsStackCfg()
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = gfxImpl.Nde0gLibpathsBlockId,
    scope = bsSystem,
    content = gfxImpl.renderLdConfBlockContent(cfg),
    priority = gfxImpl.Nde0gLibpathsPriority,
    packageName = gfxImpl.Nde0gPackageName,
    artifactName = "ldConf")

proc registerLdconfigService*() =
  ## ``repro-ldconfig.service`` Type=oneshot unit at the cascade-G fix
  ## path /usr/lib/systemd/system/ (NOT the legacy /lib/systemd/
  ## system/ which R9 systemd 257.9 dropped from the default UnitPath).
  fs.configFile(
    path = "/usr/lib/systemd/system/repro-ldconfig.service",
    content = gfxImpl.renderLdconfigUnit(),
    packageName = GraphicsStackPackageId,
    artifactName = "ldconfigService")

proc registerLdconfigServiceEtcAlias*() =
  ## Belt-and-braces cascade-G fix: a regular file record at
  ## /etc/systemd/system/repro-ldconfig.service so ``systemctl status``
  ## finds the unit even if a future overlay segment shadows /usr/lib.
  ## The content is identical to the /usr/lib/... record; the
  ## activation layer (NDEM1) materialises this as a symlink in the
  ## live tree.
  fs.configFile(
    path = "/etc/systemd/system/repro-ldconfig.service",
    content = gfxImpl.renderLdconfigUnit(),
    packageName = GraphicsStackPackageId,
    artifactName = "ldconfigServiceEtcAlias")

proc registerLdconfigWantedBy*() =
  ## WantedBy activation symlink:
  ## /etc/systemd/system/multi-user.target.wants/repro-ldconfig.service
  ## → /etc/systemd/system/repro-ldconfig.service so systemd activates
  ## the oneshot at boot. On POSIX hosts M9.B materialises a real
  ## OS-level symlink; on Windows fs.symlink falls back to a regular
  ## file with a ``# repro-symlink-intent`` header the apply layer
  ## translates.
  fs.symlink(
    path = "/etc/systemd/system/multi-user.target.wants/repro-ldconfig.service",
    target = "/etc/systemd/system/repro-ldconfig.service",
    packageName = GraphicsStackPackageId,
    artifactName = "ldconfigWantedBy")

proc registerGraphicsStackFiles*() =
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
  registerLdConf()
  registerLdconfigService()
  registerLdconfigServiceEtcAlias()
  registerLdconfigWantedBy()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package graphicsStack:
  ## NDE0-G native graphics-stack package.
  ##
  ## Downstream Tier-1 packages (NDE-F/G/K) ``uses:`` this and consume
  ## the recipe's fs.* artifacts through the DSL's ``consumeConfigFile``
  ## / ``consumeManagedBlock`` / ``consumeSymlink`` materialiser. The
  ## ``files <name>:`` arms below each register one emission so the
  ## per-artifact cache key isolates the downstream invalidation surface.
  ##
  ## NDE-D is the **anchor** for the multi-contributor managedBlock
  ## cohort: the ``ldConf`` arm registers
  ## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` with blockId
  ## ``libpaths`` at priority=100; the three priority-500 compositors
  ## (NDE-F sway, NDE-G gnome, NDE-K plasma) append their own
  ## contributions to the same block, and the merger sorts
  ## ``(priority, packageName, blockId)`` ascending so NDE0-G sorts
  ## first.

  defaultToolProvisioning "path"

  config:
    ## The apt-jammy snapshot pin for the (deferred) 6-bundle .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the libpaths
    ## block atomically — even when the .deb extraction is deferred,
    ## the fingerprint hygiene is preserved (the bundle stub hashes
    ## that appear in the planted block are a pure function of the
    ## snapshot pin).
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Selects which GL-mode banner lands in the emitted ld.so.conf.d
    ## block. ``true`` (default) advertises hardware-GL Mesa closure;
    ## ``false`` advertises software-rasterisation-only closure. v1
    ## plants the same .deb set in both branches (see impl-module
    ## honest-deferrals); the configurable's effect is mostly
    ## documentary today but the cache-key propagates honestly.
    enableHardwareGl: bool = true

    ## Font packages provisioned into the graphics-stack closure. Each
    ## entry contributes a comment line to the planted block. Default
    ## = ``@["fonts-dejavu-core"]`` matches the Tier-2 catalog tier.
    ## NB: M2/M9.D ``recordConfigDefault`` does not yet cover
    ## ``seq[string]`` — the entry is documentary; the helper reads the
    ## impl module's default. See module-preamble honest deferrals.
    fontPackages: seq[string] = @["fonts-dejavu-core"]

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) 6-bundle .deb input. v1 of NDE0-G records this
    ## dependency for fingerprint purposes but does not yet exercise
    ## ``installAptDeb()`` for the graphics-stack bundles (Tier-2's
    ## ``build-linux-graphics-stack.sh`` remains the runnable path).
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the user-session
    ## targets the runtime ldconfig oneshot may chain against + the
    ## ``BlockScope`` / ``ManagedFiles`` typed-output helpers
    ## re-exported via graphics_stack.nim. When NDE-F/G/K append their
    ## libpaths contributions, the cohort merge order
    ## ``(priority, packageName, blockId)`` puts NDE0-G first.
    "systemd-session >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files ldConf:
    ## /etc/ld.so.conf.d/00-reproos-linux.conf — THE anchor managedBlock
    ## for the multi-contributor cohort. blockId=libpaths, priority=100,
    ## packageName=graphics-stack (kebab-cased per the cohort sentinel
    ## contract).
    build:
      registerLdConf()

  files ldconfigService:
    ## /usr/lib/systemd/system/repro-ldconfig.service — Type=oneshot
    ## that runs /sbin/ldconfig before multi-user.target / sysinit.target.
    ## Cascade-G fix path: NOT /lib/systemd/system/ (R9 dropped that
    ## from the default UnitPath).
    build:
      registerLdconfigService()

  files ldconfigServiceEtcAlias:
    ## /etc/systemd/system/repro-ldconfig.service — belt-and-braces
    ## /etc record so ``systemctl status`` finds the unit even if a
    ## future overlay segment shadows /usr/lib.
    build:
      registerLdconfigServiceEtcAlias()

  files ldconfigWantedBy:
    ## /etc/systemd/system/multi-user.target.wants/repro-ldconfig.service
    ## → /etc/systemd/system/repro-ldconfig.service — WantedBy
    ## activation symlink so systemd activates the oneshot at boot.
    build:
      registerLdconfigWantedBy()
