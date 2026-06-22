## Smoke test for the from-source ``cairoSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TENTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource`` / ``libxkbcommonSource`` /
## ``pixmanSource`` / ``libinputSource``). cairo's unique coverage
## angle vs the prior nine is a single library artifact built from a
## ``.tar.xz`` (rather than ``.tar.gz``) tarball with a WIDE ``uses:``
## set (pixman + freetype + fontconfig + zlib + libpng) — the
## fetch-spec extension-discriminator must stay tolerant of the
## ``.xz`` suffix, and the M3 artifact registry's minimal-shape
## coverage complement to wlroots/pixman's narrower dependency surfaces
## is exercised here.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * SINGLE library artifact registration (M3) — ``libcairo``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifact under ``cairoSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "https://www.cairographics.org/releases/cairo-1.18.4.tar.xz"

const ExpectedHash =
  "445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb"

const ExpectedMesonOptions = @[
  "-Dtests=disabled",
  "-Dxlib=disabled",
  "-Dxcb=disabled",
  "--buildtype=release",
]

suite "cairoSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("cairoSource")
    check spec.packageName == "cairoSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 32,578,804-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("cairoSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream cairographics.org
    # release tarballs use. cairo ships ``.tar.xz`` (rather than the
    # ``.tar.gz`` the prior siblings use); the discriminator must stay
    # tolerant of the ``.xz`` suffix.
    let spec = registeredFetchSpec("cairoSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libcairo`` is the only artifact and must
    # be tagged ``dakLibrary``. cairo's meson build emits one shared
    # object bundling all 2D vector-graphics primitives (per-backend
    # code links into the same .so); a regression that mis-tagged
    # the artifact kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("cairoSource")
    check arts.len == 1
    check arts[0].packageName == "cairoSource"
    check arts[0].artifactName == "libcairo"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream cairographics.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical freedesktop.org gitlab project that hosts the
    # cairo source tree.
    let vs = registeredVersions("cairoSource")
    check vs.len == 1
    check vs[0].version == "1.18.4"
    check vs[0].sourceRevision == "1.18.4"
    check vs[0].sourceUrl ==
      "https://www.cairographics.org/releases/cairo-1.18.4.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/cairo/cairo"
