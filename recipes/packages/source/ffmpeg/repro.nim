## Source build for the FFmpeg library family used by Qt Multimedia and
## KPipeWire. Optional third-party codecs are disabled so the output depends
## only on FFmpeg sources and the platform C runtime.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ffmpegSource:
  versions:
    "7.1.1":
      sourceRevision = "n7.1.1"
      sourceUrl = "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
      sourceRepository = "https://git.ffmpeg.org/ffmpeg.git"

  fetch:
    url: "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
    sha256: "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libAvCodec:
    discard

  library libAvDevice:
    discard

  library libAvFilter:
    discard

  library libAvFormat:
    discard

  library libAvUtil:
    discard

  library libSwResample:
    discard

  library libSwScale:
    discard

  build:
    setCurrentOwningPackageOverride("ffmpegSource")
    try:
      let opts = @[
        "--enable-shared",
        "--disable-static",
        "--disable-programs",
        "--disable-doc",
        "--disable-debug",
        "--disable-autodetect",
        "--disable-x86asm",
        "--enable-pic",
      ]
      let pkg = autotools_package(srcDir = "./src",
        configureOptions = opts)
      discard pkg.library("libAvCodec")
      discard pkg.library("libAvDevice")
      discard pkg.library("libAvFilter")
      discard pkg.library("libAvFormat")
      discard pkg.library("libAvUtil")
      discard pkg.library("libSwResample")
      discard pkg.library("libSwScale")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
