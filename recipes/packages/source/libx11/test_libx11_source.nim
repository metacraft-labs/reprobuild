import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.x.org/releases/individual/lib/libX11-1.8.12.tar.xz"

const ExpectedHash =
  "fa026f9bb0124f4d6c808f9aef4057aad65e7b35d8ff43951cef0abe06bb9a9a"

suite "libx11Source source recipe":

  test "fetches the pinned X.Org release":
    let spec = registeredFetchSpec("libx11Source")
    check spec.packageName == "libx11Source"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.extractStrip == 1

  test "declares the Xlib build closure":
    check registeredBuildDeps("libx11Source") == @[
      "xorgproto",
      "xtrans",
      "libxcb >=1.11.1",
    ]
    check registeredRuntimeDeps("libx11Source") == @[
      "libxcb >=1.11.1",
    ]
    let native = registeredNativeBuildDeps("libx11Source")
    check "make" in native
    check "gcc >=11" in native
    check "pkg-config" in native
