## Smoke test for the from-source ``qt6DeclarativeSource`` recipe (M9.R.15j.1).
##
## Pins the M9.H/I/K trio's behaviour on the qt6-declarative module that
## unblocks the KF6/Plasma cascade (kdeclarative, knotifications, kio,
## ksvg, kpackage all consume QtQml/QtQuick/QuickControls2 from this
## package).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * THREE library artifact registrations (M3) — ``libQt6Qml`` +
##     ``libQt6Quick`` + ``libQt6QuickControls2`` tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + library artifacts under ``qt6DeclarativeSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtdeclarative-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "95d15d5c1b6adcedb1df6485219ad13b8dc1bb5168b5151f2f1f7246a4c039fc"

suite "qt6DeclarativeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("qt6DeclarativeSource")
    check spec.packageName == "qt6DeclarativeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("qt6DeclarativeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("qt6DeclarativeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the three Qt6 declarative libraries":
    let arts = registeredArtifacts("qt6DeclarativeSource")
    check arts.len == 3
    var names: seq[string] = @[]
    for art in arts:
      check art.packageName == "qt6DeclarativeSource"
      check art.kind == dakLibrary
      names.add(art.artifactName)
    check "libQt6Qml" in names
    check "libQt6Quick" in names
    check "libQt6QuickControls2" in names

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("qt6DeclarativeSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtdeclarative-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qtdeclarative.git"
