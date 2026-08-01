## Source build for libxcvt, the VESA coordinated-video-timing library used
## by Xwayland and compositor DRM backends.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxcvtSource:
  versions:
    "0.1.3":
      sourceRevision = "libxcvt-0.1.3"
      sourceUrl = "https://www.x.org/releases/individual/lib/libxcvt-0.1.3.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcvt"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libxcvt-0.1.3.tar.xz"
    sha256: "a929998a8767de7dfa36d6da4751cdbeef34ed630714f2f4a767b351f2442e01"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.40"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    discard

  config:
    discard

  library libxcvt:
    discard

  executable cvt:
    discard

  build:
    setCurrentOwningPackageOverride("libxcvtSource")
    try:
      let pkg = meson_package(
        srcDir = "./src",
        configureOptions = @["libdir=lib"])
      discard pkg.library("libxcvt")
      discard pkg.executable("cvt")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## libxcvt and cvt only use libc and the platform math library.
    discard
