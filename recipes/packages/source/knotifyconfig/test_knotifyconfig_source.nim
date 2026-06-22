## Smoke test for the from-source ``knotifyconfigSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "knotifyconfigSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("knotifyconfigSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("knotifyconfig-6.10.0.tar.xz")

  test "artifact libKF6NotifyConfig registered":
    let arts = registeredArtifacts("knotifyconfigSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6NotifyConfig"
