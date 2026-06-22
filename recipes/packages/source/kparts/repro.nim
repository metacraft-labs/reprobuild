## Source-from-tarball kparts recipe — M9.R.15q.10.3 KF6 cascade
## module. kparts is Tier-2 KDE Frameworks: the component plug-in
## framework (``libKF6Parts.so``).
##
## sha256 = a3c460f635f32e254093da3d46d53fe9a4a7cca5987149047981b477c50a060c

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kpartsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kparts-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kparts"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kparts-6.10.0.tar.xz"
    sha256: "a3c460f635f32e254093da3d46d53fe9a4a7cca5987149047981b477c50a060c"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kio >=6.0"
    "kxmlgui >=6.0"
    "ki18n >=6.0"
    "kjobwidgets >=6.0"
    "kservice >=6.0"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"

  config:
    discard

  library libKF6Parts:
    discard

  build:
    setCurrentOwningPackageOverride("kpartsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Parts")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
