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
## ## NDE-J: tenth and final NDE rewrite — pure-DSL declaration surface
##
## NDE-J closes the 10-package NDE campaign. Per the campaign's "real
## declaration" framing established by NDE-A and continued through
## NDE-I: even a pure proc-library package surfaces ONE DSL block beyond
## plain ``config:`` so a downstream auditor can read the canonical
## metadata (version pin; CLI shape) straight off the registry without
## peeking at the shim. Two surfaces are declared here:
##
##   * **``versions:``** (M2 lowerer) — a single ``"0.1.0"`` entry tied
##     byte-identically to the shim's ``NdemGenerationLogVersion``
##     constant. The serialised log embeds that string into its first
##     bytes (``"version":"0.1.0"``); ``deserializeGenerationLog``
##     hard-fails on mismatch. Recording the same string in the recipe's
##     ``versions:`` registry makes the cache-key contract auditable
##     from both ends without parsing the JSON envelope.
##
##   * **``executable reproosRebuild:`` + ``cli:``** (M3 + M6 lowerers)
##     — the four spec'd ``reproos-rebuild`` subcommands (``list`` /
##     ``switch <N>`` / ``rollback`` / ``gc --older-than=<duration>``)
##     are reflected as ROOT-level CLI parameters per the M6 deferred-
##     subcommand convention. The spec literal lives in
##     ``ReproOS-Generations-And-Foreign-Packages.milestones.org`` and
##     names the four subcommands the generation-log consumer drives.
##     Declaring the shape here gives the future ``apps/reproos-rebuild/``
##     CLI a single source of truth for arg-parsing schema (M7+ help/
##     usage emitter consumes the registry).
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
  ##
  ## **NDE-J**: M2 ``versions:`` + M3 ``executable:`` + M6 ``cli:``
  ## pure-DSL surface beyond the v1 ``config:`` / ``uses:`` pair. The
  ## ``versions:`` entry is byte-identical to ``NdemGenerationLogVersion``
  ## (the shim const baked into every serialised log envelope); the
  ## ``cli:`` shape captures the spec'd ``reproos-rebuild`` subcommand
  ## set so the downstream CLI emission has one source of truth.

  defaultToolProvisioning "path"

  versions:
    ## Implementation revision of the generation-log primitives. The
    ## string MUST stay in lockstep with the shim's
    ## ``NdemGenerationLogVersion`` constant
    ## (``libs/repro_dsl_stdlib/.../packages/system/generation_log.nim``)
    ## because every serialised log envelope embeds the same string as
    ## its ``"version"`` discriminator. ``deserializeGenerationLog``
    ## hard-fails on mismatch — a future on-disk format migration goes
    ## through a version-aware adapter rather than a silent
    ## re-interpretation of the bytes.
    "0.1.0":
      sourceRevision = "ndem2/generation-log/0.1.0"

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

  # -------------------------------------------------------------------------
  # M3 ``executable:`` + M6 ``cli:`` — the reproos-rebuild subcommand
  # surface. Per the M6 deferred-subcommand convention (``subcmd "<name>":``
  # nesting is documented but not yet lowered; root-level params only —
  # see `t_dsl_cli_params_pos.nim`), the four spec'd subcommands collapse
  # into ROOT-level positional/flag/boolFlag entries:
  #
  #   * ``pos subcommand is string`` — the verb (one of "list" / "switch"
  #     / "rollback" / "gc"); the future CLI dispatcher uses a closed-set
  #     validator to route.
  #   * ``flag generationId is string`` — argument to ``switch
  #     <generationId>``; lookupGeneration() consumes it. Empty string
  #     means "not switching".
  #   * ``flag olderThan is string`` — argument to ``gc
  #     --older-than=<duration>``; the duration parser is GC-layer work.
  #     Empty string means "not GC-ing".
  #   * ``boolFlag verbose`` — universal verbosity flag for every
  #     subcommand; emits the full serialised log to stdout when set.
  #
  # The build: body is intentionally empty (``discard``): the executable
  # is a SCHEMA-only declaration at NDEM2; the actual CLI binary lives in
  # ``apps/reproos-rebuild/`` (deferred) and consumes the registry via
  # ``registeredCliParams("generationLog", "reproosRebuild", "")`` at
  # init time.
  # -------------------------------------------------------------------------

  executable reproosRebuild:
    ## Spec'd ``reproos-rebuild`` CLI surface (per
    ## ``ReproOS-Generations-And-Foreign-Packages.milestones.org``).
    ## Schema-only at NDEM2; the binary build is deferred to the
    ## ``apps/reproos-rebuild/`` milestone.
    cli:
      pos subcommand is string
      flag generationId is string
      flag olderThan is string
      boolFlag verbose
    build:
      discard
