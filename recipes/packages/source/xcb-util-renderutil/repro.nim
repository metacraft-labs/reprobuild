import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbUtilRenderutilSource:
  versions:
    "0.3.10":
      sourceRevision = "xcb-util-renderutil-0.3.10"
      sourceUrl = "https://www.x.org/releases/individual/xcb/xcb-util-renderutil-0.3.10.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb-render-util"
  fetch:
    url: "https://www.x.org/releases/individual/xcb/xcb-util-renderutil-0.3.10.tar.xz"
    sha256: "3e15d4f0e22d8ddbfbb9f5d77db43eacd7a304029bf25a6166cc63caa96d04ba"
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
  library libxcbRenderUtil:
    discard
  build:
    setCurrentOwningPackageOverride("xcbUtilRenderutilSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb-render-util")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxcb"
