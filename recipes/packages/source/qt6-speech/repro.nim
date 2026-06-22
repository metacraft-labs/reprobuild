## Source-from-tarball qt6-speech recipe — M9.R.15q.10.3 cascade
## module. qt6-speech supplies QtTextToSpeech (``libQt6TextToSpeech.so``)
## which ktexteditor 6.10.0 REQUIREs via
## ``find_package(Qt6 ... TextToSpeech)``. Without it,
## plasma-workspace's umbrella KF6 probe fails because TextEditor
## refuses to resolve.
##
## sha256 = b0c5fe36c157b0b0cceb89d0d6325e539652f33963f7424cc70300870ce1acdf

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package qt6SpeechSource:
  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtspeech-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtspeech.git"

  fetch:
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtspeech-everywhere-src-6.8.1.tar.xz"
    sha256: "b0c5fe36c157b0b0cceb89d0d6325e539652f33963f7424cc70300870ce1acdf"
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

  library libQt6TextToSpeech:
    discard

  build:
    setCurrentOwningPackageOverride("qt6SpeechSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6TextToSpeech")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
