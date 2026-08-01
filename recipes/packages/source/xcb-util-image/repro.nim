import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilImageSource:
  versions:
    "0.4.1":
      sourceRevision = "xcb-util-image-0.4.1"
      sourceUrl = "https://www.x.org/releases/individual/xcb/xcb-util-image-0.4.1.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-image"
  fetch:
    url: "https://www.x.org/releases/individual/xcb/xcb-util-image-0.4.1.tar.xz"
    sha256: "ccad8ee5dadb1271fd4727ad14d9bd77a64e505608766c4e98267d9aede40d3d"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "m4"
    "gperf"
  buildDeps:
    "libxcb"
    "xcb-util"
    "xorgproto"
  config:
    discard
  library libxcbImage:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilImageSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-image")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
    "xcb-util"
