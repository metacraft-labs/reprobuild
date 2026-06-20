## Typed-Outputs M0 verification: a fixture ``executable buildNimUnittest:``
## with ``cli: subcmd "build": flag source is string; flag binary is string;
## outputs testBinary is NimUnittestBinary, binary`` compiles. The
## subcommand's ``CliCommandDef.typedOutputs`` contains exactly one
## entry with ``fieldName == "testBinary"``, ``types == @["NimUnittestBinary"]``,
## and ``pathExpr`` round-trips (via ``parseExpr``) to an ident node
## named ``binary``.

import std/[macros, unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

# Stub the framework-specific type that the typed outputs statement
# references. M0 only needs the identifier to resolve at the call site;
# M1 will populate the field's runtime value.
type NimUnittestBinary = object
  ## Typed-Outputs M1: the typed-tool wrapper now constructs the typed
  ## handle via ``NimUnittestBinary(path: <pathExpr>)`` so the type
  ## must expose a ``path`` field. The M0 test only asserted the
  ## compile-time shape; the M1 binding requires this field.
  path: string

package tDslOutputsTypedFormParsedPkg:
  executable buildNimUnittest:
    cli:
      subcmd "build":
        flag source is string
        flag binary is string
        outputs testBinary is NimUnittestBinary, binary

proc pathExprAstShape(source: static string):
    tuple[kind: NimNodeKind; ident: string] {.compileTime.} =
  ## ``parseExpr`` is a compile-time-only API (the returned ``NimNode``
  ## doesn't survive to runtime), so we summarise the round-tripped AST
  ## here at compile time and return a plain-Nim value the runtime test
  ## body can ``check``.
  let ast = parseExpr(source)
  result.kind = ast.kind
  result.ident =
    if ast.kind == nnkIdent: $ast else: ast.repr

suite "t_dsl_outputs_typed_form_parsed":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsTypedFormParsedPkg":
      pkg = p
      break

  test "t_dsl_outputs_typed_form_parsed":
    check pkg.packageName == "tDslOutputsTypedFormParsedPkg"
    check pkg.executables.len == 1
    let exe = pkg.executables[0]
    check exe.exportName == "buildNimUnittest"
    check exe.commands.len == 1
    let cmd = exe.commands[0]
    check cmd.name == "build"
    check cmd.typedOutputs.len == 1
    let td = cmd.typedOutputs[0]
    check td.fieldName == "testBinary"
    check td.types == @["NimUnittestBinary"]
    # ``pathExpr`` round-trips (via compile-time ``parseExpr``) to an
    # ident node named ``binary``. The M0 storage is the source repr;
    # the test forces the round-trip at compile time so the runtime
    # check sees the resolved kind/ident.
    const shape = pathExprAstShape("binary")
    check shape.kind == nnkIdent
    check shape.ident == "binary"
    # Confirm the stored repr is literally the ident text (no
    # parentheses or whitespace decoration).
    check td.pathExpr == "binary"
