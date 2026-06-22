## Smoke test for the from-source ``qt6MultimediaSource`` recipe (M9.R.15q.10.5).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "qt6MultimediaSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("qt6MultimediaSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("qtmultimedia-everywhere-src-6.8.1.tar.xz")

  test "artifact libQt6Multimedia registered":
    let arts = registeredArtifacts("qt6MultimediaSource")
    check arts.len == 1
    check arts[0].artifactName == "libQt6Multimedia"
