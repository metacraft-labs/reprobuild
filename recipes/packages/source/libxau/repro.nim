## Source-from-tarball libXau recipe — closes one of xwayland's 9
## leaf x.org library deps (M9.R.27.3 Gap 3 preparation).
##
## libXau is the X11 authority-file helper used by every X11 client
## to read the per-user .Xauthority file and present the cookie
## token at connection time. xwayland's Xwayland binary links against
## it for the xauth protocol exchange.
##
## Vendored at ``recipes/packages/source/libxau/vendor/libXau-1.0.12.tar.xz``.
## sha256 = 74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb
## (282,624 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxauSource:
  versions:
    "1.0.12":
      sourceRevision = "libXau-1.0.12"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXau-1.0.12.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxau"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libXau-1.0.12.tar.xz"
    sha256: "74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb"
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

  config:
    discard
  library libXau:
    discard

  build:
    setCurrentOwningPackageOverride("libxauSource")
    try:
      let opts = @["--disable-static", "--enable-shared"]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libXau")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
