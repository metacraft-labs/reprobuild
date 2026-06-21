## Smoke test for the from-source ``kauthSource`` recipe (M9.R.15p.4.1).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kauth-6.10.0.tar.xz"

const ExpectedHash =
  "be25601b91b129a48e497231be2513a1eb8c9707a82d38395561656d1df10988"

suite "kauthSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kauthSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kauthSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("kauthSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libKF6AuthCore":
    let arts = registeredArtifacts("kauthSource")
    check arts.len == 1
    check arts[0].packageName == "kauthSource"
    check arts[0].artifactName == "libKF6AuthCore"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("kauthSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kauth-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kauth"
