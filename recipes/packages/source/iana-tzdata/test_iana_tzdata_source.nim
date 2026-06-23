## Smoke test for the from-source ``ianaTzdataSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/eggert/tz/archive/refs/tags/2024b.tar.gz"
const ExpectedHash =
  "557c41d8eb5c29387a9d496db87c4aeb4f2ac8a2b6d5f60e869a8cade26e679c"

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
