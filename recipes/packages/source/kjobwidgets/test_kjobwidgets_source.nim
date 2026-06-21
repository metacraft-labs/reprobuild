## Smoke test for the from-source ``kjobwidgetsSource`` recipe (M9.R.15h.5).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kjobwidgets-6.10.0.tar.xz"

const ExpectedHash =
  "ee3ff5d21c8484959d0af1976a7c1bab01f4368414df2ebb2cb8540b3c28691b"

suite "kjobwidgetsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kjobwidgetsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kjobwidgetsSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6JobWidgets":
    let arts = registeredArtifacts("kjobwidgetsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6JobWidgets"
    check arts[0].kind == dakLibrary
