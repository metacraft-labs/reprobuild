## Typed-Outputs M0 verification (CLI-only ``executable`` blocks): a
## fixture ``executable NimUnittestBinary:`` with **only** a ``cli:``
## block (no ``build:``, no ``uses:``) compiles. The resulting
## executable registers a typed-tool client surface — the subcommand
## procs the macro emits — so a consumer package's ``build:`` body can
## call them and the emission compiles as an edge declaration.
##
## Adapter packages such as codetracer's ``ct_test_nim_unittest`` use
## this shape to declare a binary's typed CLI surface (the ``run`` /
## ``list`` subcommands of a test binary) without claiming
## responsibility for producing the binary.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

# Typed-Outputs M1 update: the wrapper now binds the typed field via
# ``<FieldType>(path: <pathExpr>)``, so we need a non-primitive type
# with a ``path`` field. Bare ``string`` does not have a constructor of
# that shape, so we declare a small handle type for the result.
type TestResultsHandle = object
  path: string

# CLI-only declaration: no ``build:``, no ``uses:``.
package tDslExecutableCliOnlyAdapter:
  executable NimUnittestBinary:
    cli:
      subcmd "run":
        flag filter is string
        outputs results is TestResultsHandle, filter
      subcmd "list":
        discard

# Consumer package whose ``build:`` body calls into the CLI-only
# adapter's typed-tool surface. If the wrapper procs were not
# registered, the body would fail to compile (no such proc /
# undeclared identifier on ``tDslExecutableCliOnlyAdapter``).
package tDslExecutableCliOnlyConsumer:
  build:
    let runEdge = tDslExecutableCliOnlyAdapter.run(filter = "case_x")
    let listEdge = tDslExecutableCliOnlyAdapter.list()
    discard runEdge
    discard listEdge

suite "t_dsl_executable_cli_only_no_build":
  test "t_dsl_executable_cli_only_no_build":
    let packages = registeredPackages()
    var adapter: PackageDef
    var consumer: PackageDef
    for p in packages:
      if p.packageName == "tDslExecutableCliOnlyAdapter":
        adapter = p
      elif p.packageName == "tDslExecutableCliOnlyConsumer":
        consumer = p
    # Adapter side: one CLI-only executable with two subcommands; no
    # ``uses:`` and no ``build:`` are required.
    check adapter.packageName == "tDslExecutableCliOnlyAdapter"
    check adapter.executables.len == 1
    let exe = adapter.executables[0]
    check exe.exportName == "NimUnittestBinary"
    check exe.commands.len == 2
    # The first command is ``run`` (with a typed output declared); the
    # second is ``list`` (no outputs of any kind).
    var runCmd, listCmd: CliCommandDef
    for cmd in exe.commands:
      if cmd.name == "run":
        runCmd = cmd
      elif cmd.name == "list":
        listCmd = cmd
    check runCmd.name == "run"
    check runCmd.typedOutputs.len == 1
    check runCmd.typedOutputs[0].fieldName == "results"
    check runCmd.typedOutputs[0].types == @["TestResultsHandle"]
    check listCmd.name == "list"
    check listCmd.typedOutputs.len == 0
    # Consumer side: the package compiles (parser accepts the body).
    # The runtime edge-registration assertion lives in the M1 suite;
    # M0 only contracts the compile-time shape.
    check consumer.packageName == "tDslExecutableCliOnlyConsumer"
