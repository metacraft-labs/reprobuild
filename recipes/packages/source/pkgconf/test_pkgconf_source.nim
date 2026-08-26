## Smoke test for the from-source ``pkgconfSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch D build-tool
## slice. pkgconf's unique coverage angles vs the prior 80 from-
## source recipes:
##
##   * THIRD from-source-autotools consumer with a MIXED-KIND
##     artifact set (one executable + one library, matching the xz
##     precedent). Pins the per-artifact stage-copy fan-out at the
##     (1, 1) mixed cardinality from a THREE-flag configure
##     channel.
##   * FIRST recipe in the corpus to declare configure flags whose
##     values carry colon-separated path lists
##     (``--with-system-libdir=/lib:/usr/lib``) — pins the per-channel
##     handling of colon-separated path values (a regression that
##     split the value on colons would surface as a flag-count
##     mismatch).
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the three-flag set (one bare flag + two
##     value-bearing flags with embedded colons) + channel-isolation
##     spot-check.
##   * MIXED-KIND artifact registration (M3) — pkgconf tagged
##     ``dakExecutable``, libpkgconf tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable + one library
# artifacts under ``pkgconfSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz"

# Real sha256 over the upstream pkgconf-2.3.0.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--with-system-libdir=/lib:/usr/lib",
  "--with-system-includedir=/usr/include",
]

suite "pkgconfSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pkgconfSource")
    check spec.packageName == "pkgconfSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream distfiles.ariadne.space tarball;
    # computed locally + asserted exactly.
    let spec = registeredFetchSpec("pkgconfSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention.
    let spec = registeredFetchSpec("pkgconfSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("pkgconfSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("pkgconfSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("pkgconfSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("pkgconfSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("pkgconfSource", "makeVars")
    check not buildBlockPassesArgument("pkgconfSource", "installMakeVars")
  test "artifacts register commands and the shared library":
    # M3 artifact registry: pkgconf tagged ``dakExecutable``;
    # libpkgconf tagged ``dakLibrary``. The unique coverage of THIS
    # recipe vs the xz precedent is the THREE-flag configure channel
    # paired with the (1, 1) mixed cardinality.
    let arts = registeredArtifacts("pkgconfSource")
    check arts.len == 3
    var seenPkgconf = false
    var seenPkgConfig = false
    var seenLibpkgconf = false
    for art in arts:
      check art.packageName == "pkgconfSource"
      case art.artifactName
      of "pkgconf":
        seenPkgconf = true
        check art.kind == dakExecutable
      of "pkgConfig":
        seenPkgConfig = true
        check art.kind == dakExecutable
      of "libpkgconf":
        seenLibpkgconf = true
        check art.kind == dakLibrary
      else:
        discard
    check seenPkgconf
    check seenPkgConfig
    check seenLibpkgconf

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream distfiles.ariadne.space
    # release tag is recorded for ``repro update-source``. The
    # repository points at the canonical github.com project.
    let vs = registeredVersions("pkgconfSource")
    check vs.len == 1
    check vs[0].version == "2.3.0"
    check vs[0].sourceRevision == "pkgconf-2.3.0"
    check vs[0].sourceUrl ==
      "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://github.com/pkgconf/pkgconf"
