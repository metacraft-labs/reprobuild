## DSL-port M3 acceptance — ``executable <ident>: <body>`` ident-form.
##
## Pins the contract for M3's v8-style ``executable`` template in its
## ident-form spelling. Two new behaviours over string-form:
##
##   1. The ident's text becomes the artifact name (no kebab
##      translation — M9.R.2c keeps the source-level spelling now
##      that the typed ``Executable`` slot surface has landed).
##   2. The macro additionally emits ``var <ident> {.inject, used.}:
##      Executable`` (M9.R.2c — was ``let <ident>: DslArtifact``) so
##      downstream code in the same module can reference ``<ident>``
##      lexically AND assign a constructor result to it from the
##      package's ``build:`` block (see ``From-Source-Build-Recipes.md``
##      §"Artifact binding by assignment").

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

# Ident-form ``executable myTool: ...`` — registers as artifact +
# injects ``var myTool {.inject, used.}: Executable``.
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

  test "ident-form injects var Executable slot referenceable lexically":
    # M9.R.2c: the slot is now typed ``Executable`` and default-init.
    # If the injection failed, this expression would not compile
    # (undeclared identifier ``refTool``). The registry above carries
    # the kind/name/packageName attribution.
    check refTool.cli.executableName == ""
    check refTool.installPrefix == ""
