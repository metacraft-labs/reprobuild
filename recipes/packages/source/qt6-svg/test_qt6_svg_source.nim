## Smoke test for the from-source ``qt6SvgSource`` recipe (M9.R.15k.1).
##
## Pins the M9.H/I/K trio's behaviour on the qt6-svg module that
## unblocks the KF6/Plasma cascade (kiconthemes, ksvg, kxmlgui all
## consume QtSvg for scalable icon-theme rendering, which feeds the
## kglobalacceld → kwin compositor chain).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ONE library artifact registration (M3) — ``libQt6Svg`` tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + library artifacts under ``qt6SvgSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtsvg-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "3d0de73596e36b2daa7c48d77c4426bb091752856912fba720215f756c560dd0"

suite "qt6SvgSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("qt6SvgSource")
    check spec.packageName == "qt6SvgSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("qt6SvgSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("qt6SvgSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the single Qt6 SVG library":
    let arts = registeredArtifacts("qt6SvgSource")
    check arts.len == 1
    check arts[0].packageName == "qt6SvgSource"
    check arts[0].kind == dakLibrary
    check arts[0].artifactName == "libQt6Svg"

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("qt6SvgSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtsvg-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qtsvg.git"
