## DSL-port M6 acceptance — ``cli:`` block ``flag`` parameter
## registration.
##
## Pins the contract for M6's ``cli:`` sub-block lowering, narrowed to
## the flag-parameter shape:
##
##   executable myTool:
##     cli:
##       flag region is string
##       flag timeout is int
##
## The M6 emitter walks every artifact body, finds the nested ``cli:``
## head, and emits one ``registerCliParam(pkg, artifact, subcmd="",
## name, typeName, cpkFlag)`` per ``flag`` statement. The ``flag``
## variant differs from ``pos`` only in the recorded kind discriminator
## — both share the ``<name> is <Type>`` infix parse path. M6's runtime
## record carries the kind so consumers (M7+ help/usage emitter, the
## v8-style ``recordCliFlag`` migration) can dispatch.

import std/[unittest]

import repro_project_dsl

package flagPkg:
  executable myTool:
    cli:
      flag region is string
      flag timeout is int
    build:
      discard

suite "DSL-port M6 — cli flag params":
  test "flag params registered":
    let params = registeredCliParams("flagPkg", "myTool", "")
    check params.len == 2
    check params[0].name == "region"
    check params[0].typeName == "string"
    check params[0].kind == cpkFlag
    check params[1].name == "timeout"
    check params[1].typeName == "int"
    check params[1].kind == cpkFlag
