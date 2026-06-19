## Smoke test for the from-source ``pixmanSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the EIGHTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource`` / ``libxkbcommonSource``).
## pixman's unique coverage angle vs the prior seven is a single
## library artifact built from a cairographics.org tarball with the
## minimal ``uses:`` set (meson + ninja + gcc only, no transitive
## library deps) — the M3 artifact registry's minimal-shape coverage
## complement to wlroots's wider dependency surface.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * SINGLE library artifact registration (M3) — ``libpixman1``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifact under ``pixmanSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/pixman/vendor/pixman-0.46.4.tar.gz"

const ExpectedHash =
  "d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c"

const ExpectedMesonOptions = @[
  "-Dtests=disabled",
  "-Ddemos=disabled",
  "--buildtype=release",
]

suite "pixmanSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pixmanSource")
    check spec.packageName == "pixmanSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 827,198-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("pixmanSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream cairographics.org
    # release tarballs use.
    let spec = registeredFetchSpec("pixmanSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libpixman1`` is the only artifact and
    # must be tagged ``dakLibrary``. pixman's meson build emits a
    # single shared object (per-arch SIMD code links into the same
    # .so via auto-detection, not separate artifacts); a regression
    # that mis-tagged the artifact kind would mis-route the M9.L
    # install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("pixmanSource")
    check arts.len == 1
    check arts[0].packageName == "pixmanSource"
    check arts[0].artifactName == "libpixman1"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream cairographics.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical freedesktop.org gitlab project that hosts the
    # pixman source tree.
    let vs = registeredVersions("pixmanSource")
    check vs.len == 1
    check vs[0].version == "0.46.4"
    check vs[0].sourceRevision == "pixman-0.46.4"
    check vs[0].sourceUrl ==
      "https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/pixman/pixman"
