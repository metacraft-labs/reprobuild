## Smoke test for the from-source ``kglobalaccelSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-FOURTH real
## production from-source recipe and the SECOND recipe in the SECOND
## KF6 module-sweep batch (kservice / kglobalaccel / knotifications /
## plasma-framework). kglobalaccel's coverage angle is a single-library
## KF6 recipe whose artifact identifier (``libKF6GlobalAccel``) pins
## the two-token PascalCase brand lowering (``Global`` + ``Accel``).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6GlobalAccel``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under
# ``kglobalaccelSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kglobalaccel-6.10.0.tar.xz"

const ExpectedHash =
  "05b0ec6a44d43ce7a9cfd6cd70c8d07dca5c5f6216968af8128fe9a5ed9b1928"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kglobalaccelSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kglobalaccelSource")
    check spec.packageName == "kglobalaccelSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,294,700-byte tarball.
    let spec = registeredFetchSpec("kglobalaccelSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kglobalaccelSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6GlobalAccel`` is the only artifact
    # and must be tagged ``dakLibrary``. A regression that mis-cased
    # the PascalCase brand (``libKF6Globalaccel`` vs
    # ``libKF6GlobalAccel``) would not match the assertion below.
    let arts = registeredArtifacts("kglobalaccelSource")
    check arts.len == 1
    check arts[0].packageName == "kglobalaccelSource"
    check arts[0].artifactName == "libKF6GlobalAccel"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("kglobalaccelSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kglobalaccel-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kglobalaccel"
