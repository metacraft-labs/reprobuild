## Smoke test for the from-source ``kcodecsSource`` recipe (M9.R.15j.2).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kcodecs-6.10.0.tar.xz"

const ExpectedHash =
  "96183ffbb18502cd67b6fc78ac286e233ef46ee0d713ee1df2cb4c138f2141a0"

suite "kcodecsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kcodecsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kcodecsSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6Codecs":
    let arts = registeredArtifacts("kcodecsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Codecs"
    check arts[0].kind == dakLibrary
