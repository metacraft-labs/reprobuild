## Smoke test for the from-source ``lvm2Source`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://mirrors.kernel.org/sourceware/lvm2/LVM2.2.03.30.tgz"
const ExpectedHash =
  "ad76abecb8dc887733e06c449cb9add04a3506f9f0780c128817a6e1a17cec05"

suite "lvm2Source — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("lvm2Source")
    check spec.packageName == "lvm2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("lvm2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("lvm2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
