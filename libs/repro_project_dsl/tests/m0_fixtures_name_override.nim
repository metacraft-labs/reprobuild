## Test-Edges-And-Parallel-Runner M0 test fixtures for
## ``t_dsl_test_block_name_override_applies_to_out``.
##
## A ``test`` block with ``name "alt"`` produces an edge whose
## implicit name is ``alt`` and whose ``output`` argument ends in
## ``/alt`` — both derived from the same override, so the override
## flows through the M1 implicit-name basename rule rather than being
## a special case.

import repro_project_dsl

package tDslTestBlockNameOverridePkg:
  uses:
    "nim >=2.2 <3.0"

  test localBuildEngineSmoke:
    source "tests/integration/t_local_build_engine.nim"
    name "alt"

export buildTDslTestBlockNameOverridePkgPackage
