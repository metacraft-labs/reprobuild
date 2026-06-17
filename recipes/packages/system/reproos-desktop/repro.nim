## NDEM1: native reproos-desktop system-level package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDEM1.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/system/
## reproos_desktop.nim`` (mirrors the layout established by NDE-H1 /
## NDE-G1 / NDE-K1 / NDE0-S / NDE0-D / NDE0-G / NDE0-K — note the new
## ``system/`` subdirectory under ``packages/`` for system-scope
## packages).
##
## ## Why this layout
##
## The spec worked example
## (``Configurable-System.md`` §"Variant Or Configurable: Choosing
## The Knob") uses several DSL block forms not yet recognised by
## ``parsePackageDef`` at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``:
##
##   * ``variant <name>: case "<value>": uses: ...`` — multi-arm
##     variant with per-arm closure-affecting ``uses:``.
##   * ``validate: <bool-expression>`` — cross-config constraint
##     enforced at finalize time (raises ``EConfigViolation``).
##   * ``files <name>: build: fs.symlink(...)`` — typed files output
##     from the activation layer.
##   * ``bootloader: generationEntry: true`` — declarative bootloader
##     integration.
##   * The spec's ``DesktopKind`` enum + the typed ``seq[DesktopKind]``
##     variant signature.
##
## ``parsePackageDef`` currently recognises only ``executable`` /
## ``library`` / ``uses`` / ``config`` / ``outputs`` section heads —
## EVERY prior NDE package documented the same limitation. The runtime
## semantics live in the impl module's procs (``validateDesktopConfig``,
## ``materializeReproosDesktop``, ``mergeLdConfBlocks``,
## ``activateDisplayManager``, ``generationId``) + the planted
## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` union + the
## display-manager symlink intent + the GRUB menu entry that
## ``materializeReproosDesktop`` emits.
##
## ## DSL limitation: variant vs configurable distinction
##
## The spec's NDE-spec-variant outcome (Configurable-System.md
## §"Variant Or Configurable") distinguishes:
##
##   * **variant** — multi-valued seq, closure-affecting; switching
##     re-runs the solver.
##   * **configurable** — single-valued, activation-only; switching
##     rebuilds only the affected ``files:`` outputs.
##
## This distinction CANNOT be expressed in the existing
## ``parsePackageDef`` DSL (no ``@variant`` annotation; no per-arm
## ``uses:`` propagation; no ``validate:`` directive). We therefore
## declare BOTH ``desktopKind`` (the variant) and ``activeAtBoot``
## (the configurable) as ordinary ``config:`` fields with primitive
## types — ``seq[string]`` and ``string`` respectively — and rely on
## the impl module's ``validateDesktopConfig`` to enforce the
## cross-constraint at materialise time.
##
## Honest documentation: this is a workaround. When ``parsePackageDef``
## gains ``@variant`` + ``validate:`` recognition (a separate DSL
## milestone), the declaration here will migrate to the spec's literal
## shape from Configurable-System.md without breaking the impl
## module's contract.
##
## ## Configurables
##
## Per the spec NDEM1 ``config:`` section. Each maps to a field on
## ``ReproosDesktopConfig`` in the impl module. See the impl module's
## ``ReproosDesktopConfig`` docstring for the full per-field
## invalidation matrix.
##
##   * ``desktopKind`` (variant; spec @variant) — which DEs are
##     *installable* in this generation. Multi-valued. Spec literal:
##     ``seq[DesktopKind]``. v1 ships ``seq[string]`` per the DSL
##     limitation; the impl module's ``parseDesktopKind`` enforces
##     the ``"sway"`` / ``"gnome"`` / ``"plasma"`` token set.
##   * ``activeAtBoot`` (configurable) — which installable DE the
##     generation boots into. Spec literal: ``DesktopKind``. v1 ships
##     ``string`` per the DSL limitation; the impl module's
##     ``validateDesktopConfig`` enforces ``activeAtBoot in
##     desktopKind``.
##   * ``defaultUser`` (configurable) — default account name; matches
##     NDE0-S's ``defaultUser``.
##   * ``bootloaderTimeout`` (configurable) — GRUB menu timeout in
##     seconds.
##   * ``aptSnapshot`` (configurable) — apt-jammy snapshot pin
##     propagated to every sub-package.
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
## * **Bootloader integration is DEFERRED.** v1 emits a
##   ``grubMenuEntries`` ``ManagedFiles`` (one entry per generation);
##   the actual ``grub-mkconfig`` invocation + the bootable-ISO lift is
##   NDEM2 work.
##
## * **Multi-generation persistence is DEFERRED.** v1 emits a SINGLE
##   generation manifest per ``materializeReproosDesktop`` call. The
##   generation-log persistence layer (which records every recent
##   generation so ``reproos-rebuild rollback`` can re-activate the
##   previous one) is NDEM2 work.
##
## * **Closure garbage collection** (variant shrink → unused DE
##   bundle GC after grace period) is NDEM2 work.
##
## * **``variant`` + ``validate:`` DSL block forms**: pure DSL spec
##   at this point. Semantics encoded directly in the impl module's
##   ``validateDesktopConfig`` + the typed ``DesktopKind`` enum.

