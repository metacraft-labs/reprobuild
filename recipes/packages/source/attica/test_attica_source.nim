## Smoke test for the from-source ``atticaSource`` recipe (M9.R.15q.10.1).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/attica-6.10.0.tar.xz"

const ExpectedHash =
  "f36c2eacbcad8c08036e9f7525144bec9f7c5d86f1150d49f9db9e3dc14abf45"

suite "atticaSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("atticaSource")
    check spec.packageName == "atticaSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("atticaSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("atticaSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libKF6Attica":
    let arts = registeredArtifacts("atticaSource")
    check arts.len == 1
    check arts[0].packageName == "atticaSource"
    check arts[0].artifactName == "libKF6Attica"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repo":
    let vs = registeredVersions("atticaSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/attica"
