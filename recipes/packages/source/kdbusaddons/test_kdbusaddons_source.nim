## Smoke test for the from-source ``kdbusaddonsSource`` recipe (M9.R.15h.7).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kdbusaddons-6.10.0.tar.xz"

const ExpectedHash =
  "e88bfaa6a10f80d9f7b2116281c4485213984caed555ac68557bb53ee88bbb32"

suite "kdbusaddonsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kdbusaddonsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kdbusaddonsSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6DBusAddons":
    let arts = registeredArtifacts("kdbusaddonsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6DBusAddons"
    check arts[0].kind == dakLibrary
