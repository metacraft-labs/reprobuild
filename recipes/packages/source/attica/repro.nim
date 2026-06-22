## Source-from-tarball attica recipe — M9.R.15q.10.1 KF6 cascade
## module. attica is Tier-3 KDE Frameworks: the Open Collaboration
## Services (OCS) client library ``libKF6Attica.so``. knewstuff
## 6.10.0's CMakeLists.txt:43 declares
## ``find_package(KF6Attica ${KF_DEP_VERSION} CONFIG REQUIRED)`` as a
## mandatory build dependency (the "Get Hot New Stuff" download
## back-end uses it to talk to OCS servers).
##
## We previously satisfied this dependency with the
## ``nixpkgs#kdePackages.attica`` stub (see
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/attica.nim``)
## but the M9.R.15q.10 attempt to build knewstuff with that stub
## failed at link time with
## ``undefined reference to ... @Qt_6.10`` because the pinned
## nixpkgs rev publishes attica 6.20.0 (linked against Qt 6.10+)
## while the from-source ``qt6-base`` recipe ships Qt 6.8.1. The
## from-source attica recipe at the matching 6.10.0 frameworks
## release links against our from-source Qt 6.8.1 and exposes the
## ABI-compatible ``Qt_6`` symbol set knewstuff actually needs.
##
## sha256 = f36c2eacbcad8c08036e9f7525144bec9f7c5d86f1150d49f9db9e3dc14abf45
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  attica-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package atticaSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/attica-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/attica"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/attica-6.10.0.tar.xz"
    sha256: "f36c2eacbcad8c08036e9f7525144bec9f7c5d86f1150d49f9db9e3dc14abf45"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"

  config:
    discard

  library libKF6Attica:
    discard

  build:
    setCurrentOwningPackageOverride("atticaSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Attica")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
