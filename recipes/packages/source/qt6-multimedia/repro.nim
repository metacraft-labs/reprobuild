## Source-from-tarball qt6-multimedia recipe — M9.R.15q.10.5 cascade
## module. qt6-multimedia supplies QtMultimedia + QtSpatialAudio +
## QtMultimediaWidgets / -Quick which qt6-speech REQUIREs at
## configure time (returns early when ``TARGET Qt6::Multimedia`` is
## missing). qt6-speech is in turn REQUIRED by ktexteditor's umbrella
## probe which plasma-workspace's KF6 umbrella REQUIRES.
##
## sha256 = 75fa87134f9afab7f0a62c55a4744799ac79519560d19c8e1d4c32bdd173f953

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package qt6MultimediaSource:
  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtmultimedia-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtmultimedia.git"

  fetch:
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtmultimedia-everywhere-src-6.8.1.tar.xz"
    sha256: "75fa87134f9afab7f0a62c55a4744799ac79519560d19c8e1d4c32bdd173f953"
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
    "qt6-declarative >=6.8"
    "qt6-shadertools >=6.8"
    "ffmpeg >=7.1"
    "pulseaudio >=17.0"
    "libx11 >=1.8"
    "xorgproto"
    "libxext >=1.3"
    "libxrandr >=1.5"

  config:
    discard

  library libQt6Multimedia:
    discard

  build:
    setCurrentOwningPackageOverride("qt6MultimediaSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        "QT_GENERATE_SBOM=OFF",
        # Qt's Linux FFmpeg backend requires PulseAudio client support.
        # PipeWire supplies the compatible server at runtime.
        "INPUT_ffmpeg=yes",
        "FEATURE_pulseaudio=ON",
        "FEATURE_alsa=OFF",
        "FEATURE_gstreamer=OFF",
        "CMAKE_CXX_FLAGS=-I/opt/repro/reprobuild/recipes/packages/source/libx11/.repro/output/install/usr/include -I/opt/repro/reprobuild/recipes/packages/source/xorgproto/.repro/output/install/usr/include -I/opt/repro/reprobuild/recipes/packages/source/libxext/.repro/output/install/usr/include -I/opt/repro/reprobuild/recipes/packages/source/libxrandr/.repro/output/install/usr/include",
        "CMAKE_SHARED_LINKER_FLAGS=-L/opt/repro/reprobuild/recipes/packages/source/libx11/.repro/output/install/usr/lib -L/opt/repro/reprobuild/recipes/packages/source/libxext/.repro/output/install/usr/lib -L/opt/repro/reprobuild/recipes/packages/source/libxrandr/.repro/output/install/usr/lib",
      ]
      let pkg = cmake_package(srcDir = "./src", generator = "Ninja",
        cacheVars = opts, allowSourceWrites = true)
      discard pkg.library("libQt6Multimedia")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "qt6-base >=6.8"
    "qt6-declarative >=6.8"
    "ffmpeg >=7.1"
    "pulseaudio >=17.0"
    "libx11 >=1.8"
    "libxext >=1.3"
    "libxrandr >=1.5"
