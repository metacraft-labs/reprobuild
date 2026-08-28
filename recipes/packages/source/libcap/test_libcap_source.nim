## Smoke test for the from-source ``libcapSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-FOURTH real
## production from-source recipe. libcap's unique coverage angle vs
## the prior thirty-three is the M9.I ``makeFlags:`` channel feeding
## a RAW Makefile (no ``./configure`` step) — only the SECOND recipe
## in the corpus to consume ``makeFlags:`` (linux-kernel was the
## first), and the FIRST recipe to drive a non-kbuild raw Makefile
## through the channel. The cross-channel isolation pin below would
## surface a regression that mis-routes a libcap ``BUILD_CC=`` /
## ``prefix=`` makefile variable onto the configure / meson / cmake
## channels (autotools / cmake / meson have different flag grammars
## and a misroute would fail the build).
##
## Additionally, libcap is the FIRST recipe in the corpus to ship a
## ONE-library + THREE-executable mixed-kind shape from a raw
## Makefile package (the kernel ships one-exec + three-files; libcap
## inverts to one-lib + three-exec).
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``makeFlags:`` block round-trip (M9.I) — exact-order sequence
##     equality on the production flag set + channel-isolation
##     spot-check (configure + meson + cmake channels MUST be empty).
##   * FOUR artifact registration (M3) — ``libCap`` tagged
##     ``dakLibrary`` + ``capsh`` + ``getcap`` + ``setcap`` tagged
##     ``dakExecutable``, all in the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + make flags + one library + three executable
# artifacts under ``libcapSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.71.tar.xz"

const ExpectedHash =
  "b7006c9af5168315f35fc734bf1a8d2aa70766bd8b8c4340962e05b19c35b900"

const ExpectedMakeFlags = @[
  "BUILD_CC=gcc",
  "RAISE_SETFCAP=no",
  "lib=lib",
  "prefix=/usr",
  "GOLANG=no",
]

suite "libcapSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libcapSource")
    check spec.packageName == "libcapSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 193,512-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libcapSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream kernel.org release
    # tarballs use.
    let spec = registeredFetchSpec("libcapSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "makeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("libcapSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMakeFlags
    check buildBlockConstructors("libcapSource") == @["autotools_package"]
  test "makeFlags does not leak into the configure channel":
    # This recipe runs no configure step at all: it passes
    # ``skipConfigure = true`` and its flag sequence is consumed by
    # the make invocation instead. Nothing can leak into a channel
    # the recipe never runs.
    check packageBuildBlockCode("libcapSource").contains("skipConfigure = true")
  test "makeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("libcapSource")
  test "makeFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("libcapSource")
  test "artifacts register one library + three executables with correct kinds":
    # M3 artifact registry: ``libCap`` is tagged ``dakLibrary`` while
    # ``capsh`` + ``getcap`` + ``setcap`` are tagged ``dakExecutable``.
    # The unique coverage of THIS recipe is that it's the first recipe
    # to ship a one-lib + three-exec mixed-kind shape from a raw
    # Makefile package. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning would not produce four distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("libcapSource")
    check arts.len == 4
    var seenLibCap = false
    var seenCapsh = false
    var seenGetcap = false
    var seenSetcap = false
    for art in arts:
      check art.packageName == "libcapSource"
      case art.artifactName
      of "libCap":
        seenLibCap = true
        check art.kind == dakLibrary
      of "capsh":
        seenCapsh = true
        check art.kind == dakExecutable
      of "getcap":
        seenGetcap = true
        check art.kind == dakExecutable
      of "setcap":
        seenSetcap = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLibCap
    check seenCapsh
    check seenGetcap
    check seenSetcap

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream kernel.org release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical mirror on git.kernel.org that hosts the libcap
    # source tree.
    let vs = registeredVersions("libcapSource")
    check vs.len == 1
    check vs[0].version == "2.71"
    check vs[0].sourceRevision == "libcap-2.71"
    check vs[0].sourceUrl ==
      "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.71.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/libs/libcap/libcap.git"
