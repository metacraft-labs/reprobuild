## NDEM1: native reproos-desktop system-level package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDEM1.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/system/
## reproos_desktop.nim`` (mirrors the layout established by NDE-H1 /
## NDE-G1 / NDE-K1 / NDE0-S / NDE0-D / NDE0-G / NDE0-K — note the
## ``system/`` subdirectory under ``packages/`` for system-scope
## packages).
##
## ## NDE-I: ninth NDE rewrite — full pure-DSL surface
##
## NDE-I (the ninth NDE rewrite, after NDE-A/B/C/D/E/F/G/H) is the most
## complex of the NDE package rewrites: it exercises *three* of the
## landed M9 gap-fixes — M9.E (``variant:`` + ``validate:``),
## M9.G (``bootloader:``), and M9.D (typed enum + ``seq[Enum]`` config
## entries) — together for the first time at the recipe level, plus
## the M9.A ``consumeManagedBlock`` consumer-side surface for the
## multi-contributor ``/etc/ld.so.conf.d/00-reproos-linux.conf`` union
## that the DE cohort populates.
##
## The spec literal from Configurable-System.md
## §"Variant Or Configurable: Choosing The Knob":
##
##   variant desktopKind:
##     case dkSway:   uses: "sway >=0.1.0"
##     case dkGnome:  uses: "gnome >=0.1.0"
##     case dkPlasma: uses: "plasma >=0.1.0"
##
##   config:
##     desktopKind: seq[DesktopKind] = @[dkSway]
##     activeAtBoot: DesktopKind = dkSway
##
##   validate:
##     activeAtBoot in desktopKind.value
##
##   bootloader:
##     generationEntry: true
##     timeout: 5
##     menuEntry:
##       title "ReproOS — generation default"
##       kernel "/boot/vmlinuz-default"
##       initrd "/boot/initrd.img-default"
##       cmdline "root=LABEL=ReproOS ro quiet"
##
## NDE-I lowers every one of those directives into the M9.E ``variant:``
## arm-dispatch / ``validate:`` closure registry / M9.G
## ``bootloader:`` config registry that landed in M9 close-out
## (commits ``eda5efd`` + ``926464e``). The ``\`case\``-backtick form is
## the v8-faithful spelling per the M9.E emitter contract.
##
## ## Configurables
##
## Per the spec NDEM1 ``config:`` section. Each maps to a field on
## ``ReproosDesktopConfig`` in the impl module. The two load-bearing
## entries are now expressed in their typed form (no
## ``seq[string]`` / ``string`` workaround as in the pre-NDE-I shape):
##
##   * ``desktopKind: seq[DesktopKind]`` (variant; closure-affecting)
##     — which DEs are *installable* in this generation. Default
##     ``@[dkSway]`` per the spec example. Adding a kind grows the
##     transitive closure (its ``uses:`` arm fires); removing one
##     shrinks it. The M9.E ``variant: arm-dispatch`` lowers each
##     ``\`case\` dkX:`` arm to a ``DslVariantArm`` row.
##
##   * ``activeAtBoot: DesktopKind`` (configurable; activation-only) —
##     which installable DE the generation boots into. Default ``dkSway``.
##     MUST be present in ``desktopKind`` (the M9.E ``validate:``
##     predicate at the package body enforces this at finalize time;
##     the impl module's ``validateDesktopConfig`` enforces the same
##     constraint at materialise time and raises the *shim's*
##     ``EConfigViolation`` from the same-named CatchableError type).
##
##   * ``defaultUser: string`` — default account name; matches NDE0-S's
##     ``defaultUser``.
##   * ``bootloaderTimeout: int`` — GRUB menu timeout in seconds.
##   * ``aptSnapshot: string`` — apt-jammy snapshot pin propagated to
##     every sub-package's sub-config.
##
## ## Honest deferrals
##
## * **Real /etc/ activation is OUT of scope.** The impl module emits
##   the ``mergedLdConf`` file + the ``displayManagerSymlink`` intent
##   + the generation manifest. The activation layer that plants the
##   live ``/etc/`` symlinks into the booted system + swaps the symlink
##   farm on rollback is deferred to NDEM2 (vm-harness gate) + a
##   follow-up activation runtime milestone.
##
## * **Bootloader integration is DEFERRED at the apply layer.** The
##   M9.G ``bootloader:`` block REGISTERS the generation-entry +
##   timeout + a single-menu-entry template here; the apply phase that
##   walks ``registeredBootloaderConfig("reproosDesktop").menuEntries``
##   and emits the live ``/boot/loader/entries/*.conf`` /
##   ``/boot/grub/grub.cfg`` snippet is NDEM2 work alongside the
##   vm-harness e2e test. The impl module's ``renderGrubMenuEntry`` /
##   ``emitGrubMenuEntries`` retain the legacy single-entry shape so
##   the v1 invariant suite keeps passing.
##
## * **Multi-generation persistence is DEFERRED.** v1 emits a SINGLE
##   generation manifest per ``materializeReproosDesktop`` call. The
##   generation-log persistence layer lives in NDEM2 (see
##   ``recipes/packages/system/generation-log/``).
##
## * **Closure garbage collection** (variant shrink → unused DE bundle
##   GC after grace period) is NDEM2 work.
##
## * **``\`case\` <enumValue>:`` per-arm bodies beyond ``uses:``** are
##   an explicit M9.E deferral. ``build:`` / ``service:`` / ``files:``
##   per-arm bodies CAN appear in the source but the M9.E emitter
##   silently skips them. NDE-I declares only ``uses:`` per arm — the
##   variant's closure-affecting contract is fully expressible this way.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the multi-contributor merge +
# variant composition + generation-manifest emission.
#
# Two-import discipline (this recipe's name overlaps with the module's
# spelling under Nim's case-and-underscore-insensitive identifier rule:
# ``reproosDesktop`` (package macro emitted const) normalises to the
# same form as the imported module ``reproos_desktop``):
#
#   * ``import ... as desktopImpl`` — the aliased form. Avoids the
#     module-name clash with the symbol the ``package reproosDesktop``
#     macro emits. The alias is used in the helper procs below where
#     the qualified spelling stays readable.
#
#   * ``from ... as reproosDesktopShim import DesktopKind, dk*`` — a
#     SECOND, restricted from-import that brings ONLY the enum type +
#     its three value spellings into the unqualified namespace WITHOUT
#     re-introducing the module-name qualifier (a plain ``from
#     reproos_desktop import ...`` would re-inject the unqualified
#     module symbol and clash with the package const; the
#     ``from ... as Alias import ...`` form does NOT). This is
#     load-bearing for the M2/M9.D ``recordConfigDefault`` emitter,
#     which does a verbatim-source string match on the type repr at
#     macro-expansion time (see ``m2IsBareIdentRepr`` in
#     ``macros_b.nim``); the qualified ``desktopImpl.DesktopKind``
#     spelling would be silently passed through and the
#     configurable-cell registration would be skipped. The bare
#     spelling is also the v8-faithful surface the spec literal calls
#     for (see Configurable-System.md §"Variant Or Configurable").
import repro_dsl_stdlib/packages/system/reproos_desktop as desktopImpl
export desktopImpl
from repro_dsl_stdlib/packages/system/reproos_desktop as
  reproosDesktopShim import DesktopKind, dkSway, dkGnome, dkPlasma

