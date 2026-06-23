## Smoke test for the from-source ``gdiskSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz"
const ExpectedHash =
  "2abed61bc6d2b9ec498973c0440b8b804b7a72d7144069b5a9209b2ad693a282"

suite "gdiskSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.packageName == "gdiskSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
