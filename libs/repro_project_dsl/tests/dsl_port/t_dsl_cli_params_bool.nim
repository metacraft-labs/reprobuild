## DSL-port M6 acceptance — ``cli:`` block ``boolFlag`` parameter
## registration plus the mixed pos/flag/boolFlag shape.
##
## Pins the contract for M6's ``cli:`` sub-block lowering when the
## body declares ``boolFlag`` entries (no type — implicit ``bool``)
## and when the three statement kinds are intermixed:
##
##   executable myTool:
##     cli:
##       boolFlag verbose
##       boolFlag dryRun
##
##   executable t:
##     cli:
##       pos input is string
##       flag output is string
##       boolFlag verbose
##
## The recorded ``DslCliParam.typeName`` for ``boolFlag`` is "bool"
## (defaulted by the emitter; the source-level form omits the type).
## Declaration order is preserved per the M2/M3/M4/M5 "empty rather
## than raise" + insertion-order conventions.

import std/[unittest]

import repro_project_dsl

package boolPkg:
  executable myTool:
    cli:
      boolFlag verbose
      boolFlag dryRun
    build:
      discard

package mixedPkg:
  executable t:
    cli:
      pos input is string
      flag output is string
      boolFlag verbose
    build:
      discard

suite "DSL-port M6 — cli boolFlag params":
  test "boolFlag params registered":
    let params = registeredCliParams("boolPkg", "myTool", "")
    check params.len == 2
    check params[0].name == "verbose"
    check params[0].kind == cpkBoolFlag
    check params[1].name == "dryRun"
    check params[1].kind == cpkBoolFlag

  test "mixed pos + flag + boolFlag":
    let params = registeredCliParams("mixedPkg", "t", "")
    check params.len == 3
    check params[0].kind == cpkPos
    check params[1].kind == cpkFlag
    check params[2].kind == cpkBoolFlag
