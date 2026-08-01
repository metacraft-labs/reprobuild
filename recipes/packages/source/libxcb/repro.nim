import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxcbSource:
  versions:
    "1.17.0":
      sourceRevision = "libxcb-1.17.0"
      sourceUrl = "https://www.x.org/releases/individual/lib/libxcb-1.17.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxcb"
  fetch:
    url: "https://www.x.org/releases/individual/lib/libxcb-1.17.0.tar.xz"
    sha256: "599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "python3"
  buildDeps:
    "libxslt"
    "libpthread-stubs"
    "libxau"
    "libxdmcp"
    "xcb-proto"
  config:
    discard
  library libxcb:
    discard
  build:
    setCurrentOwningPackageOverride("libxcbSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libxcb")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libxau"
    "libxdmcp"
