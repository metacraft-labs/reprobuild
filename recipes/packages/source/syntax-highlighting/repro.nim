## Source-from-tarball syntax-highlighting recipe — M9.R.15q.10.3 KF6
## cascade module. syntax-highlighting is Tier-1 KDE Frameworks: the
## ``libKF6SyntaxHighlighting.so`` syntax-highlighting state-machine
## engine used by ktexteditor + kate + plasma's notes widget.
##
## sha256 = b5b5e343ff27bc5c95be0051d5606dfcb3295f835830e7fc6dac8d2863891699

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package syntaxHighlightingSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/syntax-highlighting-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/syntax-highlighting"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/syntax-highlighting-6.10.0.tar.xz"
    sha256: "b5b5e343ff27bc5c95be0051d5606dfcb3295f835830e7fc6dac8d2863891699"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "perl >=5.32"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"

  config:
    discard

  library libKF6SyntaxHighlighting:
    discard

  build:
    setCurrentOwningPackageOverride("syntaxHighlightingSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6SyntaxHighlighting")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