import repro_project_dsl

# The stdlib impl module that owns the multi-contributor merge +
# variant composition + generation-manifest emission. Imported here so
# it is in scope for downstream tooling that ``uses: "reproos-desktop
# >=0.1.0"`` and inlines a ``build:`` block invoking the procs directly.
import repro_dsl_stdlib/packages/system/reproos_desktop as desktopImpl
export desktopImpl

package reproosDesktop:
  ## NDEM1 native reproos-desktop system-level package.
  ##
  ## Downstream Tier-1 system tooling (NDEM2 vm-harness gate;
  ## reproos-rebuild CLI) ``uses:`` this and consume the exported
  ## ``materializeReproosDesktop`` proc to obtain the emission
  ## outputs (the multi-contributor merged
  ## /etc/ld.so.conf.d/00-reproos-linux.conf; the
  ## /etc/systemd/system/display-manager.service symlink intent; the
  ## GRUB menu entry; the GenerationManifest recording every
  ## contributor's storePaths).
  ##
  ## Conceptual DSL declarations (surface not yet implemented;
  ## semantics encoded directly in the impl module's helpers):
  ##
  ##   variant desktopKind:
  ##     case "sway":
  ##       uses: "sway >=0.1.0"
  ##     case "gnome":
  ##       uses: "gnome >=0.1.0"
  ##     case "plasma":
  ##       uses: "plasma >=0.1.0"
  ##
  ##   config:
  ##     desktopKind: seq[DesktopKind] = @[dkSway]
  ##     activeAtBoot: DesktopKind = dkSway
  ##     defaultUser: string = "repro"
  ##     bootloaderTimeout: int = 5
  ##     aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"
  ##
  ##   validate:
  ##     activeAtBoot in desktopKind.value
  ##
  ##   files displayManagerSymlink:
  ##     build:
  ##       fs.symlink(
  ##         path = "/etc/systemd/system/display-manager.service",
  ##         target = case config.activeAtBoot:
  ##           of dkSway:   "/usr/lib/systemd/system/sway-session.service"
  ##           of dkGnome:  "/usr/lib/systemd/system/gdm.service"
  ##           of dkPlasma: "/usr/lib/systemd/system/sddm.service"
  ##       )
  ##
  ##   bootloader:
  ##     generationEntry: true

  defaultToolProvisioning "path"

  config:
    ## Variant (closure-affecting): which DEs are installable. Spec
    ## literal ``seq[DesktopKind]``; v1 uses ``seq[string]`` per the
    ## DSL limitation. Default ``@["sway"]`` per the spec example.
    ## The impl module's ``validateDesktopConfig`` enforces the
    ## ``activeAtBoot in desktopKind`` cross-constraint.
    desktopKind: seq[string] = @["sway"]

    ## Configurable (activation-only): which installable DE the
    ## generation boots into. Spec literal ``DesktopKind``; v1 uses
    ## ``string`` per the DSL limitation. Default ``"sway"`` per the
    ## spec example. MUST be present in ``desktopKind`` (validated
    ## at materialise time).
    activeAtBoot: string = "sway"

    ## Configurable: default account name. Matches NDE0-S
    ## ``defaultUser``. Propagated to the systemd-session +
    ## gnome auto-login + plasma sddm auto-login sub-configs.
    defaultUser: string = "repro"

    ## Configurable: GRUB menu timeout in seconds. Recorded in every
    ## generation's GRUB menu entry.
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
    ## contributor merge.
    "graphics-stack >=0.1.0"

    ## NDE0-K native kernel — supplies the bzImage + KERNELRELEASE
    ## the generation's GRUB menu entry references.
    "reproos-kernel >=0.1.0"

    ## NDE-H1 native sway compositor — used when ``dkSway in
    ## desktopKind``. Variant-driven inclusion (spec literal: per-arm
    ## ``uses:`` in the ``variant`` block; v1 always lists for
    ## fingerprint purposes per the DSL limitation).
    "sway >=0.1.0"

    ## NDE-G1 native GNOME compositor — used when ``dkGnome in
    ## desktopKind``.
    "gnome >=0.1.0"

    ## NDE-K1 native KDE Plasma compositor — used when ``dkPlasma in
    ## desktopKind``.
    "plasma >=0.1.0"
