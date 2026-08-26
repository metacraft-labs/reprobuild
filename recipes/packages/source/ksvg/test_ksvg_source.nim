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

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under ``ksvgSource``
# at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.kde.org/stable/frameworks/6.10/ksvg-6.10.0.tar.xz"

const ExpectedHash =
  "173e151f6ef8360149f835b1fc7494e97a33f9056d294ab213c9ef9e6d84d0c8"

const ExpectedCmakeFlags = @[
  "BUILD_TESTING=OFF",
  "BUILD_QCH=OFF",
  "BUILD_PYTHON_BINDINGS=OFF",
  "CMAKE_BUILD_TYPE=Release",
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
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("ksvgSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("ksvgSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("ksvgSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("ksvgSource")
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
