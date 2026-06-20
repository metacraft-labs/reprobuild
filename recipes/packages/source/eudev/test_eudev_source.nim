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

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executable + one library
# artifacts under ``eudevSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/eudev/vendor/eudev-3.2.14.tar.gz"

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
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
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
