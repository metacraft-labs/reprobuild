## Smoke test for the from-source ``kwindowsystemSource`` recipe (M9.R.15h.9).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kwindowsystem-6.10.0.tar.xz"

const ExpectedHash =
  "046b7aa2247811323e48b629884b824a6ffec475df2316256e7ff0b9df677944"

suite "kwindowsystemSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kwindowsystemSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kwindowsystemSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6WindowSystem":
    let arts = registeredArtifacts("kwindowsystemSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6WindowSystem"
    check arts[0].kind == dakLibrary
