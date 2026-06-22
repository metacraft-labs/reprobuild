## Source-from-tarball qt6-sensors recipe — M9.R.15q.5.10 KF6/Plasma blocker.
## qt6-sensors supplies QtSensors (libQt6Sensors.so) which kwin 6.2.5
## declares as a mandatory Qt6 component in its top-level
## ``find_package(Qt6 ... COMPONENTS ... Sensors ...)`` — kwin uses
## the sensors API for auto-rotation on convertible / tablet form
## factors.
##
## sha256 = 41f49b614850d40c647b80e70ef6be759e8fc90ac6cce3ab6f82a357201d9750
##  (computed locally over the vendored
##  ``qtsensors-everywhere-src-6.8.1.tar.xz``, 1,498,024 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package qt6SensorsSource:
  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtsensors-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtsensors.git"

  fetch:
    url: "file:./vendor/qtsensors-everywhere-src-6.8.1.tar.xz"
    sha256: "41f49b614850d40c647b80e70ef6be759e8fc90ac6cce3ab6f82a357201d9750"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.21"
    "ninja >=1.10"
    "gcc >=11"
    "perl >=5.32"
    "pkg-config"
    "python3 >=3.8"
    "qt6-tools >=6.8"

  buildDeps:
    "qt6-base >=6.8"
    ## qtsensors's QML bindings need Qt6Qml.
    "qt6-declarative >=6.8"

  config:
    discard

  library libQt6Sensors:
    discard

  build:
    setCurrentOwningPackageOverride("qt6SensorsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6Sensors")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
