## Smoke test for the from-source ``mesaSource`` recipe.
##
## Drives M9.R.15m.1 (the MAJOR OpenGL/EGL/GBM gap blocking kwin +
## mutter compositors). Mesa is the canonical open-source 3D graphics
## stack; this recipe ships libGL.so / libEGL.so / libGLESv2.so /
## libgbm.so via a software-rasterizer-only meson build.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * THREE library artifact registration (M3) — libEGL +
##     libGLESv2 + libGbm, all tagged ``dakLibrary``. libGL is NOT
##     declared: the v1 minimal config (glx=disabled, no libglvnd)
##     does not produce a libGL.so — Qt6OpenGL links against
##     libGLESv2 directly when libGL is absent.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifacts under
# ``mesaSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://archive.mesa3d.org/mesa-23.3.6.tar.xz"

const ExpectedHash =
  "cd3d6c60121dea73abbae99d399dc2facaecde1a8c6bd647e6d85410ff4b577b"

suite "mesaSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("mesaSource")
    check spec.packageName == "mesaSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("mesaSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("mesaSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "library artifacts register all three shared objects":
    let arts = registeredArtifacts("mesaSource")
    check arts.len == 3
    var seenEGL = false
    var seenGLESv2 = false
    var seenGbm = false
    for art in arts:
      check art.packageName == "mesaSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libEGL":
        seenEGL = true
      of "libGLESv2":
        seenGLESv2 = true
      of "libGbm":
        seenGbm = true
      else:
        discard
    check seenEGL
    check seenGLESv2
    check seenGbm

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("mesaSource")
    check vs.len == 1
    check vs[0].version == "23.3.6"
    check vs[0].sourceRevision == "mesa-23.3.6"
    check vs[0].sourceUrl ==
      "https://archive.mesa3d.org/mesa-23.3.6.tar.xz"
    check vs[0].sourceRepository == "https://gitlab.freedesktop.org/mesa/mesa"
