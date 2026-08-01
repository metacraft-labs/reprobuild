import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.x.org/releases/individual/lib/libxcvt-0.1.3.tar.xz"

const ExpectedHash =
  "a929998a8767de7dfa36d6da4751cdbeef34ed630714f2f4a767b351f2442e01"

suite "libxcvtSource source recipe":

  test "fetches the pinned X.Org release":
    let spec = registeredFetchSpec("libxcvtSource")
    check spec.packageName == "libxcvtSource"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.extractStrip == 1

  test "is a self-contained Meson leaf":
    check registeredBuildDeps("libxcvtSource").len == 0
    check registeredRuntimeDeps("libxcvtSource").len == 0
    let native = registeredNativeBuildDeps("libxcvtSource")
    check "meson >=0.40" in native
    check "ninja >=1.10" in native
    check "gcc >=11" in native
