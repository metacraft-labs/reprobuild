## Smoke test for the from-source ``qt6PositioningSource`` recipe (M9.R.15q.9.1).
##
## Pins the M9.H/I/K trio's behaviour on the qt6-positioning module
## that unblocks the KF6/Plasma cascade (plasma-workspace's
## CMakeLists.txt explicitly demands ``Qt6 ... COMPONENTS Positioning``
## via find_package).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * TWO library artifact registrations (M3) — ``libQt6Positioning``
##     + ``libQt6PositioningQuick`` both tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + library artifacts under ``qt6PositioningSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtpositioning-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "e310e7232591d4beb1785bfff8ff3e77430bdf5e9a17f56694b732f5267df78d"

suite "qt6PositioningSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("qt6PositioningSource")
    check spec.packageName == "qt6PositioningSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("qt6PositioningSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("qt6PositioningSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the TWO Qt6 Positioning libraries":
    let arts = registeredArtifacts("qt6PositioningSource")
    check arts.len == 2
    for a in arts:
      check a.packageName == "qt6PositioningSource"
      check a.kind == dakLibrary
    let names = @[arts[0].artifactName, arts[1].artifactName]
    check "libQt6Positioning" in names
    check "libQt6PositioningQuick" in names

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("qt6PositioningSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtpositioning-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qtpositioning.git"
