## Source build for the X Resize and Rotate extension client library.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxrandrSource:
  versions:
    "1.5.4":
      sourceRevision = "libXrandr-1.5.4"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXrandr-1.5.4.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxrandr"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libXrandr-1.5.4.tar.xz"
    sha256: "1ad5b065375f4a85915aa60611cc6407c060492a214d7f9daf214be752c3b4d3"
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
    "libxext >=1.3"
    "libxrender >=0.9"

  config:
    discard

  library libXrandr:
    discard

  build:
    setCurrentOwningPackageOverride("libxrandrSource")
    try:
      let pkg = autotools_package(srcDir = "./src",
        configureOptions = @["--disable-static", "--enable-shared"])
      discard pkg.library("libXrandr")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "libx11 >=1.8"
    "libxext >=1.3"
    "libxrender >=0.9"