# ---------------------------------------------------------------------------
# Configurable accessor + per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# The recipe owns two files: artifacts (``mergedLdConf`` +
# ``displayManagerSymlink``); each helper records one fs.* declaration
# against the recipe's packageName + artifactName. The ``files:`` arms
# below call these so the M4 ``beginBuildContext`` push covers the
# artifact name. Tests that want to re-register after toggling a
# configurable call ``registerReproosDesktopFiles()`` (below) with the
# storeRoot bound, since the per-artifact helpers' explicit packageName
# arguments keep the registration well-formed outside a build: context.
# ---------------------------------------------------------------------------

const ReproosDesktopPackageId* = "reproosDesktop"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``NdemPackageName`` (= "reproos-desktop"); the kebab-cased
  ## form is the cohort-wide sentinel segment, while
  ## ``ReproosDesktopPackageId`` is the DSL-side package identifier the
  ## M3 registry indexes by.

proc currentActiveAtBoot*(): DesktopKind =
  ## Read the ``activeAtBoot`` configurable into the typed
  ## ``DesktopKind`` enum the impl module's helpers consume. Uses the
  ## M9.D fallback-flavour of ``readConfigurable`` so this proc is
  ## callable even before the package has registered its defaults
  ## (e.g. from a unit test that imported the recipe but is exercising
  ## the helper in isolation).
  result = readConfigurable[DesktopKind](
    "reproosDesktop.activeAtBoot", dkSway)

