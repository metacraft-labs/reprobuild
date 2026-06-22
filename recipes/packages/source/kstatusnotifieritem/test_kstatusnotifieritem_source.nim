## Smoke test for the from-source ``kstatusnotifieritemSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "kstatusnotifieritemSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("kstatusnotifieritemSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("kstatusnotifieritem-6.10.0.tar.xz")

  test "artifact libKF6StatusNotifierItem registered":
    let arts = registeredArtifacts("kstatusnotifieritemSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6StatusNotifierItem"
