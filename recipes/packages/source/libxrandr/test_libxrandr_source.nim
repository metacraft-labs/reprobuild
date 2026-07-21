import std/[strutils, unittest]

import repro_project_dsl

import ./repro

suite "libxrandrSource source recipe":
  test "pins the X.Org release":
    let spec = registeredFetchSpec("libxrandrSource")
    check spec.hashHex == "1ad5b065375f4a85915aa60611cc6407c060492a214d7f9daf214be752c3b4d3"
    check spec.url.endsWith("libXrandr-1.5.4.tar.xz")

  test "declares the source extension closure":
    check registeredBuildDeps("libxrandrSource") == @[
      "xorgproto", "libx11 >=1.8", "libxext >=1.3", "libxrender >=0.9"]
    check registeredRuntimeDeps("libxrandrSource") == @[
      "libx11 >=1.8", "libxext >=1.3", "libxrender >=0.9"]
