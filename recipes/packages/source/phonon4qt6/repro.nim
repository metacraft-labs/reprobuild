## Source-from-tarball phonon4qt6 recipe — M9.R.15q.11.8 Plasma
## cascade module. Phonon is the Qt-multimedia abstraction layer KDE
## applications use to play audio + video (notifications, KCM
## previews, etc.). Plasma 6.x links against the Qt6 build of phonon
## (libphonon4qt6.so).
##
## sha256 = 3287ffe0fbcc2d4aa1363f9e15747302d0b080090fe76e5f211d809ecb43f39a

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package phonon4qt6Source:
  versions:
    "4.12.0":
      sourceRevision = "v4.12.0"
      sourceUrl = "https://download.kde.org/stable/phonon/4.12.0/phonon-4.12.0.tar.xz"
      sourceRepository = "https://invent.kde.org/libraries/phonon"

  fetch:
    url: "https://download.kde.org/stable/phonon/4.12.0/phonon-4.12.0.tar.xz"
    sha256: "3287ffe0fbcc2d4aa1363f9e15747302d0b080090fe76e5f211d809ecb43f39a"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-5compat >=6.6"

  config:
    discard

  library libphonon4qt6:
    discard

  build:
    setCurrentOwningPackageOverride("phonon4qt6Source")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "PHONON_BUILD_QT5=OFF",
        "PHONON_BUILD_QT6=ON",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libphonon4qt6")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
