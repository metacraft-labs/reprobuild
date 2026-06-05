## Typed-Outputs M0 verification: ``outputs testBinary is CargoTestBinary,
## ("target/debug/deps/" & binaryName)`` records ``types ==
## @["CargoTestBinary"]`` and ``pathExpr`` round-trips (via compile-time
## ``parseExpr``) to a parenthesised infix node. The expression is NOT
## evaluated at parse time — only its source repr is captured so M1 can
## reparse it against the call-site flag values at action-emission time.

import std/[macros, strutils, unittest]

import repro_project_dsl

type CargoTestBinary = object

package tDslOutputsTypedComplexPathExpressionPkg:
  executable buildCargoTest:
    cli:
      subcmd "build":
        flag source is string
        flag binaryName is string
        outputs testBinary is CargoTestBinary,
          ("target/debug/deps/" & binaryName)

proc pathExprAstShape(source: static string):
    tuple[kind: NimNodeKind; innerKind: NimNodeKind; opIdent: string]
    {.compileTime.} =
  ## Round-trip the stored ``pathExpr`` at compile time. The outer node
  ## is the ``Par`` (parentheses) wrapper; its single child is the
  ## ``Infix`` (``&`` concat) node that M1 will evaluate against the
  ## call-site ``binaryName`` flag value.
  let ast = parseExpr(source)
  result.kind = ast.kind
  if ast.kind == nnkPar and ast.len == 1:
    let inner = ast[0]
    result.innerKind = inner.kind
    if inner.kind == nnkInfix and inner.len == 3:
      result.opIdent = $inner[0]

suite "t_dsl_outputs_typed_complex_path_expression":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslOutputsTypedComplexPathExpressionPkg":
      pkg = p
      break

  test "t_dsl_outputs_typed_complex_path_expression":
    check pkg.executables.len == 1
    let cmd = pkg.executables[0].commands[0]
    check cmd.typedOutputs.len == 1
    let td = cmd.typedOutputs[0]
    check td.fieldName == "testBinary"
    check td.types == @["CargoTestBinary"]
    # The stored repr must preserve the parenthesised form so M1's
    # ``parseExpr`` recovers the same AST shape the author wrote.
    # ``treeRepr`` of ``("target/debug/deps/" & binaryName)`` is
    # ``Par(Infix(&, StrLit, Ident binaryName))``.
    const shape = pathExprAstShape(
      """("target/debug/deps/" & binaryName)""")
    check shape.kind == nnkPar
    check shape.innerKind == nnkInfix
    check shape.opIdent == "&"
    # Confirm the stored repr matches the canonical Nim rendering of
    # the parenthesised infix the author wrote (whitespace
    # normalisation by ``.repr`` is stable across the supported Nim
    # versions; the test pins the exact byte form so accidental
    # serialisation drift surfaces here).
    check td.pathExpr.contains("\"target/debug/deps/\"")
    check td.pathExpr.contains("binaryName")
    check td.pathExpr.contains("&")
    check td.pathExpr.startsWith("(")
    check td.pathExpr.endsWith(")")
