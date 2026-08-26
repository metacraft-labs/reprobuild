## Smoke test for the from-source ``jsonCSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTEENTH real production
## from-source recipe and the FIRST CMake-driven recipe. Prior twelve
## recipes (dbus-broker / libdrm / wayland / wlroots / sway /
## linux-kernel / libxkbcommon / pixman / libinput / cairo / pango /
## gdk-pixbuf) all used either ``mesonOptions:`` (eleven of them) or
## ``makeFlags:`` (the kernel). json-c's unique coverage angle vs the
## prior twelve is the ``cmakeFlags:`` channel — the first place to
## exercise the M9.I per-channel partitioning property from the CMake
## side. The cross-channel isolation pin below would surface a
## regression that leaks CMake flags into the meson/configure channel
## (or vice versa).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libJsonC``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library artifact under
# ``jsonCSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://github.com/json-c/json-c/archive/refs/tags/json-c-0.18-20240915.tar.gz"

const ExpectedHash =
  "3112c1f25d39eca661fe3fc663431e130cc6e2f900c081738317fba49d29e298"

const ExpectedCmakeFlags = @[
  "BUILD_SHARED_LIBS=ON",
  "BUILD_STATIC_LIBS=OFF",
  "BUILD_TESTING=OFF",
  "BUILD_APPS=OFF",
  "CMAKE_BUILD_TYPE=Release",
]

suite "jsonCSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("jsonCSource")
    check spec.packageName == "jsonCSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 401,874-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("jsonCSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("jsonCSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("jsonCSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("jsonCSource") == @["cmake_package"]
  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("jsonCSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("jsonCSource")
  test "artifacts register a single library":
    # M3 artifact registry: ``libJsonC`` is the only artifact and
    # must be tagged ``dakLibrary``. json-c's CMake build emits one
    # shared object bundling the parser + serialiser + tree walker.
    # A regression that mis-tagged the artifact kind would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("jsonCSource")
    check arts.len == 1
    check arts[0].packageName == "jsonCSource"
    check arts[0].artifactName == "libJsonC"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the json-c source tree.
    let vs = registeredVersions("jsonCSource")
    check vs.len == 1
    check vs[0].version == "0.18-20240915"
    check vs[0].sourceRevision == "json-c-0.18-20240915"
    check vs[0].sourceUrl ==
      "https://github.com/json-c/json-c/archive/refs/tags/json-c-0.18-20240915.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/json-c/json-c"
