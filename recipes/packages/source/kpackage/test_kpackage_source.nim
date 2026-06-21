## Smoke test for the from-source ``kpackageSource`` recipe (M9.R.15h.11).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kpackage-6.10.0.tar.xz"

const ExpectedHash =
  "0f49c1cdb49e01c6dce372abbc9814ccbd74b7f2b130c7310674345e3498cec1"

suite "kpackageSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kpackageSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kpackageSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6Package":
    let arts = registeredArtifacts("kpackageSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Package"
    check arts[0].kind == dakLibrary
