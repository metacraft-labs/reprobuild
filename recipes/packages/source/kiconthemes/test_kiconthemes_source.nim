## Smoke test for the from-source ``kiconthemesSource`` recipe (M9.R.15j.4).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kiconthemes-6.10.0.tar.xz"

const ExpectedHash =
  "15807e785183c048810af0141b3a560085f2bbf00f3a21fe962eb37a673f9314"

suite "kiconthemesSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kiconthemesSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kiconthemesSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6IconThemes":
    let arts = registeredArtifacts("kiconthemesSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6IconThemes"
    check arts[0].kind == dakLibrary
