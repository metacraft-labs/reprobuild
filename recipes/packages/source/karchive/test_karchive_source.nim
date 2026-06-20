## Smoke test for the from-source ``karchiveSource`` recipe (M9.R.15h.2).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/karchive-6.10.0.tar.xz"

const ExpectedHash =
  "ac5160c19dd110bbdadeba9c5355cbfd3b5c1bd00ce3dbdc4a085776698c8a48"

suite "karchiveSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("karchiveSource")
    check spec.packageName == "karchiveSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("karchiveSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("karchiveSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libKF6Archive":
    let arts = registeredArtifacts("karchiveSource")
    check arts.len == 1
    check arts[0].packageName == "karchiveSource"
    check arts[0].artifactName == "libKF6Archive"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repo":
    let vs = registeredVersions("karchiveSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/karchive"
