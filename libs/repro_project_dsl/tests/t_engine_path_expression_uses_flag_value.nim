## Typed-Outputs M1 verification: a typed-tool with
## ``outputs testBinary is NimUnittestBinary,
## ("custom/" & binaryName)`` is called with ``binaryName = "foo"``;
## the emitted edge's ``testBinary.path`` is ``"custom/foo"``.
##
## Exercises the path-expression reparse hook (the M0 deviation:
## ``TypedOutputDef.pathExpr`` is the ``.repr`` of the source-site
## node; the M1 wrapper code is generated as Nim source, so the
## surrounding ``parseStmt`` reparses ``pathExpr`` against the
## call-site flag scope — concatenating "custom/" with the actual
## ``binaryName`` flag value at wrapper-call time).

import std/[unittest]

import repro_project_dsl

type NimUnittestBinary = object
  path: string

package tEnginePathExpressionUsesFlagValuePkg:
  executable buildNimUnittest:
    cli:
      subcmd "build":
        flag source is string
        flag binaryName is string
        outputs testBinary is NimUnittestBinary,
          ("custom/" & binaryName)

suite "t_engine_path_expression_uses_flag_value":
  test "t_engine_path_expression_uses_flag_value":
    let edge = tEnginePathExpressionUsesFlagValuePkg.build(
      source = "tests/foo.nim",
      binaryName = "foo")
    # The path expression evaluated at wrapper-call time against the
    # ``binaryName`` flag value produces ``"custom/foo"``.
    check edge.testBinary.path == "custom/foo"

    # Repeat with a different flag value to confirm the expression is
    # actually re-evaluated per call (not baked into the wrapper as a
    # compile-time constant).
    let other = tEnginePathExpressionUsesFlagValuePkg.build(
      source = "tests/bar.nim",
      binaryName = "bar")
    check other.testBinary.path == "custom/bar"
