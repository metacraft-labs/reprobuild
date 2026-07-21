## Source build for the X Render extension client library.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxrenderSource:
  versions:
    "0.9.12":
      sourceRevision = "libXrender-0.9.12"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXrender-0.9.12.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxrender"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libXrender-0.9.12.tar.xz"
    sha256: "b832128da48b39c8d608224481743403ad1691bf4e554e4be9c174df171d1b97"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "xorgproto"
    "libx11 >=1.8"

  config:
    discard

  library libXrender:
    discard

  build:
    setCurrentOwningPackageOverride("libxrenderSource")
    try:
      let pkg = autotools_package(srcDir = "./src",
        configureOptions = @["--disable-static", "--enable-shared"])
      discard pkg.library("libXrender")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "libx11 >=1.8"
