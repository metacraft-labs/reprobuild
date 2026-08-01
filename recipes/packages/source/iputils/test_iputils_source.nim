import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://github.com/iputils/iputils/releases/download/20250605/iputils-20250605.tar.xz"
const ExpectedHash =
  "6f213700dbf96b5cc4499ca70cb15ecd69c09f405b06785bb4a1a10b572b6276"

suite "iputilsSource from-source recipe":
  test "pins the official release asset":
    let spec = registeredFetchSpec("iputilsSource")
    check spec.packageName == "iputilsSource"
    check spec.url == ExpectedUrl
    check spec.hashAlg == dshaSha256
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1
