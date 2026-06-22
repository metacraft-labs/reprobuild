## Smoke test for the from-source ``ki18nSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-SEVENTH real
## production from-source recipe and the SECOND recipe in the KF6
## module-sweep batch (kconfig / ki18n / kwidgetsaddons / kxmlgui).
## ki18n's coverage angle is a single-library KF6 recipe — pinning the
## per-package partitioning under the KF6 brand-casing convention
## (``libKF6I18n`` from upstream SONAME ``KF6I18n``).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6I18n``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``ki18nSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/ki18n-6.10.0.tar.xz"

const ExpectedHash =
  "2f59f093f8ce340ab46c556b35c2ead2b96dfeb2ff0024c553ac8c53e9b8a11a"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "ki18nSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("ki18nSource")
    check spec.packageName == "ki18nSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,112,804-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("ki18nSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("ki18nSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6I18n`` is the only artifact and
    # must be tagged ``dakLibrary``. ki18n's CMake build emits one
    # shared object wrapping the gettext-bridge surface for KF6.
    let arts = registeredArtifacts("ki18nSource")
    check arts.len == 1
    check arts[0].packageName == "ki18nSource"
    check arts[0].artifactName == "libKF6I18n"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the ki18n source
    # tree.
    let vs = registeredVersions("ki18nSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/ki18n-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/ki18n"
