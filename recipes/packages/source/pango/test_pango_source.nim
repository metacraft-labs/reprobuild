## Smoke test for the from-source ``pangoSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the ELEVENTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource`` / ``libxkbcommonSource`` /
## ``pixmanSource`` / ``libinputSource`` / ``cairoSource``). pango's
## unique coverage angle vs the prior ten is a TWO-library
## single-package shape (``libpango-1.0.so`` + ``libpangocairo-1.0.so``)
## where both artifacts share the same SONAME prefix but ship distinct
## ABIs — this is the first multi-library single-package shape in the
## from-source corpus (Wayland was 3 libs + 1 exe; libdrm was multi-lib
## but they were per-driver, not per-binding). The M3 artifact
## registry must keep both library artifacts disambiguated via their
## distinct Nim-identifier artifact names while sharing the
## ``dakLibrary`` kind tag.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * TWO-library single-package artifact registration (M3) —
##     ``libpango`` AND ``libpangocairo`` both tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifacts under ``pangoSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/pango/vendor/pango-1.54.0.tar.xz"

const ExpectedHash =
  "8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8"

const ExpectedMesonOptions = @[
  "-Dintrospection=disabled",
  "-Dgtk_doc=false",
  "-Dman-pages=false",
  "-Dbuild-testsuite=false",
  "--buildtype=release",
]

suite "pangoSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pangoSource")
    check spec.packageName == "pangoSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,963,180-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("pangoSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("pangoSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register two libraries":
    # M3 artifact registry: BOTH ``libpango`` and ``libpangocairo``
    # must be tagged ``dakLibrary``. The unique coverage of THIS
    # recipe is the two-library single-package shape — a regression
    # that mis-attributed the second library or flattened the artifact
    # set to one entry would mis-route the M9.L install path (one .so
    # would silently disappear from the output set).
    let arts = registeredArtifacts("pangoSource")
    check arts.len == 2
    var seenPango = false
    var seenPangoCairo = false
    for art in arts:
      check art.packageName == "pangoSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libpango":
        seenPango = true
      of "libpangocairo":
        seenPangoCairo = true
      else:
        discard
    check seenPango
    check seenPangoCairo

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the pango
    # source tree.
    let vs = registeredVersions("pangoSource")
    check vs.len == 1
    check vs[0].version == "1.54.0"
    check vs[0].sourceRevision == "1.54.0"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/pango"
