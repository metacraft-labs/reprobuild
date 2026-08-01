import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilWmSource:
  versions:
    "0.4.2":
      sourceRevision = "xcb-util-wm-0.4.2"
      sourceUrl = "https://www.x.org/releases/individual/xcb/xcb-util-wm-0.4.2.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-wm"
  fetch:
    url: "https://www.x.org/releases/individual/xcb/xcb-util-wm-0.4.2.tar.xz"
    sha256: "62c34e21d06264687faea7edbf63632c9f04d55e72114aa4a57bb95e4f888a0b"
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
  library libxcbIcccm:
    discard
  library libxcbEwmh:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilWmSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-icccm")
      discard pkg.library("libxcb-ewmh")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
