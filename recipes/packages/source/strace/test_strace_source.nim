import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl = "https://strace.io/files/6.16/strace-6.16.tar.xz"
const ExpectedHash =
  "3d7aee7e4f044b2f67f3d51a8a76eda18076e9fb2774de54ac351d777d4ebffa"

suite "straceSource from-source recipe":
  test "pins the official release tarball":
    let spec = registeredFetchSpec("straceSource")
    check spec.packageName == "straceSource"
    check spec.url == ExpectedUrl
    check spec.hashAlg == dshaSha256
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1
