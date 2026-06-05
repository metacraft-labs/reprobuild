## Typed-Outputs M0 verification (static-typing test): a typed-tool call
## against a tool with ``outputs testBinary is NimUnittestBinary, output``
## returns a value whose Nim *static* type carries a
## ``testBinary: NimUnittestBinary`` field. The check runs inside a
## ``static:`` block so the compiler must resolve the field's type at
## compile time — runtime path binding is M1, but the *shape* must
## already be there at M0.

import std/[unittest]

import repro_project_dsl

# Stub the framework-specific type that the typed outputs statement
# references. ``object`` is enough; the test asserts via
## ``typeof(edge.testBinary) is NimUnittestBinary``.
type NimUnittestBinary* = object
  ## Typed-Outputs M1 update: the wrapper now binds the typed field via
  ## ``NimUnittestBinary(path: <pathExpr>)``, so the type must carry a
  ## ``path`` field.
  path*: string

package tDslOutputsTypedFieldEmittedPkg:
  executable buildNimUnittest:
    cli:
      subcmd "build":
        flag source is string
        flag output is string
        outputs testBinary is NimUnittestBinary, output

# The typed-tool wrapper proc emits a ``BuildEdge`` subtype per call
# (``BuildNimUnittestBuildEdge`` by the M0 naming convention:
# ``<TitleExportName><TitleCmdName>Edge``). The ``static:`` block
# forces the static-type assertion at compile time using a never-
# called proc — its body is type-checked at compile time (so
# ``typeof(edge.testBinary) is NimUnittestBinary`` is asserted by
# the compiler), but it is not VM-evaluated, so it doesn't trip the
# ``buildActionRegistry`` ``var`` access that ``recordToolInvocation``
# performs.
proc shapeCheck() {.compileTime, used.} =
  let edge = tDslOutputsTypedFieldEmittedPkg.build(
    source = "tests/foo.nim", output = "build/test-bin/foo")
  doAssert typeof(edge.testBinary) is NimUnittestBinary
  doAssert typeof(edge.action) is BuildActionDef

# Sanity check: the proc above must have been declared and Nim
# resolved its body. If the wrapper's return type lacked the typed
# field, the proc wouldn't compile and this static block wouldn't
# evaluate either.
static:
  doAssert declared(shapeCheck)

suite "t_dsl_outputs_typed_field_emitted_on_subtype":
  test "t_dsl_outputs_typed_field_emitted_on_subtype":
    # Runtime body that exercises the same wrapper and checks the
    # typed field at runtime. ``typeof`` is a compile-time check the
    # compiler evaluates here too; the runtime ``check`` just keeps
    # the unittest harness happy with one [OK] line per test.
    let edge = tDslOutputsTypedFieldEmittedPkg.build(
      source = "tests/foo.nim", output = "build/test-bin/foo")
    check edge.action.call.executableName == "buildNimUnittest"
    check typeof(edge.testBinary) is NimUnittestBinary
