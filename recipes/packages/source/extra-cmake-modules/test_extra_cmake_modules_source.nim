## Smoke test for the from-source ``extraCmakeModulesSource`` recipe (M9.R.15h.14).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/extra-cmake-modules-6.10.0.tar.xz"

const ExpectedHash =
  "506989a0d400913403e669c1912238db053cd6b38dff74b17e2e6f879c79cca0"

suite "extraCmakeModulesSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("extraCmakeModulesSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("extraCmakeModulesSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "no library or executable artifacts (pure CMake module collection)":
    let arts = registeredArtifacts("extraCmakeModulesSource")
    check arts.len == 0

  test "versions block records the upstream tag + URL + repo":
    let vs = registeredVersions("extraCmakeModulesSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/extra-cmake-modules"
