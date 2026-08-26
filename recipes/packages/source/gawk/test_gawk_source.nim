## Smoke test for the from-source ``gawkSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTY-FOURTH real
## production from-source recipe. GNU awk (gawk) is THE canonical
## AWK implementation on every modern Linux distribution — every
## shell pipeline + every Makefile field-extract rule + every log-
## analysis script + every report-generation pipeline shells out to
## ``/usr/bin/awk``.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the three-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE executable artifact registration (M3) — ``awk`` tagged
##     ``dakExecutable``. The upstream binary is named ``gawk`` and
##     symlinked to ``awk`` on install; v1 pins the canonical short
##     name ``awk`` per the task brief.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``gawkSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz"

const ExpectedHash =
  "ca9c16d3d11d0ff8c69d79dc0b47267e1329a69b39b799895604ed447d3ca90b"

const ExpectedConfigureFlags = @[
  "--disable-extensions",
  "--disable-mpfr",
  "--disable-libsigsegv",
]

suite "gawkSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gawkSource")
    check spec.packageName == "gawkSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 is the canonical published upstream ``sha256sum`` for
    # gawk-5.3.0.tar.xz; length check guards against a future bump
    # that forgets to widen the hash alongside the URL.
    let spec = registeredFetchSpec("gawkSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("gawkSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("gawkSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("gawkSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("gawkSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("gawkSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("gawkSource", "makeVars")
    check not buildBlockPassesArgument("gawkSource", "installMakeVars")
  test "artifacts register a single awk executable tagged dakExecutable":
    # M3 artifact registry: ``awk`` is tagged ``dakExecutable``.
    # gawk's autotools build emits a single load-bearing binary
    # (the AWK interpreter; named ``gawk`` upstream, symlinked to
    # ``awk`` on install). Auxiliary ``gawkbug`` + ``pgawk`` +
    # ``igawk`` helpers are NOT registered in v1. A regression that
    # flattened the kind discriminator would mis-route the M9.L
    # install path; a regression that collapsed the artifact-name
    # partitioning at the one-artifact cardinality would not produce
    # a single entry with the expected name.
    let arts = registeredArtifacts("gawkSource")
    check arts.len == 1
    check arts[0].packageName == "gawkSource"
    check arts[0].artifactName == "awk"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror that hosts the gawk
    # source tree.
    let vs = registeredVersions("gawkSource")
    check vs.len == 1
    check vs[0].version == "5.3.0"
    check vs[0].sourceRevision == "gawk-5.3.0"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/gawk.git"
