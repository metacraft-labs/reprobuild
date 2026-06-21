## Smoke test for the from-source ``qt6WaylandSource`` recipe (M9.R.15p.1.1).
##
## Pins the M9.H/I/K trio's behaviour on the qt6-wayland module that
## unblocks the KF6/Plasma cascade: kwindowsystem's
## ``find_package(Qt6WaylandClient REQUIRED)`` resolves through this
## recipe's ``libQt6WaylandClient`` artifact, which in turn unblocks
## kio + plasma-framework + kwin.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * THREE library artifact registrations (M3) — libQt6WaylandClient
##     + libQt6WaylandCompositor + libQt6WaylandEglClientHwIntegration
##     all tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + library artifacts under ``qt6WaylandSource`` at
# module init time.
import ./repro

const ExpectedUrl =
  "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtwayland-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "2226fbde4e2ddd12f8bf4b239c8f38fd706a54e789e63467dfddc77129eca203"

suite "qt6WaylandSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("qt6WaylandSource")
    check spec.packageName == "qt6WaylandSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the upstream sha256":
    let spec = registeredFetchSpec("qt6WaylandSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("qt6WaylandSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register the three Qt6 Wayland libraries":
    let arts = registeredArtifacts("qt6WaylandSource")
    check arts.len == 3
    check arts[0].packageName == "qt6WaylandSource"
    check arts[0].kind == dakLibrary
    check arts[0].artifactName == "libQt6WaylandClient"
    check arts[1].kind == dakLibrary
    check arts[1].artifactName == "libQt6WaylandCompositor"
    check arts[2].kind == dakLibrary
    check arts[2].artifactName == "libQt6WaylandEglClientHwIntegration"

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("qt6WaylandSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtwayland-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/qt/qt/qtwayland"
