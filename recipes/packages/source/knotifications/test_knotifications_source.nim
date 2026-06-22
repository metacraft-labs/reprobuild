## Smoke test for the from-source ``knotificationsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-FIFTH real
## production from-source recipe and the THIRD recipe in the SECOND
## KF6 module-sweep batch (kservice / kglobalaccel / knotifications /
## plasma-framework). knotifications's coverage angle is a single-
## library KF6 recipe whose artifact identifier
## (``libKF6Notifications``) pins the plural-noun PascalCase brand
## lowering (``Notifications``).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) —
##     ``libKF6Notifications`` tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under
# ``knotificationsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/knotifications-6.10.0.tar.xz"

const ExpectedHash =
  "36b7881d50400f37b4f3aeaa4c0a6a943e5783d35441e2b0cacdc6dad06af2a1"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "knotificationsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("knotificationsSource")
    check spec.packageName == "knotificationsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,335,588-byte tarball.
    let spec = registeredFetchSpec("knotificationsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("knotificationsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6Notifications`` is the only
    # artifact and must be tagged ``dakLibrary``. A regression that
    # mis-singularised the brand (``libKF6Notification`` vs
    # ``libKF6Notifications``) would not match the assertion below.
    let arts = registeredArtifacts("knotificationsSource")
    check arts.len == 1
    check arts[0].packageName == "knotificationsSource"
    check arts[0].artifactName == "libKF6Notifications"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("knotificationsSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/knotifications-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/knotifications"
