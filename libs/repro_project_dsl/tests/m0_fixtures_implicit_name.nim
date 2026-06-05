## Test-Edges-And-Parallel-Runner M0 test fixtures for
## ``t_dsl_test_block_implicit_name_from_synthesised_out``.
##
## Lives in a SEPARATE module from the test main so the
## ``when isMainModule`` guard inside the generated
## ``runPackageProvider`` shim does not fire when the test runs as a
## standalone binary. (The test file is the main module; this module
## is imported by it.)

import repro_project_dsl

package tDslTestBlockImplicitNamePkg:
  uses:
    "nim >=2.2 <3.0"

  test localBuildEngineSmoke:
    source "tests/integration/t_local_build_engine.nim"

  test reproBuildAction:
    source "tests/integration/t_repro_build_action.nim"

  test hcrAgentSpawn:
    source "tests/integration/t_hcr_agent_spawn.nim"

export buildTDslTestBlockImplicitNamePkgPackage
