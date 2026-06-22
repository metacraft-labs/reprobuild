## Smoke test for the from-source ``kwalletSource`` recipe (M9.R.15q.10.3).

import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "kwalletSource — from-source recipe smoke test":

  test "fetch spec is registered":
    let spec = registeredFetchSpec("kwalletSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("kwallet-6.10.0.tar.xz")

  test "artifact libKF6Wallet registered":
    let arts = registeredArtifacts("kwalletSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Wallet"
