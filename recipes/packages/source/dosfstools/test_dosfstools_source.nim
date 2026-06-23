## Smoke test for the from-source ``dosfstoolsSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz"
const ExpectedHash =
  "64926eebf90092dca21b14259a5301b7b98e7b1943e8a201c7d726084809b527"

suite "dosfstoolsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("dosfstoolsSource")
    check spec.packageName == "dosfstoolsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("dosfstoolsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("dosfstoolsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
