## Smoke test for the from-source ``ianaTzdataSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://data.iana.org/time-zones/releases/tzdata2024b.tar.gz"
const ExpectedHash =
  "70e754db126a8d0db3d16d6b4cb5f7ec1e04d5f261255e4558a67fe92d39e550"

suite "ianaTzdataSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("ianaTzdataSource")
    check spec.packageName == "ianaTzdataSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("ianaTzdataSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant":
    let spec = registeredFetchSpec("ianaTzdataSource")
    check spec.kind == dfkTarball
