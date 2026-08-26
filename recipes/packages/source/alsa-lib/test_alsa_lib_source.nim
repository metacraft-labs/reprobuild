## Smoke test for the from-source ``alsaLibSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-SEVENTH real
## production from-source recipe. alsa-lib is THE userspace half of
## ALSA — every modern Linux audio stack (pipewire / wireplumber /
## pulseaudio / GStreamer-alsa) links libasound to reach the kernel
## /dev/snd/* ioctl surface.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the two-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libAsound``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``alsaLibSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.15.3.tar.bz2"

const ExpectedHash =
  "7b079d614d582cade7ab8db2364e65271d0877a37df8757ac4ac0c8970be861e"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-python",
]

suite "alsaLibSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("alsaLibSource")
    check spec.packageName == "alsaLibSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 cross-checked against nixpkgs's SRI-form hash on the
    # same upstream tarball; length check guards against a future
    # bump that forgets to widen the hash alongside the URL.
    let spec = registeredFetchSpec("alsaLibSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs use.
    let spec = registeredFetchSpec("alsaLibSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("alsaLibSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("alsaLibSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("alsaLibSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("alsaLibSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("alsaLibSource", "makeVars")
    check not buildBlockPassesArgument("alsaLibSource", "installMakeVars")
  test "artifacts register a single library":
    # M3 artifact registry: ``libAsound`` is the only artifact and
    # must be tagged ``dakLibrary``. alsa-lib's autotools build
    # emits one canonical shared object (``libasound.so``) bundling
    # the PCM / mixer / sequencer / control APIs. A regression that
    # mis-tagged the artifact kind would mis-route the M9.L install
    # path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("alsaLibSource")
    check arts.len == 1
    check arts[0].packageName == "alsaLibSource"
    check arts[0].artifactName == "libAsound"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream alsa-project.org release tag
    # is recorded for ``repro update-source``. The repository points
    # at the canonical GitHub mirror the upstream maintainers
    # publish the alsa-lib source tree on.
    let vs = registeredVersions("alsaLibSource")
    check vs.len == 1
    check vs[0].version == "1.2.15.3"
    check vs[0].sourceRevision == "v1.2.15.3"
    check vs[0].sourceUrl ==
      "https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.15.3.tar.bz2"
    check vs[0].sourceRepository ==
      "https://github.com/alsa-project/alsa-lib"
