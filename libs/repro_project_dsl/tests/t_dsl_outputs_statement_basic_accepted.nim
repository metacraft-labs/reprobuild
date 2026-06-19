## Named-Targets M0 verification: a fixture ``executable foo:`` with
## ``cli: subcmd "c": flag out is string; outputs out`` compiles and
## records ``outputFlags == @["out"]`` on the ``c`` subcommand's
## ``CliCommandDef``.
##
## The DSL is a compile-time macro that feeds the package registry, so
## the test asserts the registered shape after the package block has
## expanded.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package tDslOutputsBasicPkg:
  uses:
    "nim >=2.2 <3.0"

  executable foo:
    cli:
      subcmd "c":
        flag out is string
        outputs out

suite "t_dsl_outputs_statement_basic_accepted":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsBasicPkg":
      pkg = p
      break

  test "t_dsl_outputs_statement_basic_accepted":
    check pkg.packageName == "tDslOutputsBasicPkg"
    check pkg.executables.len == 1
    let exe = pkg.executables[0]
    check exe.exportName == "foo"
    check exe.commands.len == 1
    let cmd = exe.commands[0]
    check cmd.name == "c"
    check cmd.path == @["c"]
    check cmd.outputFlags == @["out"]
