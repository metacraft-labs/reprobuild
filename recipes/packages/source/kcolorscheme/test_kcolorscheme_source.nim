## Smoke test for the from-source ``kcolorschemeSource`` recipe (M9.R.15j.4).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kcolorscheme-6.10.0.tar.xz"

const ExpectedHash =
  "f070ed593f1d4010af5a56e247532be96a2c7ca9befc922b084c16215af79bdf"

suite "kcolorschemeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kcolorschemeSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kcolorschemeSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6ColorScheme":
    let arts = registeredArtifacts("kcolorschemeSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6ColorScheme"
    check arts[0].kind == dakLibrary
