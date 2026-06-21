## Smoke test for the from-source ``kguiaddonsSource`` recipe (M9.R.15h.3).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kguiaddons-6.10.0.tar.xz"

const ExpectedHash =
  "b3be04077313e559c5a8f66491d5d286cefe947aaf7c8937544ce85af4853ffa"

suite "kguiaddonsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kguiaddonsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kguiaddonsSource")
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "artifacts register libKF6GuiAddons":
    let arts = registeredArtifacts("kguiaddonsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6GuiAddons"
    check arts[0].kind == dakLibrary
