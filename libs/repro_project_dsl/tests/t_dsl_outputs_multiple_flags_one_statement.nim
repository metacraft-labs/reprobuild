## Named-Targets M0 verification: a single ``outputs out depfile``
## statement records both flag names in declaration order on the
## subcommand's ``outputFlags``.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package tDslOutputsMultiPkg:
  uses:
    "nim >=2.2 <3.0"

  executable tool:
    cli:
      subcmd "c":
        flag out is string
        flag dep is string
        outputs out dep

suite "t_dsl_outputs_multiple_flags_one_statement":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsMultiPkg":
      pkg = p
      break

  test "t_dsl_outputs_multiple_flags_one_statement":
    check pkg.executables.len == 1
    let cmd = pkg.executables[0].commands[0]
    check cmd.name == "c"
    check cmd.outputFlags == @["out", "dep"]
