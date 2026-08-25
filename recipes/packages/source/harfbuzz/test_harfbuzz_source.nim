## Smoke test for the from-source ``harfbuzzSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-FOURTH real
## production from-source recipe. harfbuzz is the SIXTEENTH meson-driven
## recipe in the corpus and exercises the ``mesonOptions:`` channel
## with a SIX-element flag sequence (the largest meson flag set in the
## corpus to date alongside cairo's six and pango's five) — a
## regression that truncated the seq at a specific index would surface
## here.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libHarfbuzz``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifact under
# ``harfbuzzSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz"

const ExpectedHash =
  "6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82"

const ExpectedMesonOptions = @[
  "tests=disabled",
  "introspection=enabled",
  "docs=disabled",
  "gobject=enabled",
  "icu=disabled",
]

suite "harfbuzzSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("harfbuzzSource")
    check spec.packageName == "harfbuzzSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 17,922,136-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("harfbuzzSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("harfbuzzSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("harfbuzzSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("harfbuzzSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("harfbuzzSource")
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("harfbuzzSource")
  test "artifacts register a single library":
    # M3 artifact registry: ``libHarfbuzz`` is the only artifact and
    # must be tagged ``dakLibrary``. harfbuzz's meson build emits one
    # primary shared object bundling the OpenType layout + shaper +
    # script + Unicode-tables core. A regression that mis-tagged the
    # artifact kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("harfbuzzSource")
    check arts.len == 1
    check arts[0].packageName == "harfbuzzSource"
    check arts[0].artifactName == "libHarfbuzz"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical GitHub project that hosts the harfbuzz source tree.
    let vs = registeredVersions("harfbuzzSource")
    check vs.len == 1
    check vs[0].version == "10.1.0"
    check vs[0].sourceRevision == "10.1.0"
    check vs[0].sourceUrl ==
      "https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://github.com/harfbuzz/harfbuzz"
