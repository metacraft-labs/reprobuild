## Smoke test for the from-source ``liboggSource`` recipe (M9.R.15p.2.2).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz"

const ExpectedHash =
  "c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705"

suite "liboggSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("liboggSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("liboggSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("liboggSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libOgg":
    let arts = registeredArtifacts("liboggSource")
    check arts.len == 1
    check arts[0].artifactName == "libOgg"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("liboggSource")
    check vs.len == 1
    check vs[0].version == "1.3.5"
    check vs[0].sourceRevision == "v1.3.5"
    check vs[0].sourceUrl ==
      "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz"
