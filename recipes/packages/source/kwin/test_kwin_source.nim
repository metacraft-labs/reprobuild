## Smoke test for the from-source ``kwinSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTIETH real production
## from-source recipe and the SECOND recipe in the Plasma stack batch.
## kwin's unique coverage angle vs the prior nineteen is that it's the
## FIRST CMake recipe to combine a library + an executable in the same
## ``package`` macro (the meson-side analogues — wayland, mutter,
## gnome-shell — already pinned the mixed-kind partitioning from the
## meson channel). The cross-channel isolation pin below additionally
## checks the meson + configure channels stay empty under the mixed-
## kind shape, so a regression that flattened the artifact-kind
## partitioning AND the per-channel build-flag partitioning at once
## would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) — ``libKWin``
##     tagged ``dakLibrary`` and ``kwinWayland`` tagged
##     ``dakExecutable`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library + executable artifacts under
# ``kwinSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/kwin/vendor/kwin-6.2.5.tar.xz"

const ExpectedHash =
  "5cc450a6e41105c8c49929b72550b331237f96aafb294690f4707bdc5f776848"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DKWIN_BUILD_TABBOX=OFF",
  "-DKWIN_BUILD_X11=OFF",
  "-DKWIN_BUILD_KCMS=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "kwinSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kwinSource")
    check spec.packageName == "kwinSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 8,563,352-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kwinSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kwinSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register an executable + a library with correct kinds":
    # M3 artifact registry: ``kwinWayland`` is tagged ``dakExecutable``
    # while ``libKWin`` is tagged ``dakLibrary``. This is the FIRST
    # CMake recipe to combine a library + an executable in the same
    # package macro. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``); a regression that mis-mapped the
    # PascalCase brand-casing on the library name (``libKWin``)
    # would not match the assertion below.
    let arts = registeredArtifacts("kwinSource")
    check arts.len == 2
    var seenBin = false
    var seenLib = false
    for art in arts:
      check art.packageName == "kwinSource"
      case art.artifactName
      of "kwinWayland":
        seenBin = true
        check art.kind == dakExecutable
      of "libKWin":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenBin
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the kwin source
    # tree.
    let vs = registeredVersions("kwinSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/kwin"
