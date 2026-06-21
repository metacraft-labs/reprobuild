## Source-from-tarball kjobwidgets recipe — M9.R.15h.5 KF6 cascade
## module. kjobwidgets is Tier-2 KDE Frameworks: QtWidgets-side
## progress / status display widgets for KJob (the kcoreaddons base
## class), consumed by KIO + Plasma's notification host.
##
## sha256 = ee3ff5d21c8484959d0af1976a7c1bab01f4368414df2ebb2cb8540b3c28691b
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kjobwidgets-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kjobwidgetsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kjobwidgets-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kjobwidgets"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kjobwidgets-6.10.0.tar.xz"
    sha256: "ee3ff5d21c8484959d0af1976a7c1bab01f4368414df2ebb2cb8540b3c28691b"
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
    "kwidgetsaddons >=6.0"

  config:
    discard

  library libKF6JobWidgets:
    discard

  build:
    setCurrentOwningPackageOverride("kjobwidgetsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6JobWidgets")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
