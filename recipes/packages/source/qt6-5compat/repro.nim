## Source-from-tarball qt6-5compat recipe — M9.R.15q.5.10 KF6/Plasma blocker.
## qt6-5compat supplies QtCore5Compat (libQt6Core5Compat.so) which kwin
## 6.2.5 declares as a mandatory Qt6 component in its top-level
## ``find_package(Qt6 ... COMPONENTS ... Core5Compat ...)``. Without it
## the kwin compositor build cannot configure.
##
## sha256 = 05c8c088b4cd8331fa8a9c8b7ff7c42a088cb112e673eae5708048d0131264fc
##  (computed locally over the vendored
##  ``qt5compat-everywhere-src-6.8.1.tar.xz``, 14,632,944 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below).
##
## Version 6.8.1 matches sibling qt6-base / qt6-tools / qt6-declarative.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package qt6Core5CompatSource:
  ## From-source qt6-5compat — M9.R.15q.5.10 KF6/Plasma blocker.
  ## Sibling to qt6-base (qt6BaseSource); shares the same 6.8.1 pin.

  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qt5compat-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qt5compat.git"

  fetch:
    ## M9.R.15q.5.10 — vendored tarball + file:./ relative URL form
    ## (introduced M9.R.15q.5.4) so the recipe stays portable across
    ## hosts and offline-reproducible.
    url: "file:./vendor/qt5compat-everywhere-src-6.8.1.tar.xz"
    sha256: "05c8c088b4cd8331fa8a9c8b7ff7c42a088cb112e673eae5708048d0131264fc"
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

  config:
    discard

  library libQt6Core5Compat:
    ## ``libQt6Core5Compat.so`` — Qt5-compat layer kwin 6.2.5 consumes
    ## for legacy QTextCodec + QStringList compat shims. v1 records
    ## the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("qt6Core5CompatSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        ## Same SBOM disable as siblings (qt6-base / qt6-tools /
        ## qt6-declarative / qt6-svg). SBOM gen hard-codes the
        ## canonical Qt-6.8.1 prefix which doesn't match our
        ## buildDir/out/usr install layout.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6Core5Compat")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
