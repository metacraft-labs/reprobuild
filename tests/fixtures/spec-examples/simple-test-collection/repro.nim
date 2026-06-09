## Spec example: minimal `test` build graph collection.
##
## Demonstrates:
##   - `test` template auto-enrolls the run-edge into the `test`
##     collection (Package-Model §"The `test` template",
##     Build-Graph-Collections.md §"Contribution Surface").
##   - `repro test` (alias for `repro build test`) materializes every
##     member of the collection in one engine pass.
##
## Status: spec exhibit. DSL constructs reference features not yet
## implemented (the `test` template's auto-enrollment, the build graph
## collection primitive). Compiling this with the current engine will
## fail; that is expected until the implementation milestones land.

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
    # Two test edges, each declared via the `test` template. The template
    # is sugar over a typed-tool call whose returned edge carries a
    # `TestBinary` typed-output field: it emits the build edge, emits
    # `edge.testBinary.run()` for the execute edge, and auto-enrolls the
    # execute edge into the project-scoped `test` build graph collection.
    test buildNimUnittest(source = "tests/t_smoke.nim",
                          binary = "build/test-bin/t_smoke")

    test buildNimUnittest(source = "tests/t_arithmetic.nim",
                          binary = "build/test-bin/t_arithmetic")
