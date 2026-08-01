import std/unittest

import repro_project_dsl

import ./repro

suite "fontUtilSource from-source recipe":
  test "pins the official freedesktop.org tag":
    let spec = registeredFetchSpec("fontUtilSource")
    check spec.hashHex ==
      "bf8505b74d0159cd11aeaad929d0e262ebb97eacc09eee7665300cf68f8705e5"
    check spec.extractStrip == 1
