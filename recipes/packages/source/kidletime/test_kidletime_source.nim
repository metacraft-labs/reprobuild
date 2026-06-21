## Smoke test for the from-source ``kidletimeSource`` recipe (M9.R.15h.10).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kidletime-6.10.0.tar.xz"

const ExpectedHash =
  "fa25fe866aefd4536022142822ce9856f7a85ffa95070980527de9b31eab0988"

suite "kidletimeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kidletimeSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kidletimeSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6IdleTime":
    let arts = registeredArtifacts("kidletimeSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6IdleTime"
    check arts[0].kind == dakLibrary
