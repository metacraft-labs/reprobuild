## Spec example: minimal `test` build graph collection.
##
## Demonstrates:
##   - Typed-tool ``buildNimUnittest.build(...)`` edges emitted from a
##     ``build:`` body whose actions are folded into the project-scoped
##     ``test`` build graph collection via the M0 ``collect`` primitive
##     (Build-Graph-Collections.md §"Contribution Surface").
##   - ``repro test`` (alias for ``repro build test``) materializes
##     every member of the collection in one engine pass.
##
## Status: M1 spec exhibit. The richer ``test`` template that
## auto-enrolls run-edges into the collection lands once the
## ``TestRunner`` cross-cutting interface (M3+) is in place. The M1
## form below is exactly the shape used by the live ``repro.nim`` at
## the root of this repo and exercises the same M0 + M1 surfaces.

import repro_project_dsl
import ct_test_nim_unittest

package simple_test_collection:
  config:
    sourceRepository = "https://example.invalid/simple-test-collection.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

  uses:
    "nim >=2.2 <3.0"
    "ct_test_nim_unittest"

  build:
    # Two typed-tool edges. Each ``buildNimUnittest.build(...)`` call
    # returns an edge whose ``.action`` we accumulate into a local
    # ``seq[BuildActionDef]``. The trailing ``collect("test", ...)``
    # call registers the ``test`` build graph collection so
    # ``repro build test`` (and the ``repro test`` alias) materialize
    # both test-binary compilations in one engine pass.
    var testActions: seq[BuildActionDef] = @[]

    let smoke = buildNimUnittest.build(
      source = "tests/t_smoke.nim",
      binary = "build/test-bin/t_smoke")
    testActions.add(smoke.action)

    let arithmetic = buildNimUnittest.build(
      source = "tests/t_arithmetic.nim",
      binary = "build/test-bin/t_arithmetic")
    testActions.add(arithmetic.action)

    discard collect("test", testActions)
