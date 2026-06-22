## Smoke test for the from-source ``ktextwidgetsSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "ktextwidgetsSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("ktextwidgetsSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("ktextwidgets-6.10.0.tar.xz")

  test "artifact libKF6TextWidgets registered":
    let arts = registeredArtifacts("ktextwidgetsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6TextWidgets"
