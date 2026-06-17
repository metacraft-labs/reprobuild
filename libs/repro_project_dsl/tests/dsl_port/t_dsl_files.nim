## DSL-port M3 acceptance — ``files <name>: <body>`` template.
##
## Pins the contract for M3's v8-style ``files`` template. The legacy
## ``parsePackageDef`` walker has NO ``files:`` arm — M3 is the sole
## consumer of ``files:`` entries; nothing is double-emitted.
##
## Same sidecar / injection semantics as ``executable`` and ``library``
## (see ``t_dsl_executable_ident_form.nim``); the discriminator is
## ``dakFiles``.

import std/[unittest]

import repro_project_dsl

# Ident-form files — registers + injects ``let myFiles: DslArtifact``.
package filesPkg:
  files myFiles:
    discard

# Multi-artifact package: a single recipe declares two ``files:``
# entries. The registry preserves declaration order.
package multiFilesPkg:
  files firstSet:
    discard
  files secondSet:
    discard

suite "DSL-port M3 — files template":

  test "files myFiles registers exactly one artifact":
    let arts = registeredArtifacts("filesPkg")
    check arts.len == 1

  test "files artifact name is the source-level ident text":
    let arts = registeredArtifacts("filesPkg")
    check arts[0].artifactName == "myFiles"

  test "files artifact is tagged as dakFiles":
    let arts = registeredArtifacts("filesPkg")
    check arts[0].kind == dakFiles

  test "ident-form injects let with the DslArtifact handle":
    check myFiles.artifactName == "myFiles"
    check myFiles.kind == dakFiles
    check myFiles.packageName == "filesPkg"

  test "multiple files entries preserve declaration order":
    let arts = registeredArtifacts("multiFilesPkg")
    check arts.len == 2
    check arts[0].artifactName == "firstSet"
    check arts[1].artifactName == "secondSet"
    check arts[0].kind == dakFiles
    check arts[1].kind == dakFiles
