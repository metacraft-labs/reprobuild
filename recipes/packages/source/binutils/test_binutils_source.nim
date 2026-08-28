## Smoke test for the from-source ``binutilsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch E compiler-
## chain slice. binutils's unique coverage angles vs the prior 82
## from-source recipes:
##
##   * FIRST recipe in the corpus to declare ELEVEN ``executable``
##     artifacts sharing a single ``./configure`` + ``make`` install-
##     tree. Pins the from-source-autotools convention's per-artifact
##     stage-copy fan-out at the eleven-binary cardinality.
##   * FIRST from-source-autotools consumer with a FIVE-flag
##     ``configureFlags:`` block — the prior precedents covered
##     1-flag (autoconf / automake / libtool) + 3-flag (pkgconf) +
##     4-flag (expat) cardinalities, binutils closes the 5-flag gap
##     with the canonical ``--enable-gold`` + ``--enable-ld=default``
##     + ``--enable-plugins`` + ``--enable-shared`` +
##     ``--disable-werror`` set.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the five-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * ELEVEN ``executable`` artifact registration (M3) — ld + as +
##     ar + nm + objcopy + objdump + ranlib + strip + readelf + size
##     + strings all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + eleven executable artifacts under
# ``binutilsSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/binutils/binutils-2.43.tar.xz"

# Real sha256 over the upstream binutils-2.43.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "b53606f443ac8f01d1d5fc9c39497f2af322d99e14cea5c0b4b124d630379365"

const ExpectedConfigureFlags = @[
  "--enable-gold",
  "--enable-ld=default",
  "--enable-plugins",
  "--enable-shared",
  "--disable-werror",
]

suite "binutilsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("binutilsSource")
    check spec.packageName == "binutilsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("binutilsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention.
    let spec = registeredFetchSpec("binutilsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("binutilsSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("binutilsSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("binutilsSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("binutilsSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("binutilsSource", "makeVars")
    check not buildBlockPassesArgument("binutilsSource", "installMakeVars")
  test "artifacts register eleven executables all tagged dakExecutable":
    # M3 artifact registry: ld + as + ar + nm + objcopy + objdump +
    # ranlib + strip + readelf + size + strings are all tagged
    # ``dakExecutable``. A regression that flattened the kind
    # discriminator at the eleven-artifact cardinality would surface
    # here.
    let arts = registeredArtifacts("binutilsSource")
    check arts.len == 11
    var seenLd = false
    var seenAs = false
    var seenAr = false
    var seenNm = false
    var seenObjcopy = false
    var seenObjdump = false
    var seenRanlib = false
    var seenStrip = false
    var seenReadelf = false
    var seenSize = false
    var seenStrings = false
    for art in arts:
      check art.packageName == "binutilsSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "ld":
        seenLd = true
      of "as":
        seenAs = true
      of "ar":
        seenAr = true
      of "nm":
        seenNm = true
      of "objcopy":
        seenObjcopy = true
      of "objdump":
        seenObjdump = true
      of "ranlib":
        seenRanlib = true
      of "strip":
        seenStrip = true
      of "readelf":
        seenReadelf = true
      of "size":
        seenSize = true
      of "strings":
        seenStrings = true
      else:
        discard
    check seenLd
    check seenAs
    check seenAr
    check seenNm
    check seenObjcopy
    check seenObjdump
    check seenRanlib
    check seenStrip
    check seenReadelf
    check seenSize
    check seenStrings

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical sourceware.org git tree.
    let vs = registeredVersions("binutilsSource")
    check vs.len == 1
    check vs[0].version == "2.43"
    check vs[0].sourceRevision == "binutils-2_43"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/binutils/binutils-2.43.tar.xz"
    check vs[0].sourceRepository ==
      "https://sourceware.org/git/binutils-gdb.git"
