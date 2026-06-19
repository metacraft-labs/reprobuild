## Typed-Outputs M0 regression check: the Named-Targets M0 untyped form
## ``outputs out depfile`` still produces ``outputFlags == @["out",
## "depfile"]`` on the ``CliCommandDef``, and no ``TypedOutputDef`` is
## added. The typed-form parser must not interfere with the untyped
## form's existing behavior.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package tDslOutputsUntypedFormUnchangedPkg:
  executable tool:
    cli:
      subcmd "build":
        flag out is string
        flag dep is string
        outputs out dep

suite "t_dsl_outputs_untyped_form_unchanged":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsUntypedFormUnchangedPkg":
      pkg = p
      break

  test "t_dsl_outputs_untyped_form_unchanged":
    check pkg.executables.len == 1
    let cmd = pkg.executables[0].commands[0]
    check cmd.name == "build"
    # Untyped form still produces the cumulative flag set on
    # ``outputFlags`` in declaration order.
    check cmd.outputFlags == @["out", "dep"]
    # And it does NOT add a TypedOutputDef — the typed-output list
    # stays empty for the untyped form.
    check cmd.typedOutputs.len == 0
