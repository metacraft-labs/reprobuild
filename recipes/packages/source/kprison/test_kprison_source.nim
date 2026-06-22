## Smoke test for the from-source ``kprisonSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "kprisonSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("kprisonSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("prison-6.10.0.tar.xz")

  test "artifact libKF6Prison registered":
    let arts = registeredArtifacts("kprisonSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Prison"
