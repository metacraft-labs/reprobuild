## Smoke test for the from-source ``ktexteditorSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "ktexteditorSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("ktexteditorSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("ktexteditor-6.10.0.tar.xz")

  test "artifact libKF6TextEditor registered":
    let arts = registeredArtifacts("ktexteditorSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6TextEditor"

  test "declares direct Qt Qml and speech dependencies":
    let deps = registeredBuildDeps("ktexteditorSource")
    check "qt6-declarative >=6.8" in deps
    check "qt6-multimedia >=6.8" in deps
    check "qt6-speech >=6.8" in deps
    check "kbookmarks >=6.0" in deps
    check "kservice >=6.0" in deps
    check "kcodecs >=6.0" in deps
    check "kglobalaccel >=6.0" in deps
    check "kauth >=6.0" in deps
