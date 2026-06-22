## Source-from-tarball knewstuff recipe — M9.R.15h.12 KF6 cascade
## module. knewstuff is Tier-3 KDE Frameworks: GHNS ("Get Hot New
## Stuff") download dialog + content-installer for KDE wallpapers /
## icon themes / applet bundles; consumed by Plasma settings panels.
##
## sha256 = 81cb5ea54fe03d27f80a481dde18a767ca1a95267403bd87483cfdd81981e4e7
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  knewstuff-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package knewstuffSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/knewstuff-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/knewstuff"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/knewstuff-6.10.0.tar.xz"
    sha256: "81cb5ea54fe03d27f80a481dde18a767ca1a95267403bd87483cfdd81981e4e7"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    ## M9.R.15q.5.7 — knewstuff's CMakeLists declares
    ## ``find_package(Qt6 ... Qml REQUIRED)`` for the QML-bound
    ## ``KNSCore::QtQuickDialogWrapper`` shim that wraps the C++
    ## back-end into a QML-accessible model. Qt6Qml is in the
    ## qt6-declarative recipe.
    "qt6-declarative >=6.6"
    "kcoreaddons >=6.0"
    "kconfig >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"
    "kxmlgui >=6.0"
    "karchive >=6.0"
    "kpackage >=6.0"
    ## M9.R.15q.5.7 — knewstuff's CMakeLists.txt:43 declares
    ## ``find_package(KF6Attica ... CONFIG REQUIRED)`` for the OCS
    ## (Open Collaboration Services) client back-end. attica is a
    ## nix-stub (no from-source sibling yet; only consumer is
    ## knewstuff which is itself only exercised by kwin's "Get New
    ## Window Decorations" feature, no v1 runtime path).
    "attica >=6.0"

  config:
    discard

  ## M9.R.15q.10.2 — knewstuff 6.10.0 ships the legacy ``libKF6NewStuff``
  ## widget facade renamed as ``libKF6NewStuffWidgets`` (the ``Widgets``
  ## suffix mirrors the QtWidgets-only side of the split between the
  ## QtCore-only ``Core`` library and the QtWidgets-based dialog set).
  ## Adjust both the artifact declaration + the build-block stage list.
  library libKF6NewStuffWidgets:
    discard
  library libKF6NewStuffCore:
    discard

  build:
    setCurrentOwningPackageOverride("knewstuffSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6NewStuffWidgets")
      discard pkg.library("libKF6NewStuffCore")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
