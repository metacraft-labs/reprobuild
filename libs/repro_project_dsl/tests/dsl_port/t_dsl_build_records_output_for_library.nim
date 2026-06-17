## DSL-port M4 acceptance — artifact-scoped ``build:`` block inside a
## ``library`` artifact.
##
## Sister fixture to ``t_dsl_build_with_executable.nim``. The lowerer
## logic is the same — walk the partitioned section list, filter for
## the ``soM3LibraryArtifact`` ownership tag, re-walk the library body
## for nested ``build:`` heads, emit one
## ``beginBuildContext / registerBuildAction / try body finally
## endBuildContext`` block per recognised entry. The discriminator on
## the registered action is ``DslArtifactKind.dakLibrary`` rather than
## ``dakExecutable``, but the M4 build-action / output records share the
## same shape regardless of the parent artifact's kind.
##
## This fixture also pins that the M4 emitter does NOT depend on the
## legacy ``parseLibrary`` arm running first: the partitioned section
## walk is the sole input to ``emitM4ArtifactBuildLowering``, and the
## library's body is re-walked in place (no ``parseStmt(bodyRepr)``).

import std/[unittest]

import repro_project_dsl

# Library with a single build: block declaring an .so output.
package libBuildPkg:
  library myLib:
    build:
      output("lib/myLib.so")

suite "DSL-port M4 — library build: records output":

  test "library + build: records exactly one output":
    let outputs = registeredOutputs("libBuildPkg", "myLib")
    check outputs.len == 1

  test "library + build: records the verbatim output path":
    let outputs = registeredOutputs("libBuildPkg", "myLib")
    check outputs[0] == "lib/myLib.so"

  test "library-scoped buildAction carries the artifact name":
    let actions = registeredBuildActions("libBuildPkg")
    check actions.len == 1
    check actions[0].artifactName == "myLib"
    check actions[0].packageName == "libBuildPkg"
