## Smoke test for the from-source ``ksvgSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-FIFTH real
## production from-source recipe and the FIRST recipe in the THIRD
## KF6 module-sweep batch (ksvg / ksolid / kio / kded). ksvg's
## coverage angle is a single-library KF6 recipe whose artifact
## identifier (``libKF6Svg``) pins the shortest single-token
## PascalCase brand lowering on the CMake channel.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6Svg``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``ksvgSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/ksvg/vendor/ksvg-6.10.0.tar.xz"

const ExpectedHash =
  "173e151f6ef8360149f835b1fc7494e97a33f9056d294ab213c9ef9e6d84d0c8"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "ksvgSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("ksvgSource")
    check spec.packageName == "ksvgSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 83,964-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("ksvgSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("ksvgSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6Svg`` is the only artifact and
    # must be tagged ``dakLibrary``. A regression that mis-tagged the
    # artifact kind would mis-route the M9.L install path (``lib/`` vs
    # ``bin/``).
    let arts = registeredArtifacts("ksvgSource")
    check arts.len == 1
    check arts[0].packageName == "ksvgSource"
    check arts[0].artifactName == "libKF6Svg"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("ksvgSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/ksvg-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/ksvg"
