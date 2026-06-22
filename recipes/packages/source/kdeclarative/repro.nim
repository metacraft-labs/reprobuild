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
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    ## M9.R.15l.4 — kdeclarative is fundamentally a Qt6Qml binding
    ## package: every public class wraps a QML type. CMakeLists.txt
    ## declares ``find_package(Qt6 ... Qml REQUIRED)`` at the top.
    ## qt6-declarative is the package shipping ``libQt6Qml.so`` +
    ## ``cmake/Qt6Qml/Qt6QmlConfig.cmake``.
    "qt6-declarative >=6.6"
    ## M9.R.15q.5.6 — kdeclarative's
    ## ``src/qmlcontrols/graphicaleffects/CMakeLists.txt:1`` declares
    ## ``find_package(Qt6 REQUIRED COMPONENTS ShaderTools)`` so the
    ## shader-compilation pipeline (qsb tool) is required for the
    ## graphicaleffects subdir.
    "qt6-shadertools >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kguiaddons >=6.0"
    "ki18n >=6.0"
    ## M9.R.15q.5.6 — kdeclarative 6.10.0's CMakeLists.txt:35 declares
    ## ``find_package(KF6GlobalAccel ... REQUIRED)`` on non-WIN32 /
    ## non-APPLE / non-ANDROID platforms (i.e. Linux). Without this
    ## the cmake configure trips with "Could not find ... KF6GlobalAccel".
    "kglobalaccel >=6.0"
    ## M9.R.15q.5.6 — kdeclarative 6.10.0's CMakeLists.txt:42 declares
    ## ``find_package(KF6WidgetsAddons ... REQUIRED)`` on non-Android.
    "kwidgetsaddons >=6.0"

  config:
    discard

  library libKF6CalendarEvents:
    ## M9.R.15q.5.6.c — kdeclarative 6.10.0 actually installs the
    ## ``libKF6CalendarEvents.so`` shared library plus a private
    ## ``libkquickcontrolsprivate.so``. There's no
    ## ``libKF6Declarative.so`` -- the "KF6Declarative" name is the
    ## historical package name from the merged ECM era. We claim
    ## libKF6CalendarEvents (the public one) as the recipe's artifact;
    ## the private library is consumed via the QML plugins.
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
      discard pkg.library("libKF6CalendarEvents")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
