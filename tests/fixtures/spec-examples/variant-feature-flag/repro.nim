## Spec example: variant flag affects build graph shape.
##
## Demonstrates:
##   - `variant: bool = true` declares a solver-participating Configurable
##     (Configurable-System §"Solver-Participating Configurables").
##   - Variant-conditioned `uses:` arm selects the TLS dependency only
##     when the variant resolves truthy.
##   - Variant-conditioned `build:` body emits the TLS test edge only
##     when the variant resolves truthy. The `test` template's
##     auto-enrollment drops the TLS test from the `test` collection in
##     lockstep.
##
## Status: spec exhibit. References features not yet implemented
## (solver-participating Configurables, variant-conditioned `uses:` and
## `build:` arms). Compiling this with the current engine will fail;
## that is expected until the implementation milestones land.

import repro_project_dsl
import ct_test_nim_unittest

package variant_feature_flag:
  config:
    sourceRepository = "https://example.invalid/variant-feature-flag.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Enable TLS support. Setting this variant to `false` drops the
    ## openssl dependency, the TLS build edge, and the TLS test
    ## enrollment in one consistent pass.
    enableTLS: variant bool = true

  uses:
    "nim >=2.2 <3.0"
    "ct_test_nim_unittest"
    if enableTLS.value: "openssl >=3.3 <4.0"

  build:
    # Server binary is always built. The implementation imports openssl
    # only when the `openssl` flag in `uses:` activates, so its symbol
    # set is variant-conditioned.
    let server = nim.c(source = "src/server.nim",
                       binary = "build/bin/server",
                       defines = if enableTLS.value: @["useTls"] else: @[])

    # Basic test is always enrolled in the `test` collection.
    test buildNimUnittest(source = "tests/t_basic.nim",
                          binary = "build/test-bin/t_basic")

    # TLS test is enrolled only when the variant resolves truthy. The
    # `test` template's auto-enrollment in the `test` build graph
    # collection respects the surrounding control flow: the contribution
    # is registered conditionally at stage 4.
    if enableTLS.value:
      test buildNimUnittest(source = "tests/t_tls.nim",
                            binary = "build/test-bin/t_tls",
                            imports = @["openssl"])
