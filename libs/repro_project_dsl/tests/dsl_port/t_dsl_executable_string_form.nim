## DSL-port M3 acceptance — ``executable "<name>": <body>`` string-form.
##
## Pins the contract for M3's v8-style ``executable`` template in its
## string-form spelling. The ``package`` macro records the artifact
## into the ``dslPortArtifactRegistry`` sidecar (see
## ``libs/repro_project_dsl/src/repro_project_dsl/dsl_port_runtime.nim``)
## while leaving the legacy ``parsePackageDef`` chain in place — see
## the comment above ``emitM3Artifacts`` in ``macros_b.nim`` for the
## ownership decision.
##
## Public surface introduced by M3:
##
##   * ``DslArtifactKind`` — enum (``dakExecutable`` / ``dakLibrary`` /
##     ``dakFiles``) discriminating the three artifact-template families.
##   * ``DslArtifact`` — per-artifact record (``packageName`` +
##     ``artifactName`` + ``kind`` + ``bodyRepr``).
##   * ``registerArtifact*(packageName, artifact)`` — the runtime call
##     M3's lowerer emits, one per recognised ``executable:`` /
##     ``library:`` / ``files:`` block.
##   * ``registeredArtifacts*(packageName): seq[DslArtifact]`` — the
##     host-side accessor. Returns the per-package list in registration
##     order.
##   * ``resetDslPortArtifactState*()`` — clears all artifact
##     registrations across packages so test fixtures don't leak across
##     cases.
##
## String-form ``executable "<name>":`` does NOT inject a Nim binding
## (there is no source-level identifier to inject); the registry
## append is the sole emission. The artifact name is the string
## literal verbatim — no kebab translation, no normalisation.

import std/[unittest]

import repro_project_dsl

# The artifact-internal body is recorded verbatim at macro-expansion
# time as a string (see ``DslArtifact.bodyRepr``). M3 records ``cli:``
# and ``build:`` sub-blocks WITHOUT lowering them — that work is M4+.
package execStringPkg:
  executable "myTool":
    discard

suite "DSL-port M3 — executable string-form":

  test "executable \"myTool\" registers exactly one artifact":
    let arts = registeredArtifacts("execStringPkg")
    check arts.len == 1

  test "registered artifact carries the verbatim string-form name":
    let arts = registeredArtifacts("execStringPkg")
    check arts[0].artifactName == "myTool"

  test "registered artifact is tagged as dakExecutable":
    let arts = registeredArtifacts("execStringPkg")
    check arts[0].kind == dakExecutable

  test "registered artifact carries the source-level packageName":
    let arts = registeredArtifacts("execStringPkg")
    check arts[0].packageName == "execStringPkg"

  test "querying an unregistered package yields the empty seq":
    # Symmetric with the M2 versions accessor: a package that never
    # declared an ``executable:`` / ``library:`` / ``files:`` block
    # returns the empty seq rather than raising. This makes the
    # accessor safe to call from cross-package code that does not know
    # whether the foreign package opted into the artifact surface.
    let unknown = registeredArtifacts("noSuchPackageEverDeclared")
    check unknown.len == 0
