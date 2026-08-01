import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.samba.org/pub/rsync/src/rsync-3.4.4.tar.gz"
const ExpectedHash =
  "bd88cf82fa653da32314fb229136407c5c90f80d1758d8f4b091767877d8fa96"

suite "rsyncSource from-source recipe":
  test "pins the official release tarball":
    let spec = registeredFetchSpec("rsyncSource")
    check spec.packageName == "rsyncSource"
    check spec.url == ExpectedUrl
    check spec.hashAlg == dshaSha256
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1
