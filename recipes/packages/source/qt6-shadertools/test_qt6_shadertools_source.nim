## Smoke test for the from-source ``qt6ShaderToolsSource`` recipe
## (M9.R.15n.2).
##
## Pins the M9.H/I/K trio's behaviour on the qt6-shadertools module
## that unblocks qt6-declarative's Qt Quick build (qsb shader-bundle
## tool detected at configure time gates the libQt6Quick.so +
## libQt6QuickControls2.so artifacts on qt6-declarative; without qsb
## the KF6 cascade can't link Qt6::Quick).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * TWO artifact registrations (M3) — ``qsb`` executable +
##     ``libQt6ShaderTools`` library.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + artifacts under ``qt6ShaderToolsSource`` at module
# init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtshadertools-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "55b70cd632473a8043c74ba89310f7ba9c5041d253bc60e7ae1fa789169c4846"

suite "qt6ShaderToolsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("qt6ShaderToolsSource")
    check spec.packageName == "qt6ShaderToolsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("qt6ShaderToolsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("qt6ShaderToolsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the qsb executable + libQt6ShaderTools library":
    let arts = registeredArtifacts("qt6ShaderToolsSource")
    check arts.len == 2
    check arts[0].packageName == "qt6ShaderToolsSource"
    check arts[0].kind == dakExecutable
    check arts[0].artifactName == "qsb"
    check arts[1].kind == dakLibrary
    check arts[1].artifactName == "libQt6ShaderTools"

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("qt6ShaderToolsSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtshadertools-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qtshadertools.git"
