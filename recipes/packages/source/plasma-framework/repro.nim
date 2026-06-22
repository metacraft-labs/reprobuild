## Source-from-tarball plasma-framework recipe — the FORTY-SIXTH real
## from-source production recipe to exercise the M9.H/I/K trio and the
## CLOSING recipe in the SECOND KF6 module-sweep batch (kservice /
## kglobalaccel / knotifications / plasma-framework).
##
## plasma-framework is the FOURTEENTH CMake-driven recipe and the FIRST
## recipe in the recipe suite that lifts from the ``stable/plasma/``
## release tree (every prior KF6 recipe lifted from
## ``stable/frameworks/<x.y>/``).
##
## ## Why the upstream renaming matters — ``libplasma`` vs
## ## ``plasma-framework``
##
## Plasma 6.x merged three legacy KF5/Plasma-5 modules
## (``kpackage`` + ``kdeclarative`` + ``plasma-framework``) into a
## single upstream module published as ``libplasma`` under
## ``stable/plasma/<x.y.z>/``. The legacy ``frameworks/6.10/`` tree
## does NOT publish a ``plasma-framework-6.10.0.tar.xz`` (verified
## upstream: HTTP 404). The task brief permitted falling back to the
## ``libplasma-6.2.5.tar.xz`` pin in that case, and that is the path
## taken here.
##
## We KEEP the package identifier ``plasmaFrameworkSource`` (per the
## task brief) so the recipe slot in the recipe suite maps cleanly to
## the historical "Plasma framework" role even though the upstream
## release artefact is now branded ``libplasma``. Downstream consumers
## (kwin / plasma-workspace / sddm) link against the same ABI either
## way; the rename is upstream packaging-level only.
##
## ## Why plasma-framework matters for the v1 desktop story
##
## libplasma (``libPlasma.so``) supplies the Plasma applet runtime
## surface — the QML scene the panel + desktop view + lock-screen
## render their applets into, the ``PlasmaCore`` + ``PlasmaComponents``
## + ``PlasmaExtras`` QML bindings, and the ``KPackage`` plugin loader
## consolidated from the legacy ``kpackage`` module. plasma-workspace's
## plasma-shell process loads this library at startup and refuses to
## start without it.
##
## ## sha256 strategy
##
## We vendor the upstream 6.2.5 .tar.xz at
## ``recipes/packages/source/plasma-framework/vendor/libplasma-6.2.5.tar.xz``
## and reference it via a ``file://`` URL.
##
## ## Version choice — 6.2.5 (current upstream stable in the 6.x line)
##
## libplasma 6.2.5 is the current 6.2.x patch release published under
## ``stable/plasma/6.2.5/``; the 6.2.x ABI line is the Plasma 6 LTS
## sibling of the KF6 6.10.x frameworks line and the two consume each
## other (libplasma depends on KF6 6.10.x, plasma-workspace 6.2.x
## depends on libplasma 6.2.x). Lockstep with the rest of the Plasma
## stack batch.
##
## sha256 = af770f5fef978512c70491889516fb769d340f00a02270987d2d1d17753658ec
##  (computed locally over the vendored ``libplasma-6.2.5.tar.xz``,
##  1,970,096 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## libplasma's CMake build emits a single shared library
## (``libPlasma.so``) bundling the Plasma applet runtime surface. We
## register the artifact under ``libPlasma`` (camelCased from the
## upstream SONAME ``Plasma``); note the LACK of a ``KF6`` prefix —
## libplasma is a Plasma-stack library, not a KF6 framework, and the
## upstream SONAME reflects that.
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

