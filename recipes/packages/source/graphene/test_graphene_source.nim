## Smoke test for the from-source ``grapheneSource`` recipe (M9.R.15b).
##
## Coverage:
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * SINGLE library artifact registration (M3) — ``libGraphene``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz"

const ExpectedHash =
  "922dc109d2dc5dc56617a29bd716c79dd84db31721a8493a13a5f79109a4a4ed"

suite "grapheneSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("grapheneSource")
    check spec.packageName == "grapheneSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("grapheneSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("grapheneSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "single library artifact libGraphene registered as dakLibrary":
    let arts = registeredArtifacts("grapheneSource")
    check arts.len == 1
    check arts[0].packageName == "grapheneSource"
    check arts[0].artifactName == "libGraphene"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("grapheneSource")
    check vs.len == 1
    check vs[0].version == "1.10.8"
    check vs[0].sourceRevision == "1.10.8"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository == "https://github.com/ebassi/graphene"
