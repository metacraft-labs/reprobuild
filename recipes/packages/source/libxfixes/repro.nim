import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxfixesSource:
  versions:
    "6.0.1":
      sourceRevision = "libXfixes-6.0.1"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXfixes-6.0.1.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxfixes"
  fetch:
    url: "https://www.x.org/releases/individual/lib/libXfixes-6.0.1.tar.xz"
    sha256: "b695f93cd2499421ab02d22744458e650ccc88c1d4c8130d60200213abc02d58"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "xorgproto"
    "libx11"
  config:
    discard
  library libXfixes:
    discard
  build:
    setCurrentOwningPackageOverride("libxfixesSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libXfixes")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libx11"
