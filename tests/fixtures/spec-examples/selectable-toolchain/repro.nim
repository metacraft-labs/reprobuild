## Spec example: selectable toolchain via a variant.
##
## Demonstrates:
##   - `variant: enum["gcc", "clang"] = "gcc"` declares a finite-set
##     solver-participating Configurable. The solver enforces that the
##     resolved value lies in the declared set
##     (Configurable-System §"Declaration").
##   - Variant-conditioned `uses:` arms pick the right adapter package
##     based on the solver's variant assignment
##     (Configurable-System §"`uses:` Resolution Driven by Variants",
##     Reprobuild-Standard-Library.md §"`uses:` Resolution Under
##     Variants").
##   - The abstract `cc.compile(...)` surface from the stdlib `Toolchain`
##     cross-cutting interface lets the recipe stay compiler-agnostic
##     while the adapter handles per-compiler invocation differences
##     (Reprobuild-Standard-Library.md §"Cross-Cutting Interfaces").
##
## Status: spec exhibit. References features not yet implemented (enum
## variants, the `Toolchain` cross-cutting interface, abstract
## `c-compiler` `uses:` resolution). Compiling this with the current
## engine will fail; that is expected until the implementation
## milestones land.

import repro_project_dsl
import repro_stdlib_toolchain # for the `cc` Toolchain interface handle

package selectable_toolchain:
  config:
    sourceRepository = "https://example.invalid/selectable-toolchain.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Compiler family. The solver picks the corresponding adapter
    ## package via the variant-conditioned `uses:` arms below; the
    ## abstract `cc.compile(...)` surface is unchanged across choices.
    compiler: variant enum["gcc", "clang"] = "gcc"

  uses:
    case compiler.value:
    of "gcc":   "gcc >=12 <15"
    of "clang": "clang >=16 <19"

  build:
    # Abstract typed-tool call against the `Toolchain` cross-cutting
    # interface. The interface is declared in the reprobuild stdlib; the
    # implementation is contributed by whichever adapter the solver
    # picked above. `cc.compile` reads `compiler.value` from the active
    # build context to dispatch to the right adapter's typed-tool
    # wrapper.
    discard cc.compile(source = "src/main.c",
                       binary = "build/bin/hello")
