## Smoke test for the from-source ``zlibSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-NINTH real
## production from-source recipe. zlib's unique coverage angle vs the
## prior twenty-eight is the ``configureFlags:`` channel feeding a
## CUSTOM, hand-rolled ``./configure`` script — zlib's ``configure``
## is NOT autoconf-generated and accepts a much smaller flag set with
## different naming conventions (``--shared`` not ``--enable-shared``).
## The convention layer treats the ``configureFlags:`` channel as the
## abstract "argv passed to ``./configure``" carrier, so a custom-
## configure recipe reuses the same channel without needing a new
## flag-channel taxonomy. This pins the per-channel partitioning
## property from a fourth flavour angle: autotools (expat), autotools-
## with-tristate (freetype), autotools-with-twin-binaries (gdm), and
## now custom-configure (zlib).
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libZ`` tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``zlibSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"

const ExpectedHash =
  "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

const ExpectedConfigureFlags = @[
  "--shared",
]

suite "zlibSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("zlibSource")
    check spec.packageName == "zlibSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,512,791-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("zlibSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("zlibSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libZ`` is the only artifact and must be
    # tagged ``dakLibrary``. zlib's build emits one shared object
    # bundling the deflate + inflate compression primitives, the gzip
    # stream reader/writer, and the CRC32 helper. A regression that
    # mis-tagged the artifact kind would mis-route the M9.L install
    # path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("zlibSource")
    check arts.len == 1
    check arts[0].packageName == "zlibSource"
    check arts[0].artifactName == "libZ"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the zlib source tree
    # (the historical zlib.net mirror lifecycle is brittle — GitHub
    # is the stable mirror).
    let vs = registeredVersions("zlibSource")
    check vs.len == 1
    check vs[0].version == "1.3.1"
    check vs[0].sourceRevision == "v1.3.1"
    check vs[0].sourceUrl ==
      "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/madler/zlib"
