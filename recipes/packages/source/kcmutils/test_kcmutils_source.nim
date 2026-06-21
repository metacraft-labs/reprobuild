## Smoke test for the from-source ``kcmutilsSource`` recipe
## (M9.R.15q.1.3).
##
## Pins the M9.H + M3 registry behaviour on the recipe that closes the
## ``KF6KCMUtils`` find_package gap on plasma-framework. Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 + algorithm +
##     kind discriminant + extractStrip.
##   * SINGLE library artifact registration (M3) — ``libKF6KCMUtils``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers fetch
# spec + cmake flags + library artifact under ``kcmutilsSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kcmutils-6.10.0.tar.xz"

const ExpectedHash =
  "a4bcb4b04ee4a03a9a9fdbb96c2736021d94b22c22f8d5d5d157b9ce982eb001"

suite "kcmutilsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("kcmutilsSource")
    check spec.packageName == "kcmutilsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("kcmutilsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("kcmutilsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register libKF6KCMUtils":
    let arts = registeredArtifacts("kcmutilsSource")
    check arts.len == 1
    check arts[0].packageName == "kcmutilsSource"
    check arts[0].artifactName == "libKF6KCMUtils"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("kcmutilsSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kcmutils-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kcmutils"
