## Smoke test for the from-source ``qt6BaseSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-SIXTH real
## production from-source recipe and the SIXTH CMake-driven recipe
## (json-c, kcoreaddons, kwin, plasma-workspace, sddm precedents).
## qt6-base's unique coverage angle vs the prior twenty-five recipes
## is that it's the FIRST recipe to ship SIX library artifacts from a
## single ``package`` macro — every prior multi-artifact recipe shipped
## two (wayland's libs, pango, mutter / gnome-shell / kwin /
## plasma-workspace / gdm pairs), three (sddm) or four (glib2). The
## six-artifact cardinality stresses the M3 registry's ability to keep
## six distinct ``dakLibrary`` entries disambiguated within a single
## package's artifact set.
##
## qt6-base is ALSO the LARGEST vendored recipe in the corpus by far
## (48.2 MB compressed vs the second-largest plasma-workspace at
## 19.1 MB and the prior champion kwin at 8.6 MB). The vendor-vs-
## upstream-URL choice is documented in the recipe comment block: we
## vendor because 48 MB sits well below the kernel-precedent 90 MB
## cutoff for the upstream-URL fallback.
##
## Coverage (16 check assertions across 9 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * SIX library artifact registration (M3) — ``libQt6Core``,
##     ``libQt6Gui``, ``libQt6Widgets``, ``libQt6Network``,
##     ``libQt6DBus``, ``libQt6Sql`` all tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + six library artifacts under
# ``qt6BaseSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/qt6-base/vendor/qtbase-everywhere-src-6.8.1.tar.xz"

const ExpectedHash =
  "40b14562ef3bd779bc0e0418ea2ae08fa28235f8ea6e8c0cb3bce1d6ad58dcaf"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
  "-DFEATURE_developer_build=OFF",
  "-DFEATURE_xcb=OFF",
  "-DFEATURE_dbus=ON",
  "-DFEATURE_sql_sqlite=ON",
  "-DFEATURE_widgets=ON",
]

suite "qt6BaseSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    # The 48-MB tarball is vendored (well under GitHub's 100-MB
    # single-file ceiling; the kernel-style upstream-URL fallback
    # would only kick in above ~90 MB).
    let spec = registeredFetchSpec("qt6BaseSource")
    check spec.packageName == "qt6BaseSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 48,220,752-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("qt6BaseSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.qt.io
    # release tarballs use (top-level dir inside is
    # ``qtbase-everywhere-src-6.8.1/`` which we strip).
    let spec = registeredFetchSpec("qt6BaseSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the CMake channel — CMake
    # evaluates ``-D`` overrides left-to-right and a regression that
    # reorders this seq would silently change build behaviour
    # (testing, build-type, developer-build, xcb, dbus, sqlite,
    # widgets). The SEVEN-element length pin also catches a regression
    # that truncated the seq at a specific index.
    let flags = registeredBuildFlags("qt6BaseSource", "", "cmake")
    check flags == ExpectedCmakeFlags
    check flags.len == 7

  test "cmakeFlags does not leak into the meson channel":
    # Cross-channel isolation under the six-artifact mixed-kind shape
    # — guards against a regression that simultaneously collapsed the
    # six-artifact partitioning AND the per-channel build-flag
    # partitioning.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("qt6BaseSource", "", "meson") == emptyStrSeq

  test "cmakeFlags does not leak into the configure channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the CMake + autotools channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("qt6BaseSource", "", "configure") == emptyStrSeq

  test "artifacts register six libraries with correct kinds":
    # M3 artifact registry: all six artifacts must be tagged
    # ``dakLibrary``. This is the FIRST recipe in the corpus to ship
    # six artifacts from a single ``package`` macro; a regression that
    # collapsed the artifact-name partitioning at the six-artifact
    # cardinality would not produce six distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("qt6BaseSource")
    check arts.len == 6
    var seenCore = false
    var seenGui = false
    var seenWidgets = false
    var seenNetwork = false
    var seenDBus = false
    var seenSql = false
    for art in arts:
      check art.packageName == "qt6BaseSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libQt6Core":
        seenCore = true
      of "libQt6Gui":
        seenGui = true
      of "libQt6Widgets":
        seenWidgets = true
      of "libQt6Network":
        seenNetwork = true
      of "libQt6DBus":
        seenDBus = true
      of "libQt6Sql":
        seenSql = true
      else:
        discard
    check seenCore
    check seenGui
    check seenWidgets
    check seenNetwork
    check seenDBus
    check seenSql

  test "artifacts preserve the upstream PascalCase brand-casing":
    # M3 artifact-name partitioning under the SIX-artifact cardinality:
    # every artifact name preserves the ``libQt6X`` PascalCase shape
    # (where X is the Qt6 module name). A regression that mangled the
    # casing (e.g. lowercased to ``libqt6core``) or stripped the
    # ``Qt6`` prefix would silently break the M3 -> M9.L install-path
    # lookup which keys on the exact artifact identifier.
    let arts = registeredArtifacts("qt6BaseSource")
    var prefixMatches = 0
    for art in arts:
      if art.artifactName.len >= 5 and art.artifactName[0..4] == "libQt":
        inc prefixMatches
    check prefixMatches == 6

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.qt.io release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical code.qt.io qtbase git repository that hosts the
    # qt6-base source tree.
    let vs = registeredVersions("qt6BaseSource")
    check vs.len == 1
    check vs[0].version == "6.8.1"
    check vs[0].sourceRevision == "v6.8.1"
    check vs[0].sourceUrl ==
      "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtbase-everywhere-src-6.8.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://code.qt.io/qt/qtbase.git"
