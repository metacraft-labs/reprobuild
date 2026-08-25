## Smoke test for the from-source ``plasmaFrameworkSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-SIXTH real production
## from-source recipe and the CLOSING recipe in the SECOND KF6 module-
## sweep batch (kservice / kglobalaccel / knotifications /
## plasma-framework). plasma-framework's coverage angle is the FIRST
## recipe in the recipe suite to lift from ``stable/plasma/<x.y.z>/``
## instead of ``stable/frameworks/<x.y>/`` (Plasma 6.x renamed the
## kpackage + kdeclarative + plasma-framework trio into a unified
## ``libplasma``), so the test pins both the post-rename release-tree
## path AND the ``v6.2.5`` upstream tag (instead of the ``v6.10.0``
## the sibling KF6 recipes use).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libPlasma`` (note
##     the LACK of a ``KF6`` prefix on the artifact identifier — Plasma
##     is a Plasma-stack library, not a KF6 framework) tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under
# ``plasmaFrameworkSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.kde.org/stable/plasma/6.2.5/libplasma-6.2.5.tar.xz"

const ExpectedHash =
  "af770f5fef978512c70491889516fb769d340f00a02270987d2d1d17753658ec"

const ExpectedCmakeFlags = @[
  "BUILD_TESTING=OFF",
  "BUILD_QCH=OFF",
  "BUILD_PYTHON_BINDINGS=OFF",
  "CMAKE_BUILD_TYPE=Release",
]

suite "plasmaFrameworkSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    # The vendored tarball is named ``libplasma-6.2.5.tar.xz`` per
    # the upstream post-rename release artefact (NOT
    # ``plasma-framework-6.2.5.tar.xz``); a regression that mis-lifted
    # the legacy KF5 filename would not match the assertion below.
    let spec = registeredFetchSpec("plasmaFrameworkSource")
    check spec.packageName == "plasmaFrameworkSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,970,096-byte tarball.
    let spec = registeredFetchSpec("plasmaFrameworkSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("plasmaFrameworkSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("plasmaFrameworkSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("plasmaFrameworkSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("plasmaFrameworkSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("plasmaFrameworkSource")
  test "artifacts register a single library":
    # M3 artifact registry: ``libPlasma`` is the only artifact and
    # must be tagged ``dakLibrary``. A regression that re-added the
    # ``KF6`` prefix that the sibling KF6 recipes carry
    # (``libKF6Plasma`` vs ``libPlasma``) would not match the
    # assertion below — libplasma is a Plasma-stack library, not a KF6
    # framework, and the upstream SONAME reflects that.
    let arts = registeredArtifacts("plasmaFrameworkSource")
    check arts.len == 1
    check arts[0].packageName == "plasmaFrameworkSource"
    check arts[0].artifactName == "libPlasma"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry. Pins both the post-rename release-tree path
    # (``stable/plasma/6.2.5/`` instead of
    # ``stable/frameworks/<x.y>/``) AND the v6.2.5 upstream tag
    # (instead of the v6.10.0 the sibling KF6 recipes use).
    let vs = registeredVersions("plasmaFrameworkSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma/6.2.5/libplasma-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/libplasma"
