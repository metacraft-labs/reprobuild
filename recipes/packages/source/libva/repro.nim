import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libvaSource:
  versions:
    "2.22.0":
      sourceRevision = "2.22.0"
      sourceUrl = "https://github.com/intel/libva/archive/refs/tags/2.22.0.tar.gz"
      sourceRepository = "https://github.com/intel/libva"
  fetch:
    url: "https://github.com/intel/libva/archive/refs/tags/2.22.0.tar.gz"
    sha256: "467c418c2640a178c6baad5be2e00d569842123763b80507721ab87eb7af8735"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.56"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libdrm"
  config:
    discard
  library libva:
    discard
  library libvaDrm:
    discard
  build:
    setCurrentOwningPackageOverride("libvaSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "disable_drm=false",
        "with_x11=no",
        "with_glx=no",
        "with_wayland=no",
        "with_win32=no",
        "enable_docs=false",
        "driverdir=/usr/lib/dri",
      ])
      discard pkg.library("libva")
      discard pkg.library("libva-drm")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libdrm"
