## DSL-port M3 acceptance — ``executable <ident>: <body>`` ident-form.
##
## Pins the contract for M3's v8-style ``executable`` template in its
## ident-form spelling. Two new behaviours over string-form:
##
##   1. The ident's text becomes the artifact name (no kebab
##      translation — M4+ may widen this when the typed
##      ``Executable[name]`` surface lands, but M3 keeps the
##      source-level spelling).
##   2. The macro additionally emits ``let <ident> {.inject, used.}:
##      DslArtifact = DslArtifact(...)`` so downstream code in the
##      same module can reference ``<ident>`` lexically. M4+ may widen
##      the injected type from ``DslArtifact`` to v8's typed
##      ``Executable[name]`` without renaming the symbol.

import std/[unittest]

import repro_project_dsl

# Ident-form ``executable myTool: ...`` — registers as artifact +
# injects ``let myTool {.inject, used.}: DslArtifact = ...``.
package execIdentPkg:
  executable myTool:
    discard

# Separate package whose ident-form binding we reference from outside
# the ``package`` macro body to verify the injection took. Two
# packages so each test reads a known-clean fixture.
package execRefPkg:
  executable refTool:
    discard

suite "DSL-port M3 — executable ident-form":

  test "executable myTool registers exactly one artifact":
    let arts = registeredArtifacts("execIdentPkg")
    check arts.len == 1

  test "ident-form artifact name is the source-level ident text":
    # No kebab translation: ``myTool`` stays ``myTool``. The decision
    # is documented in ``m3ArtifactNameNode`` (macros_b.nim).
    let arts = registeredArtifacts("execIdentPkg")
    check arts[0].artifactName == "myTool"

  test "ident-form artifact is tagged as dakExecutable":
    let arts = registeredArtifacts("execIdentPkg")
    check arts[0].kind == dakExecutable

  test "ident-form injects let so the binding is referenceable":
    # The package macro emits
    #   let refTool {.inject, used.}: DslArtifact = DslArtifact(...)
    # at module scope. If the injection failed, this expression would
    # not compile (undeclared identifier ``refTool``).
    check refTool.artifactName == "refTool"
    check refTool.kind == dakExecutable
    check refTool.packageName == "execRefPkg"
