import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilCursorSource:
  versions:
    "0.1.5":
      sourceRevision = "xcb-util-cursor-0.1.5"
      sourceUrl = "https://www.x.org/releases/individual/lib/xcb-util-cursor-0.1.5.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-cursor"
  fetch:
    url: "https://www.x.org/releases/individual/lib/xcb-util-cursor-0.1.5.tar.xz"
    sha256: "0caf99b0d60970f81ce41c7ba694e5eaaf833227bb2cbcdb2f6dc9666a663c57"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "m4"
    "gperf"
  buildDeps:
    "libxcb"
    "xcb-util-image"
    "xcb-util-renderutil"
    "xorgproto"
  config:
    discard
  library libxcbCursor:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilCursorSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-cursor")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
    "xcb-util-image"
    "xcb-util-renderutil"
