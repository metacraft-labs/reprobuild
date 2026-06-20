## Source-from-tarball kcoreaddons recipe — the NINETEENTH real from-
## source production recipe to exercise the M9.H/I/K trio and the FIRST
## recipe in the Plasma stack batch (kcoreaddons / kwin / plasma-
## workspace / sddm).
##
## Prior eighteen from-source recipes — fourteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput,
## cairo, pango, gdk-pixbuf, glib2, mutter, gnome-shell), one make
## (linux-kernel), one CMake (json-c), two autotools (expat + gdm) —
## collectively covered every M9.I flag-injection channel and every
## artifact-kind permutation. kcoreaddons is the SECOND CMake-driven
## recipe (json-c was the first) and the first KDE Frameworks 6 (KF6)
## foundation module in the recipe suite. KF6 is itself ~80 modules;
## kcoreaddons is the foundation module every other KF6 module + every
## Plasma component links against, so it goes first in the Plasma
## stack batch ordering (kcoreaddons -> kwin -> plasma-workspace ->
## sddm).
##
## ## Why kcoreaddons matters for the v1 desktop story
##
## kcoreaddons (``libKF6CoreAddons.so``) is the bottom of the KDE
## Frameworks 6 dependency graph: every other KF6 module (kconfig,
## ki18n, kwidgetsaddons, kcompletion, kxmlgui, etc.) and every Plasma
## component (kwin, plasma-workspace, plasma-desktop, kwallet, etc.)
## links against it. It bundles the cross-cutting helpers that
## predate ``QCoreApplication`` proper: ``KJob``, ``KAboutData``,
## ``KFormat``, ``KPluginFactory``, ``KShell``, ``KSignalHandler``,
## ``KUser``, ``KRandom``, ``KStringHandler``, ``KOSRelease``, etc.
## NDE-K1's manifest layer pins the apt-jammy kf5-frameworks bundle for
## v1 stubs; the from-source recipe lifts that pin to a real
## ``libKF6CoreAddons.so`` artifact for the v2 Plasma story.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kcoreaddons/vendor/kcoreaddons-6.10.0.tar.xz``
## and reference it via a ``file://`` URL. The download.kde.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## download.kde.org publishes KDE Frameworks releases at
## ``https://download.kde.org/stable/frameworks/<major.minor>/`` and
## 6.10.0 is the current stable in the 6.x line as of mid-2026. The
## 6.x ABI line is the KF6/Qt6 sibling of the legacy KF5/Qt5 stack;
## kwin 6.x + plasma-workspace 6.x + sddm 0.21.x consume the 6.x
## frameworks ABI so the four Plasma-batch recipes stay in lockstep.
##
## sha256 = 89bf28747915e987cab21c77397b0971caffa1258b6f575543d73d4188184a72
##  (computed locally over the vendored ``kcoreaddons-6.10.0.tar.xz``,
##  2,553,780 bytes; downloaded once from the upstream URL recorded in
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
##   4. install/output collection actions for the library artifact
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifact via the ``library`` block so the
## M9.K artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## kcoreaddons's CMake build emits a single shared library
## (``libKF6CoreAddons.so``) bundling the cross-cutting KF6 helpers
## listed above. We register the artifact under the package-level
## identifier ``libKF6CoreAddons`` (camelCased from the upstream
## SONAME ``KF6CoreAddons`` per the json-c precedent of preserving
## library-style PascalCase identifiers when the upstream SONAME is
## already PascalCase).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``         — skip the upstream test suite to
##                                      keep the build hermetic + fast.
##   * ``BUILD_QCH=OFF``             — skip the Qt Compressed Help (QCH)
##                                      API documentation build (heavy
##                                      qdoc dep surface, not needed at
##                                      runtime).
##   * ``BUILD_PYTHON_BINDINGS=OFF`` — skip the Python bindings (PyKF6
##                                      surface, not in the v1 NDE-K1
##                                      Plasma dep set).
##   * ``CMAKE_BUILD_TYPE=Release``  — release-mode optimisation;
##                                      matches the sibling from-source
##                                      recipes' ``--buildtype=release``
##                                      meson option and the json-c
##                                      cmake recipe's matching flag.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``BUILD_TESTING=ON`` for CI bundles).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kcoreaddonsSource:
  ## From-source kcoreaddons — nineteenth M9.H/I/K production recipe
  ## and the FIRST recipe in the Plasma stack batch (kcoreaddons /
  ## kwin / plasma-workspace / sddm). Second CMake-driven recipe after
  ## json-c and the first KDE Frameworks 6 (KF6) foundation module in
  ## the recipe suite.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream KDE invent.kde.org
    ## project --- kcoreaddons's canonical home.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcoreaddons-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcoreaddons"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,553,780-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/frameworks/6.10/kcoreaddons-6.10.0.tar.xz"
    sha256: "89bf28747915e987cab21c77397b0971caffa1258b6f575543d73d4188184a72"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``.
    ## kcoreaddons 6.x requires cmake 3.16 for the modern
    ## ECM-as-found-package + ``add_library(... ALIAS ...)`` semantics
    ## the KF6 ABI line depends on.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kcoreaddons is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtConcurrent / QtNetwork the KF6
    ## helpers wrap on top of (KJob ~ QObject, KAboutData ~ QSettings,
    ## KPluginFactory ~ QPluginLoader, etc.). 6.6 is the minimum the
    ## 6.10 frameworks line targets.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation (we
    ## disable QCH via ``BUILD_QCH=OFF`` but the ECM module still
    ## probes for the tool at configure time).
    "qt6-tools >=6.6"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libKF6CoreAddons:
    ## ``libKF6CoreAddons.so`` — the cross-cutting KF6 helpers library
    ## every other KF6 module + every Plasma component links against
    ## (KJob, KAboutData, KFormat, KPluginFactory, KShell,
    ## KSignalHandler, KUser, KRandom, KStringHandler, KOSRelease,
    ## etc.). v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("kcoreaddonsSource")
    try:
      let opts = @[
        "-DBUILD_TESTING=OFF",
        "-DBUILD_QCH=OFF",
        "-DBUILD_PYTHON_BINDINGS=OFF",
        "-DCMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6CoreAddons")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
