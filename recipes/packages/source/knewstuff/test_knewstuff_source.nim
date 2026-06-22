## Smoke test for the from-source ``knewstuffSource`` recipe (M9.R.15h.12).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/knewstuff-6.10.0.tar.xz"

const ExpectedHash =
  "81cb5ea54fe03d27f80a481dde18a767ca1a95267403bd87483cfdd81981e4e7"

suite "knewstuffSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("knewstuffSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("knewstuffSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register two KF6NewStuff libraries":
    ## M9.R.15q.10.2 — knewstuff 6.10.0 ships the legacy ``libKF6NewStuff``
    ## widget facade renamed as ``libKF6NewStuffWidgets`` (Core unchanged).
    let arts = registeredArtifacts("knewstuffSource")
    check arts.len == 2
    check arts[0].artifactName == "libKF6NewStuffWidgets"
    check arts[1].artifactName == "libKF6NewStuffCore"
