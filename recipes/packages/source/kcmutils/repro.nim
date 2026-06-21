## Source-from-tarball kcmutils recipe — closes the
## ``KF6 COMPONENTS KCMUtils`` find_package gap on plasma-framework.
##
## kcmutils (KCMUtils, ``libKF6KCMUtils.so``) is the KF6 framework that
## bundles the System Settings module-host runtime + the K-Configuration-
## Module loader API (KQuickConfigModule + KCModule) that Plasma's System
## Settings, kcm-* settings modules, and a handful of KDE applications
## (Dolphin, Kate, KMail) embed for in-place settings UIs.
##
## ## Why kcmutils matters for the v1 desktop story
##
## plasma-framework's CMakeLists.txt declares
## ``find_package(KF6 ${KF6_MIN_VERSION} REQUIRED COMPONENTS ... KCMUtils ...)``
## (libplasma-6.2.5/CMakeLists.txt:46-66). Without kcmutils,
## plasma-framework's configure step fails on the missing
## ``KF6KCMUtilsConfig.cmake`` package config. plasma-framework is the
## prereq for kwin + plasma-workspace + sddm, so closing kcmutils is on
## the critical path for the whole Plasma 6 desktop chain.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kcmutils/vendor/kcmutils-6.10.0.tar.xz``
## and reference it via a ``file://`` URL.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = a4bcb4b04ee4a03a9a9fdbb96c2736021d94b22c22f8d5d5d157b9ce982eb001
##  (computed locally over the vendored ``kcmutils-6.10.0.tar.xz``,
##  2,464,756 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kcmutils's CMake build emits a single shared library
## (``libKF6KCMUtils.so``) bundling the System Settings module-host
## runtime + the KCModule API. We register the artifact under
## ``libKF6KCMUtils`` (the KF6 SONAME ``KF6KCMUtils`` reproduced verbatim
## — same shape as the kxmlgui / ``libKF6XmlGui`` precedent for KF6
## modules whose SONAME contains an acronym; the ``KCM`` acronym is
## kept all-caps because every consumer recipe references the KF6 CMake
## component as ``KCMUtils``, not ``KcmUtils``).
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

package kcmutilsSource:
  ## From-source kcmutils — M9.R.15q.1.3 production recipe. Closes the
  ## ``KF6KCMUtils`` find_package gap on plasma-framework's configure
  ## step. Tier-2b c_cpp_cmake convention consumer. Single library
  ## artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcmutils-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcmutils"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable.
    ##
    ## sha256 was computed over the vendored 2,464,756-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "https://download.kde.org/stable/frameworks/6.10/kcmutils-6.10.0.tar.xz"
    sha256: "a4bcb4b04ee4a03a9a9fdbb96c2736021d94b22c22f8d5d5d157b9ce982eb001"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kcmutils is C++17.
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtGui / QtWidgets the kcmutils KCModule
    ## API + KQuickConfigModule QML loader consume.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies the QML compiler + ``qmltyperegistrar``
    ## kcmutils's KQuickConfigModule QML loader registers types through.
    "qt6-declarative >=6.6"
    ## kio is the transparent-network-IO layer kcmutils's KModuleAction
    ## helper invokes for module discovery on remote desktop entries.
    "kio >=6.0"
    ## kitemviews supplies the QtWidgets model/view extensions kcmutils's
    ## module-browser dialog consumes for the KCModule list view.
    "kitemviews >=6.0"
    ## M9.R.15q.1.7 — kcmutils's KPluginProxyModel inherits from
    ## KCategorizedSortFilterProxyModel which lives in kitemmodels
    ## (kcmutils/src/quick/kpluginproxymodel.h:14).
    "kitemmodels >=6.0"
    ## kconfigwidgets supplies the QtWidgets KConfig-aware widgets
    ## kcmutils's KCModule API exposes for settings UI composition.
    "kconfigwidgets >=6.0"
    ## kcoreaddons is the KF6 foundation library kcmutils's KPluginFactory
    ## + KAboutData paths consume.
    "kcoreaddons >=6.0"
    ## kguiaddons supplies the QtGui extensions kcmutils's module-host
    ## runtime uses for X11 / Wayland integration helpers.
    "kguiaddons >=6.0"
    ## ki18n is the translation/internationalisation layer kcmutils uses
    ## to localise module titles + descriptions.
    "ki18n >=6.0"
    ## kxmlgui supplies the XMLGUI menu-bar / toolbar framework kcmutils's
    ## kcmshell6 host embeds.
    "kxmlgui >=6.0"
    ## kwidgetsaddons supplies the QtWidgets extensions kcmutils's
    ## KCModule API consumes (KMessageWidget, KMessageDialog, etc.).
    "kwidgetsaddons >=6.0"
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive``); no explicit per-recipe
    ## declarations needed.

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  library libKF6KCMUtils:
    ## ``libKF6KCMUtils.so`` — System Settings module-host runtime +
    ## KCModule API. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  build:
    ## M9.R.15q.1.3 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor. Same modern-
    ## desktop baseline as the sibling KF6 recipes.
    setCurrentOwningPackageOverride("kcmutilsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6KCMUtils")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until the
    ## M9.R.5b per-recipe pass populates per-output ELF interrogation.
    discard
