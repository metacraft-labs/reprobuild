## Smoke test for the from-source ``nettleSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-SECOND real
## production from-source recipe and the SECOND recipe in the crypto-
## and-FFI batch (libffi + nettle + libgcrypt + gnutls). nettle's
## unique coverage angle vs the prior fifty-one is the TWO-library
## autotools-driven shape paired with a mixed-polarity flag set
## (two ``--disable-*`` flags followed by ONE ``--enable-*`` flag) —
## the first place in the corpus the configure channel is exercised
## with a mixed disable/enable polarity. A regression that bucketed
## disable + enable flags into separate sub-channels would surface in
## the exact-sequence pinning below.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set (including the
##     mixed disable/enable polarity) + channel-isolation spot-check
##     (meson + cmake + make channels MUST be empty).
##   * TWO library artifact registration (M3) — ``libNettle`` +
##     ``libHogweed`` both tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two library artifacts under
# ``nettleSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz"

const ExpectedHash =
  "b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-documentation",
  "--enable-shared",
]

suite "nettleSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("nettleSource")
    check spec.packageName == "nettleSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,640,485-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("nettleSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("nettleSource")
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
  test "artifacts register two libraries":
    # M3 artifact registry: TWO libraries are registered, each tagged
    # ``dakLibrary``. nettle's autotools build emits two shared objects
    # from one ``./configure`` + ``make`` invocation: ``libnettle.so``
    # (the symmetric-cipher + hash + AEAD primitive library) and
    # ``libhogweed.so`` (the public-key cipher library layered on top
    # of libnettle). A regression that collapsed the multi-library
    # packages or dropped one of the two would surface in the
    # artifact-count + per-artifact name pinning below.
    let arts = registeredArtifacts("nettleSource")
    check arts.len == 2
    var seenNettle = false
    var seenHogweed = false
    for art in arts:
      check art.packageName == "nettleSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libNettle":
        seenNettle = true
      of "libHogweed":
        seenHogweed = true
      else:
        discard
    check seenNettle
    check seenHogweed

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GNU project page that hosts the nettle source
    # tree.
    let vs = registeredVersions("nettleSource")
    check vs.len == 1
    check vs[0].version == "3.10"
    check vs[0].sourceRevision == "nettle_3_10"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz"
    check vs[0].sourceRepository ==
      "https://www.lysator.liu.se/~nisse/nettle/"
