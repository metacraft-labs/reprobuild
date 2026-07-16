## Smoke test for the from-source ``cryptsetupSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://gitlab.com/cryptsetup/cryptsetup/-/archive/v2.7.5/cryptsetup-v2.7.5.tar.gz"
const ExpectedHash =
  "da290c93b17c913540b97ca177f107e22032c56e5371076d2d30e97f1fffa4cf"

suite "cryptsetupSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("cryptsetupSource")
    check spec.packageName == "cryptsetupSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("cryptsetupSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("cryptsetupSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "build dependencies cover source runtime libraries":
    check registeredNativeBuildDeps("cryptsetupSource") == @[
      "autoconf", "automake", "libtool", "m4", "make", "gcc >=11",
      "pkg-config", "gettext",
    ]
    check registeredBuildDeps("cryptsetupSource") == @[
      "libgcrypt", "json-c", "popt", "lvm2", "util-linux",
    ]

  test "tools and shared library are registered":
    let artifacts = registeredArtifacts("cryptsetupSource")
    check artifacts.len == 4
    check artifacts[0].artifactName == "cryptsetup"
    check artifacts[1].artifactName == "veritysetup"
    check artifacts[2].artifactName == "integritysetup"
    check artifacts[3].artifactName == "libCryptsetup"
    check artifacts[0].kind == dakExecutable
    check artifacts[1].kind == dakExecutable
    check artifacts[2].kind == dakExecutable
    check artifacts[3].kind == dakLibrary
