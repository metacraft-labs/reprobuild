## Named-Targets M0 verification: two separate ``outputs out`` and
## ``outputs depfile`` statements accumulate to the same set as a single
## ``outputs out depfile``. A duplicate ``outputs out`` is a no-op so
## the order remains the declaration order of the first mention.

import std/[unittest]

import repro_project_dsl

package tDslOutputsAccumulatePkg:
  uses:
    "nim >=2.2 <3.0"

  executable tool:
    cli:
      subcmd "c":
        flag out is string
        flag dep is string
        outputs out
        outputs dep
        outputs out  # duplicate; expected to be ignored.

suite "t_dsl_outputs_statements_accumulate":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsAccumulatePkg":
      pkg = p
      break

  test "t_dsl_outputs_statements_accumulate":
    check pkg.executables.len == 1
    let cmd = pkg.executables[0].commands[0]
    check cmd.outputFlags == @["out", "dep"]
