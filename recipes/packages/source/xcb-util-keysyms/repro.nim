import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilKeysymsSource:
  versions:
    "0.4.1":
      sourceRevision = "xcb-util-keysyms-0.4.1"
      sourceUrl = "https://www.x.org/releases/individual/xcb/xcb-util-keysyms-0.4.1.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-keysyms"
  fetch:
    url: "https://www.x.org/releases/individual/xcb/xcb-util-keysyms-0.4.1.tar.xz"
    sha256: "7c260a5294412aed429df1da2f8afd3bd07b7cba3fec772fba15a613a6d5c638"
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
  library libxcbKeysyms:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilKeysymsSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-keysyms")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
