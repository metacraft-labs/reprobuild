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
    "extra-cmake-modules >=6.0"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"
    "kconfig >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"
    "kxmlgui >=6.0"
    "karchive >=6.0"
    "kpackage >=6.0"

  config:
    discard

  library libKF6NewStuff:
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
      discard pkg.library("libKF6NewStuff")
      discard pkg.library("libKF6NewStuffCore")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
