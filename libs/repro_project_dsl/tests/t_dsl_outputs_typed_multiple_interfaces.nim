## Typed-Outputs M0 verification: ``outputs testBinary is
## NimUnittestBinary, InstallableExecutable, binary`` records
## ``types == @["NimUnittestBinary", "InstallableExecutable"]`` in
## declaration order with ``binary`` as the path expression. The first
## type determines the field's static type on the per-call ``BuildEdge``
## subtype; additional types tag the output as implementing further
## interfaces (consumed by M1 framework-recognition).

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

type
  NimUnittestBinary = object
    ## Typed-Outputs M1 update: the wrapper now binds via
    ## ``NimUnittestBinary(path: <pathExpr>)``.
    path: string
  InstallableExecutable = object

package tDslOutputsTypedMultipleInterfacesPkg:
  executable buildNimUnittest:
    cli:
      subcmd "build":
        flag source is string
        flag binary is string
        outputs testBinary is NimUnittestBinary, InstallableExecutable, binary

suite "t_dsl_outputs_typed_multiple_interfaces":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsTypedMultipleInterfacesPkg":
      pkg = p
      break

  test "t_dsl_outputs_typed_multiple_interfaces":
    check pkg.executables.len == 1
    let cmd = pkg.executables[0].commands[0]
    check cmd.typedOutputs.len == 1
    let td = cmd.typedOutputs[0]
    check td.fieldName == "testBinary"
    check td.types == @["NimUnittestBinary", "InstallableExecutable"]
    check td.pathExpr == "binary"
