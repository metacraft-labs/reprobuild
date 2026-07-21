## Smoke test for the from-source ``qt6SpeechSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "qt6SpeechSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("qt6SpeechSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("qtspeech-everywhere-src-6.8.1.tar.xz")

  test "artifact libQt6TextToSpeech registered":
    let arts = registeredArtifacts("qt6SpeechSource")
    check arts.len == 1
    check arts[0].artifactName == "libQt6TextToSpeech"

  test "build dependencies include the required Qt modules":
    let deps = registeredBuildDeps("qt6SpeechSource")
    check "qt6-base >=6.8" in deps
    check "qt6-declarative >=6.8" in deps
    check "qt6-multimedia >=6.8" in deps

  test "runtime closure includes the required Qt modules":
    check registeredRuntimeDeps("qt6SpeechSource") == @[
      "qt6-base >=6.8",
      "qt6-declarative >=6.8",
      "qt6-multimedia >=6.8",
    ]
