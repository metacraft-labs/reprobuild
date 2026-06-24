## Source-from-tarball qcoro6 recipe — M9.R.33.1.
##
## QCoro is a C++20 coroutines wrapper for Qt6 (``libQCoro6Core.so``,
## ``libQCoro6DBus.so``, ``libQCoro6Network.so``, ...) that
## plasma-workspace + several KF6 modules link against for async-await-
## style Qt task composition.  Surfaces as a REQUIRED dep on
## plasma-workspace's CMakeLists.txt ``find_package(QCoro6 ...)`` probe.
##
## Prior to M9.R.33.1 ``qcoro6`` existed only as a Nix-channel stub at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/qcoro6.nim``,
## which routed ``--tool-provisioning=from-source`` builds through the
## nixpkgs prebuilt instead of from-source.  M9.R.32.5 documented the
## resulting fresh-configure trip: a clean
## ``rm -rf recipes/packages/source/plasma-workspace/.repro/build &&
## repro build recipes/packages/source/plasma-workspace`` failed with
## "QCoro6 not found" because the nix-store-baked ``QCoro6_DIR`` from a
## prior incremental run was wiped alongside the build dir.
##
## This recipe surfaces qcoro6 cleanly under from-source provisioning
## so a fresh build resolves ``find_package(QCoro6 REQUIRED)`` via the
## sibling install-mirror's ``usr/lib/cmake/QCoro6/QCoro6Config.cmake``.
## The stdlib stub stays in place so the nix-provisioning path keeps
## working; the from-source resolver picks the sibling recipe first
## (same precedence as the qt6-positioning recipe alongside its stub).
##
## ## sha256 strategy
##
## We vendor the upstream 0.12.0 .tar.gz at
## ``recipes/packages/source/qcoro6/vendor/qcoro-0.12.0.tar.gz`` and
## reference it via the github.com release URL.  The convention layer's
## emitted fetch action carries the URL + sha256 verbatim so the engine's
## content-addressed cache fingerprint stays stable across rebuilds.
##
## ## Version choice — 0.12.0
##
## QCoro publishes releases on github.com under tags of the form
## ``v<x.y.z>``.  0.12.0 is the current stable in the 0.12.x line as of
## mid-2026 (released 2024-12-21); the plasma-workspace ``qcoro6 >=0.10``
## floor is satisfied.  0.13.0 is also published but adds a Qt6.8+ floor
## that some KF6 6.x consumers haven't moved to yet; 0.12.0 keeps the
## ABI in lockstep with the rest of the Plasma 6.2.x batch.
##
## sha256 = 809afafab61593f994c005ca6e242300e1e3e7f4db8b5d41f8c642aab9450fbc
##  (computed locally over the vendored ``qcoro-0.12.0.tar.gz``,
##  161,468 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the inlined cmake-flag set off this package's registries
## and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in the ``opts`` sequence to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction.
##   4. install/output collection actions for the library artifact.
##
## ## Library artifact
##
## QCoro's CMake build emits multiple per-Qt-module shared libraries
## (``libQCoro6Core.so``, ``libQCoro6DBus.so``, ``libQCoro6Network.so``,
## ``libQCoro6Qml.so``, ``libQCoro6Quick.so``, ...). The v1 artifact
## registry records the ``libQCoro6Core`` library --- the foundation
## module plasma-workspace's ``find_package(QCoro6 REQUIRED COMPONENTS
## Core DBus)`` umbrella probe resolves first.  The DBus / Network /
## Qml / Quick sub-libraries are picked up by the M9.R.14h.8 per-artifact
## stage-copy + install-mirror probe even though they're not registered
## as named artifacts here: the install-mirror tree is mirrored verbatim
## by the M9.R.27.1 staging mechanism.
##
## ## Configurables
##
## v1 ships NO configurables --- the CMake options are hardcoded to the
## modern-desktop baseline per the M9.R.33 task brief:
##
##   * ``BUILD_TESTING=OFF``        --- skip the upstream test suite to
##                                       keep the build hermetic + fast.
##   * ``QCORO_BUILD_EXAMPLES=OFF`` --- skip the example apps (they pull
##                                       in QtWidgets + QtConcurrent
##                                       beyond the v1 desktop closure).
##   * ``QCORO_WITH_QTQUICK=OFF``   --- skip the QtQuick integration.
##                                       Plasma-workspace's QCoro6 consume
##                                       only Core + DBus + Network; the
##                                       QtQuick integration needs
##                                       Qt6QuickPrivate which qt6-
##                                       declarative's CMake config does
##                                       not export.  A future fullbuild
##                                       milestone can flip this back ON.
##   * ``QCORO_WITH_QML=OFF``       --- ditto (needs Qt6QmlPrivate).
##   * ``QCORO_WITH_QTWEBSOCKETS=OFF`` --- not in v1 from-source closure.
##   * ``QCORO_WITH_QTTEST=OFF``    --- not needed at runtime.
##   * ``CMAKE_BUILD_TYPE=Release`` --- release-mode optimisation; matches
##                                       the sibling from-source recipes.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qcoro6Source:
  ## From-source qcoro6 --- M9.R.33.1 production recipe closing the
  ## "QCoro6 not found" fresh-configure trip documented in
  ## ``recipes/reproos-iso/run-evidence/m9r32_complete.txt`` G5.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer reads
  ## the ``fetch:`` block (registered via ``registeredFetchSpec``) and
  ## the inlined cmake-flag set and lowers them into fetch + configure
  ## BuildActions wired with the right URL + hash + flags. Single
  ## library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below carries the same URL verbatim.
    ##
    ## ``sourceRepository`` points at the canonical github.com project
    ## --- QCoro's upstream home.
    "0.12.0":
      sourceRevision = "v0.12.0"
      sourceUrl = "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz"
      sourceRepository = "https://github.com/danvratil/qcoro"

  fetch:
    ## Vendored tarball mirrored at
    ## ``recipes/packages/source/qcoro6/vendor/qcoro-0.12.0.tar.gz``
    ## (161 KB, well under any vendoring ceiling).  The convention
    ## layer's argv carries this URL verbatim so the engine's content-
    ## addressed cache fingerprint stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 161,468-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz"
    sha256: "809afafab61593f994c005ca6e242300e1e3e7f4db8b5d41f8c642aab9450fbc"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver --- the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.  QCoro
    ## 0.12 requires cmake 3.18 for the ``project(... VERSION ...)``
    ## semantics + ``GenerateModuleConfigFile`` helper.
    "cmake >=3.18"
    ## ninja is CMake's preferred backend on Linux --- the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C++20 toolchain --- QCoro is a C++20 coroutines
    ## wrapper.  GCC 11 is the minimum the QCoro 0.12 CMakeLists.txt
    ## ``cxx_std_20`` target_compile_features pins.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore + QtDBus + QtNetwork which the M9.R.33
    ## QCoro6 build consumes (the QtQuick + QtQml + QtWebSockets + QtTest
    ## extras are disabled via the ``QCORO_WITH_*=OFF`` flags below).
    ## 6.6 is the minimum the QCoro 0.12 ``find_package(Qt6 ...
    ## COMPONENTS Core DBus Network REQUIRED)`` umbrella probe accepts;
    ## the sibling qt6-base recipe vendors 6.8.1.
    "qt6-base >=6.6"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libQCoro6Core:
    ## ``libQCoro6Core.so`` --- the foundation QCoro6 library plasma-
    ## workspace's ``find_package(QCoro6 REQUIRED COMPONENTS Core ...)``
    ## umbrella probe resolves first.  The QCoro6 cmake-config is shared
    ## across all sub-libraries; mirroring the install-mirror's
    ## ``usr/lib/cmake/QCoro6/`` dir surfaces every sub-config to
    ## downstream consumers via the M9.R.15i.5 walker.
    discard

  build:
    ## M9.R.5b --- explicit `build:` block constructed from the inlined
    ## verbatim cmake-flag set.  Calls the M9.R.2b high-level
    ## `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("qcoro6Source")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "QCORO_BUILD_EXAMPLES=OFF",
        # M9.R.33.1 --- disable QtQuick + QtQml integration.  QCoro's
        # Quick + Qml sub-modules depend on Qt6QuickPrivate +
        # Qt6QmlPrivate which qt6-declarative's CMake config does not
        # export.  Plasma-workspace's QCoro6 consume is Core + DBus
        # only so the trim is invisible at the v1 desktop surface.
        # A future fullbuild milestone can flip these back ON when
        # qt6-declarative ships the Private cmake-config dirs.
        "QCORO_WITH_QTQUICK=OFF",
        "QCORO_WITH_QML=OFF",
        # M9.R.33.1 --- WebSockets / Test are not in the v1 from-source
        # closure (no qt6-websockets recipe, qt6-base doesn't ship the
        # QtTest cmake-config in the from-source mirror).
        "QCORO_WITH_QTWEBSOCKETS=OFF",
        "QCORO_WITH_QTTEST=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQCoro6Core")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
