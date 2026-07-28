import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.nano-editor.org/dist/latest/nano-9.1.tar.xz"
const ExpectedHash =
  "5f47764274cb7532349ce0aa20ec10f1e8e851a6e9fa3eb66812c43d196db042"

suite "nanoSource from-source recipe":
  test "pins the official release tarball":
    let spec = registeredFetchSpec("nanoSource")
    check spec.packageName == "nanoSource"
    check spec.url == ExpectedUrl
    check spec.hashAlg == dshaSha256
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1
