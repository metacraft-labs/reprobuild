## Smoke test for the from-source ``libepoxySource`` recipe (M9.R.15b).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz"

const ExpectedHash =
  "a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15"

suite "libepoxySource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("libepoxySource")
    check spec.packageName == "libepoxySource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("libepoxySource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("libepoxySource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "single library artifact libEpoxy registered as dakLibrary":
    let arts = registeredArtifacts("libepoxySource")
    check arts.len == 1
    check arts[0].packageName == "libepoxySource"
    check arts[0].artifactName == "libEpoxy"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("libepoxySource")
    check vs.len == 1
    check vs[0].version == "1.5.10"
    check vs[0].sourceRevision == "1.5.10"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository == "https://github.com/anholt/libepoxy"
