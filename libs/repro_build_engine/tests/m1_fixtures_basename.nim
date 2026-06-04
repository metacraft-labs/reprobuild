## Named-Targets M1 test fixtures for
## ``t_engine_implicit_target_name_basename_rule``.
##
## Lives in a SEPARATE module from the test main so the
## ``when isMainModule`` guard inside the generated
## ``runPackageProvider`` shim does not fire when the test runs as a
## standalone binary. (The test file is the main module; this module
## is imported by it.)

import repro_project_dsl

defineCliInterface nimC, "test-nimC":
  subcmd "c":
    flag output is string,
      alias = "--out:",
      role = output,
      required = true
    pos source is string,
      role = input,
      position = 0
    outputs output

package tEnginePlainBasenamePkg:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard nimC.c(source = "src/codetracer.nim",
      output = "bin/codetracer", actionId = "plain")

package tEngineExeSuffixPkg:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard nimC.c(source = "src/codetracer.nim",
      output = "bin/codetracer.exe", actionId = "exe-suffix")

package tEngineAbsolutePathPkg:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard nimC.c(source = "src/codetracer.nim",
      output = "/abs/path/codetracer-cli", actionId = "absolute")

export nimC
export buildTEnginePlainBasenamePkgPackage
export buildTEngineExeSuffixPkgPackage
export buildTEngineAbsolutePathPkgPackage
