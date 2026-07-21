## Source build for the X11 extension client library.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxextSource:
  versions:
    "1.3.6":
      sourceRevision = "libXext-1.3.6"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXext-1.3.6.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxext"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libXext-1.3.6.tar.xz"
    sha256: "edb59fa23994e405fdc5b400afdf5820ae6160b94f35e3dc3da4457a16e89753"
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
    "libxau"

  config:
    discard

  library libXext:
    discard

  build:
    setCurrentOwningPackageOverride("libxextSource")
    try:
      let pkg = autotools_package(srcDir = "./src",
        configureOptions = @["--disable-static", "--enable-shared"])
      discard pkg.library("libXext")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "libx11 >=1.8"
