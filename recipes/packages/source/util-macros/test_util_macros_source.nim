import std/unittest

import repro_project_dsl

import ./repro

suite "utilMacrosSource from-source recipe":
  test "pins the official freedesktop.org tag":
    let spec = registeredFetchSpec("utilMacrosSource")
    check spec.hashHex ==
      "beac7e00e5996bd0c9d9bd8cf62704583b22dbe8613bd768626b95fcac955744"
    check spec.extractStrip == 1
