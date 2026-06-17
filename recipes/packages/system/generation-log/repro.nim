## NDEM2: generation-log persistence + rollback package declaration.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDEM2 at
## the **manifest level** (NOT at the Hyper-V boot level — the real
## /etc/ activation runtime + .deb extraction required by the spec's
## ~vm-harness/tests/e2e/t_vm_harness_hyperv_reproos_native_generations.nim~
## are explicitly deferred).
##
## ## Why this layout
##
## Mirrors NDEM1's split: this ``repro.nim`` is the user-facing package
## declaration; the actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/system/
## generation_log.nim``.
##
## ## What this package owns
##
## NDEM2 closes the spec's "**multi-generation persistence**" deferral
## documented in NDEM1's ``reproos_desktop.nim``. The append-only
## ``GenerationLog`` records every ``GenerationManifest`` produced by
## ``materializeReproosDesktop``; the "active" generation is the most
## recently added entry; ``rollback`` pops the active entry; the prior
## entry becomes active.
##
## See the impl module for the full docstring + the honest-deferral
## list (real Hyper-V boot tests NDE-H2 / NDE-G2 / NDE-K2 remain
## blocked on .deb extraction + activation runtime).
##
## ## Configurables
##
## v1 ships a single configurable (``storeRoot``) for parity with the
## sub-packages; the log itself lives in memory + as a serialised JSON
## string. Planting the JSON under
## ``<storeRoot>/.reproos-generations.json`` is the activation layer's
## job (deferred).

import repro_project_dsl

# The stdlib impl module that owns the log primitives + serialiser.
# Imported here so it is in scope for downstream tooling that
# ``uses: "generation-log >=0.1.0"`` and inlines a ``build:`` block
# invoking the procs directly.
import repro_dsl_stdlib/packages/system/generation_log as logImpl
export logImpl

package generationLog:
  ## NDEM2 native generation-log persistence + rollback package.
  ##
  ## Downstream Tier-1 system tooling (reproos-rebuild CLI; vm-harness
  ## boot-test gate) ``uses:`` this and consume the exported
  ## ``addGeneration`` / ``activeGeneration`` / ``rollback`` /
  ## ``lookupGeneration`` / ``serializeGenerationLog`` /
  ## ``deserializeGenerationLog`` procs to maintain the multi-
  ## generation history.

  defaultToolProvisioning "path"

  config:
    ## Store root for the on-disk serialised log. v1 records this
    ## but the activation layer that actually plants the JSON file
    ## is deferred. Tests override.
    storeRoot: string = "/opt/reproos-linux/store"

  uses:
    ## NDEM1 native reproos-desktop — supplies the
    ## ``GenerationManifest`` shape this log records, the
    ## ``EConfigViolation`` error type ``activeGeneration`` /
    ## ``rollback`` raise on failure paths, and the ``DesktopKind``
    ## enum used in deserialisation.
    "reproos-desktop >=0.1.0"
