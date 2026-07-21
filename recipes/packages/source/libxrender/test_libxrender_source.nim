import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "libxrenderSource source recipe":
  test "pins the X.Org release":
    let spec = registeredFetchSpec("libxrenderSource")
    check spec.hashHex == "b832128da48b39c8d608224481743403ad1691bf4e554e4be9c174df171d1b97"
    check spec.url.endsWith("libXrender-0.9.12.tar.xz")

  test "declares the source X11 closure":
    check registeredBuildDeps("libxrenderSource") == @["xorgproto", "libx11 >=1.8"]
    check registeredRuntimeDeps("libxrenderSource") == @["libx11 >=1.8"]
