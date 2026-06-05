## Typed-Outputs M1 verification: a typed-tool call returns a
## ``BuildEdge`` subtype whose typed field carries a non-empty ``path``
## matching the flag value passed at the call site. Asserted against
## the Nim runtime value after the wrapper proc returns — no
## ``buildPackageFragment`` involved.
##
## The fixture defines a typed-output framework type
## ``NimUnittestBinary`` with a ``path: string`` field; the M1 wrapper
## emits ``result.testBinary = NimUnittestBinary(path: <pathExpr>)`` so
## the typed handle round-trips the bound path into UFCS-friendly
## storage. The check below pulls ``edge.testBinary.path`` and asserts
## it matches the call-site ``binary`` flag value.

import std/[unittest]

import repro_project_dsl

type NimUnittestBinary = object
  ## Typed-Outputs M1 framework type. The ``path`` field is what the
  ## wrapper writes through; downstream method calls
  ## (``edge.testBinary.run(...)``) read it back through UFCS.
  path: string

package tEngineTypedOutputFieldPopulatedPkg:
  executable buildNimUnittest:
    cli:
      subcmd "build":
        flag source is string
        flag binary is string
        outputs testBinary is NimUnittestBinary, binary

suite "t_engine_typed_output_field_populated_at_action_emission":
  test "t_engine_typed_output_field_populated_at_action_emission":
    let edge = tEngineTypedOutputFieldPopulatedPkg.build(
      source = "tests/foo.nim",
      binary = "build/test-bin/foo")
    # The typed field's static type was contracted at M0; M1 binds
    # ``path`` to the call's ``binary`` flag value.
    check edge.testBinary.path == "build/test-bin/foo"
    # The underlying engine record continues to point at the same
    # action — the typed handle is a wrapper around the same edge.
    check edge.action.call.executableName == "buildNimUnittest"
    check edge.action.call.subcommand == "build"