package plasmaFrameworkSource:
  ## From-source plasma-framework — forty-sixth M9.H/I/K production
  ## recipe and the CLOSING recipe in the SECOND KF6 module-sweep
  ## batch. Fourteenth CMake-driven recipe and the FIRST recipe to lift
  ## from ``stable/plasma/<x.y.z>/`` (every prior KF6 recipe lifted from
  ## ``stable/frameworks/<x.y>/``). Pins the post-rename
  ## ``libplasma-6.2.5`` tarball under the historical
  ## ``plasmaFrameworkSource`` slot per the task brief's fallback
  ## clause.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the post-rename upstream KDE
    ## invent.kde.org project — ``plasma/libplasma`` — that hosts the
    ## merged kpackage + kdeclarative + plasma-framework source tree.
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/libplasma-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/libplasma"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 1,970,096-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.kde.org/stable/plasma/6.2.5/libplasma-6.2.5.tar.xz"
    sha256: "af770f5fef978512c70491889516fb769d340f00a02270987d2d1d17753658ec"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — libplasma is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore / QtGui / QtQml / QtQuick / QtSvg /
    ## QtDBus the libplasma applet runtime + ``PlasmaCore`` QML bindings
    ## consume.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies the QML compiler + ``qmltyperegistrar``
    ## libplasma's QML module ships are registered through.
    "qt6-declarative >=6.6"
    ## kconfig is the KF6 configuration-storage library libplasma uses
    ## to read panel layout + applet preferences.
    "kconfig >=6.0"
    ## kcoreaddons is the KF6 foundation library libplasma's plugin
    ## loader + ``KPackage`` paths consume.
    "kcoreaddons >=6.0"
    ## ki18n is the translation/internationalisation layer libplasma
    ## uses to localise applet metadata strings.
    "ki18n >=6.0"
    ## kservice is the service-registry layer libplasma's
    ## ``KPackage`` plugin loader probes for ``*.desktop`` applet
    ## entries.
    "kservice >=6.0"
    ## knotifications is the notification dispatch layer libplasma's
    ## ``Plasma::Containment`` surfaces ``KNotification`` events
    ## through.
    "knotifications >=6.0"
    ## M9.R.15p.4.4 — libplasma's CMakeLists.txt:13 declares
    ## ``find_package(ECM ${KF6_MIN_VERSION} REQUIRED NO_MODULE)``.
    "extra-cmake-modules >=6.0"
    ## M9.R.15p.4.4 — libplasma's CMakeLists.txt:46 declares
    ## ``find_package(Qt6 ... COMPONENTS ... Svg ...)``; qt6-svg
    ## supplies libQt6Svg.so + Qt6SvgConfig.cmake.
    "qt6-svg >=6.6"
    ## M9.R.15q.1.4 — libplasma's CMakeLists.txt:46 declares
    ## ``find_package(KF6 ... COMPONENTS ... Archive ConfigWidgets
    ## GuiAddons IconThemes KIO WindowSystem Package KirigamiPlatform
    ## KCMUtils Svg)``; each KF6 component must be a buildDep so the
    ## resolver discovers the corresponding ``KF6<X>Config.cmake``.
    "karchive >=6.0"
    "kconfigwidgets >=6.0"
    "kguiaddons >=6.0"
    "kiconthemes >=6.0"
    "kio >=6.0"
    "kwindowsystem >=6.0"
    "kpackage >=6.0"
    "kirigami >=6.0"
    "kcmutils >=6.10"
    "ksvg >=6.0"
    ## M9.R.15q.1.4 — libplasma's CMakeLists.txt:68 declares
    ## ``find_package(PlasmaActivities REQUIRED ${PROJECT_DEP_VERSION})``;
    ## the plasmaActivitiesSource recipe ships
    ## ``PlasmaActivitiesConfig.cmake``.
    "plasma-activities >=6.2"
    ## M9.R.15q.1.4 — libplasma's CMakeLists.txt:70-72 declares
    ## ``find_package(PlasmaWaylandProtocols 1.10.0 REQUIRED)`` +
    ## ``find_package(Qt6WaylandClient REQUIRED CONFIG)`` +
    ## ``find_package(Wayland 1.9 REQUIRED Client)``. The first two
    ## supply CMake configs; wayland-client comes via the wayland recipe.
    "plasma-wayland-protocols"
    "qt6-wayland >=6.6"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libPlasma:
    ## ``libPlasma.so`` — Plasma applet runtime surface
    ## (Plasma::Applet + Plasma::Containment + Plasma::Theme +
    ## PlasmaCore + PlasmaComponents + PlasmaExtras QML bindings +
    ## KPackage plugin loader). v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's ninja-
    ## spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("plasmaFrameworkSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.3.4 — v1 is Wayland-only. kwindowsystem is built
        # with ``KWINDOWSYSTEM_X11=OFF`` so it ships no ``KX11Extras``
        # header. plasma-framework's ``src/plasma/private/theme_p.cpp``
        # unconditionally ``#include <KX11Extras>`` when ``HAVE_X11`` is
        # set, so we MUST suppress the X11 detection at configure time
        # via plasma-framework's ``WITHOUT_X11`` option. Without this,
        # the build trips on ``fatal error: KX11Extras: No such file
        # or directory`` even though the configure step succeeded.
        "WITHOUT_X11=ON",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libPlasma")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
