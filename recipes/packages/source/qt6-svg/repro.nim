## Source-from-tarball qt6-svg recipe — M9.R.15k.1 KF6/Plasma blocker.
## qt6-svg supplies QtSvg (libQt6Svg.so) which kiconthemes/ksvg/kxmlgui
## consume to render scalable SVG icon themes and Plasma's scalable
## widget assets. Without qt6-svg, the kglobalacceld → kwin compositor
## chain cannot close.
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-svg/vendor/qtsvg-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 2-MiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling ``qt6-base`` vendors the matching 48-MiB
## qtbase tarball, ``qt6-declarative`` vendors the 36-MiB
## qtdeclarative tarball, and ``qt6-tools`` vendors the 10-MiB qttools
## tarball with the same strategy.
##
## sha256 = 3d0de73596e36b2daa7c48d77c4426bb091752856912fba720215f756c560dd0
##  (computed locally over the vendored
##  ``qtsvg-everywhere-src-6.8.1.tar.xz``, 2,006,760 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below; cross-checked against the upstream HTTP Digest: SHA-256
##  header on download.qt.io's HEAD response —
##  ``SHA-256=PQ3nNZbjay2qfEjXfEQmuwkXUoVpEvunICFfdWxWDdA=`` base64-
##  decoded to the same hex digest above).
##
## ## Version choice — 6.8.1 (matches qt6-base + qt6-tools + qt6-declarative)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## qt6-base + qt6-tools + qt6-declarative sibling recipes pin the same
## 6.8.1 tag; the Qt module set is built as a coordinated release so
## cross-module ABI matches tag-for-tag.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the inlined ``cmake_package`` flags and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in the inlined ``opts`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction.
##   4. install/output collection actions for the libraries.
##
## ## Library artifacts
##
## qt6-svg's CMake build emits a single shared library that
## kiconthemes / ksvg / kxmlgui consume:
##
##   * ``libQt6Svg.so``     — the Qt SVG renderer.
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline:
##
##   * ``BUILD_TESTING=OFF``        — skip the upstream test suite to
##                                     keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches sibling qt6-base /
##                                     qt6-tools / qt6-declarative
##                                     recipes.
##   * ``QT_BUILD_TESTS=OFF``       — Qt-side test-build disable.
##   * ``QT_BUILD_EXAMPLES=OFF``    — skip the upstream examples build.
##   * ``QT_GENERATE_SBOM=OFF``     — SBOM gen hard-codes the canonical
##                                     install prefix and fails when our
##                                     cmake_package install passes a
##                                     different ``--prefix``.  Same
##                                     trip as qt6-base / qt6-tools /
##                                     qt6-declarative.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6SvgSource:
  ## From-source qt6-svg — M9.R.15k.1 KF6/Plasma blocker. Sibling to
  ## qt6-base (qt6BaseSource), qt6-tools (qt6ToolsSource), and
  ## qt6-declarative (qt6DeclarativeSource); shares the same 6.8.1 pin.

  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtsvg-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtsvg.git"

  fetch:
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtsvg-everywhere-src-6.8.1.tar.xz"
    sha256: "3d0de73596e36b2daa7c48d77c4426bb091752856912fba720215f756c560dd0"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.21"
    "ninja >=1.10"
    "gcc >=11"
    "perl >=5.32"
    "pkg-config"
    "python3 >=3.8"
    "qt6-tools >=6.8"

  buildDeps:
    "qt6-base >=6.8"

  config:
    discard

  library libQt6Svg:
    ## ``libQt6Svg.so`` — the Qt SVG renderer KF6 consumes through
    ## kiconthemes / ksvg / kxmlgui for scalable icon-theme rendering
    ## and Plasma's scalable widget assets. v1 records the artifact
    ## only.
    discard

  build:
    setCurrentOwningPackageOverride("qt6SvgSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15k.1 — Qt6's SBOM module hard-codes
        # ``/usr/local/Qt-6.8.1`` as the canonical install prefix when
        # computing per-artifact checksums (same trip as qt6-base
        # M9.R.15f.3 + qt6-tools M9.R.15h.1.4 + qt6-declarative
        # M9.R.15j.1). The ``cmake --install --prefix <buildDir>/out/usr``
        # we emit doesn't match the baked-in prefix, so install fails
        # with "Cannot find <file> to compute its checksum". Disable
        # SBOM gen for v1.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6Svg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
