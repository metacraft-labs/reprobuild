## Spec example: variant flag affects build graph shape.
##
## Demonstrates:
##   - ``variant: bool = true`` declares a solver-participating
##     Configurable (Configurable-System §"Solver-Participating
##     Configurables").
##   - Variant-conditioned ``uses:`` arm selects the TLS dependency
##     only when the variant resolves truthy. (M1 evaluates this arm
##     at ``evalConfig`` finalize time using the variant default plus
##     any in-scope ``override`` / CLI contributions; full SAT-solver
##     participation lands in M2.)
##   - Variant-conditioned ``build:`` body emits the TLS test edge
##     only when the variant resolves truthy. The TLS test's
##     contribution to the ``test`` build graph collection is gated
##     by the surrounding ``if`` so the collection's membership tracks
##     the variant's resolved value.
##
## Status: M1 spec exhibit. Uses the same long-form
## ``buildNimUnittest.build(...)`` + ``collect("test", ...)`` shape as
## the live ``repro.nim`` at the root of this repo. The richer
## auto-enrolling ``test`` template lands once the ``TestRunner``
## cross-cutting interface (M3+) is in place.

import repro_project_dsl
import ct_test_nim_unittest

package variant_feature_flag:
  config:
    sourceRepository = "https://example.invalid/variant-feature-flag.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Enable TLS support. Setting this variant to ``false`` drops the
    ## openssl dependency, the TLS build edge, and the TLS test
    ## enrollment in one consistent pass.
    enableTLS: variant bool = true

  uses:
    "nim >=2.2 <3.0"
    "ct_test_nim_unittest"
    if enableTLS.value: "openssl >=3.3 <4.0"

  build:
    # Server binary is always built. The implementation imports openssl
    # only when the ``openssl`` flag in ``uses:`` activates, so its
    # symbol set is variant-conditioned via the ``defines`` arm below.
    let server = nim.c(
      source = "src/server.nim",
      binary = "build/bin/server",
      defines = if enableTLS.value: @["useTls"] else: @[])

    # Accumulate test-edge actions into a local seq, then register the
    # ``test`` build graph collection with one ``collect`` call. The
    # M0 ``collect`` primitive (Build-Graph-Collections.md) records the
    # members so ``repro build test`` (and the ``repro test`` alias)
    # materializes every member in one engine pass.
    var testActions: seq[BuildActionDef] = @[]

    # Basic test is always enrolled.
    let basic = buildNimUnittest.build(
      source = "tests/t_basic.nim",
      binary = "build/test-bin/t_basic")
    testActions.add(basic.action)

    # TLS test is enrolled only when the variant resolves truthy. The
    # collection's contribution surface respects the surrounding
    # control flow: the ``buildNimUnittest.build(...)`` call (and its
    # ``add(...)`` into ``testActions``) execute only on the truthy
    # branch, so the ``test`` collection's membership tracks the
    # variant's resolved value.
    if enableTLS.value:
      let tls = buildNimUnittest.build(
        source = "tests/t_tls.nim",
        binary = "build/test-bin/t_tls",
        imports = @["openssl"])
      testActions.add(tls.action)

    discard collect("test", testActions)
