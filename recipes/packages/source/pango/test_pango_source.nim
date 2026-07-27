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
## Coverage across seven test cases:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * Explicit ``build:`` lowering — the emitted Meson setup action
##     carries the exact production option sequence, while the retired
##     build-flags registry stays unavailable.
##   * TWO-library single-package artifact registration (M3) —
##     ``libpango`` AND ``libpangocairo`` both tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source`` and the exact tool/library
##     constraints required by the pinned upstream release.

import std/[strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + build actions + library artifacts under ``pangoSource``
# at module init time.
import ./repro

const ExpectedVersion = "1.56.4"

const ExpectedUrl =
  "https://download.gnome.org/sources/pango/1.56/pango-1.56.4.tar.xz"

const ExpectedHash =
  "17065e2fcc5f5a5bdbffc884c956bfc7c451a96e8c4fb2f8ad837c6413cb5a01"

const ExpectedMesonOptions = @[
  "introspection=disabled",
  "documentation=false",
  "build-testsuite=false",
]

const ExpectedNativeBuildDeps = @[
  "meson >=1.2.0",
  "ninja >=1.10",
  "gcc >=7",
  "python3",
]

const ExpectedBuildDeps = @[
  "glib2 >=2.82",
  "harfbuzz >=8.4.0",
  "fribidi >=1.0.6",
  "freetype >=2.10",
  "fontconfig >=2.15.0",
  "cairo >=1.18.0",
]

suite "pangoSource — from-source recipe smoke test":

  test "fetch spec carries the canonical upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pangoSource")
    check spec.packageName == "pangoSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # GNOME publishes this digest beside the 1.56.4 release tarball.
    # The test pins it locally rather than consulting the network at
    # runtime; the length check also guards against a malformed bump.
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

  test "Meson setup action carries the exact production option sequence":
    # M9.R.6.1 moved recipe options from the retired build-flags
    # registry into the explicit package-level build body. Inspect the
    # resulting typed action rather than treating the source as text.
    let expectedEncoded = ExpectedMesonOptions.join("\x1f")
    var matchingSetupActions = 0
    for action in registeredBuildActions():
      if action.call.providerEntrypointId != "meson.mesonBin.setup":
        continue
      var optionArguments = 0
      var hasExactOptions = false
      for argument in action.call.arguments:
        if argument.name == "options":
          inc optionArguments
          if argument.encodedValue == expectedEncoded:
            hasExactOptions = true
      if hasExactOptions:
        inc matchingSetupActions
        check optionArguments == 1
    check matchingSetupActions == 1

  test "retired build-flags registry cannot shadow explicit options":
    check not compiles((proc (): seq[string] =
      result = registeredBuildFlags("pangoSource", "", "meson"))())
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

  test "release metadata and dependency constraints match upstream":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` and agrees with the
    # independently pinned fetch URL. The repository points at the
    # canonical GNOME gitlab project that hosts the pango source tree.
    let vs = registeredVersions("pangoSource")
    check vs.len == 1
    check vs[0].version == ExpectedVersion
    check vs[0].sourceRevision == ExpectedVersion
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/pango"
    check registeredNativeBuildDeps("pangoSource") ==
      ExpectedNativeBuildDeps
    check registeredBuildDeps("pangoSource") == ExpectedBuildDeps
