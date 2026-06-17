## DSL-port M3 acceptance — ``library <name>: <body>`` template.
##
## Pins the contract for M3's v8-style ``library`` template. Same
## sidecar / injection semantics as ``executable`` (see
## ``t_dsl_executable_ident_form.nim``); the only difference is the
## ``DslArtifactKind`` discriminator (``dakLibrary`` vs
## ``dakExecutable``) and that the legacy ``parsePackageDef`` walker
## populates ``pkg.libraries`` instead of ``pkg.executables``.

import std/[unittest]

import repro_project_dsl

# Ident-form library — registers + injects ``let myLib: DslArtifact``.
package libPkg:
  library myLib:
    discard

# String-form library — registers without injecting (no source-level
# ident to inject for ``"my-other-lib"``).
package libStringPkg:
  library "my-other-lib":
    discard

suite "DSL-port M3 — library template":

  test "library myLib registers exactly one artifact":
    let arts = registeredArtifacts("libPkg")
    check arts.len == 1

  test "library artifact name is the source-level ident text":
    let arts = registeredArtifacts("libPkg")
    check arts[0].artifactName == "myLib"

  test "library artifact is tagged as dakLibrary":
    let arts = registeredArtifacts("libPkg")
    check arts[0].kind == dakLibrary

  test "ident-form injects let with the DslArtifact handle":
    # Mirrors the ident-form executable injection: ``myLib`` is
    # referenceable as a ``DslArtifact`` value after the declaration.
    check myLib.artifactName == "myLib"
    check myLib.kind == dakLibrary
    check myLib.packageName == "libPkg"

  test "string-form library records verbatim name without injection":
    let arts = registeredArtifacts("libStringPkg")
    check arts.len == 1
    check arts[0].artifactName == "my-other-lib"
    check arts[0].kind == dakLibrary
