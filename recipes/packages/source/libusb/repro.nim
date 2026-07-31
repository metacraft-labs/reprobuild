import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libusbSource:
  versions:
    "1.0.28":
      sourceRevision = "v1.0.28"
      sourceUrl = "https://github.com/libusb/libusb/archive/refs/tags/v1.0.28.tar.gz"
      sourceRepository = "https://github.com/libusb/libusb"
  fetch:
    url: "https://github.com/libusb/libusb/archive/refs/tags/v1.0.28.tar.gz"
    sha256: "378b3709a405065f8f9fb9f35e82d666defde4d342c2a1b181a9ac134d23c6fe"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "eudev"
  config:
    discard
  library libusb:
    discard
  build:
    setCurrentOwningPackageOverride("libusbSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared", "--enable-udev",
      ], patchHardcodedFile = true)
      discard pkg.library("libusb-1.0")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "eudev"
