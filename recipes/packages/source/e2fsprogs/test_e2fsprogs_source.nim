## Smoke test for the from-source ``e2fsprogsSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.xz"
const ExpectedHash =
  "08242e64ca0e8194d9c1caad49762b19209a06318199b63ce74ae4ef2d74e63c"

suite "e2fsprogsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("e2fsprogsSource")
    check spec.packageName == "e2fsprogsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("e2fsprogsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("e2fsprogsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
