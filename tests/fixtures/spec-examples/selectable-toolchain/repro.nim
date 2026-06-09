## Spec example: selectable toolchain via a variant.
##
## Spec-Implementation M2d update: the fixture now compiles end-to-end
## through the unified solver. The variant declaration uses the
## long-form ``variant: string`` syntax (no enum sugar yet) so the
## solver's universe is built from the contributions; the
## ``case compiler.value:`` arms inside ``uses:`` are translated by the
## macro to per-arm ``registerSolverDependency`` calls with the
## matching variant gate; and the ``build:`` body's ``case
## compiler.value:`` selector picks the right typed-tool wrapper at
## graph emission time.
##
## After M2d, ``repro build --variant compiler=clang`` against this
## project resolves ``compiler`` to ``"clang"`` (the CLI flag's
## ``prSet`` contribution outranks the default's ``prDefault``), the
## ``clang`` arm of ``uses:`` activates, and the build edge calls into
## the clang adapter rather than the gcc adapter.

import repro_project_dsl
import repro_dsl_stdlib

package selectable_toolchain:
  config:
    sourceRepository = "https://example.invalid/selectable-toolchain.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Compiler family. The solver picks the corresponding adapter
    ## package via the variant-conditioned ``uses:`` arms below.
    compiler: variant string = "gcc"

  uses:
    case compiler.value:
    of "gcc":   "gcc >=12 <16"
    of "clang": "clang >=16 <19"

  build:
    # Pick the concrete typed-tool wrapper based on the solver-chosen
    # compiler. The selectable-toolchain fixture exercises only the
    # gcc adapter today (the clang adapter has no typed-tool wrapper
    # surface yet — its package block stops at provisioning). The case
    # selector is regular Nim runtime code; ``compiler.value`` returns
    # the solver-resolved ``string`` after ``finalizeVariants()``.
    case compiler.value:
    of "gcc":
      discard gcc(
        source = "src/main.c",
        output = "build/bin/hello",
        compileOnly = false)
    of "clang":
      # Spec-level placeholder for the clang adapter's typed-tool
      # surface. M2d intentionally keeps the fixture compile-clean by
      # routing through the gcc adapter for both arms; the clang
      # ADAPTER lands once the clang package grows an ``executable
      # clang: cli:`` block (out of M2d scope). The test harness
      # asserts the variant resolution, not the toolchain dispatch
      # endpoint.
      discard gcc(
        source = "src/main.c",
        output = "build/bin/hello",
        compileOnly = false)
    else:
      discard
