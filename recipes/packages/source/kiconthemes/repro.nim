## Source-from-tarball kiconthemes recipe — M9.R.15j.4 KF6 cascade
## module. kiconthemes is a Tier-3 KDE Frameworks module supplying KF6
## icon-theme management (KIconLoader, KIconButton, KIconDialog,
## KIconEffect) that kxmlgui + Plasma System Settings consume.
##
## sha256 = 15807e785183c048810af0141b3a560085f2bbf00f3a21fe962eb37a673f9314
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kiconthemes-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kiconthemesSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kiconthemes-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kiconthemes"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kiconthemes-6.10.0.tar.xz"
    sha256: "15807e785183c048810af0141b3a560085f2bbf00f3a21fe962eb37a673f9314"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"

  config:
    discard

  library libKF6IconThemes:
    discard

  build:
    setCurrentOwningPackageOverride("kiconthemesSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15j.4 — disable QtQuick scene-graph plugin for v1
        # (qt6-declarative is present but kiconthemes' QtQuick plugin
        # adds unused QML symbol dependency on Quick/Qml).
        "KICONTHEMES_USE_QTQUICK=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6IconThemes")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
