## Spec example: cross-compilation via a variant.
##
## Per Reprobuild-Standard-Library §"Worked Example: Cross-Compilation"
## and Configurable-System §"Worked Example: Cross-Compilation",
## cross-compilation is the analogue of Nix's
## ``pkgsCross.<target>.stdenv``: the author declares a
## ``targetTriple`` variant; the solver picks a cross-compilation
## ``Toolchain`` + ``CrossTarget`` adapter; recipes consult
## ``currentBuildContext().toolchain.compile(...)`` /
## ``currentBuildContext().crossTarget.triple`` and the swap is
## invisible from the recipe's perspective.
##
## ## Status
##
## Spec-Implementation M5 spec exhibit. The fixture's variant
## resolution and adapter selection flow through the live unified
## solver (M2d) + active-context (M3) machinery. The cross-toolchain
## adapter package at
## ``libs/repro_dsl_stdlib/.../adapters/cross_aarch64_linux_gnu.nim``
## supplies the ``Toolchain`` and ``CrossTarget`` for the
## ``aarch64-linux-gnu`` triple; the active build context's
## ``resolveToolchain`` / ``resolveCrossTarget`` consult the variant
## solution and pick the cross adapter when the resolved triple
## matches.
##
## ## Variant resolution
##
## - Default: ``targetTriple = "native"`` — host gcc, native binary.
## - ``--variant targetTriple=aarch64-linux-gnu`` (or
##   ``REPRO_VARIANTS=targetTriple=aarch64-linux-gnu``) — cross gcc,
##   aarch64 binary.
##
## ## Implementation note
##
## The recipe's interaction with the active build context lives in
## the ``emitCrossCompilationEdges`` helper proc declared at module
## scope. The ``build:`` body just calls the helper. This keeps the
## top-level ``let`` bindings out of the M5 cross-project binding
## collector's scope (which would otherwise try to evaluate
## ``typeof(currentBuildContext())`` at module-level, where the
## context isn't yet active).

import repro_project_dsl
import repro_dsl_stdlib

proc emitCrossCompilationEdges*() =
  ## Build the two edges that turn ``src/hello.c`` into a host- or
  ## cross-compiled ``build/bin/hello`` binary. Consults the active
  ## build context's toolchain slot (gcc for native; cross-aarch64-gcc
  ## for the cross variant) and routes the compile + link actions
  ## through ``buildAction(...)`` so the engine sees real
  ## ``BuildActionDef`` rows.
  let ctx = currentBuildContext()
  let compileAction = ctx.toolchain.compile(
    "src/hello.c",
    "build/obj/hello.o",
    @[])
  let linkAction = ctx.toolchain.link(
    @["build/obj/hello.o"],
    "build/bin/hello",
    @[])

  discard buildAction(
    id = compileAction.actionId,
    call = inlineExecCall(compileAction.argv),
    inputs = compileAction.inputs,
    outputs = compileAction.outputs)
  discard buildAction(
    id = linkAction.actionId,
    call = inlineExecCall(linkAction.argv),
    inputs = linkAction.inputs,
    outputs = linkAction.outputs,
    deps = @[compileAction.actionId])

  # Enroll the two-edge slice into a collection so
  # ``repro build hello`` (or the M5 cross-compilation e2e test) has
  # a single name to target. ``collect`` writes to the M5 parallel
  # collection registry per Build-Graph-Collections.md §"Persistence
  # and the Target-Export Table".
  discard collect("hello", actions = @[
    BuildActionDef(id: compileAction.actionId),
    BuildActionDef(id: linkAction.actionId)])

package cross_compilation:
  config:
    sourceRepository = "https://example.invalid/cross-compilation.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Target triple for the cross-compilation worked example. ``native``
    ## builds for the host; ``aarch64-linux-gnu`` cross-compiles via the
    ## stdlib's M5 cross-toolchain adapter.
    targetTriple: variant string = "native"

  uses:
    # The variant-conditioned arms mirror the Configurable-System
    # §"Worked Example: Cross-Compilation" pattern: a ``native`` arm
    # selects the host compiler; a non-native triple selects the
    # matching cross-toolchain adapter. The dependency-version ranges
    # are stub values — the cross-toolchain adapter is supplied
    # locally by the stdlib catalogue rather than the solver's package
    # set, so the constraints exist for documentation / solver
    # warm-up purposes.
    case targetTriple.value:
    of "native":              "gcc >=12 <16"
    of "aarch64-linux-gnu":   "gcc >=12 <16"
    else:                     "gcc >=12 <16"

  build:
    emitCrossCompilationEdges()
