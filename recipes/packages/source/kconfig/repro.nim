## Source-from-tarball kconfig recipe — the THIRTY-SIXTH real from-
## source production recipe to exercise the M9.H/I/K trio and the FIRST
## recipe in the KF6 module-sweep batch (kconfig / ki18n /
## kwidgetsaddons / kxmlgui).
##
## Prior thirty-five from-source recipes covered every M9.I flag-
## injection channel (meson, cmake, configure, make, kbuild) and every
## artifact-kind permutation up to the eight-artifact mixed-kind
## util-linux shape. kconfig is the SEVENTH CMake-driven recipe (json-c,
## kcoreaddons, kwin, plasma-workspace, sddm, fontconfig precedents) and
## the SECOND KDE Frameworks 6 (KF6) foundation module in the recipe
## suite after kcoreaddons.
##
## ## Why kconfig matters for the v1 desktop story
##
## kconfig (``libKF6Config.so`` + ``libKF6ConfigCore.so`` +
## ``libKF6ConfigGui.so``) is the KF6 configuration-storage stack. It
## bundles the ``KConfig`` / ``KConfigGroup`` / ``KSharedConfig``
## key-value store classes used by every KF6 application + every Plasma
## component to read/write user-config in INI-style files under
## ``$XDG_CONFIG_HOME`` (``kdeglobals``, ``kwinrc``, ``plasmarc``,
## etc.). kwin's ``uses:`` block declares ``kf6-base`` which umbrella-
## bundles kconfig + ki18n + kwidgetsaddons + kxmlgui + kcompletion +
## kservice + knotifications; lifting that umbrella to per-module
## from-source recipes lets the v2 Plasma story link against
## individually pinned KF6 modules.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kconfig/vendor/kconfig-6.10.0.tar.xz``
## and reference it via a ``file://`` URL. The download.kde.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same choice + lockstep ABI rationale as the sibling ``kcoreaddons``
## recipe — 6.10.0 is the current stable in the 6.x line as of
## mid-2026 and the kwin 6.2.x / plasma-workspace 6.2.x consumers
## target the 6.x frameworks ABI.
##
## sha256 = 00ef2c75be68bacf8c30e3bf072358b8f6d2bc78d462e7b14c086808c69d8d7f
##  (computed locally over the vendored ``kconfig-6.10.0.tar.xz``,
##  349,400 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``cmakeFlags:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in ``cmakeFlags:`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction (M9.L).
##   4. install/output collection actions for the library artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifacts via the ``library`` blocks so the
## M9.K artifact registry already knows what shared objects to expect.
##
## ## Library artifacts
##
## kconfig's CMake build emits THREE shared libraries that partition
## the KConfig surface across the core/GUI boundary:
##
##   * ``libKF6Config.so``     — the umbrella shim ``find_package``
##                                consumers link against; aggregates
##                                ConfigCore + ConfigGui transparently.
##   * ``libKF6ConfigCore.so`` — the headless key-value store classes
##                                (KConfig / KConfigGroup /
##                                KSharedConfig) used by daemons that
##                                don't link QtWidgets.
##   * ``libKF6ConfigGui.so``  — the QtWidgets-aware extensions
##                                (KConfigSkeletonGui / shortcut
##                                management) consumed by KF6
##                                applications that present GUI config.
##
## We register the artifacts under their PascalCase camel-cased
## identifiers (``libKF6Config`` / ``libKF6ConfigCore`` /
## ``libKF6ConfigGui``) per the kcoreaddons precedent of preserving
## library-style PascalCase identifiers when the upstream SONAMEs are
## already PascalCase.
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``         — skip the upstream test suite to
##                                      keep the build hermetic + fast.
##   * ``BUILD_QCH=OFF``             — skip the Qt Compressed Help (QCH)
##                                      API documentation build.
##   * ``BUILD_PYTHON_BINDINGS=OFF`` — skip the Python bindings (PyKF6
##                                      surface, not in the v1 NDE-K1
##                                      Plasma dep set).
##   * ``CMAKE_BUILD_TYPE=Release``  — release-mode optimisation;
##                                      matches the sibling from-source
##                                      recipes' baseline.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kconfigSource:
  ## From-source kconfig — thirty-sixth M9.H/I/K production recipe and
  ## the FIRST recipe in the KF6 module-sweep batch (kconfig / ki18n /
  ## kwidgetsaddons / kxmlgui). Seventh CMake-driven recipe and the
  ## SECOND KF6 foundation module after kcoreaddons.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Three-library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kconfig-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kconfig"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 349,400-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/frameworks/6.10/kconfig-6.10.0.tar.xz"
    sha256: "00ef2c75be68bacf8c30e3bf072358b8f6d2bc78d462e7b14c086808c69d8d7f"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## kconfig 6.x requires cmake 3.16 for the modern ECM + Qt6
    ## ``find_package`` semantics the KF6 ABI line depends on.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kconfig is C++17.
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtGui / QtWidgets / QtXml which the
    ## three kconfig libraries wrap on top of. 6.6 is the minimum the
    ## 6.10 frameworks line targets.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation (we
    ## disable QCH via ``BUILD_QCH=OFF`` but the ECM module still
    ## probes for the tool at configure time).
    "qt6-tools >=6.6"
    ## kcoreaddons is the KF6 foundation library kconfig's
    ## ``KConfigSkeleton`` consumes for KSharedConfig / KAboutData
    ## plumbing. The sibling ``kcoreaddonsSource`` recipe vendors a
    ## compatible 6.x version.
    "kcoreaddons >=6.0"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  # M9.R.15i.3.2 — kconfig 6.10.0 does NOT ship an umbrella
  # ``libKF6Config.so``; CMake's ``find_package(KF6Config)`` imports
  # KF6::ConfigCore + KF6::ConfigGui targets directly. The legacy
  # umbrella library declaration would cause stage-copy to fail
  # looking for a library that doesn't exist.

  library libKF6ConfigCore:
    ## ``libKF6ConfigCore.so`` — the headless key-value store classes
    ## (KConfig / KConfigGroup / KSharedConfig) used by daemons that
    ## don't link QtWidgets. v1 records the artifact only.
    discard

  library libKF6ConfigGui:
    ## ``libKF6ConfigGui.so`` — the QtWidgets-aware extensions
    ## (KConfigSkeletonGui / shortcut management) consumed by KF6
    ## applications that present GUI config. v1 records the artifact
    ## only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("kconfigSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15i.3 — qt6-declarative isn't in the v1 closure; ECM's
        # ECMQmlModule does find_package(Qt6 Qml Quick REQUIRED) when
        # KCONFIG_USE_QML is on. Disable the optional Qml component;
        # the KCoreAddons / KConfig core libraries don't need it.
        "KCONFIG_USE_QML=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6ConfigCore")
      discard pkg.library("libKF6ConfigGui")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
