## Smoke test for the from-source ``kbookmarksSource`` recipe (M9.R.15h.8).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kbookmarks-6.10.0.tar.xz"

const ExpectedHash =
  "891eb12d2b9a2c3cdfbfdba250599c544d7186ce8d1ef07f4fc4cce1d57a945b"

suite "kbookmarksSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kbookmarksSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kbookmarksSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6Bookmarks":
    let arts = registeredArtifacts("kbookmarksSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6Bookmarks"
    check arts[0].kind == dakLibrary
