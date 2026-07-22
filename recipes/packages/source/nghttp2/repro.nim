import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package nghttp2Source:
  versions:
    "1.64.0":
      sourceRevision = "v1.64.0"
      sourceUrl = "https://github.com/nghttp2/nghttp2/releases/download/v1.64.0/nghttp2-1.64.0.tar.xz"
      sourceRepository = "https://github.com/nghttp2/nghttp2"
  fetch:
    url: "https://github.com/nghttp2/nghttp2/releases/download/v1.64.0/nghttp2-1.64.0.tar.xz"
    sha256: "88bb94c9e4fd1c499967f83dece36a78122af7d5fb40da2019c56b9ccc6eb9dd"
    extractStrip: 1
  nativeBuildDeps:
    "gcc >=11"
    "make"
    "pkg-config"
  config:
    discard
  library libNghttp2:
    discard
  build:
    setCurrentOwningPackageOverride("nghttp2Source")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--enable-lib-only", "--disable-static", "--disable-dependency-tracking",
      ])
      discard pkg.library("libNghttp2")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
