import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "libxextSource source recipe":
  test "pins the X.Org release":
    let spec = registeredFetchSpec("libxextSource")
    check spec.hashHex == "edb59fa23994e405fdc5b400afdf5820ae6160b94f35e3dc3da4457a16e89753"
    check spec.url.endsWith("libXext-1.3.6.tar.xz")

  test "declares the source X11 closure":
    check registeredBuildDeps("libxextSource") == @[
      "xorgproto", "libx11 >=1.8", "libxau"]
    check registeredRuntimeDeps("libxextSource") == @["libx11 >=1.8"]
