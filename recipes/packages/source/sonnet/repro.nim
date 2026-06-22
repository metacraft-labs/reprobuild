## Source-from-tarball sonnet recipe — M9.R.15q.10.3 KF6 cascade
## module. sonnet is Tier-2 KDE Frameworks: the spell-checker / language
## detector library ``libKF6Sonnet*.so`` consumed by ktextwidgets +
## ktexteditor. Required by plasma-workspace's umbrella
## ``find_package(KF6 ... REQUIRED COMPONENTS ... TextWidgets ...)``
## probe transitively via ``find_dependency(KF6Sonnet)`` in
## ``KF6TextWidgetsConfig.cmake``.
##
## sha256 = 99c0bca563594fd115f31f18ad3264770046290c6695ded0d2aa3c2eddb0d4b7
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  sonnet-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package sonnetSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/sonnet-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/sonnet"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/sonnet-6.10.0.tar.xz"
    sha256: "99c0bca563594fd115f31f18ad3264770046290c6695ded0d2aa3c2eddb0d4b7"
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

  config:
    discard

  library libKF6SonnetCore:
    discard
  library libKF6SonnetUi:
    discard

  build:
    setCurrentOwningPackageOverride("sonnetSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.10.3 — sonnet's CMakeLists FATAL_ERRORs in
        # ``src/plugins/CMakeLists.txt:58`` when no spell-check backend
        # (aspell/hspell/hunspell/voikko) is found. Our v1 dep closure
        # carries none of those backends yet; ``SONNET_NO_BACKENDS=ON``
        # tells sonnet to ship the API library + UI widgets without a
        # spell-check engine (callers see "no dictionary available" at
        # runtime). plasma-workspace's TextWidgets + TextEditor probes
        # only need the libraries to exist; the optional backends can
        # land in a follow-up milestone.
        "SONNET_NO_BACKENDS=ON",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6SonnetCore")
      discard pkg.library("libKF6SonnetUi")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
