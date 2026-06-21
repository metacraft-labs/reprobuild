## Source-from-tarball extra-cmake-modules (ECM) recipe — M9.R.15h.14.
## ECM is the KDE Frameworks 6 CMake foundation module: KDECMakeSettings,
## KDEInstallDirs, ECMQmlModule, ECMGenerateExportHeader, etc. EVERY
## KF6 module's CMakeLists.txt declares ``find_package(ECM 6.10.0
## NO_MODULE)`` at the top; without ECM no KF6 module can configure.
##
## ECM ships no compiled libraries — it's a pure CMake module collection
## installed under ``<prefix>/share/ECM/`` + ``<prefix>/share/cmake/``.
## The "build" reduces to ``cmake --install`` after a no-op configure.
##
## sha256 = 506989a0d400913403e669c1912238db053cd6b38dff74b17e2e6f879c79cca0
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  extra-cmake-modules-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package extraCmakeModulesSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/extra-cmake-modules-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/extra-cmake-modules"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/extra-cmake-modules-6.10.0.tar.xz"
    sha256: "506989a0d400913403e669c1912238db053cd6b38dff74b17e2e6f879c79cca0"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"

  buildDeps:
    discard

  config:
    discard

  # ECM has no compiled artifact — it's a pure CMake module collection
  # installed under share/ECM/ + share/cmake/. Per the kded precedent
  # we don't register any library() or executable() artifact; the
  # install-mirror step copies the share/ tree into .repro/output/install
  # so consumers' CMAKE_PREFIX_PATH probe finds ECMConfig.cmake.

  build:
    setCurrentOwningPackageOverride("extraCmakeModulesSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_HTML_DOCS=OFF",
        "BUILD_MAN_DOCS=OFF",
        "BUILD_QTHELP_DOCS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      discard cmake_package(srcDir = "./src", cacheVars = opts)
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
