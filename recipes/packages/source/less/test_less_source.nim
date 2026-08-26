## Smoke test for the from-source ``lessSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTIETH real production
## from-source recipe. less's unique coverage angle vs the prior
## fifty-nine is being THE canonical Unix pager + a SINGLE-flag
## ``configureFlags:`` block — the smallest configure-channel
## cardinality in the corpus so far, pinning the M9.I block parser's
## one-flag path against potential off-by-one regressions.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the single-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE executable artifact registration (M3) — ``less`` tagged
##     ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``lessSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://www.greenwoodsoftware.com/less/less-668.tar.gz"

const ExpectedHash =
  "2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8"

const ExpectedConfigureFlags = @[
  "--with-regex=posix",
]

suite "lessSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("lessSource")
    check spec.packageName == "lessSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 649,770-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("lessSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs
    # use.
    let spec = registeredFetchSpec("lessSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("lessSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("lessSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("lessSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("lessSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("lessSource", "makeVars")
    check not buildBlockPassesArgument("lessSource", "installMakeVars")
  test "ncurses is registered as the terminal capability build dependency":
    check registeredBuildDeps("lessSource") == @["ncurses >=6.0"]

  test "artifacts register a single less executable tagged dakExecutable":
    # M3 artifact registry: ``less`` is tagged ``dakExecutable``.
    # less's autotools build emits a single load-bearing binary (the
    # pager); auxiliary ``lessecho`` + ``lesskey`` helpers are NOT
    # registered in v1. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path; a
    # regression that collapsed the artifact-name partitioning at the
    # one-artifact cardinality would not produce a single entry with
    # the expected name.
    let arts = registeredArtifacts("lessSource")
    check arts.len == 1
    check arts[0].packageName == "lessSource"
    check arts[0].artifactName == "less"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream greenwoodsoftware.com release
    # tag is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # github.com mirror where the upstream maintainer publishes the
    # less source tree (greenwoodsoftware.com only hosts tarballs).
    let vs = registeredVersions("lessSource")
    check vs.len == 1
    check vs[0].version == "668"
    check vs[0].sourceRevision == "v668"
    check vs[0].sourceUrl ==
      "https://www.greenwoodsoftware.com/less/less-668.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/gwsw/less.git"
