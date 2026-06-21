## Smoke test for the from-source ``kitemviewsSource`` recipe (M9.R.15j.2).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kitemviews-6.10.0.tar.xz"

const ExpectedHash =
  "8b15ff5719ea65e9d0c722eea6412e312d05d9da49c872caf9d97d329d56d76d"

suite "kitemviewsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kitemviewsSource")
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kitemviewsSource")
    check spec.hashHex == ExpectedHash

  test "artifacts register libKF6ItemViews":
    let arts = registeredArtifacts("kitemviewsSource")
    check arts.len == 1
    check arts[0].artifactName == "libKF6ItemViews"
    check arts[0].kind == dakLibrary
