## Source-from-tarball ksysguard recipe — M9.R.15q.10.9 Plasma cascade
## module. ksysguard / libksysguard is the system-resource monitoring
## library (``libKSysGuardSensors.so`` + friends) plasma5support links
## against to expose CPU / RAM / network gauges to the plasma applets.
##
## Note: the upstream tarball is named ``libksysguard-6.2.5.tar.xz``
## but the dep is conventionally spelled ``ksysguard`` in our recipe
## registry (matching the stdlib stub); this recipe lives under
## ``recipes/packages/source/ksysguard/`` so the directory name aligns
## with the dep declarations on plasma5support.
##
## sha256 = 9694f3d6b5078b4d82eb8e6ed34eb20e2d109ed7c2234c59a640bc32f31c76ab

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ksysguardSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/libksysguard-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/libksysguard"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/libksysguard-6.2.5.tar.xz"
    sha256: "9694f3d6b5078b4d82eb8e6ed34eb20e2d109ed7c2234c59a640bc32f31c76ab"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-declarative >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"
    "kwindowsystem >=6.0"
    "kauth >=6.0"
    "kiconthemes >=6.0"
    "kconfigwidgets >=6.0"
    "kcompletion >=6.0"
    "knewstuff >=6.0"
    "kservice >=6.0"
    "ksolid >=6.0"
    ## M9.R.15q.11.1 — libnl + lm-sensors are ksysguard's two REQUIRED
    ## non-KF6 deps. CMakeLists.txt declares
    ## ``find_package(NL)`` + ``find_package(Sensors)`` with
    ## ``TYPE REQUIRED``; without them
    ## ``feature_summary(REQUIRED_PACKAGES_NOT_FOUND
    ## FATAL_ON_MISSING_REQUIRED_PACKAGES)`` aborts the configure run.
    "libnl"
    "lm-sensors"
    ## X11 transitives.
    "xorgproto"
    "libx11"
    "libxcb"
    "libxau"
    "libxdmcp"
    "xcb-util-keysyms"
    "xcb-util-wm"
    "libxext"
    "libxfixes"
    "libxrender"

  config:
    discard

  library libKSysGuard:
    discard

  build:
    setCurrentOwningPackageOverride("ksysguardSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKSysGuard")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
