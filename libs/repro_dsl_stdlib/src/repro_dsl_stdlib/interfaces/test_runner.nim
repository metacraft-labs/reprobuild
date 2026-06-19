## Compatibility re-export. The ``TestRunner`` cross-cutting contract
## (``TestRunner``, ``TestBinary``, ``newTestRunner``, ``validate``,
## ``defaultTestRunner`` …) moved to the standalone, dependency-free
## ``repro_test_adapters`` package so that out-of-tree adapter libraries
## and the reprobuild engine can share the types without a dependency
## cycle through the engine. This module keeps the historical import
## path ``repro_dsl_stdlib/interfaces/test_runner`` working by
## re-exporting the contract verbatim.
import repro_test_adapters/test_runner
export test_runner