proc currentDesktopKind*(): seq[DesktopKind] =
  ## Read the ``desktopKind`` variant into the typed
  ## ``seq[DesktopKind]`` the impl module's helpers consume. M9.D
  ## fallback-flavoured ``readConfigurable[E: enum]`` (the seq overload)
  ## returns the fallback when the key is unknown — matches the
  ## ``activeAtBoot`` scalar path.
  result = readConfigurable[DesktopKind](
    "reproosDesktop.desktopKind", @[dkSway])

proc registerMergedLdConf*() =
  ## /etc/ld.so.conf.d/00-reproos-linux.conf — the multi-contributor
  ## managed-block UNION. This recipe is the CONSUMER side: the DE
  ## cohort (graphics-stack + each active DE) registers per-contributor
  ## ``fs.managedBlock`` rows via their own recipes. NDE-I reads the
  ## merged file via ``mergedManagedBlockFile(path)`` and plants the
  ## final concrete file via ``fs.configFile`` so the activation layer
  ## has a single byte-deterministic output to materialise.
  ##
  ## The cache-key for this output therefore propagates atomically
  ## whenever any contributor's content changes (the merged bytes flow
  ## through ``configFileSha256Of`` exactly once).
  let merged = mergedManagedBlockFile(
    "/etc/ld.so.conf.d/00-reproos-linux.conf")
  fs.configFile(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    content = merged,
    packageName = ReproosDesktopPackageId,
    artifactName = "mergedLdConf")

proc displayManagerTargetFor*(active: DesktopKind): string =
  ## Pure helper: which systemd unit handles login for the active DE.
  ## Mirrors ``activateDisplayManager(cfg).target`` from the impl module
  ## but consumes the configurable directly so the recipe avoids
  ## constructing a synthetic ``ReproosDesktopConfig`` just to read one
  ## field. Test fixtures use this for parity assertions against the
  ## impl module's ``activateDisplayManager``.
  case active
  of dkSway:   "/usr/lib/systemd/system/sway-session.service"
  of dkGnome:  "/usr/lib/systemd/system/gdm.service"
  of dkPlasma: "/usr/lib/systemd/system/sddm.service"

proc registerDisplayManagerSymlink*() =
  ## /etc/systemd/system/display-manager.service → (per ``activeAtBoot``)
  ## the DE-specific session unit at /usr/lib/systemd/system/. The
  ## activation symlink itself is a `fs.symlink` row; M9.B materialises
  ## a live OS-level symlink on POSIX (or a planted intent file on
  ## Windows). The target is derived from the ``activeAtBoot``
  ## configurable so swapping ``activeAtBoot`` re-keys only this output
  ## (the closure-invariant guarantee of the M9.E ``configurable``
  ## category).
  let active = currentActiveAtBoot()
  let target = displayManagerTargetFor(active)
  fs.symlink(
    path = "/etc/systemd/system/display-manager.service",
    target = target,
    packageName = ReproosDesktopPackageId,
    artifactName = "displayManagerSymlink")

