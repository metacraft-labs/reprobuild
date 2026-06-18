## Smoke test for the from-source ``kconfigSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-SIXTH real
## production from-source recipe and the FIRST recipe in the KF6
## module-sweep batch (kconfig / ki18n / kwidgetsaddons / kxmlgui).
## kconfig's unique coverage angle vs the prior thirty-five is that
## it's the FIRST CMake recipe in the corpus to ship THREE library
## artifacts from a single ``package`` macro — every prior multi-
## artifact CMake recipe shipped at most two. The cross-channel
## isolation pin below additionally checks the meson + configure
## channels stay empty under the three-library shape, so a regression
## that flattened the artifact partitioning AND the per-channel build-
## flag partitioning at once would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * THREE library artifact registration (M3) — ``libKF6Config`` +
##     ``libKF6ConfigCore`` + ``libKF6ConfigGui`` all tagged
##     ``dakLibrary`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + three library artifacts under
# ``kconfigSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/kconfig/vendor/kconfig-6.10.0.tar.xz"

const ExpectedHash =
  "00ef2c75be68bacf8c30e3bf072358b8f6d2bc78d462e7b14c086808c69d8d7f"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_QCH=OFF",
  "-DBUILD_PYTHON_BINDINGS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kconfigSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kconfigSource")
    check spec.packageName == "kconfigSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 349,400-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kconfigSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kconfigSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the CMake channel — CMake
    # evaluates ``-D`` overrides left-to-right and a regression that
    # reorders this seq would silently change build behaviour
    # (testing, qch, python-bindings, release/debug).
    let flags = registeredBuildFlags("kconfigSource", "", "cmake")
    check flags == ExpectedCmakeFlags
    check flags.len == 4

  test "cmakeFlags does not leak into the meson channel":
    # Cross-channel isolation under the three-library shape — guards
    # against a regression that simultaneously flattened the per-channel
    # registries AND the artifact-set partitioning.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kconfigSource", "", "meson") == emptyStrSeq

  test "cmakeFlags does not leak into the configure channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the CMake + autotools channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kconfigSource", "", "configure") == emptyStrSeq

  test "artifacts register THREE libraries with dakLibrary kind":
    # M3 artifact registry: ``libKF6Config`` + ``libKF6ConfigCore`` +
    # ``libKF6ConfigGui`` are ALL tagged ``dakLibrary``. This is the
    # FIRST CMake recipe to ship three library artifacts from a single
    # package macro. A regression that mis-tagged any artifact kind
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``); a
    # regression that dropped one of the three would shrink the
    # registry below three entries.
    let arts = registeredArtifacts("kconfigSource")
    check arts.len == 3
    var seenUmbrella = false
    var seenCore = false
    var seenGui = false
    for art in arts:
      check art.packageName == "kconfigSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libKF6Config":     seenUmbrella = true
      of "libKF6ConfigCore": seenCore = true
      of "libKF6ConfigGui":  seenGui = true
      else: discard
    check seenUmbrella
    check seenCore
    check seenGui

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the kconfig
    # source tree.
    let vs = registeredVersions("kconfigSource")
    check vs.len == 1
    check vs[0].version == "6.10.0"
    check vs[0].sourceRevision == "v6.10.0"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/frameworks/6.10/kconfig-6.10.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/frameworks/kconfig"
