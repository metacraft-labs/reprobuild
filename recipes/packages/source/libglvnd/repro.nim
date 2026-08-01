## Source build for the GL Vendor-Neutral Dispatch library.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libglvndSource:
  versions:
    "1.7.0":
      sourceRevision = "v1.7.0"
      sourceUrl = "https://gitlab.freedesktop.org/api/v4/projects/glvnd%2Flibglvnd/repository/archive.tar.gz?sha=v1.7.0"
      sourceRepository = "https://gitlab.freedesktop.org/glvnd/libglvnd"

  fetch:
    url: "https://gitlab.freedesktop.org/api/v4/projects/glvnd%2Flibglvnd/repository/archive.tar.gz?sha=v1.7.0"
    sha256: "8797914ff69e62d7d89b331cab311b29fff5cfaddae5aae09695a7ccbaf353d7"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "m4"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "libx11"
    "libxext"
    "xorgproto"

  config:
    discard

  library libGL:
    discard
  library libOpenGL:
    discard
  library libEGL:
    discard
  library libGLX:
    discard
  library libGLESv2:
    discard

  build:
    setCurrentOwningPackageOverride("libglvndSource")
    try:
      let opts = @["--disable-static", "--enable-shared", "--enable-x11"]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = opts,
        patchHardcodedFile = true)
      discard pkg.library("libGL")
      discard pkg.library("libOpenGL")
      discard pkg.library("libEGL")
      discard pkg.library("libGLX")
      discard pkg.library("libGLESv2")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "libx11"
    "libxext"
