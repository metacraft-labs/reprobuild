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

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``kioSource``
# at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/kio-6.10.0.tar.xz"

const ExpectedHash =
  "7eb454438f149e7ed513c3bbd526b67e3e3ecfe32ae7c986168baa59600b699c"

const ExpectedCmakeFlags = @[
  "BUILD_TESTING=OFF",
  "BUILD_QCH=OFF",
  "BUILD_PYTHON_BINDINGS=OFF",
  "CMAKE_BUILD_TYPE=Release",
  "WITH_X11=OFF",
  "WITH_WAYLAND=OFF",
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
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("kioSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("kioSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("kioSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("kioSource")
  test "artifacts register the four KIO libraries":
    # M9.R.15i.3.3 — KIO ships FOUR libraries upstream (Core, Gui,
    # Widgets, FileWidgets), not one umbrella ``libKF6Kio``. The
    # recipe matches what upstream actually builds; this assertion
    # pins the per-library kind + identifier-casing (``Kio`` not
    # ``KIO`` — that mis-casing would also mis-route any consumer
    # recipe that depends on an artifact by identifier).
    let arts = registeredArtifacts("kioSource")
    check arts.len == 4
    var seenCore = false
    var seenGui = false
    var seenWidgets = false
    var seenFileWidgets = false
    for art in arts:
      check art.packageName == "kioSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libKF6KIOCore": seenCore = true
      of "libKF6KIOGui": seenGui = true
      of "libKF6KIOWidgets": seenWidgets = true
      of "libKF6KIOFileWidgets": seenFileWidgets = true
      else: discard
    check seenCore
    check seenGui
    check seenWidgets
    check seenFileWidgets

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
