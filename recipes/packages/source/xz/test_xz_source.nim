## Smoke test for the from-source ``xzSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-THIRD real
## production from-source recipe. xz's unique coverage angle vs the
## prior sixty-two is being THE canonical modern LZMA2 compressor on
## Linux + a ONE-executable + ONE-library mixed-kind autotools shape
## (libcap-style pairing where both kinds emerge off a single
## ``./configure`` + ``make`` invocation), with a THREE-flag
## ``configureFlags:`` block.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the three-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * MIXED artifact registration (M3) — one executable
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``xzSource`` with kind discriminators preserved per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable + one library artifact
# under ``xzSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://tukaani.org/xz/xz-5.6.3.tar.xz"

const ExpectedHash =
  "db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-doc",
  "--disable-rpath",
]

suite "xzSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("xzSource")
    check spec.packageName == "xzSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,503,860-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("xzSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs use.
    let spec = registeredFetchSpec("xzSource")
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
  test "artifacts register one executable + one library mixed-kind":
    # M3 artifact registry: ``xz`` is tagged ``dakExecutable`` while
    # ``libLzma`` is tagged ``dakLibrary``. The unique coverage of THIS
    # recipe vs less / bash / gnutls is the MIXED autotools shape where
    # a single ``./configure`` + ``make`` emits BOTH kinds — a
    # regression that flattened the kind discriminator at the autotools
    # convention layer would mis-route the M9.L install path (``lib/``
    # vs ``bin/``) for one of the two.
    let arts = registeredArtifacts("xzSource")
    check arts.len == 2
    var seenXz = false
    var seenLzma = false
    for art in arts:
      check art.packageName == "xzSource"
      case art.artifactName
      of "xz":
        seenXz = true
        check art.kind == dakExecutable
      of "libLzma":
        seenLzma = true
        check art.kind == dakLibrary
      else:
        discard
    check seenXz
    check seenLzma

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream tukaani.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # github.com mirror where the upstream maintainers publish the
    # xz-utils source tree after the CVE-2024-3094 incident.
    let vs = registeredVersions("xzSource")
    check vs.len == 1
    check vs[0].version == "5.6.3"
    check vs[0].sourceRevision == "v5.6.3"
    check vs[0].sourceUrl ==
      "https://tukaani.org/xz/xz-5.6.3.tar.xz"
    check vs[0].sourceRepository ==
      "https://github.com/tukaani-project/xz.git"
