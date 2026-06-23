## Smoke test for the from-source ``sudoSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl = "https://www.sudo.ws/dist/sudo-1.9.16p2.tar.gz"
const ExpectedHash =
  "976aa56d3e3b2a75593307864288addb748c9c136e25d95a9cc699aafa77239c"

suite "sudoSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("sudoSource")
    check spec.packageName == "sudoSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("sudoSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("sudoSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
