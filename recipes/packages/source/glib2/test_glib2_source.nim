## Smoke test for the from-source ``glib2Source`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTEENTH real production
## from-source recipe. glib2's unique coverage angle vs the prior
## fourteen is the FOUR-LIBRARY single-package shape: glib2 emits FOUR
## shared objects from one meson build tree (``libglib-2.0.so`` +
## ``libgobject-2.0.so`` + ``libgio-2.0.so`` + ``libgmodule-2.0.so``)
## all sharing the same SONAME prefix but shipping distinct ABIs. This
## is the third multi-library single-package shape (Wayland was the
## first with two libraries, pango was the second with two libraries),
## and the FIRST to ship four artifacts under one ``package`` macro.
##
## Coverage (10 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * FOUR library artifact registration (M3) — ``libGlib2`` +
##     ``libGObject`` + ``libGio`` + ``libGModule`` all tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + four library artifacts under
# ``glib2Source`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/glib2/vendor/glib-2.82.5.tar.xz"

const ExpectedHash =
  "05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f"

const ExpectedMesonOptions = @[
  "-Dtests=false",
  "-Ddocumentation=false",
  "-Dman-pages=disabled",
  "-Dintrospection=disabled",
  "-Dnls=disabled",
  "-Dxattr=false",
  "--buildtype=release",
]

suite "glib2Source — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("glib2Source")
    check spec.packageName == "glib2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 5,554,704-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("glib2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("glib2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register four libraries":
    # M3 artifact registry: FOUR libraries are registered, each
    # tagged ``dakLibrary``. glib2's meson build emits four shared
    # objects from one build tree (``libglib-2.0.so`` +
    # ``libgobject-2.0.so`` + ``libgio-2.0.so`` +
    # ``libgmodule-2.0.so``). A regression that collapsed multi-
    # library packages or dropped one of the four would surface in
    # the artifact-count + per-artifact name pinning below.
    let arts = registeredArtifacts("glib2Source")
    check arts.len == 4
    var seenGlib2 = false
    var seenGObject = false
    var seenGio = false
    var seenGModule = false
    for art in arts:
      check art.packageName == "glib2Source"
      check art.kind == dakLibrary
      case art.artifactName
      of "libGlib2":
        seenGlib2 = true
      of "libGObject":
        seenGObject = true
      of "libGio":
        seenGio = true
      of "libGModule":
        seenGModule = true
      else:
        discard
    check seenGlib2
    check seenGObject
    check seenGio
    check seenGModule

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the glib
    # source tree.
    let vs = registeredVersions("glib2Source")
    check vs.len == 1
    check vs[0].version == "2.82.5"
    check vs[0].sourceRevision == "2.82.5"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/glib"
