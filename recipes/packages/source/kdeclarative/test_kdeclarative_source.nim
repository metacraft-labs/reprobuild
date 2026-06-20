## Smoke test for the from-source ``kdeclarativeSource`` recipe (M9.R.15h.13).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kdeclarative-6.10.0.tar.xz"

const ExpectedHash =
  "db9eb2b5e615b484949e41ac5a05c5cea136e231d15a3de203902cedcdfd9e73"

suite "kdeclarativeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kdeclarativeSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kdeclarativeSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6Declarative":
    let arts = registeredArtifacts("kdeclarativeSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Declarative"
    check arts[0].kind == dakLibrary
