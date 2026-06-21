## Smoke test for the from-source ``kitemmodelsSource`` recipe
## (M9.R.15q.1.7).

import std/[unittest]

import repro_project_dsl
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kitemmodels-6.10.0.tar.xz"

const ExpectedHash =
  "83859a4aee67bf5e768a93325422264cb9e847013f281c5cb02e631c3b3b0007"

suite "kitemmodelsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kitemmodelsSource")
    check spec.packageName == "kitemmodelsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kitemmodelsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("kitemmodelsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libKF6ItemModels":
    let arts = registeredArtifacts("kitemmodelsSource")
    check arts.len == 1
    check arts[0].packageName == "kitemmodelsSource"
    check arts[0].artifactName == "libKF6ItemModels"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("kitemmodelsSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kitemmodels-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kitemmodels"
