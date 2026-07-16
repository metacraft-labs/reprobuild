import std/unittest

import repro_project_dsl

import ./repro

const
  ExpectedUrl =
    "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz"
  ExpectedHash =
    "c25a4838fc8e4c1c8aacb8bd620edb3084a3d63bf8987fdad3ca2758c63240f9"

suite "poptSource from-source recipe":
  test "fetch metadata pins the upstream release":
    let spec = registeredFetchSpec("poptSource")
    check spec.packageName == "poptSource"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "build tools and artifact are registered":
    check registeredNativeBuildDeps("poptSource") == @[
      "make", "gcc >=11", "pkg-config",
    ]
    let artifacts = registeredArtifacts("poptSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "libPopt"
    check artifacts[0].kind == dakLibrary
