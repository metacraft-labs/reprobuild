## DSL-port M6 acceptance — ``cli:`` block ``pos`` parameter
## registration.
##
## Pins the contract for M6's ``cli:`` sub-block lowering, narrowed to
## the positional-parameter shape:
##
##   executable myTool:
##     cli:
##       pos input is string
##       pos count is int
##
## The M6 emitter walks every ``executable``/``library``/``files``
## artifact body (re-walked off the M3 ``classifyPackageSections`` seam,
## same pattern M4's ``emitM4ArtifactBuildLowering`` uses) looking for a
## nested ``cli:`` head. Inside the ``cli:`` body it dispatches one
## ``registerCliParam(pkg, artifact, subcmd="", name, typeName, kind)``
## call per ``pos``/``flag``/``boolFlag`` statement. The recorded specs
## round-trip through ``registeredCliParams`` so this test can pin them.
##
## Distinct from the legacy ``parsePackageDef`` ``cli:`` arm which
## populates ``ExecutableDef.commands[].params`` for the typed-tool
## wrapper emission: M6's registry is a NEW sidecar (mirrors how M3's
## ``dslPortArtifactRegistry`` co-exists with ``pkg.executables``).

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package posPkg:
  executable myTool:
    cli:
      pos input is string
      pos count is int
    build:
      discard

suite "DSL-port M6 — cli pos params":
  test "positional params registered":
    let params = registeredCliParams("posPkg", "myTool", "")
    check params.len == 2
    check params[0].name == "input"
    check params[0].typeName == "string"
    check params[0].kind == cpkPos
    check params[1].name == "count"
    check params[1].typeName == "int"
    check params[1].kind == cpkPos
