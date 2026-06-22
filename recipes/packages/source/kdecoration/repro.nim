## Source-from-tarball kdecoration recipe — M9.R.15q.4.8 KDE Plasma 6.2.x
## window-decoration framework. kdecoration is the abstract decoration
## API every Plasma server-side decoration plugin (Breeze, Plastik, etc.)
## links against. kwin 6.2.5 declares
## ``find_package(KDecoration2 ${PROJECT_DEP_VERSION} CONFIG REQUIRED)``
## which resolves against the legacy "KDecoration2" CMake namespace
## published by upstream kdecoration 6.2.x. (Upstream renamed the
## namespace to "KDecoration3" in 6.3+.)
##
## ## sha256 strategy
##
## We fetch the upstream 6.2.0 .tar.xz from download.kde.org/stable/
## plasma/6.2.0/ at build time (no vendor copy; the tarball is ~95 KB
## so streaming is fine).
##
## sha256 = 05d0d38ee55c922db135fd864e35c4742988a7b26516a341b824e9804960c919
##  (computed locally over the upstream tarball, ~95 KB).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kdecorationSource:
  versions:
    "6.2.0":
      sourceRevision = "v6.2.0"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.0/kdecoration-6.2.0.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kdecoration"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.0/kdecoration-6.2.0.tar.xz"
    sha256: "05d0d38ee55c922db135fd864e35c4742988a7b26516a341b824e9804960c919"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore + QtGui kdecoration's abstract API
    ## consumes (find_package(Qt6 ... COMPONENTS Core Gui)).
    "qt6-base >=6.6"
    ## M9.R.15q.5.3 — kdecoration 6.2.0's CMakeLists.txt:53 declares
    ## ``find_package(KF6I18n ${KF6_MIN_VERSION} CONFIG REQUIRED)``
    ## (KF6_MIN_VERSION = 6.5.0). ki18n is the KF6 internationalization
    ## framework (gettext wrapper + KLocalizedString).
    "ki18n >=6.5"

  config:
    discard

  library libKDecoration2:
    ## ``libKDecoration2.so`` — abstract window-decoration framework
    ## kwin 6.2.5 + Plasma 6.2.x decoration plugins (Breeze) link
    ## against. v1 records the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("kdecorationSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKDecoration2")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
