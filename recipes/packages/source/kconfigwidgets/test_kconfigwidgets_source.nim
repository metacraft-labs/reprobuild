## Smoke test for the from-source ``kconfigwidgetsSource`` recipe (M9.R.15j.4).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kconfigwidgets-6.10.0.tar.xz"

const ExpectedHash =
  "5cb17bcafaae3eefc144fb1014f14cb9998c9e13b714808d940ab20d9c0fb51c"

suite "kconfigwidgetsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kconfigwidgetsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kconfigwidgetsSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6ConfigWidgets":
    let arts = registeredArtifacts("kconfigwidgetsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6ConfigWidgets"
    check arts[0].kind == dakLibrary
