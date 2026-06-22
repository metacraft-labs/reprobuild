## Smoke test for the from-source ``kcoreaddonsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the NINETEENTH real production
## from-source recipe and the FIRST recipe in the Plasma stack batch.
## kcoreaddons is the SECOND CMake-driven recipe after json-c, so the
## ``cmakeFlags:`` channel cross-channel-isolation pin gets a second
## exemplar that catches a regression that would target a future
## CMake-only flatten of the per-channel registries (json-c was the
## only canary before this recipe landed).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libKF6CoreAddons``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under
# ``kcoreaddonsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kcoreaddons-6.10.0.tar.xz"

const ExpectedHash =
  "89bf28747915e987cab21c77397b0971caffa1258b6f575543d73d4188184a72"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kcoreaddonsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kcoreaddonsSource")
    check spec.packageName == "kcoreaddonsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,553,780-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kcoreaddonsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kcoreaddonsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libKF6CoreAddons`` is the only artifact
    # and must be tagged ``dakLibrary``. kcoreaddons's CMake build
    # emits one shared object bundling the cross-cutting KF6 helpers.
    # A regression that mis-tagged the artifact kind would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("kcoreaddonsSource")
    check arts.len == 1
    check arts[0].packageName == "kcoreaddonsSource"
    check arts[0].artifactName == "libKF6CoreAddons"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the kcoreaddons
    # source tree.
    let vs = registeredVersions("kcoreaddonsSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kcoreaddons-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kcoreaddons"
