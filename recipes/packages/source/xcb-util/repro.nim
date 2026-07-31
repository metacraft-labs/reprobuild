import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilSource:
  versions:
    "0.4.1":
      sourceRevision = "xcb-util-0.4.1"
      sourceUrl = "https://www.x.org/releases/individual/xcb/xcb-util-0.4.1.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-util"
  fetch:
    url: "https://www.x.org/releases/individual/xcb/xcb-util-0.4.1.tar.xz"
    sha256: "5abe3bbbd8e54f0fa3ec945291b7e8fa8cfd3cccc43718f8758430f94126e512"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "m4"
    "gperf"
  buildDeps:
    "libxcb"
    "xorgproto"
  config:
    discard
  library libxcbUtil:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-util")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
