## Smoke test for the from-source ``kioSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-SEVENTH real
## production from-source recipe and the THIRD recipe in the THIRD
## KF6 module-sweep batch (ksvg / ksolid / kio / kded). kio's coverage
## angle is the LARGEST KF6 framework in the recipe suite by source-
## size and the FIRST KF6 recipe whose upstream SONAME contains a
## three-letter all-caps acronym (``KF6KIO``) — the artifact
## identifier (``libKF6Kio``) pins the brand-conventional casing rule
## (``Kio`` not ``KIO``) on the M3 registry.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6Kio``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``kioSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/kio/vendor/kio-6.10.0.tar.xz"

const ExpectedHash =
  "7eb454438f149e7ed513c3bbd526b67e3e3ecfe32ae7c986168baa59600b699c"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kioSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kioSource")
    check spec.packageName == "kioSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,423,932-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kioSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kioSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the CMake channel.
    let flags = registeredBuildFlags("kioSource", "", "cmake")
    check flags == ExpectedCmakeFlags
    check flags.len == 4

  test "cmakeFlags does not leak into the meson channel":
    # Cross-channel isolation.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kioSource", "", "meson") == emptyStrSeq

  test "cmakeFlags does not leak into the configure channel":
    # Cross-channel isolation #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kioSource", "", "configure") == emptyStrSeq

  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6Kio`` is the only artifact and
    # must be tagged ``dakLibrary``. A regression that all-cased the
    # KIO acronym in the artifact identifier (``libKF6KIO`` instead
    # of ``libKF6Kio``) would not match the assertion below — that
    # mis-casing would also mis-route any consumer recipe that
    # depends on the artifact by identifier.
    let arts = registeredArtifacts("kioSource")
    check arts.len == 1
    check arts[0].packageName == "kioSource"
    check arts[0].artifactName == "libKF6Kio"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry.
    let vs = registeredVersions("kioSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kio-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kio"
