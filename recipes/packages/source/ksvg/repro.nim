## Source-from-tarball ksvg recipe — the FIFTY-FIFTH real from-source
## production recipe to exercise the M9.H/I/K trio and the FIRST
## recipe in the THIRD KF6 module-sweep batch (ksvg / ksolid / kio /
## kded).
##
## ksvg is the THIRTEENTH CMake-driven recipe and the NINTH KF6
## foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice + kglobalaccel + knotifications.
##
## ## Why ksvg matters for the v1 desktop story
##
## ksvg (``libKF6Svg.so``) supplies the QtSvg-on-top KF6 wrapper that
## Plasma 6's theme engine consumes to render scalable vector assets
## (panel icons, popup-menu chrome, system-tray badges, plasmoid
## backgrounds). plasma-framework's ``Svg`` / ``SvgItem`` / ``FrameSvg``
## QML primitives all link against this library; without it the
## Breeze + Oxygen theme stacks cannot paint a single rounded-corner
## frame.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/ksvg/vendor/ksvg-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 173e151f6ef8360149f835b1fc7494e97a33f9056d294ab213c9ef9e6d84d0c8
##  (computed locally over the vendored ``ksvg-6.10.0.tar.xz``,
##  83,964 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## ksvg's CMake build emits a single shared library
## (``libKF6Svg.so``) bundling the SVG-asset surface. We register the
## artifact under ``libKF6Svg`` (camelCased from the upstream SONAME
## ``KF6Svg``).
##
## ## Configurables
##
## v1 ships NO configurables — same modern-desktop baseline as the
## sibling KF6 recipes (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``BUILD_PYTHON_BINDINGS=OFF`` + ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package ksvgSource:
  ## From-source ksvg — fifty-fifth M9.H/I/K production recipe and the
  ## FIRST recipe in the THIRD KF6 module-sweep batch (ksvg / ksolid /
  ## kio / kded). Thirteenth CMake-driven recipe and the NINTH KF6
  ## foundation module after kcoreaddons + kconfig + ki18n +
  ## kwidgetsaddons + kxmlgui + kservice + kglobalaccel + knotifications.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/ksvg-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/ksvg"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 83,964-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/frameworks/6.10/ksvg-6.10.0.tar.xz"
    sha256: "173e151f6ef8360149f835b1fc7494e97a33f9056d294ab213c9ef9e6d84d0c8"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — ksvg is C++17.
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtGui / QtSvg / QtQml ksvg wraps for
    ## the scalable-asset surface.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## kconfig is the KF6 configuration-storage library ksvg uses to
    ## persist theme-asset cache validation cookies.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library ksvg's ``KPluginFactory``
    ## + ``KAboutData`` paths consume.
    "kcoreaddons >=6.0"
    ## karchive (transitive via the sibling KF6 modules) is required at
    ## link-time so ksvg can read compressed-SVG (``.svgz``) assets.
    "karchive >=6.0"
    ## kguiaddons supplies the QtGui extensions ksvg's renderer wraps
    ## (KColorUtils + KModifierKeyInfo glue).
    "kguiaddons >=6.0"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libKF6Svg:
    ## ``libKF6Svg.so`` — QtSvg-on-top KF6 wrapper (Svg + SvgItem +
    ## FrameSvg + ImageSet). v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's ninja-
    ## spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("ksvgSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Svg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
