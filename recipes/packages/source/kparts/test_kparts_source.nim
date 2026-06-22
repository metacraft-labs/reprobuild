## Smoke test for the from-source ``kpartsSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "kpartsSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("kpartsSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("kparts-6.10.0.tar.xz")

  test "artifact libKF6Parts registered":
    let arts = registeredArtifacts("kpartsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Parts"
