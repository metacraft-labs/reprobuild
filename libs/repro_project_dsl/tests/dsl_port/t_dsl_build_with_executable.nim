## DSL-port M4 acceptance — artifact-scoped ``build:`` block inside an
## ``executable`` artifact.
##
## Pins the contract for M4's nested-build lowering when the ``build:``
## sub-block appears inside an ``executable <name>: ...`` artifact body.
## The M4 emitter:
##
##   1. Walks the partitioned section list (via ``classifyPackageSections``
##      per M3's seam), filters for ``executable`` artifacts, then
##      re-walks each artifact body looking for nested ``build:`` heads
##      — NEVER ``parseStmt(bodyRepr)``; the partition seam returns the
##      actual NimNode.
##   2. For each nested ``build:`` entry, emits a module-init block
##      that:
##         - Pushes ``(packageName, artifactName)`` onto the active
##           build context stack via ``beginBuildContext``.
##         - Records the action via ``registerBuildAction`` with the
##           artifact's name as the ``artifactName`` field (NON-empty,
##           discriminating this from the package-level form).
##         - Splices the user's verbatim build body so any
##           ``output(path)`` calls reached inside resolve against the
##           active context and append onto ``dslPortOutputs[<pkg>.
##           <artifact>]``.
##         - Pops the context via ``endBuildContext`` in a ``finally``.
##
## The legacy ``parsePackageDef`` walker continues to populate
## ``pkg.executables`` (the typed-tool wrapper sidecar) AND
## ``collectBuildStatements`` continues to splice the nested ``build:``
## body into the legacy ``buildXxxPackage*()`` proc — but that proc is
## only invoked under ``reproProviderMode + isMainModule``, so tests do
## not double-register. See the ownership comment above
## ``emitM4ArtifactBuildLowering`` in ``macros_b.nim``.

import std/[unittest]

import repro_project_dsl

# Single-artifact executable with a build: block declaring one output.
package execBuildPkg:
  executable myTool:
    build:
      output("out/myTool")

# Two outputs from a single artifact, asserting declaration order is
# preserved in the registry.
package multiOutPkg:
  executable multiTool:
    build:
      output("out/multiTool")
      output("out/multiTool.dbg")

suite "DSL-port M4 — artifact-scoped build: block":

  test "executable + build: records exactly one output":
    let outputs = registeredOutputs("execBuildPkg", "myTool")
    check outputs.len == 1

  test "executable + build: records the verbatim output path":
    # ``output("out/myTool")`` runs at module-init time inside the
    # active build context pushed by ``beginBuildContext``. The path
    # appears in the registry exactly as the author wrote it.
    let outputs = registeredOutputs("execBuildPkg", "myTool")
    check outputs[0] == "out/myTool"

  test "multiple outputs preserve declaration order":
    # ``dslPortOutputs`` appends per call; the registry surface is a
    # ``seq[string]``, not a ``Table``, so iteration order matches the
    # source-level call order.
    let outputs = registeredOutputs("multiOutPkg", "multiTool")
    check outputs.len == 2
    check outputs[0] == "out/multiTool"
    check outputs[1] == "out/multiTool.dbg"

  test "artifact-scoped buildAction carries the artifact name":
    # The action record discriminator: ``artifactName`` is the
    # source-level ident text ("myTool"), NOT the empty string the
    # package-level form uses. This is the per-test guarantee that
    # registry rows are disjoint between the two surfaces.
    let actions = registeredBuildActions("execBuildPkg")
    check actions.len == 1
    check actions[0].artifactName == "myTool"
    check actions[0].packageName == "execBuildPkg"
