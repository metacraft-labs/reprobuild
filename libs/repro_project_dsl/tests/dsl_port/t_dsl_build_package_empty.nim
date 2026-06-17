## DSL-port M4 acceptance — package-level ``build:`` block.
##
## Pins the contract for M4's v8-style package-level ``build:`` block.
## The ``package`` macro detects every top-level ``build:`` entry in the
## body (already classified as ``soM4Build`` by ``classifyPackageSections``
## per M3's section-ownership discriminator), then for each entry emits
## a module-init block that:
##
##   1. Calls ``registerBuildAction(packageName, "", bodyRepr)`` so the
##      runtime sidecar (see ``dsl_port_runtime.nim``) records the
##      package-level build action with an empty ``artifactName`` and a
##      verbatim ``bodyRepr`` for diagnostic round-trip.
##   2. Wraps the user's verbatim build body in a
##      ``beginBuildContext(packageName, "") / try / finally
##      endBuildContext()`` pair so any ``output(path)`` calls reached
##      from inside the body record against the active context.
##
## The body itself is captured as the partitioned section's actual
## ``NimNode`` (re-walked at compile time via ``classifyPackageSections``
## — never via ``parseStmt(bodyRepr)``) so author syntax (any Nim
## statement that compiles at module top level) survives expansion
## unchanged.
##
## Why "package-level" deserves a dedicated fixture: the M4 lowerer
## emits a DIFFERENT statement shape from the artifact-scoped build:
## here ``artifactName`` is the empty string, distinguishing the
## registry record from artifact-scoped recordings (``t_dsl_build_with
## _executable.nim``, ``t_dsl_build_records_output_for_library.nim``).
## Tests in this file MUST observe the empty-artifact case directly.

import std/[strutils, unittest]

import repro_project_dsl

# Package-level ``build:`` block with a single trivial discard. The
# legacy ``parsePackageDef`` chain accepts this body (the ``build``
# section is one of the recognised heads; ``collectBuildStatements``
# would also pick it up for the ``buildXxxPackage*()`` proc in
# provider mode). M4 ADDS a runtime registration in the
# ``dslPortBuildActions`` sidecar without disturbing the legacy
# emission — see the ownership comment above ``emitM4BuildActions``
# in ``macros_b.nim``.
package buildPkg:
  build:
    discard "M4 package build body"

suite "DSL-port M4 — package-level build: block":

  test "package build: registers exactly one buildAction":
    # M4's emitter walks ``classifyPackageSections``'s output and
    # emits one ``registerBuildAction`` call per ``soM4Build`` entry.
    # The empty-artifact case is the package-level form.
    let actions = registeredBuildActions("buildPkg")
    check actions.len == 1

  test "package build: action carries the source-level packageName":
    let actions = registeredBuildActions("buildPkg")
    check actions[0].packageName == "buildPkg"

  test "package build: action carries the empty artifactName":
    # The empty string discriminates the package-level form from the
    # artifact-scoped form (``executable myTool: build: ...`` records
    # with ``artifactName == "myTool"``). Callers must NOT collapse
    # these — the registry rows are disjoint by design.
    let actions = registeredBuildActions("buildPkg")
    check actions[0].artifactName == ""

  test "package build: action carries the verbatim body repr":
    # ``bodyRepr`` is the diagnostic surface — the actual NimNode the
    # M4 emitter re-walks lives in the partitioned section list at
    # compile time. The repr is captured at macro-expansion time so
    # downstream diagnostics can show what was recorded without
    # re-parsing.
    let actions = registeredBuildActions("buildPkg")
    check actions[0].bodyRepr.contains("M4 package build body")

  test "querying an unregistered package yields the empty seq":
    # Symmetric with M2's ``registeredVersions`` and M3's
    # ``registeredArtifacts``: a package that never declared a
    # ``build:`` block returns the empty seq rather than raising.
    let unknown = registeredBuildActions("noSuchPackageEverDeclared")
    check unknown.len == 0
