## Source-from-tarball kirigami recipe — M9.R.15p.3.1 KF6/Plasma
## blocker. kirigami supplies the QML-based UI framework KF6's
## convergent (mobile + desktop) applications consume:
##
##   * ``libKF6Kirigami.so``         — the Kirigami QML platform layer:
##                                      cross-platform UI primitives,
##                                      convergent navigation patterns,
##                                      theming hooks, and the platform-
##                                      abstraction layer (KirigamiPlatform)
##                                      that ksvg + plasma-framework
##                                      consume.
##
## Without kirigami, ksvg's ``find_package(KF6 ... KirigamiPlatform)``
## fails at configure time, blocking plasma-framework, kwin, and the
## broader Plasma desktop stack.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kirigami/vendor/kirigami-6.10.0.tar.xz``
## and reference it via the canonical download.kde.org URL.
##
## sha256 = 2e245ffd79eca1fcfb591f43ff39e7c2f5160e868a36e20ebbe2d66c550da8d4
##  (computed locally over the vendored 558,268-byte tarball;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below).
##
## ## Version choice — 6.10.0 (matches sibling KF6 modules)
##
## Same lockstep ABI rationale as the other KF6 6.10.x modules
## (kxmlgui / kpackage / kcrash / etc.) — KDE Frameworks 6.10.x is
## the current upstream stable in the 6.x line and the recipes track
## a single tag-set for cross-module ABI compatibility.
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 / Qt6
## recipes. The CMake build emits ``libKF6Kirigami.so`` + the
## KirigamiPlatform CMake-config consumed by ksvg.
##
## ## Library artifact
##
## kirigami's CMake build emits a single shared library
## (``libKF6Kirigami.so``) bundling the Kirigami QML platform layer.
## We register the artifact under ``libKF6Kirigami`` (camelCased from
## the upstream SONAME ``KF6Kirigami``).
##
## ## Configurables
##
## v1 ships NO configurables — same modern-desktop baseline as the
## sibling KF6 recipes (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kirigamiSource:
  ## From-source kirigami — M9.R.15p.3.1 KF6/Plasma blocker.
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe. M9.R.15p.0's package-macro auto-injection handles
  ## libxkbcommon + mesa transparently for all qt6-* consumers.

  versions:
    ## Pinned upstream tag.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kirigami-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kirigami"

  fetch:
    ## Vendored tarball; URL records the canonical download.kde.org
    ## upstream so the engine's fetch cache is content-addressed by
    ## sha256.
    url: "https://download.kde.org/stable/frameworks/6.10/kirigami-6.10.0.tar.xz"
    sha256: "2e245ffd79eca1fcfb591f43ff39e7c2f5160e868a36e20ebbe2d66c550da8d4"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kirigami is C++17.
    "gcc >=11"
    ## qt6-tools supplies qhelpgenerator (QCH doc generation) and the
    ## Qt6QmlIntegration linguist tooling consumed by the QML modules.
    "qt6-tools >=6.6"

  buildDeps:
    ## extra-cmake-modules is the KF6 CMake macros + find-modules
    ## library kirigami's CMakeLists.txt:23 invokes via
    ## ``find_package(ECM 6.10.0 REQUIRED NO_MODULE)``.
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtGui / QtConcurrent / QtDBus the
    ## kirigami QML modules link against. CMakeLists.txt:34 invokes
    ## ``find_package(Qt6 ... COMPONENTS Core Quick Gui Svg
    ## QuickControls2 Concurrent ShaderTools)`` REQUIRED.
    "qt6-base >=6.6"
    ## qt6-declarative supplies Qt6Qml / Qt6Quick / Qt6QuickControls2
    ## the kirigami QML modules consume.
    "qt6-declarative >=6.6"
    ## qt6-svg supplies Qt6Svg the kirigami theme rendering uses for
    ## SVG icon assets.
    "qt6-svg >=6.6"
    ## qt6-shadertools supplies Qt6ShaderTools the kirigami compositor-
    ## side QtQuick scene-graph shader compilation consumes.
    "qt6-shadertools >=6.6"
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive``); no explicit per-recipe
    ## declarations needed.

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  library libKirigamiPlatform:
    ## ``libKirigamiPlatform.so`` — the platform-abstraction layer
    ## ksvg's ``find_package(KF6 ... KirigamiPlatform)`` resolves
    ## against. v1 records the artifact only.
    discard

  library libKirigamiPrimitives:
    ## ``libKirigamiPrimitives.so`` — QML-side primitive types
    ## (theme palette, scaling units) consumed via the kirigami
    ## QML import.
    discard

  library libKirigamiPrivate:
    ## ``libKirigamiPrivate.so`` — internal helpers used only by the
    ## sibling kirigami shared libraries.
    discard

  library libKirigamiDelegates:
    ## ``libKirigamiDelegates.so`` — QML-side delegate types
    ## (ListItemDelegate, SwipeListItem, etc.).
    discard

  library libKirigamiDialogs:
    ## ``libKirigamiDialogs.so`` — QML-side modal-dialog widgets.
    discard

  library libKirigamiLayouts:
    ## ``libKirigamiLayouts.so`` — QML-side layout primitives
    ## (FormLayout, etc.).
    discard

  library libKirigami:
    ## ``libKirigami.so`` — the main aggregator library exposing
    ## the Kirigami C++ public API.
    discard

  build:
    ## M9.R.15p.3.1 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor.
    setCurrentOwningPackageOverride("kirigamiSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKirigamiPlatform")
      discard pkg.library("libKirigamiPrimitives")
      discard pkg.library("libKirigamiPrivate")
      discard pkg.library("libKirigamiDelegates")
      discard pkg.library("libKirigamiDialogs")
      discard pkg.library("libKirigamiLayouts")
      discard pkg.library("libKirigami")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
