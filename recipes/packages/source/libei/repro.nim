import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libeiSource:
  versions:
    "1.4.1":
      sourceRevision = "1.4.1"
      sourceUrl = "https://gitlab.freedesktop.org/libinput/libei/-/archive/1.4.1/libei-1.4.1.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/libinput/libei"
  fetch:
    url: "https://gitlab.freedesktop.org/libinput/libei/-/archive/1.4.1/libei-1.4.1.tar.gz"
    sha256: "d0e8f18eb3617fbcc3d860bb54a47e17709e94e8e7cb0ae01ae221c67f000872"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.56"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "python3-with-modules"
  config:
    discard
  library libei:
    discard
  library libeis:
    discard
  build:
    setCurrentOwningPackageOverride("libeiSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "documentation=[]",
        "tests=disabled",
        "liboeffis=disabled",
        "libei=enabled",
        "libeis=enabled",
      ])
      discard pkg.library("libei")
      discard pkg.library("libeis")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
