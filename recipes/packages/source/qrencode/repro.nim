import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package qrencodeSource:
  versions:
    "4.1.1":
      sourceRevision = "v4.1.1"
      sourceUrl = "https://github.com/fukuchi/libqrencode/archive/refs/tags/v4.1.1.tar.gz"
      sourceRepository = "https://github.com/fukuchi/libqrencode"
  fetch:
    url: "https://github.com/fukuchi/libqrencode/archive/refs/tags/v4.1.1.tar.gz"
    sha256: "5385bc1b8c2f20f3b91d258bf8ccc8cf62023935df2d2676b5b67049f31a049c"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libpng"
  config:
    discard
  library libqrencode:
    discard
  executable qrencode:
    discard
  build:
    setCurrentOwningPackageOverride("qrencodeSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared", "--without-tests",
      ], patchHardcodedFile = true)
      discard pkg.library("libqrencode")
      discard pkg.executable("qrencode")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libpng"
