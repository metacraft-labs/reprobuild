## Named-Targets M0 verification: a root-level ``outputs globalOut``
## combined with a subcommand-level ``outputs subOut`` produces
## ``outputFlags == @["globalOut", "subOut"]`` on that subcommand —
## confirms root-level statements seed the cumulative set every nested
## scope inherits.

import std/[unittest]

import repro_project_dsl

package tDslOutputsRootInheritedPkg:
  uses:
    "nim >=2.2 <3.0"

  executable tool:
    cli:
      flag globalOut is string
      outputs globalOut

      subcmd "c":
        flag subOut is string
        outputs subOut

suite "t_dsl_outputs_lexical_scope_root_flag_inherited":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsRootInheritedPkg":
      pkg = p
      break

  test "t_dsl_outputs_lexical_scope_root_flag_inherited":
    let cmd = pkg.executables[0].commands[0]
    check cmd.name == "c"
    check cmd.outputFlags == @["globalOut", "subOut"]
