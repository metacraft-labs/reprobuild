## Smoke test for the from-source ``krunnerSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "krunnerSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("krunnerSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("krunner-6.10.0.tar.xz")

  test "artifact libKF6Runner registered":
    let arts = registeredArtifacts("krunnerSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Runner"
