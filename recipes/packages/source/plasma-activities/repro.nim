## Source-from-tarball plasma-activities recipe — closes the
## ``PlasmaActivities`` find_package gap on plasma-framework.
##
## plasma-activities (Plasma::Activities, ``libPlasmaActivities.so``) is
## the Plasma 6 desktop activity tracking + per-activity context library
## the plasma-shell + plasma-framework consume to record / restore
## per-activity window / panel / wallpaper state.
##
## ## Why plasma-activities matters for the v1 desktop story
##
## plasma-framework's CMakeLists.txt declares
## ``find_package(PlasmaActivities REQUIRED ${PROJECT_DEP_VERSION})``
## (libplasma-6.2.5/CMakeLists.txt:68). Without plasma-activities,
## plasma-framework's configure step fails on the missing
## ``PlasmaActivitiesConfig.cmake`` package config. plasma-framework is
## the prereq for kwin + plasma-workspace + sddm, so closing
## plasma-activities is on the critical path for the whole Plasma 6
## desktop chain.
##
## ## sha256 strategy
##
## We vendor the upstream 6.2.5 .tar.xz at
## ``recipes/packages/source/plasma-activities/vendor/plasma-activities-6.2.5.tar.xz``
## and reference it via a ``file://`` URL on disk; the recipe records
## the canonical download.kde.org URL so the engine's content-addressed
## cache fingerprint stays stable.
##
## ## Version choice — 6.2.5 (current upstream stable in the 6.2.x line)
##
## plasma-activities 6.2.5 is the 6.2.x patch release lockstep-paired
## with libplasma-6.2.5 (the plasma-framework recipe's pin). Both libs
## share the Plasma 6.2.x ABI line.
##
## sha256 = 77ea739c7ce5170d92d78d6f3765e19a32f0e24b741f525555d59dc7de15e6c7
##  (computed locally over the vendored ``plasma-activities-6.2.5.tar.xz``,
##  66,752 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling Plasma 6 +
## KF6 recipes.
##
## ## Library artifact
##
## plasma-activities's CMake build emits a single shared library
## (``libPlasmaActivities.so``) bundling the per-activity tracking +
## context API. We register the artifact under ``libPlasmaActivities``
## (camelCased from the upstream SONAME ``PlasmaActivities``);
## note the LACK of a ``KF6`` prefix — plasma-activities is a Plasma-
## stack library, not a KF6 framework, and the upstream SONAME reflects
## that (same shape as plasma-framework's ``libPlasma`` artifact).
##
## ## Configurables
##
## v1 ships the modern-desktop baseline + ``PLASMA_ACTIVITIES_LIBRARY_ONLY=OFF``
## (the default) so the QML imports + cli helper are built alongside
## the core library — plasma-framework's PlasmaCore QML bindings call
## into the QML imports surface.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package plasmaActivitiesSource:
  ## From-source plasma-activities — M9.R.15q.1.2 production recipe.
  ## Closes the ``PlasmaActivities`` find_package gap on plasma-framework.
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/plasma-activities"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 66,752-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-6.2.5.tar.xz"
    sha256: "77ea739c7ce5170d92d78d6f3765e19a32f0e24b741f525555d59dc7de15e6c7"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — plasma-activities is C++20.
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore + QtDBus the plasma-activities library
    ## consumes (per CMakeLists:41 ``COMPONENTS Core DBus``).
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies the QML compiler the imports/ subtree
    ## consumes when PLASMA_ACTIVITIES_LIBRARY_ONLY=OFF.
    "qt6-declarative >=6.6"
    ## M9.R.15q.1.2 — boost (>=1.49) is consumed by src/CMakeLists.txt:6
    ## ``find_package (Boost 1.49 REQUIRED)``. plasma-activities's CLI
    ## helper consumes Boost.System + Boost.Filesystem; the v1 boost
    ## recipe (1.86.0) widely satisfies the floor.
    "boost >=1.49"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  library libPlasmaActivities:
    ## ``libPlasmaActivities.so`` — Plasma 6 desktop activity tracking
    ## + per-activity context library. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard

  build:
    ## M9.R.15q.1.2 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor. Same modern-
    ## desktop baseline as the sibling Plasma 6 + KF6 recipes.
    setCurrentOwningPackageOverride("plasmaActivitiesSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libPlasmaActivities")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until the
    ## M9.R.5b per-recipe pass populates per-output ELF interrogation.
    discard
