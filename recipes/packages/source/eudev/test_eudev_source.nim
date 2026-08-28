## Smoke test for the from-source ``eudevSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-FIFTH real
## production from-source recipe. eudev's unique coverage angle vs the
## prior thirty-four is being the FIRST recipe in the corpus to ship
## an artifact identifier (``libUdev``) that COLLIDES with a sibling
## recipe's artifact identifier (systemd's ``libUdev``). The two
## recipes vendor DIFFERENT upstream implementations of the same ABI
## and the convention layer's artifact registry must track
## (packageName, artifactName) tuples — a regression that flattened
## the tuple to ``artifactName`` alone would surface here in the
## collision-distinct assertion below.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * THREE artifact registration (M3) — ``udevd`` + ``udevadm``
##     tagged ``dakExecutable`` + ``libUdev`` tagged ``dakLibrary``.
##   * Artifact-name collision distinctness — eudev's ``libUdev``
##     is registered under the ``eudevSource`` packageName and is
##     DISTINCT from any sibling's ``libUdev`` (the package-name
##     pin guards the collision-distinctness property).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executable + one library
# artifacts under ``eudevSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://github.com/eudev-project/eudev/releases/download/v3.2.14/eudev-3.2.14.tar.gz"

const ExpectedHash =
  "8da4319102f24abbf7fff5ce9c416af848df163b29590e666d334cc1927f006f"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-blkid",
  "--disable-manpages",
  "--enable-hwdb",
]

suite "eudevSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("eudevSource")
    check spec.packageName == "eudevSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,188,254-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("eudevSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("eudevSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("eudevSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("eudevSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("eudevSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("eudevSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("eudevSource", "makeVars")
    check not buildBlockPassesArgument("eudevSource", "installMakeVars")
  test "artifacts register two executables + one library with correct kinds":
    # M3 artifact registry: ``udevd`` + ``udevadm`` are tagged
    # ``dakExecutable`` while ``libUdev`` is tagged ``dakLibrary``. A
    # regression that flattened the kind discriminator would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("eudevSource")
    check arts.len == 3
    var seenUdevd = false
    var seenUdevadm = false
    var seenLibUdev = false
    for art in arts:
      check art.packageName == "eudevSource"
      case art.artifactName
      of "udevd":
        seenUdevd = true
        check art.kind == dakExecutable
      of "udevadm":
        seenUdevadm = true
        check art.kind == dakExecutable
      of "libUdev":
        seenLibUdev = true
        check art.kind == dakLibrary
      else:
        discard
    check seenUdevd
    check seenUdevadm
    check seenLibUdev

  test "libUdev artifact-name collision with systemd is distinct by packageName":
    # The unique coverage of THIS recipe: eudev's ``libUdev`` and
    # systemd's ``libUdev`` are DISTINCT entries in the (packageName,
    # artifactName) tuple registry. A regression that flattened the
    # tuple to ``artifactName`` alone would merge the two and mis-route
    # the convention layer's install action (shipping a corrupt
    # ``libudev.so`` that's neither the systemd nor the eudev
    # implementation cleanly).
    let arts = registeredArtifacts("eudevSource")
    var foundLibUdevForEudev = false
    for art in arts:
      if art.artifactName == "libUdev":
        check art.packageName == "eudevSource"
        foundLibUdevForEudev = true
    check foundLibUdevForEudev

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the eudev source tree.
    let vs = registeredVersions("eudevSource")
    check vs.len == 1
    check vs[0].version == "3.2.14"
    check vs[0].sourceRevision == "v3.2.14"
    check vs[0].sourceUrl ==
      "https://github.com/eudev-project/eudev/releases/download/v3.2.14/eudev-3.2.14.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/eudev-project/eudev"