proc registerReproosDesktopFiles*() =
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
  registerMergedLdConf()
  registerDisplayManagerSymlink()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package reproosDesktop:
  ## NDEM1 native reproos-desktop system-level package.
  ##
  ## Downstream Tier-1 system tooling (NDEM2 vm-harness gate;
  ## reproos-rebuild CLI) ``uses:`` this and consume the recipe's
  ## fs.* artifacts plus the exported ``materializeReproosDesktop``
  ## proc to obtain the emission outputs (the multi-contributor merged
  ## ``/etc/ld.so.conf.d/00-reproos-linux.conf``; the
  ## ``/etc/systemd/system/display-manager.service`` symlink intent;
  ## the GRUB menu entry; the GenerationManifest recording every
  ## contributor's storePaths).
  ##
  ## **NDE-I**: M9.E + M9.G + M9.D + M9.A pure-DSL surface. The
  ## ``variant:`` + ``validate:`` + ``bootloader:`` directives lower
  ## into the corresponding M9 registries; the ``files:`` artifacts
  ## consume the multi-contributor managed block + emit the activation
  ## symlink.

  defaultToolProvisioning "path"

  config:
    ## Variant (closure-affecting): which DEs are installable. Typed
    ## ``seq[DesktopKind]`` via the M9.D ``seq[Enum]`` overload.
    ## Default ``@[dkSway]`` per the spec example. Adding kinds grows
    ## the closure; the M9.E ``variant:`` arms (below) carry the
    ## per-kind ``uses:`` propagation.
    ##
    ## NB: the type repr MUST be the **bare** ``seq[DesktopKind]``
    ## spelling (NOT ``seq[desktopImpl.DesktopKind]``) so the M2/M9.D
    ## emitter's ``m2IsBareIdentRepr`` filter recognises it as a
    ## seq[Enum] — qualified type reprs are silently passed through
    ## (the legacy ``seq[string]`` workaround relied on this).
    desktopKind: seq[DesktopKind] = @[dkSway]

    ## Configurable (activation-only): which installable DE the
    ## generation boots into. Typed ``DesktopKind`` via the M9.D
    ## scalar-enum overload. Default ``dkSway`` per the spec example.
    ## MUST be present in ``desktopKind`` — enforced both by the M9.E
    ## ``validate:`` predicate (recipe-side, finalize-time) and by the
    ## impl module's ``validateDesktopConfig`` (build-time; raises the
    ## shim's ``EConfigViolation``).
    activeAtBoot: DesktopKind = dkSway

    ## Configurable: default account name. Matches NDE0-S
    ## ``defaultUser``. Propagated to the systemd-session +
    ## gnome auto-login + plasma sddm auto-login sub-configs.
    defaultUser: string = "repro"

    ## Configurable: GRUB menu timeout in seconds. Recorded in every
    ## generation's GRUB menu entry. Mirrored by the M9.G
    ## ``bootloader: timeout`` setter below so the apply phase can read
    ## either the configurable cell or the bootloader-registry row.
    bootloaderTimeout: int = 5

    ## Configurable: apt-jammy snapshot pin. Default
    ## ``ubuntu/jammy/20260615T000000Z`` (matches every NDE0 / NDE-H/G/K
    ## package's pin). Propagated to every sub-package's sub-config so
    ## a snapshot bump invalidates the right thing transitively.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) compositor + foundation .deb input. v1 of NDEM1
    ## records this dependency for fingerprint purposes via every
    ## sub-package's snapshot pin.
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
    ## ``DefaultStoreRoot`` helpers + the PAM stacks + the user-
    ## session targets every DE hooks against.
    "systemd-session >=0.1.0"

    ## NDE0-D native dbus-broker — supplies the system bus runtime.
    ## Every DE uses D-Bus for portals + session management.
    "dbus-broker >=0.1.0"

    ## NDE0-G native graphics-stack — supplies the Mesa + libdrm +
    ## libwayland + libxkbcommon + fontconfig prerequisites every
    ## compositor needs. The graphics-stack libpaths block
    ## contribution is the priority-100 anchor of the multi-
    ## contributor merge that NDE-I consumes via
    ## ``mergedManagedBlockFile`` in the ``mergedLdConf`` arm below.
    "graphics-stack >=0.1.0"

    ## NDE0-K native kernel — supplies the bzImage + KERNELRELEASE
    ## the generation's GRUB menu entry references. The kernel package
    ## publishes its dependency name as ``"reproos-kernel"`` (per
    ## ``kernelImpl.Nde0kPackageName``); ``uses:`` strings are
    ## byte-matched against the published name so the kebab-prefixed
    ## form is load-bearing.
    "reproos-kernel >=0.1.0"

  # -------------------------------------------------------------------------
  # M9.E variant: arm-dispatch — each ``\`case\` dkX:`` lowers to a
  # ``DslVariantArm`` row carrying the per-kind ``uses:`` propagation.
  # The ``\`case\``-backtick spelling is the v8-faithful form the M9.E
  # emitter recognises (per `t_dsl_variant_uses.nim`); ``of`` would
  # require a case-statement context Nim's parser doesn't permit inside
  # a ``package`` body.
  # -------------------------------------------------------------------------

  variant desktopKind:
    `case` dkSway:
      uses "sway >=0.1.0"
    `case` dkGnome:
      uses "gnome >=0.1.0"
    `case` dkPlasma:
      uses "plasma >=0.1.0"

  # -------------------------------------------------------------------------
  # M9.E validate: predicate — closure-form lambda enforcing the spec's
  # ``activeAtBoot in desktopKind.value`` cross-config constraint. The
  # M9.E emitter splices the lambda verbatim into a
  # ``registerValidateExpr`` call; ``evaluateValidates`` calls it and
  # raises the DSL-runtime's ``EConfigViolation`` on ``false``.
  #
  # The ``readConfigurable[DesktopKind](key, fallback)`` overload is the
  # M9.D fallback-flavour: gracefully degrades when the key is unknown
  # so the predicate can be evaluated before defaults have been
  # registered (e.g. from a test fixture that imports the recipe but
  # has just called ``resetConfigurable``).
  # -------------------------------------------------------------------------

  validate:
    proc(): bool =
      readConfigurable[DesktopKind](
        "reproosDesktop.activeAtBoot", dkSway) in
        readConfigurable[DesktopKind](
          "reproosDesktop.desktopKind", newSeq[DesktopKind]())

  # -------------------------------------------------------------------------
  # M9.G bootloader: block — per-package GRUB metadata. Lowers to one
  # ``registerBootloaderConfig`` call (generationEntry + timeout) + one
  # ``registerBootloaderMenuEntry`` call per ``menuEntry:`` body. The
  # apply-phase consumer (NDEM2) walks ``registeredBootloaderConfig
  # ("reproosDesktop").menuEntries`` to render the live
  # ``/boot/loader/entries/*.conf`` (systemd-boot shape) or the
  # ``/boot/grub/grub.cfg`` snippet (GRUB shape).
  # -------------------------------------------------------------------------

  bootloader:
    generationEntry: true
    timeout: 5
    menuEntry:
      title "ReproOS — generation default"
      kernel "/boot/vmlinuz-default"
      initrd "/boot/initrd.img-default"
      cmdline "root=LABEL=ReproOS ro quiet"

  # -------------------------------------------------------------------------
  # files: artifacts — the system-composition outputs NDEM1 plants for
  # the activation layer. Two artifacts:
  #
  #   * mergedLdConf — the multi-contributor union of
  #     /etc/ld.so.conf.d/00-reproos-linux.conf the DE cohort
  #     contributes to. NDE-I is the CONSUMER side: it reads the merged
  #     bytes via ``mergedManagedBlockFile(path)`` and plants the final
  #     concrete file. The merger sorts ``(priority, packageName,
  #     blockId)`` ascending so graphics-stack (priority=100) sorts
  #     before the three priority=500 compositors.
  #
  #   * displayManagerSymlink — the activation symlink at
  #     /etc/systemd/system/display-manager.service whose target is
  #     derived from the ``activeAtBoot`` configurable. Swapping
  #     ``activeAtBoot`` re-keys ONLY this output (closure-invariant
  #     contract of the M9.E ``configurable`` category).
  # -------------------------------------------------------------------------

  files mergedLdConf:
    ## /etc/ld.so.conf.d/00-reproos-linux.conf — multi-contributor
    ## managed-block union. Consumer-side: reads
    ## ``mergedManagedBlockFile(path)`` and emits a concrete configFile
    ## so the activation layer has a single byte-deterministic target.
    build:
      registerMergedLdConf()

  files displayManagerSymlink:
    ## /etc/systemd/system/display-manager.service → (per
    ## ``activeAtBoot``) the DE-specific session unit at
    ## /usr/lib/systemd/system/. M9.B materialises an OS-level symlink
    ## on POSIX or a planted-intent file on Windows.
    build:
      registerDisplayManagerSymlink()
