import std/unittest

import repro_project_dsl

import ./repro

suite "libpciaccessSource from-source recipe":
  test "pins the official X.Org release":
    let spec = registeredFetchSpec("libpciaccessSource")
    check spec.hashHex ==
      "ae2d080c8394d2b36a54aed270bc826f1438e41e7daf783ca5cff60285529ae2"
    check spec.extractStrip == 1
