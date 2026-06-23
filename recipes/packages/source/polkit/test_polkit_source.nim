## Smoke test for the from-source ``polkitSource`` recipe.
##
## Closes M9.R.26 Gap 3: polkit is now a first-class from-source
## recipe, not an apt fallback.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/polkit-org/polkit/archive/refs/tags/124.tar.gz"

const ExpectedHash =
  "72457d96a0538fd03a3ca96a6bf9b7faf82184d4d67c793eb759168e4fd49e20"

suite "polkitSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("polkitSource")
    check spec.packageName == "polkitSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("polkitSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("polkitSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
