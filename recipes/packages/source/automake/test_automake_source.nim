## Smoke test for the from-source ``automakeSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch D build-tool
## slice. automake's unique coverage angles vs the prior 78 from-
## source recipes:
##
##   * From-source-autotools consumer with TWO executable artifacts
##     sharing a single ``./configure`` + ``make`` install-tree.
##     Pins the per-artifact stage-copy fan-out at the
##     two-executable cardinality (vs the seven-executable autoconf
##     sibling in this same batch).
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality + channel-isolation spot-check.
##   * TWO ``executable`` artifact registration (M3) — automake +
##     aclocal both tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executable artifacts under
# ``automakeSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz"

# Real sha256 over the upstream automake-1.17.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "8920c1fc411e13b90bf704ef9db6f29d540e76d232cb3b2c9f4dc4cc599bd990"

const ExpectedConfigureFlags = @[
  "--disable-static",
]

suite "automakeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("automakeSource")
    check spec.packageName == "automakeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("automakeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("automakeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("automakeSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("automakeSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("automakeSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("automakeSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("automakeSource", "makeVars")
    check not buildBlockPassesArgument("automakeSource", "installMakeVars")
  test "artifacts register two executables all tagged dakExecutable":
    # M3 artifact registry: automake + aclocal are both tagged
    # ``dakExecutable``.
    let arts = registeredArtifacts("automakeSource")
    check arts.len == 2
    var seenAutomake = false
    var seenAclocal = false
    for art in arts:
      check art.packageName == "automakeSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "automake":
        seenAutomake = true
      of "aclocal":
        seenAclocal = true
      else:
        discard
    check seenAutomake
    check seenAclocal

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror.
    let vs = registeredVersions("automakeSource")
    check vs.len == 1
    check vs[0].version == "1.17"
    check vs[0].sourceRevision == "v1.17"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/automake.git"
