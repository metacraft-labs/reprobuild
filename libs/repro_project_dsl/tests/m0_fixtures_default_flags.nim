## Test-Edges-And-Parallel-Runner M0 test fixtures for
## ``t_dsl_test_block_default_compile_flags``. A single ``test`` block
## with no explicit ``build:`` body exercises the synthesised default
## ``nim.c(...)`` call shape; the test asserts the bool flag values
## the M0 default applies — ``threadsOn``, ``hintsOff``, and
## ``warningsOff`` — surface on the resulting ``BuildActionDef``
## under the aliases the typed-tool wrapper attaches
## (``--threads:on``, ``--hints:off``, ``--warnings:off``).

import repro_project_dsl

package tDslTestBlockDefaultFlagsPkg:
  uses:
    "nim >=2.2 <3.0"

  test smoke:
    source "tests/integration/t_smoke.nim"

export buildTDslTestBlockDefaultFlagsPkgPackage
