## Source-from-tarball kdeclarative recipe — M9.R.15h.13 KF6 cascade
## module. kdeclarative is Tier-3 KDE Frameworks: QML bindings for
## KConfig + KCoreAddons + KWindowSystem, consumed by Plasma's QML
## panel + applet runtime.
##
## sha256 = db9eb2b5e615b484949e41ac5a05c5cea136e231d15a3de203902cedcdfd9e73
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kdeclarative-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kdeclarativeSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kdeclarative-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kdeclarative"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kdeclarative-6.10.0.tar.xz"
    sha256: "db9eb2b5e615b484949e41ac5a05c5cea136e231d15a3de203902cedcdfd9e73"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "extra-cmake-modules >=6.0"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kguiaddons >=6.0"
    "ki18n >=6.0"

  config:
    discard

  library libKF6Declarative:
    discard

  build:
    setCurrentOwningPackageOverride("kdeclarativeSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Declarative")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
