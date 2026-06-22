## Source-from-tarball qt6-positioning recipe — M9.R.15q.9.1 KF6/Plasma blocker.
## qt6-positioning supplies QtPositioning (``libQt6Positioning.so`` +
## ``libQt6PositioningQuick.so``) which plasma-workspace's CMakeLists.txt
## explicitly demands via
## ``find_package(Qt6 ... COMPONENTS ... Positioning)``.  Without
## qt6-positioning the plasma-workspace configure step hard-fails with
##
##   Failed to find required Qt component "Positioning".
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-positioning/vendor/qtpositioning-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 661 KiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling ``qt6-svg`` vendors a 2-MiB qtsvg tarball
## with the same strategy.
##
## sha256 = e310e7232591d4beb1785bfff8ff3e77430bdf5e9a17f56694b732f5267df78d
##  (computed locally over the vendored
##  ``qtpositioning-everywhere-src-6.8.1.tar.xz``, 661,544 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below; cross-checked against the upstream HTTP Digest: SHA-256
##  header on download.qt.io's HEAD response —
##  ``SHA-256=4xDnIyWR1L6xeFv/+P8+d0ML316aF/VmlLcy9SZ9940=`` base64-
##  decoded to the same hex digest above).
##
## ## Version choice — 6.8.1 (matches qt6-base + qt6-tools + qt6-declarative + qt6-svg)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## qt6-base + qt6-tools + qt6-declarative + qt6-svg sibling recipes
## pin the same 6.8.1 tag; the Qt module set is built as a coordinated
## release so cross-module ABI matches tag-for-tag.
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
## qt6-positioning's CMake build emits two shared libraries that
## plasma-workspace's positioning consumers link against:
##
##   * ``libQt6Positioning.so``       — the Qt Positioning core library.
##   * ``libQt6PositioningQuick.so``  — the QML-binding shim.
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
##                                     qt6-tools / qt6-declarative /
##                                     qt6-svg recipes.
##   * ``QT_BUILD_TESTS=OFF``       — Qt-side test-build disable.
##   * ``QT_BUILD_EXAMPLES=OFF``    — skip the upstream examples build.
##   * ``QT_GENERATE_SBOM=OFF``     — SBOM gen hard-codes the canonical
##                                     install prefix and fails when our
##                                     cmake_package install passes a
##                                     different ``--prefix``.  Same
##                                     trip as qt6-base / qt6-tools /
##                                     qt6-declarative / qt6-svg.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6PositioningSource:
  ## From-source qt6-positioning — M9.R.15q.9.1 KF6/Plasma blocker.
  ## Sibling to qt6-base (qt6BaseSource), qt6-tools (qt6ToolsSource),
  ## qt6-declarative (qt6DeclarativeSource), qt6-svg (qt6SvgSource);
  ## shares the same 6.8.1 pin.

  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtpositioning-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtpositioning.git"

  fetch:
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtpositioning-everywhere-src-6.8.1.tar.xz"
    sha256: "e310e7232591d4beb1785bfff8ff3e77430bdf5e9a17f56694b732f5267df78d"
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
    "qt6-declarative >=6.8"

  config:
    discard

  library libQt6Positioning:
    ## ``libQt6Positioning.so`` — the Qt Positioning core library that
    ## plasma-workspace's Qt6 ``COMPONENTS Positioning`` find_package
    ## probe demands. v1 records the artifact only.
    discard

  library libQt6PositioningQuick:
    ## ``libQt6PositioningQuick.so`` — the QML-binding shim built on
    ## top of QtPositioning + QtQuick. v1 records the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("qt6PositioningSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15q.9.1 — Qt6's SBOM module hard-codes
        # ``/usr/local/Qt-6.8.1`` as the canonical install prefix when
        # computing per-artifact checksums (same trip as qt6-base
        # M9.R.15f.3 + qt6-tools M9.R.15h.1.4 + qt6-declarative
        # M9.R.15j.1 + qt6-svg M9.R.15k.1). The
        # ``cmake --install --prefix <buildDir>/out/usr`` we emit
        # doesn't match the baked-in prefix, so install fails with
        # "Cannot find <file> to compute its checksum". Disable SBOM
        # gen for v1.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6Positioning")
      discard pkg.library("libQt6PositioningQuick")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
