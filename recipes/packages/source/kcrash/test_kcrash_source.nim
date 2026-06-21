## Smoke test for the from-source ``kcrashSource`` recipe (M9.R.15h.6).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kcrash-6.10.0.tar.xz"

const ExpectedHash =
  "c0329da6ac28aaac824db235e578999e4a487e5cedbb3cec3a6a39e9ee9b5db4"

suite "kcrashSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kcrashSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kcrashSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6Crash":
    let arts = registeredArtifacts("kcrashSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Crash"
    check arts[0].kind == dakLibrary
