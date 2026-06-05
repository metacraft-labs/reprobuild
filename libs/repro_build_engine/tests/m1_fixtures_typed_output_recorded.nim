## Typed-Outputs M1 test fixture for
## ``t_engine_typed_output_recorded_in_normalized_graph``.
##
## A typed-tool whose ``outputs testBinary is NimUnittestBinary,
## TestBinary, binary`` declaration carries two interface tags. The
## consumer package's ``build:`` body calls the wrapper once, and the
## test asserts the engine artifact records ``fieldName``, ``types``,
## and bound ``path`` round-trip through the payload codec.
##
## Lives in a separate module from the test main so the auto-generated
## ``runPackageProvider`` shim's ``isMainModule`` guard doesn't fire
## on the test binary.

import repro_project_dsl

type NimUnittestBinary* = object
  path*: string

defineCliInterface buildNimUnittest, "test-buildNimUnittest":
  subcmd "build":
    flag source is string,
      role = input,
      required = true
    flag binary is string,
      role = output,
      required = true
    outputs testBinary is NimUnittestBinary, TestBinary, binary

package tEngineTypedOutputRecordedPkg:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard buildNimUnittest.build(source = "tests/foo.nim",
      binary = "build/test-bin/foo", actionId = "build-foo")

export buildNimUnittest
export NimUnittestBinary
export buildTEngineTypedOutputRecordedPkgPackage
