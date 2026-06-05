## Test-Edges-And-Parallel-Runner M0 test fixtures for
## ``t_dsl_test_block_explicit_build_body_overrides_default``. A
## ``test`` block whose ``build:`` body explicitly invokes
## ``nim.c(source, output = "alt-path/custom")`` should emit an edge
## whose implicit name is ``custom`` (the override's ``output``
## basename) — i.e. the user keeps full control by writing the call
## themselves; the default ``nim_module.nim.c(...)`` synthesis is
## suppressed entirely.

import repro_project_dsl

package tDslTestBlockExplicitBuildPkg:
  uses:
    "nim >=2.2 <3.0"

  test localBuildEngineSmoke:
    source "tests/integration/t_local_build_engine.nim"
    build:
      # The user keeps full control here: the M0 default body
      # (``--threads:on --hints:off --warnings:off`` plus
      # ``build/test-bin/local-build-engine-smoke``) is NOT applied;
      # only this expression's return value is tagged ``bakTest``.
      nim_module.nim.c(source = "tests/integration/t_local_build_engine.nim",
                       output = "alt-path/custom")

export buildTDslTestBlockExplicitBuildPkgPackage
