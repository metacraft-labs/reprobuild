## Source-from-tarball kitemviews recipe — M9.R.15j.2 KF6 cascade
## module. kitemviews is a Tier-3 KDE Frameworks module supplying the
## KF6 model/view item widgets (KCategorizedView, KExtendableItemDelegate,
## KCategoryDrawer, etc.) that kxmlgui, kio, plasma-workspace, and the
## Plasma System Settings KCM modules consume.
##
## sha256 = 8b15ff5719ea65e9d0c722eea6412e312d05d9da49c872caf9d97d329d56d76d
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kitemviews-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kitemviewsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kitemviews-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kitemviews"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kitemviews-6.10.0.tar.xz"
    sha256: "8b15ff5719ea65e9d0c722eea6412e312d05d9da49c872caf9d97d329d56d76d"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"

  config:
    discard

  library libKF6ItemViews:
    discard

  build:
    setCurrentOwningPackageOverride("kitemviewsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6ItemViews")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
