## Named-Targets M0 verification: a nested ``subcmd "build": subcmd
## "target": outputs dir name`` where ``dir`` is declared on the outer
## ``build`` and ``name`` on the inner ``target`` compiles; the inner
## ``target`` command's ``outputFlags`` contains both names.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package tDslOutputsParentScopePkg:
  uses:
    "nim >=2.2 <3.0"

  executable tool:
    cli:
      subcmd "build":
        flag dir is string
        subcmd "target":
          pos name is string
          outputs dir name

suite "t_dsl_outputs_lexical_scope_parent_subcmd":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsParentScopePkg":
      pkg = p
      break

  proc findCmd(path: seq[string]): CliCommandDef =
    for cmd in pkg.executables[0].commands:
      if cmd.path == path:
        return cmd
    raise newException(ValueError, "command not found: " & $path)

  test "t_dsl_outputs_lexical_scope_parent_subcmd":
    let target = findCmd(@["build", "target"])
    check target.name == "target"
    check target.outputFlags == @["dir", "name"]
