## DSL-port M3 acceptance — ``library <name>: <body>`` template.
##
## Pins the contract for M3's v8-style ``library`` template. Same
## sidecar / injection semantics as ``executable`` (see
## ``t_dsl_executable_ident_form.nim``); the only difference is the
## ``DslArtifactKind`` discriminator (``dakLibrary`` vs
## ``dakExecutable``) and that the legacy ``parsePackageDef`` walker
## populates ``pkg.libraries`` instead of ``pkg.executables``.
##
## DSL-port M9.R.2c update: the slot variable injected for the
## ident-form is now typed ``Library`` (was ``DslArtifact``). The
## per-package registry sidecar still records the artifact metadata
## the same way; this test reads the registry to verify the
## kind/name/packageName attribution. The slot binding itself is now
## a default-initialised ``Library`` (declared = false) until the
## recipe assigns a constructor result to it from the ``build:``
## block.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

# Ident-form library — registers + injects ``var myLib: Library``.
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

  test "ident-form injects var Library slot referenceable lexically":
    # M9.R.2c: the slot is now typed ``Library`` and default-init
    # (``api.declared == false``). Reading the slot must compile;
    # the registry above carries the kind/name/packageName attribution.
    check myLib.api.declared == false
    check myLib.soname == ""
    check myLib.linkKind == llkUnset

  test "string-form library records verbatim name without injection":
    let arts = registeredArtifacts("libStringPkg")
    check arts.len == 1
    check arts[0].artifactName == "my-other-lib"
    check arts[0].kind == dakLibrary
