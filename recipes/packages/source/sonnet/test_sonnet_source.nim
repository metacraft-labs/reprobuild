## Smoke test for the from-source ``sonnetSource`` recipe (M9.R.15q.10.3).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/sonnet-6.10.0.tar.xz"

const ExpectedHash =
  "99c0bca563594fd115f31f18ad3264770046290c6695ded0d2aa3c2eddb0d4b7"

suite "sonnetSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("sonnetSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("sonnetSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "artifacts register the two KF6Sonnet libraries":
    let arts = registeredArtifacts("sonnetSource")
    check arts.len == 2
    check arts[0].artifactName == "libKF6SonnetCore"
    check arts[1].artifactName == "libKF6SonnetUi"

  test "versions block records the upstream tag + URL + repo":
    let vs = registeredVersions("sonnetSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
