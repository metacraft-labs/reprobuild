## Smoke test for the from-source ``sedSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTY-THIRD real
## production from-source recipe. GNU sed is THE canonical stream-
## editor CLI on every modern Linux distribution — every shell
## pipeline + every Makefile substitution rule + every config-rewrite
## script + every autotools ``./configure`` run shells out to
## ``/usr/bin/sed``.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the one-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE executable artifact registration (M3) — ``sed`` tagged
##     ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``sedSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"

const ExpectedHash =
  "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181"

const ExpectedConfigureFlags = @[
  "--disable-acl",
  "--without-selinux",
]

suite "sedSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("sedSource")
    check spec.packageName == "sedSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 cross-checked against nixpkgs's SRI-form hash on the
    # same upstream tarball; length check guards against a future
    # bump that forgets to widen the hash alongside the URL.
    let spec = registeredFetchSpec("sedSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("sedSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("sedSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("sedSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("sedSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("sedSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("sedSource", "makeVars")
    check not buildBlockPassesArgument("sedSource", "installMakeVars")
  test "artifacts register a single sed executable tagged dakExecutable":
    # M3 artifact registry: ``sed`` is tagged ``dakExecutable``.
    # sed's autotools build emits a single load-bearing binary (the
    # canonical stream-editor CLI). A regression that flattened the
    # kind discriminator would mis-route the M9.L install path; a
    # regression that collapsed the artifact-name partitioning at
    # the one-artifact cardinality would not produce a single entry
    # with the expected name.
    let arts = registeredArtifacts("sedSource")
    check arts.len == 1
    check arts[0].packageName == "sedSource"
    check arts[0].artifactName == "sed"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror that hosts the sed
    # source tree.
    let vs = registeredVersions("sedSource")
    check vs.len == 1
    check vs[0].version == "4.9"
    check vs[0].sourceRevision == "v4.9"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/sed.git"
