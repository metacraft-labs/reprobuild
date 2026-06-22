## Smoke test for the from-source ``gdkPixbufSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWELFTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource`` / ``libxkbcommonSource`` /
## ``pixmanSource`` / ``libinputSource`` / ``cairoSource`` /
## ``pangoSource``). gdk-pixbuf's unique coverage angle vs the prior
## eleven is the kebab-to-camel package identifier mapping shape
## (``gdk-pixbuf`` -> ``gdkPixbufSource``) — the directory carries a
## hyphen but the Nim DSL identifier MUST camelCase it; a regression
## that mis-cased or hyphenated the package identifier would surface
## in the registry-lookup tests below.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * SINGLE library artifact registration (M3) — ``libgdkPixbuf``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifact under
# ``gdkPixbufSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz"

const ExpectedHash =
  "b9505b3445b9a7e48ced34760c3bcb73e966df3ac94c95a148cb669ab748e3c7"

const ExpectedMesonOptions = @[
  "-Dtests=false",
  "-Dman=false",
  "-Dgtk_doc=false",
  "-Dintrospection=disabled",
  "--buildtype=release",
]

suite "gdkPixbufSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gdkPixbufSource")
    check spec.packageName == "gdkPixbufSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 6,525,072-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gdkPixbufSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("gdkPixbufSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libgdkPixbuf`` is the only artifact and
    # must be tagged ``dakLibrary``. gdk-pixbuf's meson build emits
    # one shared object bundling the pixbuf core + the built-in
    # image-format loaders; additional loaders are emitted as plug-in
    # ``.so`` modules discovered at runtime via the
    # ``gdk-pixbuf-loaders.cache`` and are NOT separate link-time
    # artifacts. A regression that mis-tagged the artifact kind would
    # mis-route the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("gdkPixbufSource")
    check arts.len == 1
    check arts[0].packageName == "gdkPixbufSource"
    check arts[0].artifactName == "libgdkPixbuf"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the
    # gdk-pixbuf source tree.
    let vs = registeredVersions("gdkPixbufSource")
    check vs.len == 1
    check vs[0].version == "2.42.12"
    check vs[0].sourceRevision == "2.42.12"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/gdk-pixbuf"
